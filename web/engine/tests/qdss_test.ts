// src/qdss on synthetic traces (nothing capture-derived): each layer's rules on hand-built input, the stats'
// keys and order, split invariance, and a differential run against the Python reference itself on random traces
// (gated on python3 and the reference script being on this machine).

import { writeQmdl } from '../src/diag/qmdl.ts';
import { type DeframeOutput, QdssDeframer } from '../src/qdss/deframer.ts';
import { DIAG_ATID, Deformatter } from '../src/qdss/formatter.ts';
import { classify, splitPackets } from '../src/qdss/packets.ts';
import { ByteQueue } from '../src/qdss/queue.ts';
import { expectedUnits, findPhase, Fragment, PHASE_WINDOW } from '../src/qdss/units.ts';
import { exists, fixture } from '../tools/fixtures.ts';
import { jsonDiff } from '../tools/golden.ts';
import { md5, Md5 } from '../tools/md5.ts';
import { assert, assertEquals, assertThrows } from './assert.ts';
import {
  barePacket, channelUnit, chunksOf, container, contUnit, fillUnit, formatFrames, fragmentUnits, logPacket, PAD_ATID,
  randomStream, type Run, securePacket, SKIP_FRAME, ts2026, tsvOf, withOtherIds,
} from './qdss_support.ts';
import { concat, randomPieces, rng } from './support.ts';

const bytes = (seed: number, n: number) => {
  const r = rng(seed);
  return Uint8Array.from({ length: n }, () => Math.floor(r() * 256));
};

/** Layer 1 alone: the wanted ID's bytes and the per-ID counts. */
function deformat(chunks: Uint8Array[][]): { out: Uint8Array; perId: Record<string, number> } {
  const f = new Deformatter();
  const q = new ByteQueue();
  for (const pieces of chunks) {
    for (const p of pieces) f.feed(p, q);
    f.endChunk();
  }
  return { out: q.bytes.slice(q.start, q.end), perId: f.bytesPerAtid() };
}

/** A units stream through the whole deframer, as one DIAG-only chunk. */
function deframe(stream: Uint8Array): DeframeOutput {
  const d = new QdssDeframer({ index: true });
  d.feed(formatFrames([{ id: DIAG_ATID, bytes: stream }]));
  d.endChunk();
  return d.finish();
}

const qmdlMd5 = (out: DeframeOutput) => {
  const h = new Md5();
  writeQmdl(out.records, (f) => h.update(f));
  return h.hex();
};

/** Everything the deframer outputs, as one comparable string. */
const fingerprint = (out: DeframeOutput) =>
  [qmdlMd5(out), JSON.stringify(out.stats), JSON.stringify(out.secure), JSON.stringify(out.bytesPerAtid), tsvOf(out.index ?? [])].join('\n');

// ------------------------------------------------------------------------------------------------ layer 1

Deno.test('layer 1: formatter frames give back each trace ID\'s bytes, through the fast and the ID-change paths', () => {
  const r = rng(11);
  const ids = [DIAG_ATID, 0x10, 0x00, 0x05];
  const runs: Run[] = Array.from({ length: 400 }, (_, i) => ({ id: ids[Math.floor(r() * 4)], bytes: bytes(i, 1 + Math.floor(r() * (r() < 0.1 ? 400 : 20))) }));
  const frames = formatFrames(runs);
  let fast = 0;
  for (let k = 0; k < frames.length; k += 16) {
    let any = 0;
    for (let i = 0; i < 16; i += 2) any |= frames[k + i];
    if (!(any & 1)) fast++;
  }
  assert(fast > 10 && fast < frames.length / 16 - 10, `${fast} fast-path frames of ${frames.length / 16}`);
  const { out, perId } = deformat([[frames]]);
  assertEquals(md5(out), md5(concat(runs.filter((x) => x.id === DIAG_ATID).map((x) => x.bytes))));
  for (const id of ids) {
    const want = runs.filter((x) => x.id === id).reduce((n, x) => n + x.bytes.length, 0);
    assertEquals(perId['0x' + id.toString(16).padStart(2, '0')], want, `bytes of 0x${id.toString(16)}`);
  }
  // Counter order: IDs as first seen.
  const firstSeen = [...new Set(runs.map((x) => x.id)), PAD_ATID].map((id) => '0x' + id.toString(16).padStart(2, '0'));
  assertEquals(Object.keys(perId), firstSeen);
});

