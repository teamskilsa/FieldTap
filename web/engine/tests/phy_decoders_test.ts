// The PHY decoders and the extractor on synthetic records built byte by byte (no capture data): every field at its
// documented position, the strict version policy (another version is a counted miss with a "not decodable" entry,
// never a guess), short bodies (malformed, not a crash), the (second, carrier) bins, the 0xB888 counter deltas and
// plain data throughout.

import type { LogRecord } from '../src/diag/record.ts';
import { GPS_EPOCH_UTC_MS, TimeBase } from '../src/diag/timebase.ts';
import { decodeB139 } from '../src/phy/decoders/b139.ts';
import { decodeB173 } from '../src/phy/decoders/b173.ts';
import { decodeB193 } from '../src/phy/decoders/b193.ts';
import { decodeB14D, decodeB14E } from '../src/phy/decoders/csf.ts';
import { decodeB062, decodeB064 } from '../src/phy/decoders/lteMac.ts';
import { decodeB0C1, decodeB0C2 } from '../src/phy/decoders/lteRrc.ts';
import { decodeB887, decodeB888, decodeB97F, q7 } from '../src/phy/decoders/nr.ts';
import { extractPhy, runPhy } from '../src/phy/extract.ts';
import { LteTbsLookup } from '../src/phy/lteTbs.ts';
import { assert, assertEquals } from './assert.ts';

/** A little-endian byte builder. */
class Bytes {
  private readonly b: number[] = [];
  u8(...v: number[]) {
    for (const x of v) this.b.push(x & 0xff);
    return this;
  }
  u16(v: number) {
    return this.u8(v, v >> 8);
  }
  u32(v: number) {
    return this.u8(v, v >>> 8, v >>> 16, v >>> 24);
  }
  u64(v: number) {
    return this.u32(v % 4_294_967_296).u32(Math.floor(v / 4_294_967_296));
  }
  zeros(n: number) {
    for (let i = 0; i < n; i++) this.b.push(0);
    return this;
  }
  bytes(x: Uint8Array) {
    this.b.push(...x);
    return this;
  }
  get length() {
    return this.b.length;
  }
  done() {
    return new Uint8Array(this.b);
  }
}

const value = <V>(d: { kind: string; value?: V }): V => {
  assertEquals(d.kind, 'value');
  return d.value as V;
};

/** A plausible stamp (2030-01-01 plus `ms`), in the modem's 1.25 ms units. */
const T0 = Date.UTC(2030, 0, 1);
const raw = (ms: number) => BigInt(Math.round((T0 + ms - GPS_EPOCH_UTC_MS) / 1.25)) << 16n;
const rec = (code: number, ms: number, body: Uint8Array): LogRecord => ({ code, timestampRaw: raw(ms), body, more: 0 });

// ------------------------------------------------------------------------------------------------ records

const mib = (ver = 2) => new Bytes().u8(ver).u16(123).u32(1_000).u16(512).u8(4).u8(50).done();

function b193(cells: { earfcn: number; pci: number; serving: boolean; carrier: number; rxMap: number; rsrp: number }[], subVersion = 66): Uint8Array {
  // One subpacket per EARFCN; RSRP x16+180*16 is the raw of every per-Rx and combined field (x = (dBm+180)*16).
  const byEarfcn = new Map<number, typeof cells>();
  for (const c of cells) byEarfcn.set(c.earfcn, [...(byEarfcn.get(c.earfcn) ?? []), c]);
  const out = new Bytes().u8(1, byEarfcn.size, 0, 0);
  for (const [earfcn, list] of byEarfcn) {
    const body = new Bytes().u32(earfcn).u16(list.length).u16(0);
    for (const c of list) {
      const r = Math.round((c.rsrp + 180) * 16);
      const q = Math.round((-12 + 30) * 16), s = Math.round((-80 + 110) * 16);
      const w = new Array(13).fill(0);
      w[0] = r << 10;
      w[1] = r << 12;
      w[2] = r << 12;
      w[4] = (r | ((r - 640) << 12)) >>> 0; // Rx3 in the low 12 bits; the combined value 640 units below
      w[5] = (r << 12) >>> 0;
      w[6] = (q | (q << 20)) >>> 0;
      w[7] = ((q << 10) | (q << 20)) >>> 0;
      w[8] = (q | (q << 20)) >>> 0;
      w[9] = s | (s << 11);
      w[10] = s | (s << 11);
      w[11] = s;
      const cell = new Bytes().u32(c.rxMap).zeros(4).u16(c.pci | (c.carrier << 9) | (c.serving ? 0x8000 : 0)).zeros(2).u16(0).zeros(10);
      for (const x of w) cell.u32(x);
      cell.zeros(144 - cell.length);
      body.bytes(cell.done());
    }
    out.u8(0x19, subVersion).u16(body.length + 4).bytes(body.done());
  }
  return out.done();
}

