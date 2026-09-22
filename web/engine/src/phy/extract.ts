// A port of the numbers, not the code, of the validated reference extractor (Fixtures/local/reference-phy
// kpis.py), as FTPhy's PhyExtractor.swift ports it: the same sample selection and derivations, but only what the
// records carry, with no cell tables. Records are decoded per code in time order (the reference's order), and
// every per-second bin is keyed by (whole UTC second, carrier index) at second + 0.5 s (CONTRACT.md, PHY parity:
// phy-golden-v1.json / phy-summary-v1.json). Only the record versions validated on this modem are decoded; any
// other version is counted in versionMisses, never guessed.

import { hexCode, type LogRecord } from '../diag/record.ts';
import { GPS_EPOCH_UTC_MS, modemMs, type TimeBase, utcMs } from '../diag/timebase.ts';
import type { Availability, EncryptedCensus, PhyCheck, PhyMetric, PhySample, PhySeries, PhySummary, RachEvent } from '../types.ts';
import { availability } from './catalog.ts';
import { phyChecks } from './checks.ts';
import type { Decoded } from './decoders/bytes.ts';
import { type CellMeasurement, decodeB193, measured, rxCount } from './decoders/b193.ts';
import { decodeB173, type PdschRecord } from './decoders/b173.ts';
import { decodeB139, puschQm, type PuschTransmission, requiredPowerDbm } from './decoders/b139.ts';
import { decodeB14D, decodeB14E, type PucchCsf, type PuschCsf } from './decoders/csf.ts';
import { decodeB062, decodeB064, type MacUlSample, type RachAttempt } from './decoders/lteMac.ts';
import { decodeB0C1, decodeB0C2, type Mib } from './decoders/lteRrc.ts';
import { decodeB887, decodeB888, decodeB97F, type NrCarrierMeasurement, type NrPdschCounters, type NrPdschSlot } from './decoders/nr.ts';
import { BUILT_IN_TBS, type LteTbsLookup } from './lteTbs.ts';
import { finish } from './finish.ts';
import { nrMcs, nrQm, nrTbsBits } from './nrTbs.ts';
import { PHY_CODES, TAG } from './metrics.ts';
import { lteTimingAdvanceMetres } from '../signalling/spectrum.ts';

export interface PhyCapture {
  /** One series per metric that had samples, in PhyMetric order. Sample times are ms since `timeBase`. */
  series: PhySeries[];
  summary: PhySummary;
  /** The QDSS secure-record census, passed through for the 'Not available' page and the findings. */
  encrypted: EncryptedCensus;
  checks: PhyCheck[];
  /** '0xB173 v48' -> records skipped. */
  versionMisses: Record<string, number>;
  availability: Availability[];
}

export const EMPTY_PHY_SUMMARY: PhySummary = { scellActivity: [], rach: [], txAntennasMib: [], rxAntennasByEarfcn: {} };

/** Every PHY series, the PHY summary the journey reads, the self-checks and the availability entries. */
export function extractPhy(records: readonly LogRecord[], timeBase: TimeBase, secure: EncryptedCensus): PhyCapture {
  return runPhy(records, timeBase, secure, BUILT_IN_TBS).capture;
}

/** The extraction with the counts behind the self-checks, against a given TBS table (tests pass the reference's). */
export function runPhy(records: readonly LogRecord[], timeBase: TimeBase, secure: EncryptedCensus, tbs: LteTbsLookup): PhyRun {
  const x = new Extraction(timeBase, tbs);
  x.decode(records);
  return finish(x, secure, (stats, tbsAvailable) => phyChecks(stats, tbsAvailable), availability);
}

export interface PhyRun {
  capture: PhyCapture;
  stats: PhyStats;
}