Deno.test('layer 1: an ID change with its aux bit set leaves the next byte to the old ID; f[14] can change the ID', () => {
  const f1 = new Uint8Array(16);
  f1.set([(0x32 << 1) | 1, 0xaa, (0x10 << 1) | 1, 0xbb]);
  for (let i = 2; i < 7; i++) f1.set([0x44, 0x55], 2 * i);
  f1[14] = (0x32 << 1) | 1; // i = 7: an ID change with no byte after it
  f1[15] = 0b0000_0010; // aux bit 1: 0xbb is still 0x32's
  // A frame with no ID byte: 15 data bytes, the even ones' LSBs in aux.
  const f2 = Uint8Array.from({ length: 16 }, (_, i) => (i % 2 ? i : 2 * i));
  f2[15] = 0b1000_0101;
  const { out, perId } = deformat([[concat([f1, f2])]]);
  const want = [0xaa, 0xbb, ...[...f2.subarray(0, 15)].map((b, i) => (i % 2 === 0 && (0b1000_0101 >> (i / 2)) & 1 ? b | 1 : b))];
  assertEquals([...out], want);
  assertEquals(perId, { '0x32': 17, '0x10': 10 });
});

Deno.test('layer 1: f[14] is data whose LSB is aux bit 7; ff ff ff 7f frames are skipped and counted nowhere', () => {
  const f = new Uint8Array(16);
  f.set([(0x32 << 1) | 1, 0x01]);
  for (let i = 1; i < 7; i++) f.set([0x02, 0x03], 2 * i);
  f[14] = 0x08;
  f[15] = 0x80;
  const { out, perId } = deformat([[concat([f, SKIP_FRAME, f])]]);
  const one = [0x01, ...Array(6).fill([0x02, 0x03]).flat(), 0x09];
  assertEquals([...out], [...one, ...one]);
  assertEquals(perId, { '0x32': 28 });
});

Deno.test('layer 1: frames align to each chunk, a shorter tail is dropped, and the ID carries across chunks', () => {
  const runs: Run[] = [{ id: DIAG_ATID, bytes: bytes(1, 5000) }, { id: 0x10, bytes: bytes(2, 30) }, { id: DIAG_ATID, bytes: bytes(3, 3000) }];
  const frames = formatFrames(runs);
  const whole = deformat([[frames]]);
  // Cut inside the first run (so the second chunk starts with no ID byte), each chunk with a junk tail.
  const cut = 16 * 150;
  const chunked = deformat([[concat([frames.subarray(0, cut), bytes(4, 9)])], [concat([frames.subarray(cut), bytes(5, 15)])]]);
  assertEquals(md5(chunked.out), md5(whole.out));
  assertEquals(chunked.perId, whole.perId);
  // The same bytes as one chunk: the tail shifts every later frame and the stream changes.
  const shifted = deformat([[concat([frames.subarray(0, cut), bytes(4, 9), frames.subarray(cut)])]]);
  assert(md5(shifted.out) !== md5(whole.out), 'a tail inside a chunk would misalign the frames after it');
});

Deno.test('layer 1: any split of a chunk deformats the same', () => {
  const frames = formatFrames(withOtherIds(bytes(7, 40_000), 7));
  const whole = deformat([[frames]]);
  for (const seed of [1, 2, 3]) {
    const split = deformat([randomPieces(frames, seed, 37)]);
    assertEquals(md5(split.out), md5(whole.out));
    assertEquals(split.perId, whole.perId);
  }
});

// ------------------------------------------------------------------------------------------------ layer 2