function b173(carrier: number, blocks: { mcs: number; nrb: number; tbs: number; qm: number; crc: boolean }[], layers = 1, version = 50): Uint8Array {
  const r = new Bytes().u16((100 << 4) | 3).u8(layers, blocks.length, carrier).zeros(7);
  for (let j = 0; j < 2; j++) {
    const t = blocks[j];
    if (t) r.u8((t.crc ? 0x80 : 0) | 1).u16(0).u8(0).u16(t.tbs).u8(t.mcs, t.nrb, t.qm).zeros(3);
    else r.zeros(12);
  }
  r.zeros(4);
  return new Bytes().u8(version, 1, 0, 0).bytes(r.done()).done();
}

function b139(carrier: number, nRb: number, tbsBytes: number, modulation: number, powerRaw: number): Uint8Array {
  const r = new Bytes().u16(1_234).u16(carrier).u32((5 << 1) | (nRb << 15)).u16(tbsBytes).u16(512).zeros(24).u8(modulation << 2).zeros(9).u8(powerRaw);
  r.zeros(100 - r.length);
  return new Bytes().u8(162).u16(77 | (1 << 9)).u8(0).u16(0).zeros(2).bytes(r.done()).done();
}

const b14e = (carrier: number, ri: number, cqi0: number, cqi1: number, pmi: number) =>
  new Bytes().u8(164).u32((carrier << 14) | ((ri - 1) << 28)).u32((cqi0 << 7) | (cqi1 << 11) | (pmi << 24)).u8(4).done();

const b14d = (type: number, word6: number, word10: number) => new Bytes().u8(164).u32(type << 26).u8(0).u16(word6).u16(4).u16(word10).u16(0).done();

function b064(grant: number, header: number[]): Uint8Array {
  const sample = new Bytes().u8(0, 3, 0).u16((10 << 4) | 2).u16(grant).u8(0).u16(0).u8(0, 0, header.length).u8(...header);
  const body = new Bytes().u8(1).bytes(sample.done());
  return new Bytes().u8(1, 1, 0, 0).u8(0x08, 7).u16(body.length + 4).bytes(body.done()).done();
}

function b062(ta: number | null, target = -110, ulEarfcn = 19_000, subVersion = 50): Uint8Array {
  const body = new Bytes().u8(6, 0, 1, 0, 1, ta === null ? 1 : 3).u8(12, 0).u16(target & 0xffff).zeros(3).u16(0).u8(0).u16(0).u16(ta ?? 0);
  body.zeros(37 - body.length).u32(ulEarfcn);
  return new Bytes().u8(1, 1, 0, 0).u8(6, subVersion).u16(body.length).bytes(body.done()).done();
}

const q7raw = (v: number) => (((Math.floor(v) & 0xff) << 7) | Math.round((v - Math.floor(v)) * 128)) >>> 0;

function b97f(arfcn: number, ccId: number, servingPci: number, cells: { pci: number; rsrp: number; rsrq: number; beams: number }[], minor = 0): Uint8Array {
  const out = new Bytes().u16(minor).u16(3).zeros(4).u8(1).zeros(11);
  out.u32(arfcn).u8(ccId, cells.length).u16(servingPci).u8(0).zeros(31);
  for (const c of cells) out.u16(c.pci).u16(0).u8(c.beams).zeros(3).u32(q7raw(c.rsrp)).u32(q7raw(c.rsrq)).zeros(84 * c.beams);
  return out.done();
}

