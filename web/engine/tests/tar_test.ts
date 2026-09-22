// archive/tar.ts and archive/stream.ts on synthetic archives.

import { readArchive, ArchiveError } from '../src/archive/stream.ts';
import { type TarEntry, TarError, type TarHeader, TarReader } from '../src/archive/tar.ts';
import { assert, assertEquals, assertRejects, assertThrows } from './assert.ts';
import { buildTar, gzip, randomPieces, randomSizes, streamOf, type TarSpec } from './support.ts';

const enc = new TextEncoder();
const dec = new TextDecoder();
const ROOT = 'sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84';
const LONG_DIR = `${ROOT}/logs/${'deep/'.repeat(12)}end`; // 130 bytes: over the 100-byte name, within the 155-byte prefix

const SPECS: TarSpec[] = [
  { path: `${ROOT}/`, type: '5' },
  { path: `${ROOT}/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss/0x000000F0.bin`, data: new Uint8Array(1500).fill(0xf0) },
  { path: `${ROOT}/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss/._0x000000F0.bin`, data: 'appledouble' },
  { path: `${ROOT}/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss/0x0000006F.bin`, data: new Uint8Array(512).fill(0x6f) },
  { path: `${ROOT}/big.bin`, data: new Uint8Array(3000).fill(7), base256: true },
  { path: `${LONG_DIR}/posix-prefix.txt`, data: 'posix' },
  { path: `${LONG_DIR}/gnu-long-name.txt`, data: 'gnu', format: 'gnu' },
  { path: 'short-in-header.txt', data: 'pax', pax: { path: `${LONG_DIR}/pax-path.txt`, mtime: '1790019725.5' } },
  { path: `${ROOT}/empty.txt`, data: '' },
  { path: `${ROOT}/link`, type: '2' },
];

function collect(tar: Uint8Array, pieces: Uint8Array[], select = (_h: TarHeader) => true) {
  const entries: TarEntry[] = [];
  const headers: string[] = [];
  const r = new TarReader({ select, onEntry: (e) => entries.push(e), onHeader: (h) => headers.push(h.path) });
  for (const p of pieces) r.feed(p);
  r.finish();
  return { r, entries, headers, tarLength: tar.length };
}

Deno.test('TarReader: ustar prefix, GNU long name, pax path/mtime, base-256 size; AppleDouble skipped', () => {
  const tar = buildTar(SPECS);
  const { r, entries, headers } = collect(tar, [tar]);
  assertEquals(entries.map((e) => e.path), [
    SPECS[1].path,
    SPECS[3].path,
    `${ROOT}/big.bin`,
    `${LONG_DIR}/posix-prefix.txt`,
    `${LONG_DIR}/gnu-long-name.txt`,
    `${LONG_DIR}/pax-path.txt`,
    `${ROOT}/empty.txt`,
  ]);
  assertEquals(entries.map((e) => e.size), [1500, 512, 3000, 5, 3, 3, 0]);
  assert(entries[0].bytes.every((b) => b === 0xf0) && entries[2].bytes.every((b) => b === 7));
  assertEquals(dec.decode(entries[5].bytes), 'pax');
  assertEquals(entries[5].mtimeS, 1790019725.5);
  assertEquals(headers.length, 10, 'every real entry is seen, pax and long-name headers are not');
  assertEquals(r.counts.appleDoubleSkipped, 1);
  assertEquals(r.counts.selected, 7);
  assertEquals(r.counts.entries, 10);
  assert(r.ended);
});

Deno.test('TarReader: identical results for any split of the stream, down to one byte at a time', () => {
  const tar = buildTar(SPECS);
  const whole = collect(tar, [tar]).entries.map((e) => [e.path, [...e.bytes].reduce((a, b) => (a * 31 + b) >>> 0, 0)]);
  for (const seed of [11, 12, 13]) {
    const split = collect(tar, randomPieces(tar, seed, 700)).entries.map((e) => [e.path, [...e.bytes].reduce((a, b) => (a * 31 + b) >>> 0, 0)]);
    assertEquals(split, whole, `seed ${seed}`);
  }
  const bytes = [...Array(tar.length).keys()].map((i) => tar.subarray(i, i + 1));
  assertEquals(collect(tar, bytes).entries.length, 7);
});

Deno.test('TarReader: unselected bodies are skipped without being kept', () => {
  const tar = buildTar(SPECS);
  const { entries, r } = collect(tar, [tar], (h) => h.path.endsWith('.bin') && h.path.includes('qdss'));
  assertEquals(entries.map((e) => e.path.split('/').pop()), ['0x000000F0.bin', '0x0000006F.bin']);
  assertEquals(r.counts.selectedBytes, 2012);
});

Deno.test('TarReader: a bad checksum is notTar at the start and corrupt later; a cut body is truncated', () => {
  const tar = buildTar(SPECS);
  const first = tar.slice();
  first[10] ^= 1;
  assertThrows(() => collect(first, [first]), (e) => e instanceof TarError && e.kind === 'notTar');
  const later = tar.slice();
  later[512 * 5 + 10] ^= 1; // the third header: directory (block 0), chunk header (1), its 1500-byte body (2-4)
  assertThrows(() => collect(later, [later]), (e) => e instanceof TarError && e.kind === 'corrupt');
  const cut = tar.subarray(0, 512 + 700);
  assertThrows(() => collect(cut, [cut]), (e) => e instanceof TarError && e.kind === 'truncated');
});