Deno.test('find_phase: the offset with the most unit-shaped units, the first maximum winning', () => {
  assertEquals(findPhase(new Uint8Array(1600).fill(0x03)), 0, 'every phase ties: the first wins');
  const units = concat(Array.from({ length: 200 }, (_, i) => (i % 3 ? contUnit(i % 8, 0x5a) : channelUnit(i % 8, 0x152))));
  for (const p of [0, 3, 8, 15]) assertEquals(findPhase(concat([bytes(p, p), units])), p);
  // A fill unit counts only with its 01*11 tail.
  const fills = concat(Array.from({ length: 50 }, () => fillUnit()));
  assertEquals(findPhase(concat([new Uint8Array(5), fills])), 5);
  const broken = concat([new Uint8Array(5), fills]);
  for (let i = 5; i < broken.length; i += 16) broken[i + 15] = 2;
  assertEquals(findPhase(broken), 0, 'no unit-shaped units anywhere: phase 0');
  assertEquals(findPhase(new Uint8Array(10)), 0, 'shorter than a unit');
});

Deno.test('find_phase: only the first 320,031 bytes count, and the streaming deframer settles on the same phase', () => {
  const units = (n: number) => concat(Array.from({ length: n }, (_, i) => (i % 5 ? contUnit(i % 8, 0x5a) : channelUnit(i % 8, 0x152))));
  // Phase 3 through the sample window, then a shift to phase 10 carrying many more units.
  const head = concat([bytes(1, 3), units(Math.ceil(PHASE_WINDOW / 16))]);
  const tail = concat([bytes(2, 7), units(60_000)]);
  const s = concat([head, tail]);
  assertEquals(findPhase(tail), 7, 'the tail alone has its own phase');
  assertEquals(findPhase(s), 3);
  assertEquals(findPhase(s.subarray(0, PHASE_WINDOW)), 3);
  const d = new QdssDeframer();
  for (const p of randomPieces(formatFrames([{ id: DIAG_ATID, bytes: s }]), 3, 5000)) d.feed(p);
  d.endChunk();
  const out = d.finish();
  assertEquals(out.stats.stats['phase'], 3);
  assertEquals(out.stats.atid32_bytes, s.length);
});

Deno.test('expected_units: bursts of 16 units for 240 bytes, then 12-byte word units', () => {
  const table: [number, number, number][] = [[0, 0, 0], [8, 0, 0], [9, 0, 1], [20, 0, 1], [21, 0, 2], [247, 0, 20], [248, 0, 16], [249, 0, 17], [5, 3, 0], [6, 3, 1], [8 + 480 + 13, 0, 34]];
  for (const [L, pad, n] of table) assertEquals(expectedUnits(L, pad), n, `L=${L} pad=${pad}`);
  // The synthetic encoder writes exactly that many.
  for (let L = 0; L < 800; L += 7) for (const pad of [0, 2, 7]) assertEquals(fragmentUnits({ lane: 0, kind: 1, payload: bytes(L, L), pad }).length - 1, expectedUnits(L, pad));
});

/** A Fragment fed its units directly. */
function assemble(units: Uint8Array[]): Fragment {
  const f = new Fragment(0, 0x152, units[0], 0, true);
  for (const u of units.slice(1)) f.add(u, 0);
  return f;
}

Deno.test('assembly: start-only payloads after the pad, bursts with their displaced bytes, reversed last words', () => {
  const small = bytes(1, 5);
  const f = assemble(fragmentUnits({ lane: 0, kind: 1, payload: small, pad: 3 }));
  assertEquals([[...f.payload()], f.complete, f.units, f.used], [[...small], true, 0, 0]);
  // Two bursts, then word units; every remainder of the last word unit, 0..11.
  for (let rem = 0; rem < 12; rem++) {
    for (const pad of [0, 5]) {
      const payload = bytes(rem, 8 - pad + 480 + 24 + rem);
      const g = assemble(fragmentUnits({ lane: 0, kind: 1, payload, pad }));
      assertEquals(md5(g.payload()), md5(payload), `remainder ${rem}, pad ${pad}`);
      assertEquals([g.complete, g.units, g.used, g.units === expectedUnits(payload.length, pad)], [true, g.units, g.units, true]);
    }
  }
});