function b887(slots: { mcs: number; nrb: number; tbs: number; layers: number; crc: boolean; pci?: number; slot?: number }[], minor = 13): Uint8Array {
  const out = new Bytes().u16(minor).u16(3).zeros(3).u8(slots.length);
  for (const s of slots) {
    const w2 = (7 << 5) | ((s.slot ?? 3) << 15);
    const w4 = ((s.tbs << 5) | (s.mcs << 26)) >>> 0;
    const w5 = (s.nrb | (2 << 11) | ((s.layers - 1) << 29)) >>> 0;
    out.zeros(8).u32(w2).u16(s.pci ?? 3).zeros(2).u32(w4).u32(w5).u8(s.crc ? 1 : 0).zeros(19);
  }
  return out.done();
}

const b888 = (c: { decodes: number; pass: number; fail: number; passBytes: number; failBytes: number }) =>
  new Bytes().u16(1).u16(3).zeros(12).u32(0).u32(0).u32(0).u32(c.decodes).u32(c.pass).u32(c.fail).u32(0).u32(0).u32(0)
    .u64(c.passBytes).u64(c.failBytes).u64(c.passBytes + c.failBytes).u64(0).u64(0).done();

// ------------------------------------------------------------------------------------------------ decoders

Deno.test('phy decoders: LTE MIB and serving cell info read their fields; other versions are misses', () => {
  assertEquals(value(decodeB0C1(mib())), { pci: 123, earfcn: 1_000, sfn: 512, txAntennas: 4, dlBandwidthPrb: 50 });
  assertEquals(decodeB0C1(mib(3)), { kind: 'versionMiss', key: '0xB0C1 v3', version: 'v3' });
  assertEquals(decodeB0C1(new Uint8Array([2, 1, 2])).kind, 'malformed');
  const sci = new Bytes().u8(3).u16(7).u32(1_000).u32(19_000).u8(50, 50).zeros(6).u32(2).zeros(6).done();
  assertEquals(value(decodeB0C2(sci)), { pci: 7, dlEarfcn: 1_000, ulEarfcn: 19_000, dlBandwidthPrb: 50, ulBandwidthPrb: 50, band: 2 });
  assertEquals(decodeB0C2(new Uint8Array([4])).kind, 'versionMiss');
});

Deno.test('phy decoders: 0xB193 per-Rx, combined and filtered measurements, serving flag and SCell index', () => {
  const cells = value(decodeB193(b193([{ earfcn: 1_000, pci: 7, serving: true, carrier: 2, rxMap: 0b0101, rsrp: -95.5 }, { earfcn: 1_000, pci: 9, serving: false, carrier: 0, rxMap: 0b0011, rsrp: -110 }])));
  assertEquals(cells.length, 2);
  const [a, b] = cells;
  assertEquals([a.earfcn, a.pci, a.serving, a.carrier, a.rxMap], [1_000, 7, true, 2, 5]);
  assertEquals(a.rsrpRx, [-95.5, -95.5, -95.5, -95.5]);
  assertEquals([a.rsrp, a.rsrpFiltered, a.rsrqFiltered, a.rssi], [-95.5, -95.5, -12, -80]);
  assertEquals([b.serving, b.pci], [false, 9]);
  assertEquals(decodeB193(b193([{ earfcn: 1, pci: 1, serving: true, carrier: 0, rxMap: 1, rsrp: -90 }], 65)), { kind: 'versionMiss', key: '0xB193 v1/0x19 v65', version: 'v1/0x19 v65' });
  assertEquals(decodeB193(new Uint8Array([1, 1, 0, 0, 0x19])).kind, 'malformed');
});