/** The raw counts behind PhyCheck, for the tests and the Decoder health page. */
export interface PhyStats {
  /** Per Rx antenna: mean, population sd and count of RSRQ - (RSRP - RSSI + 10log10(N_RB)) in dB. */
  rsrqResidual: Map<number, { mean: number; sd: number; n: number }>;
  rsrqWithinQuarterDb: number;
  rsrqResiduals: number;
  /** EARFCN -> N_RB inferred from the same identity. */
  inferredPrb: Map<number, number>;
  dlTbs: { table64: number; table256: number; retx: number; unexplained: number };
  ul: { unique: number; ambiguous: number; uciOnly: number; noMatch: number };
  /** New transmissions whose TBS fits TS 38.214, and (negative control) how many would also fit at MCS + 1. */
  nrTbs: { matched: number; retx: number; unexplained: number; controlMatched: number };
  /** 0xB887 sums against the 0xB888 counter deltas over the same window. */
  nr: {
    b887Records: number;
    b887CrcFail: number;
    b887PassBytes: number;
    deltaDecodes?: number;
    deltaCrcFail?: number;
    deltaPassBytes?: number;
  };
  /** 0xB888 records whose pass + fail = decodes and pass + fail bytes = TB bytes. */
  b888Identity: { holds: number; records: number };
  macSamples: number;
  macConsistent: number;
  /** Records of a validated version too short for their own layout, per code. */
  malformed: Record<string, number>;
  /** PHY records without a usable stamp (zero, or before network time in a capture that has it), per code. */
  unstamped: Record<string, number>;
}

/** The sample fields besides tMs and value; only the defined ones are written (plain data for the UI). */
interface SampleExtra {
  perIndex?: (number | null)[];
  carrier?: number;
  earfcn?: number;
  pci?: number;
  tag?: string;
}

/** The N'RE per PRB values the NR TBS check tries: 12 subcarriers x 8-13 symbols less DMRS and overhead. With
 *  only 120-150 the moving capture's n77 carrier fits 744 of 828 (it also uses 114 and 156). So many values let a
 *  wrong MCS fit too, which the check reports as a negative control (MCS + 1): a shifted field fails outright
 *  (0 of 828 with the old 0xB887 widths). */
export const NR_RE_PER_PRB: readonly number[] = [96, 102, 108, 114, 120, 126, 132, 138, 144, 150, 156];

/** One extraction pass: decoders feed samples and counters in; finish.ts builds the capture. */
export class Extraction {
  readonly samples = new Map<PhyMetric, PhySample[]>();
  readonly versionMisses: Record<string, number> = {};
  readonly missVersions = new Map<string, Set<string>>();
  readonly recordsPerCode = new Map<number, number>();
  readonly stats: PhyStats = {
    rsrqResidual: new Map(),
    rsrqWithinQuarterDb: 0,
    rsrqResiduals: 0,
    inferredPrb: new Map(),
    dlTbs: { table64: 0, table256: 0, retx: 0, unexplained: 0 },
    ul: { unique: 0, ambiguous: 0, uciOnly: 0, noMatch: 0 },
    nrTbs: { matched: 0, retx: 0, unexplained: 0, controlMatched: 0 },
    nr: { b887Records: 0, b887CrcFail: 0, b887PassBytes: 0 },
    b888Identity: { holds: 0, records: 0 },
    macSamples: 0,
    macConsistent: 0,
    malformed: {},
    unstamped: {},
  };
  /** Unix ms of the time base, when the capture has network time (bins then sit on whole UTC seconds). */
  readonly startUtcMs: number | null;

  // 0xB193
  readonly rsrqTerms: { earfcn: number; rx: number; rsrq: number; rsrp: number; rssi: number }[] = [];
  readonly scells = new Map<string, { index: number; earfcn: number; pci: number; first: number; last: number; n: number }>();
  readonly rxByEarfcn = new Map<number, Map<number, number>>();
  // 0xB173 / 0xB139 bins: 'second/carrier' -> (TBs, CRC fails, pass bits) / scheduled bits
  readonly dlBins = new Map<string, { second: number; carrier: number; n: number; fail: number; bits: number }>();
  readonly ulBins = new Map<string, { second: number; carrier: number; bits: number }>();
  // 0xB062 / 0xB0C1
  readonly rach: RachEvent[] = [];
  readonly txAntennas = new Set<number>();
  // 0xB887 / 0xB888
  readonly nrTimes: number[] = [];
  readonly nrPcis = new Set<number>();
  readonly nrCounters: { tMs: number; c: NrPdschCounters }[] = [];