Deno.test('assembly: a burst cut short is dropped, a missing word leaves it short, extra units are counted', () => {
  const payload = bytes(2, 8 + 240 + 30);
  const inBurst = assemble(fragmentUnits({ lane: 0, kind: 1, payload, cut: 17 }));
  assertEquals([[...inBurst.payload()], inBurst.complete, inBurst.used, inBurst.units], [[...payload.subarray(0, 8)], false, 0, 2]);
  const noLast = assemble(fragmentUnits({ lane: 0, kind: 1, payload, cut: 1 }));
  assertEquals([md5(noLast.payload()), noLast.complete, noLast.used], [md5(payload.subarray(0, 8 + 240 + 24)), false, 18]);
  const extra = assemble(fragmentUnits({ lane: 0, kind: 1, payload, cut: -2 }));
  assertEquals([md5(extra.payload()), extra.complete, extra.used, extra.units], [md5(payload), true, 19, 21]);
  // Through the deframer: the fits counters.
  const out = deframe(concat([channelUnit(0, 1), ...[1, 0, -2, 17].flatMap((cut) => fragmentUnits({ lane: 0, kind: 2, payload, cut }))]));
  assertEquals(out.stats.fits, { exact: 1, short: 2, extra_units: 1, count_mismatch: 3 });
});

Deno.test('gather by kind: 3+4+5 joined, a 3 ended by a 1 flushed as it stands, orphans, unknown kinds, left open', () => {
  const log = (code: number, n: number) => logPacket(code, ts2026(n), bytes(n, 40 + n));
  const m1 = log(0xb0c0, 1), m2 = log(0xb821, 2), m3 = log(0x1375, 3), m4 = log(0xb0e2, 4);
  const frag = (kind: number, payload: Uint8Array) => fragmentUnits({ lane: 2, kind, payload });
  const out = deframe(concat([
    channelUnit(2, 0x194),
    ...frag(3, m1.subarray(0, 20)), ...frag(4, m1.subarray(20, 40)), ...frag(5, m1.subarray(40)),
    ...frag(3, m2), ...frag(1, m3),
    ...frag(5, bytes(5, 30)), ...frag(4, bytes(6, 30)),
    ...frag(7, bytes(7, 30)), ...frag(2, bytes(8, 30)),
    ...frag(3, m4),
  ]));
  // Keys in the Python's order: first increment.
  assertEquals(JSON.stringify(out.stats.stats), JSON.stringify({
    phase: 0, u_chan: 1, u_start: 10, u_cont: out.stats.stats['u_cont'], messages: 2, gather_flushed_unterminated: 1,
    messages_unterm: 2, gather_orphan_kind5: 1, gather_orphan_kind4: 1, gather_unknown_kind_7: 1, qshrink_f3: 1, gather_left_open: 1,
  }));
  assertEquals(out.stats.fragment_kinds, { '1': 1, '2': 1, '3': 3, '4': 2, '5': 2, '7': 1 });
  assertEquals(JSON.stringify(out.stats.packets), JSON.stringify({ log: 2, log_unterm: 2 }));
  assertEquals(out.index!.map((r) => [r.code, r.form, r.channel]), [
    [0xb0c0, 'plain/log', 0x194], [0xb821, 'plain/log/unterm', 0x194], [0x1375, 'plain/log', 0x194], [0xb0e2, 'plain/log/unterm', 0x194],
  ]);
  assertEquals(md5(out.records[0].body), md5(m1.subarray(16)));
  assertEquals(out.records.map((r) => r.more), [0, 0, 0, 0]);
});

Deno.test('demux: fragments are keyed by channel, not lane; an unbound lane is key None; rebinding orphans units', () => {
  const log = (code: number, n: number) => logPacket(code, ts2026(n), bytes(n, 100));
  const [a, b] = [fragmentUnits({ lane: 0, kind: 1, payload: log(0xb0c0, 1) }), fragmentUnits({ lane: 5, kind: 1, payload: log(0xb0c1, 2) })];
  // a's continuations arrive on lane 3, bound to the same channel as lane 0.
  const aMoved = [a[0], ...a.slice(1).map((u) => Uint8Array.from(u, (x, i) => (i === 0 ? (3 << 5) | 0x03 : x)))];
  const out = deframe(concat([channelUnit(0, 0x100), channelUnit(3, 0x100), ...aMoved, ...b]));
  assertEquals(out.index!.map((r) => [r.code, r.channel, r.complete]), [[0xb0c0, 0x100, true], [0xb0c1, null, true]]);
  assert(tsvOf(out.index!).includes('\tNone\tplain/log\t0xB0C1\t'), 'None in the .tsv, as Python prints it');
  // Lane 0 rebound mid-fragment: the rest of its units look for channel 0x200's fragment and find none.
  const c = fragmentUnits({ lane: 0, kind: 1, payload: log(0xb0c2, 3) });
  const rebound = deframe(concat([channelUnit(0, 0x100), c[0], c[1], channelUnit(0, 0x200), ...c.slice(2)]));
  assertEquals([rebound.stats.stats['u_cont_orphan'], rebound.stats.fits], [c.length - 2, { short: 1, count_mismatch: 1 }]);
  assertEquals(rebound.stats.packets, { log_bad: 1 });
});