Deno.test('phy decoders: 0xB173 transport blocks and 0xB139 PUSCH', () => {
  const [r] = value(decodeB173(b173(2, [{ mcs: 20, nrb: 25, tbs: 1_000, qm: 6, crc: true }, { mcs: 31, nrb: 25, tbs: 0, qm: 6, crc: false }], 2)));
  assertEquals([r.sfn, r.subframe, r.layers, r.transportBlocks, r.carrier], [100, 3, 2, 2, 2]);
  assertEquals(r.blocks.map((t) => [t.mcs, t.nRb, t.tbsBytes, t.qm, t.crcOk, t.rntiType, t.harq]), [[20, 25, 1_000, 6, true, 0, 1], [31, 25, 0, 6, false, 0, 1]]);
  assertEquals(decodeB173(b173(0, [], 1, 48)), { kind: 'versionMiss', key: '0xB173 v48', version: 'v48' });
  const [tx] = value(decodeB139(b139(1, 40, 1_479, 3, 150)));
  assertEquals([tx.pci, tx.carrier, tx.nRb, tx.startRb, tx.tbsBytes, tx.codeRate, tx.modulation, tx.powerRaw], [77, 1, 40, 5, 1_479, 0.5, 3, 150]);
});

Deno.test('phy decoders: CSF reports (0xB14E aperiodic, 0xB14D periodic by report type)', () => {
  assertEquals(value(decodeB14E(b14e(1, 2, 11, 9, 12))), { sfn: 0, subframe: 0, carrier: 1, ri: 2, cqiCw0: 11, cqiCw1: 9, widebandPmi: 12, txMode: 4 });
  const ri = value(decodeB14D(b14d(3, 0, 1 << 8)));
  assertEquals([ri.reportType, ri.ri, ri.cqiCw0], [3, 2, undefined]);
  const cqi = value(decodeB14D(b14d(2, (10 << 4) | (6 << 8) | (13 << 12), 0)));
  assertEquals([cqi.cqiCw0, cqi.cqiCw1, cqi.widebandPmi, cqi.ri, cqi.txMode], [10, 6, 13, undefined, 4]);
  assertEquals(decodeB14D(new Uint8Array([142])).kind, 'versionMiss');
});

Deno.test('phy decoders: 0xB064 MAC control elements are walked per TS 36.321, and 0xB062 RACH', () => {
  // Subheaders: PHR (LCID 26, E=1), long BSR (30, E=1), then an SDU on LCID 3 without a length (E=0); the CEs follow.
  const [s] = value(decodeB064(b064(236, [0x20 | 26, 0x20 | 30, 3, 40, 1, 2, 3])));
  assertEquals([s.grantBytes, s.harq, s.headerLength, s.headerConsistent], [236, 3, 7, true]);
  assertEquals(s.controlElements.map((c) => [c.lcid, [...c.payload]]), [[26, [40]], [30, [1, 2, 3]]]);
  const [bad] = value(decodeB064(b064(9, [0x20 | 26, 3, 40, 99])));
  assertEquals(bad.headerConsistent, false, 'a byte the layout does not account for');
  const [a] = value(decodeB062(b062(18, -110, 19_000)));
  assertEquals([a.taRar, a.preambleTargetDbm, a.ulEarfcn, a.preamble], [18, -110, 19_000, 12]);
  assertEquals(value(decodeB062(b062(null)))[0].taRar, null, 'no Msg2 in the bitmask: no TA');
  assertEquals(decodeB062(b062(1, -110, 1, 49)).kind, 'versionMiss');
});

Deno.test('phy decoders: NR measurement (Q7), PDSCH status with the widened fields, and PDSCH stats', () => {
  assertEquals([q7(0), q7(q7raw(-101.5)), q7(q7raw(-11.25))], [null, -101.5, -11.25]);
  const [c] = value(decodeB97F(b97f(174_000, 0, 3, [{ pci: 3, rsrp: -101.5, rsrq: -11.25, beams: 2 }, { pci: 8, rsrp: -110, rsrq: -15, beams: 1 }])));
  assertEquals([c.arfcn, c.ccId, c.servingPci, c.cells.map((x) => [x.pci, x.rsrp, x.rsrq])], [174_000, 0, 3, [[3, -101.5, -11.25], [8, -110, -15]]]);
  assertEquals(decodeB97F(b97f(1, 0, 1, [], 1)), { kind: 'versionMiss', key: '0xB97F 3.1', version: '3.1' });
  // 217 PRB, 4 layers, slot 19 and a TBS above 2^16 bytes need the widths the moving capture showed.
  const [w] = value(decodeB887(b887([{ mcs: 27, nrb: 217, tbs: 140_000, layers: 4, crc: true, slot: 19 }])));
  assertEquals([w.mcs, w.nRb, w.tbsBytes, w.layers, w.slot, w.crcOk, w.harq, w.pci], [27, 217, 140_000, 4, 19, true, 2, 3]);
  // w4 bit 23 is a flag, not part of the TBS.
  const flagged = b887([{ mcs: 5, nrb: 10, tbs: 100, layers: 1, crc: false }]);
  flagged[8 + 16 + 2] |= 0x80;
  assertEquals(value(decodeB887(flagged))[0].tbsBytes, 100);
  assertEquals(decodeB887(b887([], 12)).kind, 'versionMiss');
  assertEquals(value(decodeB888(b888({ decodes: 10, pass: 9, fail: 1, passBytes: 5_000_000_000, failBytes: 10 }))), {
    carrier: 0, slots: 0, decodes: 10, crcPass: 9, crcFail: 1, retx: 0, passBytes: 5_000_000_000, failBytes: 10, tbBytes: 5_000_000_010,
  });
});