  constructor(readonly timeBase: TimeBase, readonly tbs: LteTbsLookup) {
    this.startUtcMs = timeBase.startUtcMs === null ? null : GPS_EPOCH_UTC_MS + modemMs(timeBase.firstRaw);
  }

  // ------------------------------------------------------------------------------------------------- time

  /** Ms since the time base, or null for an unstamped record or one stamped before network time in a capture that
   *  has it (the reference interpolates those from the trace position; none of the 12 PHY codes has one). */
  tMs(raw: bigint): number | null {
    const ms = this.timeBase.sinceStartMs(raw);
    if (ms === null) return null;
    if (this.startUtcMs !== null && utcMs(raw) === null) return null;
    return ms;
  }

  /** The whole second a record falls in: UTC when the capture has network time, else since the start. */
  second(raw: bigint, tMs: number): number {
    return this.startUtcMs !== null ? Math.floor((GPS_EPOCH_UTC_MS + modemMs(raw)) / 1000) : Math.floor(tMs / 1000);
  }

  /** A bin's centre (second + 0.5 s) in ms since the time base. */
  binCentre(second: number): number {
    return second * 1000 + 500 - (this.startUtcMs ?? 0);
  }

  add(metric: PhyMetric, tMs: number, value: number | null, extra: SampleExtra = {}): void {
    const s: PhySample = { tMs, value };
    if (extra.perIndex !== undefined) s.perIndex = extra.perIndex;
    if (extra.carrier !== undefined) s.carrier = extra.carrier;
    if (extra.earfcn !== undefined) s.earfcn = extra.earfcn;
    if (extra.pci !== undefined) s.pci = extra.pci;
    if (extra.tag !== undefined) s.tag = extra.tag;
    let list = this.samples.get(metric);
    if (!list) this.samples.set(metric, (list = []));
    list.push(s);
  }

  // ----------------------------------------------------------------------------------------------- decode

  decode(records: readonly LogRecord[]): void {
    const byCode = new Map<number, number[]>(PHY_CODES.map((c) => [c, []]));
    records.forEach((r, i) => {
      this.recordsPerCode.set(r.code, (this.recordsPerCode.get(r.code) ?? 0) + 1);
      byCode.get(r.code)?.push(i);
    });
    for (const code of PHY_CODES) {
      // The reference reads each code in time order; ties keep file order.
      const order = byCode.get(code)!;
      order.sort((a, b) => {
        const ra = records[a].timestampRaw, rb = records[b].timestampRaw;
        return ra < rb ? -1 : ra > rb ? 1 : a - b;
      });
      for (const i of order) {
        const r = records[i];
        const t = this.tMs(r.timestampRaw);
        if (t === null) {
          const k = hexCode(code);
          this.stats.unstamped[k] = (this.stats.unstamped[k] ?? 0) + 1;
          continue;
        }
        this.record(code, r, t);
      }
    }
  }

  private handle<V>(code: number, d: Decoded<V>, body: (v: V) => void): void {
    if (d.kind === 'value') body(d.value);
    else if (d.kind === 'versionMiss') {
      this.versionMisses[d.key] = (this.versionMisses[d.key] ?? 0) + 1;
      const k = hexCode(code);
      if (!this.missVersions.has(k)) this.missVersions.set(k, new Set());
      this.missVersions.get(k)!.add(d.version);
    } else {
      const k = hexCode(code);
      this.stats.malformed[k] = (this.stats.malformed[k] ?? 0) + 1;
    }
  }