// ------------------------------------------------------------------------------------------------ layer 3

Deno.test('layer 3: containers, and each packet form classified as the reference does', () => {
  const body = bytes(9, 30);
  const logA = logPacket(0xb0c0, ts2026(1), body), logB = logPacket(0xb821, ts2026(2), body);
  const split = (m: Uint8Array) => {
    const got: [string, number][] = [];
    splitPackets(m, (form, p) => got.push([form, p.length]));
    return got;
  };
  assertEquals(split(container([logA, logB])), [['multi98', logA.length], ['multi98', logB.length]]);
  assertEquals(split(container([logA, logB], 1)), [['multi98', logA.length]], 'the count limits the packets');
  assertEquals(split(container([logA, new Uint8Array([0x79, 1, 2])], 0)), [['multi98', logA.length], ['multi98', 3]], 'n = 0: until the end');
  assertEquals(split(container([new Uint8Array([0x99, 1]), logA])), [['multi98', 2 + logA.length]], 'not a log packet: the rest is one packet');
  assertEquals(split(new Uint8Array([0x98, 1, 0, 0, 1])), [['plain', 5]], 'too short for a container');
  assertEquals(split(logA.subarray(0, 0)), [['plain', 0]]);

  const kinds = (p: Uint8Array) => classify(p).kind;
  const bad = logA.slice();
  bad[2]++;
  assertEquals(
    [logA, bad, logA.subarray(0, 15), securePacket(0xb8dd, 0n, body), securePacket(0xb8dd, 0n, body).subarray(0, 40), barePacket(0xb0c0, 0n, body),
      barePacket(0, 0n, body), new Uint8Array([0x79]), new Uint8Array([0x99]), new Uint8Array([0x60]), new Uint8Array([0x9d]),
      new Uint8Array([0x9e, 0x02, 0, 0]), new Uint8Array([0x26, 1]), new Uint8Array(0)].map(kinds),
    ['log', 'log_bad', 'log_bad', 'secure', 'secure_bad', 'bare', 'other_0x2a', 'extmsg_0x79', 'qsr4_0x99', 'event_0x60', 'cmd_0x9d', 'other_0x9e', 'other_0x26', 'empty'],
  );
  // A bare entry whose length byte happens to be 0x79 is counted as an extended message, as in the reference.
  assertEquals(kinds(barePacket(0xb0c0, 0n, bytes(1, 0x79 - 12))), 'extmsg_0x79');
  const c = classify(securePacket(0xb8dd, ts2026(7), body));
  assertEquals([c.code, c.tsAt, c.bodyAt], [0xb8dd, 24, 32]);
});

Deno.test('layer 3: records keep log and bare bodies; secure logs are counted per code, not kept', () => {
  const body = bytes(3, 50);
  const msgs = [
    container([logPacket(0xb0c0, ts2026(1), body), logPacket(0xb0c0, ts2026(2), body.subarray(0, 10))]),
    securePacket(0xb8dd, ts2026(3), body), securePacket(0xb8c5, ts2026(4), body), securePacket(0xb8dd, ts2026(5), body),
    container([securePacket(0xb8dd, ts2026(6), body)]),
    barePacket(0x1375, ts2026(7), body),
    new Uint8Array([0x60, 1, 2, 3]),
    new Uint8Array(0),
  ];
  const out = deframe(concat([channelUnit(1, 0xdc), ...msgs.flatMap((m) => fragmentUnits({ lane: 1, kind: 1, payload: m }))]));
  assertEquals(out.secure, { records: 4, codes: 2, byCode: { '0xB8C5': 1, '0xB8DD': 3 } });
  assertEquals(JSON.stringify(out.stats.packets), JSON.stringify({ log: 2, secure: 4, bare: 1, event_0x60: 1, empty: 1 }));
  assertEquals(out.index!.map((r) => [r.form, r.bodyLength]), [['multi98/log', 50], ['multi98/log', 10], ['plain/bare', 50]]);
  assertEquals(md5(out.records[2].body), md5(body));
});