// ------------------------------------------------------------------------------------------------ extractor

Deno.test('phy extractor: strict versions, bins per (second, carrier), carriers, RACH, and plain data', () => {
  const records: LogRecord[] = [
    rec(0xb0c1, 0, mib()),
    rec(0xb193, 100, b193([{ earfcn: 1_000, pci: 7, serving: true, carrier: 0, rxMap: 0b1111, rsrp: -90 }, { earfcn: 5_100, pci: 8, serving: true, carrier: 1, rxMap: 0b0011, rsrp: -100 }])),
    rec(0xb193, 400, b193([{ earfcn: 5_100, pci: 8, serving: true, carrier: 1, rxMap: 0b0011, rsrp: -101 }])),
    rec(0xb173, 200, b173(0, [{ mcs: 10, nrb: 20, tbs: 500, qm: 4, crc: true }])),
    rec(0xb173, 300, b173(0, [{ mcs: 10, nrb: 20, tbs: 500, qm: 4, crc: false }])),
    rec(0xb173, 350, b173(1, [{ mcs: 10, nrb: 20, tbs: 250, qm: 4, crc: true }], 4)),
    rec(0xb173, 1_200, b173(0, [{ mcs: 10, nrb: 20, tbs: 125, qm: 4, crc: true }])),
    rec(0xb173, 1_300, b173(0, [], 1, 48)),
    rec(0xb173, 1_310, b173(0, [], 1, 48)),
    rec(0xb139, 250, b139(0, 10, 100, 1, 100)),
    rec(0xb062, 500, b062(18)),
    rec(0xb14e, 600, b14e(0, 2, 11, 9, 12)),
    rec(0xb14d, 590, b14d(3, 0, 0)),
    rec(0xb888, 700, b888({ decodes: 100, pass: 99, fail: 1, passBytes: 1_000, failBytes: 0 })),
    rec(0xb887, 800, b887([{ mcs: 30, nrb: 10, tbs: 100, layers: 1, crc: true }])),
    rec(0xb888, 900, b888({ decodes: 110, pass: 108, fail: 2, passBytes: 26_000, failBytes: 0 })),
    rec(0xb97f, 950, new Uint8Array([0, 0, 3])),
  ];
  const tb = TimeBase.of(records);
  const cap = extractPhy(records, tb, { records: 5, codes: 2 });
  const by = Object.fromEntries(cap.series.map((s) => [s.metric, s]));

  assertEquals(cap.versionMisses, { '0xB173 v48': 2 });
  const miss = cap.availability.find((a) => a.id === 'version-0xB173')!;
  assertEquals([miss.status, miss.codes], ['notDecodedYet', ['0xB173']]);
  assert(miss.reason.startsWith('Not decodable (version 48): FieldTap decodes only version 50') && miss.reason.includes('2 records skipped'), miss.reason);
  assert(cap.availability.some((a) => a.id === 'lteTbsTable'), 'this build has no TS 36.213 table');

  // 1 s bins keyed by (whole UTC second, carrier), at second + 0.5 s: the second 0 carries two carriers.
  assertEquals(by.lte_dl_bler.samples.map((s) => [s.tMs, s.carrier, s.value]), [[500, 0, 50], [500, 1, 0], [1_500, 0, 0]]);
  assertEquals(by.lte_dl_phy_throughput.samples.map((s) => s.value), [0.004, 0.002, 0.001]);
  assertEquals(by.lte_ul_phy_throughput.samples.map((s) => [s.tMs, s.value]), [[500, 0.0008]]);
  // 4 layers with one TB is transmit diversity.
  assertEquals(by.lte_dl_layers.samples.map((s) => [s.value, s.tag ?? null]), [[1, null], [1, null], [4, 'TxD'], [1, null]]);
  // CSI from both records in one time order, tagged by source.
  assertEquals(by.lte_ri.samples.map((s) => [s.tMs, s.value, s.tag]), [[590, 1, 'PUCCH CSF'], [600, 2, 'PUSCH CSF']]);
  // SCell activity and Rx antennas per PCell EARFCN from 0xB193.
  assertEquals(cap.summary.scellActivity, [{ index: 1, earfcn: 5_100, pci: 8, firstMs: 100, lastMs: 400, records: 2, source: '0xB193 serving records with SCell index' }]);
  assertEquals(cap.summary.rxAntennasByEarfcn, { '1000': { '4': 1 } });
  assertEquals(cap.summary.rach, [{ tMs: 500, ta: 18, ulEarfcn: 19_000, preambleTargetDbm: -110, distanceM: 1406.2 }]);
  assertEquals(cap.summary.txAntennasMib, [4]);
  // NR: the retransmission MCS keeps its modulation; the counters give BLER and MAC throughput over 200 ms.
  assertEquals(by.nr_dl_modulation.samples.map((s) => s.value), [6]);
  assertEquals(cap.summary.nrDlActivity, { index: 0, firstMs: 800, lastMs: 800, records: 1, source: '0xB887', pci: 3 });
  assertEquals(by.nr_dl_bler.samples.map((s) => [s.tMs, s.value]), [[900, 10]]);
  assertEquals(by.nr_dl_mac_throughput.samples.map((s) => s.value), [1]);
  assert(!by.nr_ss_rsrp, 'a short 0xB97F body decodes to nothing');

  const checks = Object.fromEntries(cap.checks.map((c) => [c.id, c]));
  assert(checks.b887VsB888 && !checks.b887VsB888.passed, 'one logged slot against ten counted decodes');
  assertEquals(checks.b888CounterIdentity.passed, true);

  const walk = (v: unknown, p: string): void => {
    assert(v !== undefined, `${p} is undefined`);
    if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) walk(x, `${p}.${k}`);
  };
  walk(cap, 'capture');
  JSON.stringify(cap); // plain data: serialisable
});