  private record(code: number, r: LogRecord, t: number): void {
    const b = r.body;
    switch (code) {
      case 0xb0c1:
        return this.handle(code, decodeB0C1(b), (m) => this.mib(m, t));
      case 0xb0c2:
        return this.handle(code, decodeB0C2(b), (s) => this.add('lte_band', t, s.band, { carrier: 0, earfcn: s.dlEarfcn, pci: s.pci }));
      case 0xb193:
        return this.handle(code, decodeB193(b), (cells) => cells.forEach((c) => this.measurement(c, t)));
      case 0xb173:
        return this.handle(code, decodeB173(b), (recs) => recs.forEach((p) => this.pdsch(p, r.timestampRaw, t)));
      case 0xb139:
        return this.handle(code, decodeB139(b), (txs) => txs.forEach((tx) => this.pusch(tx, r.timestampRaw, t)));
      case 0xb14e:
        return this.handle(code, decodeB14E(b), (c) => this.puschCsf(c, t));
      case 0xb14d:
        return this.handle(code, decodeB14D(b), (c) => this.pucchCsf(c, t));
      case 0xb064:
        return this.handle(code, decodeB064(b), (ss) => ss.forEach((s) => this.macUl(s, t)));
      case 0xb062:
        return this.handle(code, decodeB062(b), (as) => as.forEach((a) => this.rachAttempt(a, t)));
      case 0xb97f:
        return this.handle(code, decodeB97F(b), (cs) => cs.forEach((c) => this.nrMeasurement(c, t)));
      case 0xb887:
        return this.handle(code, decodeB887(b), (slots) => slots.forEach((s) => this.nrSlot(s, t)));
      case 0xb888:
        return this.handle(code, decodeB888(b), (c) => this.nrCounter(c, t));
    }
  }

  private mib(m: Mib, t: number): void {
    const where = { carrier: 0, earfcn: m.earfcn, pci: m.pci };
    this.add('lte_tx_antennas_mib', t, m.txAntennas, where);
    this.add('lte_dl_bandwidth_prb', t, m.dlBandwidthPrb, where);
    this.txAntennas.add(m.txAntennas);
  }

  private measurement(c: CellMeasurement, t: number): void {
    const where: SampleExtra = c.serving ? { carrier: c.carrier, earfcn: c.earfcn, pci: c.pci } : { earfcn: c.earfcn, pci: c.pci, tag: TAG.neighbour };
    if (c.serving) {
      this.add('lte_rsrp', t, c.rsrp, where);
      this.add('lte_rsrp_filtered', t, c.rsrpFiltered, where);
      this.add('lte_rsrq_filtered', t, c.rsrqFiltered, where);
      this.add('lte_rssi', t, c.rssi, where);
    } else {
      this.add('lte_neighbour_rsrp', t, c.rsrp, where);
      this.add('lte_neighbour_rsrp_filtered', t, c.rsrpFiltered, where);
      this.add('lte_neighbour_rsrq_filtered', t, c.rsrqFiltered, where);
      this.add('lte_neighbour_rssi', t, c.rssi, where);
    }
    const n = rxCount(c);
    this.add('lte_rx_antennas_measured', t, n, where);
    const perRx = (v: number[]) => [0, 1, 2, 3].map((k) => (measured(c, k) ? v[k] : null));
    this.add('lte_rsrp_per_rx', t, null, { ...where, perIndex: perRx(c.rsrpRx) });
    this.add('lte_rsrq_per_rx', t, null, { ...where, perIndex: perRx(c.rsrqRx) });
    this.add('lte_rssi_per_rx', t, null, { ...where, perIndex: perRx(c.rssiRx) });
    for (let k = 0; k < 4; k++) {
      if (measured(c, k)) this.rsrqTerms.push({ earfcn: c.earfcn, rx: k, rsrq: c.rsrqRx[k], rsrp: c.rsrpRx[k], rssi: c.rssiRx[k] });
    }
    if (c.serving && c.carrier >= 1) {
      const key = `${c.carrier}/${c.earfcn}/${c.pci}`;
      const s = this.scells.get(key);
      if (s) {
        s.first = Math.min(s.first, t);
        s.last = Math.max(s.last, t);
        s.n++;
      } else this.scells.set(key, { index: c.carrier, earfcn: c.earfcn, pci: c.pci, first: t, last: t, n: 1 });
    }
    if (c.serving && c.carrier === 0) {
      let counts = this.rxByEarfcn.get(c.earfcn);
      if (!counts) this.rxByEarfcn.set(c.earfcn, (counts = new Map()));
      counts.set(n, (counts.get(n) ?? 0) + 1);
    }
  }