async function drain(stream: ReadableStream<Uint8Array>, opts: { stopAfter?: number } = {}) {
  const entries: string[] = [];
  const result = await readArchive(stream, {
    select: () => true,
    onEntry: (e) => entries.push(e.path),
    shouldStop: opts.stopAfter === undefined ? undefined : () => entries.length >= opts.stopAfter!,
  });
  return { entries, result };
}

Deno.test('readArchive: gzip and plain tar, any split of the compressed stream, same entries', async () => {
  const tar = buildTar(SPECS);
  const gz = await gzip(tar);
  const plain = await drain(streamOf(tar, [333]));
  assertEquals(plain.result.format, 'tar');
  for (const seed of [1, 2]) {
    const z = await drain(streamOf(gz, randomSizes(seed, 50, 90)));
    assertEquals(z.result.format, 'gzip');
    assertEquals(z.entries, plain.entries);
    assertEquals(z.result.compressedBytes, gz.length);
    assertEquals(z.result.uncompressedBytes >= tar.length - 1024, true);
    assertEquals(z.result.stoppedEarly, false);
  }
});

Deno.test('readArchive: shouldStop ends the read early and cancels the source', async () => {
  const filler: TarSpec[] = Array.from({ length: 200 }, (_, i) => ({ path: `${ROOT}/f${i}`, data: new Uint8Array(4096).fill(i) }));
  const gz = await gzip(buildTar(filler));
  let pulled = 0;
  const source = streamOf(gz, [512]);
  const counting = source.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({ transform(c, ctl) { pulled += c.length; ctl.enqueue(c); } }));
  const { entries, result } = await drain(counting, { stopAfter: 3 });
  assert(result.stoppedEarly);
  assert(entries.length >= 3 && entries.length < 200, `${entries.length} entries`);
  assert(pulled < gz.length, `read ${pulled} of ${gz.length} compressed bytes`);
});

Deno.test('readArchive: not an archive, a truncated gzip, and a damaged gzip', async () => {
  await assertRejects(() => drain(streamOf(enc.encode('PK\x03\x04 this is a zip, not a sysdiagnose'.padEnd(600, '.')))),
    (e) => e instanceof ArchiveError && e.kind === 'notArchive');
  await assertRejects(() => drain(streamOf(new Uint8Array(0))), (e) => e instanceof ArchiveError && e.kind === 'notArchive');
  const gz = await gzip(buildTar(SPECS));
  const cut = await assertRejects(() => drain(streamOf(gz.subarray(0, Math.floor(gz.length * 0.6)), [100])),
    (e) => e instanceof ArchiveError && e.kind === 'truncated');
  assert(String((cut as Error).message).length > 0);
  const damaged = gz.slice();
  for (let i = 20; i < 60; i++) damaged[i] ^= 0x5a;
  await assertRejects(() => drain(streamOf(damaged, [64])), (e) => e instanceof ArchiveError && (e.kind === 'corrupt' || e.kind === 'truncated'));
  // A gzip of something that is not a tar.
  const notTar = await gzip(enc.encode('hello '.repeat(200)));
  await assertRejects(() => drain(streamOf(notTar)), (e) => e instanceof ArchiveError && e.kind === 'notArchive');
});

Deno.test('readArchive: an aborted signal rejects with an AbortError', async () => {
  const gz = await gzip(buildTar(SPECS));
  const controller = new AbortController();
  controller.abort();
  await assertRejects(() => readArchive(streamOf(gz), { select: () => true, onEntry: () => {}, signal: controller.signal }),
    (e) => e instanceof DOMException && e.name === 'AbortError');
  const late = new AbortController();
  await assertRejects(() => readArchive(streamOf(gz, [40]), { select: () => true, onEntry: () => late.abort(), signal: late.signal }),
    (e) => e instanceof DOMException && e.name === 'AbortError');
});

Deno.test('TarReader: a pax size record applies to the entry after an intervening GNU long-name header', () => {
  const long = `${LONG_DIR}/pax-size-then-gnu.bin`;
  const data = new Uint8Array(700).fill(9);
  // pax 'x' (size=700) + GNU 'L' + a header whose own size field says 0: the pax size must win for the entry.
  const tar = buildTar([{ path: long, data, format: 'gnu', pax: { size: '700' } }]);
  const h = tar.slice();
  // Zero the real header's size field: pax header + body (0, 512), L header (1024) + body, then the entry.
  const at = 512 * 3 + 512 * Math.ceil((long.length + 1) / 512);
  h.fill(0x30, at + 124, at + 135);
  let sum = 0;
  for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 0x20 : h[at + i];
  h.set(new TextEncoder().encode(sum.toString(8).padStart(6, '0') + '\0 '), at + 148);
  const { entries } = collect(h, [h]);
  assertEquals(entries.map((e) => [e.path, e.size]), [[long, 700]]);
  assert(entries[0].bytes.every((b) => b === 9));
});