Deno.test('phy extractor: with a TBS table, UL MCS is derived and the table checks run', () => {
  // A toy table (not 3GPP values: the lookup logic is what is tested): rows[I_TBS][N_PRB - 1] = 8 (I_TBS + 1) N_PRB.
  const rows = Array.from({ length: 11 }, (_, i) => Array.from({ length: 110 }, (_, n) => (i + 1) * 8 * (n + 1)));
  // 100 bytes at 10 PRB = I_TBS 9: PUSCH MCS 9 (QPSK) is the only MCS for it; with 16QAM no MCS fits.
  const records = [rec(0xb139, 10, b139(0, 10, 100, 1, 100)), rec(0xb139, 11, b139(0, 10, 100, 2, 100)), rec(0xb173, 20, b173(0, [{ mcs: 9, nrb: 10, tbs: 100, qm: 2, crc: true }]))];
  const run = runPhy(records, TimeBase.of(records), { records: 0, codes: 0 }, new LteTbsLookup(rows));
  assertEquals(run.stats.ul, { unique: 1, ambiguous: 1, uciOnly: 0, noMatch: 0 });
  assertEquals(run.capture.series.find((x) => x.metric === 'lte_ul_mcs_derived')?.samples.map((x) => x.value), [9]);
  assertEquals(run.stats.dlTbs, { table64: 1, table256: 0, retx: 0, unexplained: 0 });
  assertEquals(run.capture.checks.map((c) => c.id), ['b173TbsTable', 'b139TbsModulation']);
  assert(!run.capture.availability.some((a) => a.id === 'lteTbsTable'));
});