  private pdsch(r: PdschRecord, raw: bigint, t: number): void {
    r.blocks.forEach((tb, j) => {
      if (tb.rntiType !== 0 || tb.qm === 0) return; // C-RNTI traffic only
      const layers = (r.transportBlocks === 2 && r.layers === 4) || (r.transportBlocks === 2 && r.layers === 3 && j === 1) ? 2 : 1;
      const bits = tb.tbsBytes * 8;
      if (this.tbs.isAvailable) {
        const d = this.stats.dlTbs;
        if (tb.mcs >= 29) d.retx++;
        else if (bits === this.tbs.dl(tb.mcs, tb.nRb, layers, false)) d.table64++;
        else if (bits === this.tbs.dl(tb.mcs, tb.nRb, layers, true)) d.table256++;
        else d.unexplained++;
      }
      const where = { carrier: r.carrier, tag: `CW${j}` };
      this.add('lte_dl_mcs', t, tb.mcs, where);
      this.add('lte_dl_prb', t, tb.nRb, where);
      this.add('lte_dl_tbs', t, tb.tbsBytes, where);
      this.add('lte_dl_modulation', t, tb.qm, where);
      this.add('lte_dl_crc_ok', t, tb.crcOk ? 1 : 0, where);
      const second = this.second(raw, t), key = `${second}/${r.carrier}`;
      const bin = this.dlBins.get(key) ?? { second, carrier: r.carrier, n: 0, fail: 0, bits: 0 };
      bin.n++;
      if (tb.crcOk) bin.bits += bits;
      else bin.fail++;
      this.dlBins.set(key, bin);
    });
    const first = r.blocks[0];
    if (first && first.rntiType === 0) {
      // 4 layers with one transport block is transmit diversity (one layer of data), not 4-layer MIMO.
      const tag = r.layers === 4 && r.transportBlocks === 1 ? TAG.txDiversity : r.layers === 3 ? TAG.unverified : undefined;
      this.add('lte_dl_layers', t, r.layers, tag ? { carrier: r.carrier, tag } : { carrier: r.carrier });
    }
  }

  private pusch(tx: PuschTransmission, raw: bigint, t: number): void {
    if (tx.nRb === 0) return;
    const qm = puschQm(tx);
    let mcs: number[] = [];
    if (this.tbs.isAvailable) {
      const u = this.stats.ul;
      if (tx.tbsBytes === 0) u.uciOnly++;
      else {
        const found = this.tbs.ulMcs(tx.tbsBytes * 8, tx.nRb, qm);
        mcs = found.mcs;
        if (mcs.length === 1) u.unique++;
        else if (found.matchesTable) u.ambiguous++;
        else u.noMatch++;
      }
    }
    const where = { carrier: tx.carrier, pci: tx.pci };
    this.add('lte_ul_prb', t, tx.nRb, where);
    this.add('lte_ul_tbs', t, tx.tbsBytes, where);
    this.add('lte_ul_modulation', t, qm, where);
    this.add('lte_ul_code_rate', t, tx.codeRate, where);
    if (mcs.length === 1) this.add('lte_ul_mcs_derived', t, mcs[0], where);
    this.add('lte_pusch_tx_power_required', t, requiredPowerDbm(tx), where);
    const second = this.second(raw, t), key = `${second}/${tx.carrier}`;
    const bin = this.ulBins.get(key) ?? { second, carrier: tx.carrier, bits: 0 };
    bin.bits += tx.tbsBytes * 8;
    this.ulBins.set(key, bin);
  }

  private puschCsf(c: PuschCsf, t: number): void {
    const where = { carrier: c.carrier, tag: TAG.puschCsf };
    this.add('lte_cqi_wideband_cw0', t, c.cqiCw0, where);
    if (c.ri > 1) this.add('lte_cqi_wideband_cw1', t, c.cqiCw1, where);
    this.add('lte_ri', t, c.ri, where);
    this.add('lte_pmi_wideband', t, c.widebandPmi, where);
    this.add('lte_csf_tx_mode', t, c.txMode, where);
  }