Deno.test('output order: by effective timestamp, stamps inherited per channel, ties in emission order', () => {
  const rec = (lane: number, code: number, ts: bigint) => fragmentUnits({ lane, kind: 1, payload: logPacket(code, ts, bytes(code, 20)) });
  const out = deframe(concat([
    channelUnit(0, 0xa), channelUnit(1, 0xb), channelUnit(2, 0xc),
    ...rec(0, 0x0001, ts2026(100)), ...rec(0, 0x0002, 0n), // inherits 100 from its channel
    ...rec(1, 0x0003, ts2026(50)), ...rec(1, 0x0004, 5n << 40n), // implausible: inherits 50
    ...rec(2, 0x0005, 0n), // nothing to inherit: 0
    ...rec(1, 0x0006, 0n), // inherits 50: ties with 0x0003 and 0x0004, after them
  ]));
  // Emitted as they close (r1 r3 r4, then at the end r2 r5 r6 in opening order), then sorted.
  assertEquals(out.records.map((r) => r.code), [0x0005, 0x0003, 0x0004, 0x0006, 0x0001, 0x0002]);
  assertEquals(out.records.map((r) => r.timestampRaw), [0n, ts2026(50), 5n << 40n, 0n, ts2026(100), 0n], 'the stamps themselves are kept');
  assertEquals(JSON.stringify(out.stats.ts), JSON.stringify({ '2026': 2, other: 1, zero: 3 }));
});

Deno.test('stats: the reference\'s keys; top_codes ties in first-seen order; targets always present', () => {
  const codes = [0x2222, 0x1111, 0x2222, 0xb0c0, 0x1111, 0xb0c0, 0xb0c0];
  const out = deframe(concat([channelUnit(0, 1), ...codes.flatMap((c, i) => fragmentUnits({ lane: 0, kind: 1, payload: logPacket(c, ts2026(i), bytes(i, 9)) }))]));
  const s = out.stats;
  assertEquals(Object.keys(s), ['atid32_bytes', 'chunks', 'stats', 'fits', 'fragment_kinds', 'packets', 'log_records', 'distinct_codes', 'ts', 'incomplete_records', 'targets', 'top_codes']);
  assertEquals(s.top_codes, [['0xB0C0', 3], ['0x2222', 2], ['0x1111', 2]]);
  assertEquals(Object.keys(s.targets), ['0xB0C0', '0xB0C1', '0xB0C2', '0xB0E2', '0xB0E3', '0xB0EC', '0xB0ED', '0xB0E4', '0xB0E5', '0xB821', '0xB825', '0xB826', '0xB80A', '0xB80B', '0xB80C']);
  assertEquals([s.targets['0xB0C0'], s.targets['0xB821'], s.distinct_codes, s.log_records, s.incomplete_records, s.chunks], [3, 0, 3, 7, 0, 1]);
  // An empty trace still has the phase.
  const empty = new QdssDeframer().finish();
  assertEquals([empty.stats.stats, empty.stats.chunks, empty.records.length, empty.stats.top_codes], [{ phase: 0 }, 0, 0, []]);
});

// ------------------------------------------------------------------------------------------------ streaming

Deno.test('random synthetic traces: whole chunks and 10 random splits of them give identical output', () => {
  const stream = randomStream(21, 3000, 6);
  assert(stream.length > PHASE_WINDOW, 'long enough to settle the phase while streaming');
  const chunks = chunksOf(formatFrames(withOtherIds(stream, 21)), 21, true);
  const run = (split: (c: Uint8Array, i: number) => Uint8Array[]) => {
    const d = new QdssDeframer({ index: true });
    chunks.forEach((c, i) => {
      for (const p of split(c, i)) d.feed(p);
      d.endChunk();
    });
    return d.finish();
  };
  const whole = run((c) => [c]);
  assertEquals([whole.stats.stats['phase'], whole.stats.chunks], [6, chunks.length]);
  assert(whole.records.length > 500 && whole.secure.records > 50, `${whole.records.length} records`);
  const want = fingerprint(whole);
  for (let seed = 1; seed <= 10; seed++) assertEquals(fingerprint(run((c, i) => randomPieces(c, seed * 100 + i, 1 + seed * 997))), want, `split ${seed}`);
});

