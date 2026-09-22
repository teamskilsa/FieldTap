// diag/: HDLC framing, log packets, the qmdl2 container and the D1 time base, on synthetic bytes.

import { crc16, GOOD_CRC, hdlcEncode, Unframer, unescape } from '../src/diag/hdlc.ts';
import { encodeLogPacket, hexCode, type LogRecord, logPacketsOf, NotALogPacket, parseLogPacket } from '../src/diag/record.ts';
import { readQmdl, recordsPerCode, writeQmdl } from '../src/diag/qmdl.ts';
import { GPS_EPOCH_UTC_MS, modemMs, TimeBase, utcMs } from '../src/diag/timebase.ts';
import { assert, assertAlmost, assertEquals, assertThrows } from './assert.ts';
import { concat, randomPieces } from './support.ts';

const enc = new TextEncoder();

Deno.test('crc16 is CRC-16/X-25: check value 0x906E, and a frame with its CRC checks to GOOD_CRC', () => {
  assertEquals(crc16(enc.encode('123456789')), 0x906e);
  const payload = new Uint8Array([0x10, 0x00, 0x7e, 0x7d, 0x01]);
  const c = crc16(payload);
  assertEquals(crc16(concat([payload, new Uint8Array([c & 0xff, c >> 8])])), GOOD_CRC);
});

Deno.test('hdlcEncode escapes 0x7D/0x7E (CRC bytes too) and ends with one flag; unescape inverts it', () => {
  const payload = new Uint8Array([0x7e, 0x01, 0x7d, 0x02]);
  const frame = hdlcEncode(payload);
  assertEquals(frame[frame.length - 1], 0x7e);
  assertEquals([...frame.subarray(0, 6)], [0x7d, 0x5e, 0x01, 0x7d, 0x5d, 0x02]);
  assertEquals(frame.indexOf(0x7e), frame.length - 1, 'no flag inside the frame');
  const body = unescape(frame, 0, frame.length - 1);
  assertEquals([...body.subarray(0, 4)], [...payload]);
  assertEquals(crc16(body), GOOD_CRC);
  // Find a payload whose CRC itself contains an escapable byte, and check it round-trips.
  for (let x = 0; x < 4096; x++) {
    const p = new Uint8Array([x & 0xff, x >> 8, 0x33]);
    const c = crc16(p);
    if ([c & 0xff, c >> 8].some((b) => b === 0x7e || b === 0x7d)) {
      const got: Uint8Array[] = [];
      new Unframer().feed(hdlcEncode(p), (f) => got.push(f));
      assertEquals(got.map((g) => [...g]), [[...p]]);
      return;
    }
  }
  throw new Error('no payload with an escapable CRC byte found');
});

Deno.test('Unframer yields the same frames for any split, counts CRC errors and drops them', () => {
  const payloads = Array.from({ length: 40 }, (_, i) => new Uint8Array(Array.from({ length: 1 + (i * 37) % 300 }, (_, j) => (i * 31 + j * 7) % 256)));
  const good = concat(payloads.map(hdlcEncode));
  const bad = hdlcEncode(new Uint8Array([1, 2, 3, 4]));
  bad[1] ^= 0xff; // corrupt a byte (not a flag)
  const stream = concat([good, bad, new Uint8Array([0x7e, 0x7e]), hdlcEncode(new Uint8Array([9, 9]))]);
  const expect = [...payloads.map((p) => [...p]), [9, 9]];
  for (const seed of [1, 2, 3, 4, 5]) {
    const u = new Unframer();
    const got: number[][] = [];
    for (const piece of randomPieces(stream, seed, 97)) u.feed(piece, (f) => got.push([...f]));
    assertEquals(got, expect, `split seed ${seed}`);
    assertEquals(u.crcErrors, 1);
    assertEquals(u.frames, 41);
    assertEquals(u.pending, 0);
  }
  // One byte at a time.
  const u = new Unframer();
  let n = 0;
  for (let i = 0; i < stream.length; i++) u.feed(stream.subarray(i, i + 1), () => n++);
  assertEquals(n, 41);
});

Deno.test('a frame shorter than its CRC is a CRC error, and a trailing lone escape is dropped', () => {
  const u = new Unframer();
  u.feed(new Uint8Array([0x01, 0x7e]), () => {});
  assertEquals(u.crcErrors, 1);
  assertEquals([...unescape(new Uint8Array([1, 0x7d]))], [1]);
});

function record(code: number, ts: bigint, body: number[], more = 0): LogRecord {
  return { code, timestampRaw: ts, body: new Uint8Array(body), more };
}

Deno.test('encodeLogPacket lays out <BBHHHQ> + body, and parseLogPacket reads it back exactly', () => {
  const r = record(0xb0c0, 0x0112_3456_789a_bcden, [1, 2, 3], 0);
  const p = encodeLogPacket(r);
  assertEquals([...p.subarray(0, 8)], [0x10, 0, 15, 0, 15, 0, 0xc0, 0xb0]);
  assertEquals(p.length, 16 + 3);
  const back = parseLogPacket(p);
  assertEquals(back.code, 0xb0c0);
  assertEquals(back.timestampRaw, 0x0112_3456_789a_bcden);
  assertEquals([...back.body], [1, 2, 3]);
  assertEquals(hexCode(0xb0c0), '0xB0C0');
  assertEquals(hexCode(0x11eb), '0x11EB');
});