  private pucchCsf(c: PucchCsf, t: number): void {
    const where = { carrier: c.carrier, tag: TAG.pucchCsf };
    if (c.ri !== undefined) this.add('lte_ri', t, c.ri, where);
    if (c.cqiCw0 !== undefined && c.widebandPmi !== undefined) {
      this.add('lte_cqi_wideband_cw0', t, c.cqiCw0, where);
      this.add('lte_pmi_wideband', t, c.widebandPmi, where);
    }
  }

  private macUl(s: MacUlSample, t: number): void {
    this.stats.macSamples++;
    if (s.headerConsistent) this.stats.macConsistent++;
    for (const ce of s.controlElements) {
      if (ce.lcid === 26 && ce.payload.length > 0) this.add('lte_power_headroom', t, (ce.payload[0] & 63) - 23, { carrier: s.carrier });
    }
    this.add('lte_mac_ul_grant', t, s.grantBytes, { carrier: s.carrier });
  }

  private rachAttempt(a: RachAttempt, t: number): void {
    if (a.taRar === null) return;
    this.add('lte_timing_advance_rar', t, a.taRar, { carrier: 0 });
    const e: RachEvent = { tMs: t, ta: a.taRar, ulEarfcn: a.ulEarfcn, preambleTargetDbm: a.preambleTargetDbm };
    const m = lteTimingAdvanceMetres(a.taRar);
    if (m !== null) e.distanceM = Math.round(m * 10) / 10;
    this.rach.push(e);
  }

  private nrMeasurement(c: NrCarrierMeasurement, t: number): void {
    for (const cell of c.cells) {
      const where: SampleExtra = { earfcn: c.arfcn, pci: cell.pci, tag: c.servingPci === cell.pci ? TAG.serving : TAG.neighbour };
      // CC id 255: measured as a candidate before the SCG was added, so on no serving carrier yet.
      if (c.ccId !== 255) where.carrier = c.ccId;
      if (cell.rsrp !== null) this.add('nr_ss_rsrp', t, cell.rsrp, where);
      if (cell.rsrq !== null) this.add('nr_ss_rsrq', t, cell.rsrq, where);
    }
  }

  private nrSlot(s: NrPdschSlot, t: number): void {
    const fits = (mcs: number) => {
      const e = nrMcs('qam256', mcs);
      return e !== null && NR_RE_PER_PRB.some((n) => nrTbsBits(n, s.nRb, e[0], e[1] / 1024, s.layers) === s.tbsBytes * 8);
    };
    const m = this.stats.nrTbs;
    if (nrMcs('qam256', s.mcs)) {
      if (fits(s.mcs)) m.matched++;
      else m.unexplained++;
      if (fits(s.mcs + 1)) m.controlMatched++;
    } else m.retx++;
    const where = { carrier: 0, pci: s.pci };
    this.add('nr_dl_mcs', t, s.mcs, where);
    this.add('nr_dl_prb', t, s.nRb, where);
    this.add('nr_dl_layers', t, s.layers, where);
    this.add('nr_dl_tbs', t, s.tbsBytes, where);
    const qm = nrQm('qam256', s.mcs);
    if (qm !== null) this.add('nr_dl_modulation', t, qm, where);
    this.add('nr_dl_crc_ok', t, s.crcOk ? 1 : 0, where);
    const n = this.stats.nr;
    n.b887Records++;
    if (s.crcOk) n.b887PassBytes += s.tbsBytes;
    else n.b887CrcFail++;
    this.nrTimes.push(t);
    this.nrPcis.add(s.pci);
  }

  private nrCounter(c: NrPdschCounters, t: number): void {
    const id = this.stats.b888Identity;
    id.records++;
    if (c.crcPass + c.crcFail === c.decodes && c.passBytes + c.failBytes === c.tbBytes) id.holds++;
    this.nrCounters.push({ tMs: t, c });
  }
}