Deno.test('lifecycle: an unended chunk is ended at finish, an empty chunk counts, nothing is accepted after finish', () => {
  const d = new QdssDeframer();
  d.endChunk();
  d.feed(formatFrames([{ id: DIAG_ATID, bytes: concat([channelUnit(0, 1), fillUnit()]) }]));
  const out = d.finish();
  assertEquals([out.stats.chunks, out.stats.stats], [2, { phase: 0, u_chan: 1, u_fill: 1 }]);
  assertThrows(() => d.feed(new Uint8Array(16)));
  assertThrows(() => d.endChunk());
  assertThrows(() => d.finish());
});

// ------------------------------------------------------------------------------------------------ differential

const REFERENCE = fixture('reference/qdss_deframe.py');
// The reference imports fieldtap.diag.hdlc from the checkout it names.
const FIELDTAP_HDLC = new URL('../../../fieldtap/diag/hdlc.py', import.meta.url).pathname;
const python = (() => {
  try {
    return new Deno.Command('python3', { args: ['--version'], stdout: 'null', stderr: 'null' }).outputSync().success;
  } catch {
    return false;
  }
})();

Deno.test({
  name: 'differential: random synthetic traces deframe exactly as qdss_deframe.py does (stats, .tsv, .qmdl, ATID stream)',
  ignore: !python || !exists(REFERENCE) || !exists(FIELDTAP_HDLC),
  fn: async () => {
    for (const [seed, fragments, phase] of [[1, 400, 0], [2, 700, 9], [3, 250, 15], [4, 3000, 4]]) {
      const dir = await Deno.makeTempDir({ prefix: 'qdss-synth-' });
      try {
        const chunks = chunksOf(formatFrames(withOtherIds(randomStream(seed, fragments, phase), seed)), seed, true);
        chunks.forEach((c, i) => Deno.writeFileSync(`${dir}/0x${i.toString(16).toUpperCase().padStart(8, '0')}.bin`, c));
        const py = await new Deno.Command('python3', { args: [REFERENCE, dir, `${dir}/out`, '--name', 'synth'], stdout: 'null', stderr: 'piped' }).output();
        assert(py.success, new TextDecoder().decode(py.stderr));

        const atid = new Md5();
        const d = new QdssDeframer({ index: true, onStream: (b) => atid.update(b) });
        for (const c of chunks) {
          d.feed(c);
          d.endChunk();
        }
        const out = d.finish();
        const pyStats = JSON.parse(Deno.readTextFileSync(`${dir}/out/stats.json`));
        assertEquals(jsonDiff(out.stats, pyStats, { tolerance: 0, ignore: [] }), [], `seed ${seed}: stats`);
        // Byte for byte too, but for 'ts': JS always orders the integer-like key '2026' first.
        const text = (s: Record<string, unknown>) => JSON.stringify({ ...s, ts: null }, null, 1);
        assertEquals(text(out.stats as unknown as Record<string, unknown>), text(pyStats), `seed ${seed}: stats.json text`);
        assertEquals(tsvOf(out.index!), Deno.readTextFileSync(`${dir}/out/synth.tsv`), `seed ${seed}: .tsv`);
        assertEquals(qmdlMd5(out), md5(Deno.readFileSync(`${dir}/out/synth.qmdl`)), `seed ${seed}: .qmdl`);
        assertEquals(atid.hex(), md5(Deno.readFileSync(`${dir}/out/atid32.bin`)), `seed ${seed}: atid32.bin`);
        assertEquals(out.bytesPerAtid, JSON.parse(Deno.readTextFileSync(`${dir}/out/atid32.bin.json`)).bytes_per_atid, `seed ${seed}: bytes per ID`);
        assert(out.records.length > 50, `seed ${seed}: ${out.records.length} records`);
      } finally {
        await Deno.remove(dir, { recursive: true });
      }
    }
  },
});
