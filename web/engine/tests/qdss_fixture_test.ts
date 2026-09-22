// src/qdss against the Python deframer's own outputs for the qdss-first3 and qdss-attach4 chunk sets
// (fixture-gated; read in place from $FT_FIXTURES): the .qmdl, the .tsv index, stats.json byte for byte, the
// ATID-0x32 stream (atid32.bin) and its per-ID byte counts, all by md5 from each set's manifest. Then first3 fed
// in 50 random splits deframes identically. Only md5s and counts are compared or printed.

import { writeQmdl } from '../src/diag/qmdl.ts';
import { type DeframeOutput, QdssDeframer } from '../src/qdss/deframer.ts';
import { fixture, gate } from '../tools/fixtures.ts';
import { readJson } from '../tools/golden.ts';
import { md5, Md5 } from '../tools/md5.ts';
import { assert, assertEquals } from './assert.ts';
import { tsvOf } from './qdss_support.ts';
import { randomPieces } from './support.ts';

// deno-lint-ignore no-explicit-any
type Manifest = any;

const SETS = [
  { set: 'qdss-first3', name: 'first3', qmdl: '8bee416586647da91511a952c527c272' },
  { set: 'qdss-attach4', name: 'attach4', qmdl: '245d59fc9af24e3acb5535966de6946d' },
];

async function chunksOf(set: string): Promise<{ manifest: Manifest; chunks: Uint8Array[] }> {
  const manifest: Manifest = await readJson(fixture(`${set}/manifest.json`));
  // The deframer's inputs: 0x*.bin in name order (header.qmdl2 is a descriptor, not stream data).
  const names = Object.keys(manifest.inputs).filter((n) => /^0x[0-9A-F]+\.bin$/i.test(n)).sort();
  const chunks = await Promise.all(names.map((n) => Deno.readFile(fixture(`${set}/chunks/${n}`))));
  chunks.forEach((c, i) => assertEquals(md5(c), manifest.inputs[names[i]].md5, `${set} input ${names[i]}`));
  return { manifest, chunks };
}

function qmdlMd5(out: DeframeOutput): string {
  const h = new Md5();
  writeQmdl(out.records, (f) => h.update(f));
  return h.hex();
}

const text = (s: string) => md5(new TextEncoder().encode(s));

for (const { set, name, qmdl } of SETS) {
  Deno.test({
    name: `${set}: .qmdl, .tsv, stats.json, atid32.bin and bytes per ID equal the Python deframer's`,
    ignore: gate(fixture(`${set}/manifest.json`), fixture(`${set}/expected/atid32.bin.json`)),
    fn: async () => {
      const { manifest, chunks } = await chunksOf(set);
      const outputs = manifest.outputs;
      const stream = new Md5();
      const d = new QdssDeframer({ index: true, onStream: (b) => stream.update(b) });
      for (const c of chunks) {
        d.feed(c);
        d.endChunk();
      }
      const out = d.finish();
      assertEquals(qmdlMd5(out), qmdl, `${name}.qmdl`);
      assertEquals(qmdlMd5(out), outputs[`${name}.qmdl`].md5);
      assertEquals(text(tsvOf(out.index!)), outputs[`${name}.tsv`].md5, `${name}.tsv`);
      assertEquals(text(JSON.stringify(out.stats, null, 1)), outputs['stats.json'].md5, 'stats.json, byte for byte');
      assertEquals(stream.hex(), outputs['atid32.bin'].md5, 'atid32.bin');
      assertEquals(out.stats.atid32_bytes, outputs['atid32.bin'].bytes);
      const meta: Manifest = await readJson(fixture(`${set}/expected/atid32.bin.json`));
      assertEquals(out.bytesPerAtid, meta.bytes_per_atid);
      assertEquals(out.secure.records, manifest.counters.packets.secure, 'every secure packet counted');
    },
  });
}

Deno.test({
  name: 'qdss-first3 fed in 50 random splits (1 byte to 64 KiB pieces) deframes identically',
  ignore: gate(fixture('qdss-first3/manifest.json')),
  fn: async () => {
    const { chunks } = await chunksOf('qdss-first3');
    const run = (split: (c: Uint8Array, i: number) => Uint8Array[]) => {
      const d = new QdssDeframer({ index: true });
      chunks.forEach((c, i) => {
        for (const p of split(c, i)) d.feed(p);
        d.endChunk();
      });
      const out = d.finish();
      return [qmdlMd5(out), JSON.stringify(out.stats), JSON.stringify(out.secure), JSON.stringify(out.bytesPerAtid), text(tsvOf(out.index!))].join('\n');
    };
    const want = run((c) => [c]);
    assert(want.startsWith('8bee416586647da91511a952c527c272'));
    for (let seed = 1; seed <= 50; seed++) {
      // Piece sizes from 1..17 bytes (seed 1) up to 1..64 KiB, so frames and units are cut everywhere.
      const max = Math.max(17, Math.round(65_536 * (seed / 50) ** 2));
      assertEquals(run((c, i) => randomPieces(c, seed * 10 + i, max)), want, `split ${seed} (pieces up to ${max} bytes)`);
    }
  },
});