Deno.test('parseLogPacket trusts the inner length only when the bytes agree, and rejects non-log packets', () => {
  const p = encodeLogPacket(record(0x1234, 5n, [1, 2, 3, 4]));
  assertEquals([...parseLogPacket(p.subarray(0, 18)).body], [1, 2], 'cut short: keep what arrived');
  const longer = concat([p, new Uint8Array([9, 9])]);
  assertEquals([...parseLogPacket(longer).body], [1, 2, 3, 4], 'extra bytes after the stated length are not body');
  assertThrows(() => parseLogPacket(new Uint8Array(15).fill(0x10)), (e) => e instanceof NotALogPacket);
  assertThrows(() => parseLogPacket(new Uint8Array(20)), (e) => e instanceof NotALogPacket);
});

Deno.test('logPacketsOf unwraps a qmdl2 (0x98) container by each packet length, and ignores other frames', () => {
  const a = encodeLogPacket(record(0xb0c0, 1n, [1]));
  const b = encodeLogPacket(record(0xb0c1, 2n, [2, 2]));
  const header = new Uint8Array([0x98, 1, 0, 0, 2, 0, 0, 0]);
  const packets = logPacketsOf(concat([header, a, b]));
  assertEquals(packets.map((x) => parseLogPacket(x).code), [0xb0c0, 0xb0c1]);
  const counted = logPacketsOf(concat([new Uint8Array([0x98, 1, 0, 0, 1, 0, 0, 0]), a, b]));
  assertEquals(counted.length, 1, 'the count is honoured');
  assertEquals(logPacketsOf(new Uint8Array([0x79, 1, 2])).length, 0);
  assertEquals(logPacketsOf(new Uint8Array(0)).length, 0);
});

Deno.test('readQmdl / writeQmdl round-trip and recordsPerCode sorts by code', () => {
  const records = [record(0xb193, 10n, [1, 0x7e]), record(0x11eb, 20n, [0x7d]), record(0xb193, 30n, [])];
  const frames: Uint8Array[] = [];
  const bytes = writeQmdl(records, (f) => frames.push(f));
  const file = concat(frames);
  assertEquals(bytes, file.length);
  const read = readQmdl(file);
  assertEquals(read.frames, 3);
  assertEquals(read.crcErrors, 0);
  assertEquals(read.records.map((r) => [r.code, r.timestampRaw, [...r.body]]), records.map((r) => [r.code, r.timestampRaw, [...r.body]]));
  assertEquals(recordsPerCode(read.records), { '0x11EB': 1, '0xB193': 2 });
  assertEquals(Object.keys(recordsPerCode(read.records)), ['0x11EB', '0xB193']);
});

// A raw stamp for a Unix time on the 1.25 ms grid (whole multiples of 5 ms are): the inverse of modemMs.
const rawAt = (unixMs: number, frac = 0) => (BigInt(Math.round((unixMs - GPS_EPOCH_UTC_MS) / 1.25)) << 16n) | BigInt(frac);

Deno.test('modemMs reads 1.25 ms units and 1/32 of them at 1.2288 MHz; utcMs truncates and rejects pre-2005', () => {
  assertEquals(modemMs(1n << 16n), 1.25);
  assertAlmost(modemMs(0xffffn), 0xffff / 39_321.6, 1e-12);
  const t = Date.UTC(2026, 8, 21, 19, 42, 5, 985);
  assertEquals(utcMs(rawAt(t)), t);
  assertEquals(utcMs(rawAt(t, 30000)), t, 'the fraction (< 1 ms) truncates');
  assertEquals(utcMs(0n), null);
  assertEquals(utcMs(rawAt(Date.UTC(2004, 11, 31))), null, 'before 2005: no network time');
  assertEquals(utcMs(1n << 63n), null, 'a negative Long in Kotlin');
});

Deno.test('TimeBase D1: measure from the first plausible stamp; fall back to the first non-zero one', () => {
  const t0 = Date.UTC(2026, 8, 21, 19, 42, 5, 985);
  const early = rawAt(Date.UTC(1980, 0, 7)); // before network time
  const recs = [0n, early, rawAt(t0), 0n, rawAt(t0 + 1000), rawAt(Date.UTC(1980, 0, 8)), rawAt(t0 + 26_959)];
  const tb = new TimeBase();
  recs.forEach((r) => tb.add(r));
  assertEquals(tb.firstRaw, rawAt(t0));
  assertEquals(tb.lastRaw, rawAt(t0 + 26_959), 'the last plausible stamp, not the last non-zero one');
  assertAlmost(tb.durationMs, 26_959, 1.25);
  assertEquals(tb.startUtcMs, t0);
  assertEquals(tb.sinceStartMs(0n), null);
  assertAlmost(tb.sinceStartMs(rawAt(t0 + 1000))!, 1000, 1.25);
  assert(tb.sinceStartMs(early)! < 0, 'an implausible stamp before the base is negative, as in Kotlin');
  const none = new TimeBase();
  [0n, early, rawAt(Date.UTC(1980, 0, 7, 0, 0, 2))].forEach((r) => none.add(r));
  assertEquals(none.firstRaw, early, 'no plausible stamp: the first non-zero one');
  assertEquals(none.startUtcMs, null);
  assertAlmost(none.durationMs, 2000, 1.25);
  assertEquals(new TimeBase().durationMs, 0);
});
