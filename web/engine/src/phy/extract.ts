// A port of the numbers, not the code, of the validated reference extractor (Fixtures/local/reference-phy
// kpis.py), as FTPhy's PhyExtractor.swift ports it: the same sample selection and derivations, but only what the
// records carry, with no cell tables. Records are decoded per code in time order (the reference's order), and
// every per-second bin is keyed by (whole UTC second, carrier index) at second + 0.5 s (CONTRACT.md, PHY parity:
// phy-golden-v1.json / phy-summary-v1.json). Only the record versions validated on this modem are decoded; any
// other version is counted in versionMisses, never guessed.

import { hexCode, type LogRecord } from '../diag/record.ts';
import { GPS_EPOCH_UTC_MS, modemMs, type TimeBase, utcMs } from '../diag/timebase.ts';
import type {
  Availability,
  EncryptedCensus,
  PhyCheck,
  PhyMetric,
  PhySample,
  PhySeries,
  PhySummary,
  RachEvent,
} from '../types.ts';
import { availability } from './catalog.ts';
import { phyChecks } from './checks.ts';
import type { Decoded } from './decoders/bytes.ts';
import { type CellMeasurement, decodeB193, measured, rxCount } from './decoders/b193.ts';
import { decodeB173, type PdschRecord } from './decoders/b173.ts';
import { decodeB139, puschQm, type PuschTransmission, requiredPowerDbm } from './decoders/b139.ts';
import { decodeB14D, decodeB14E, type PucchCsf, type PuschCsf } from './decoders/csf.ts';
import {
  decodeB062,
  decodeB063,
  decodeB064,
  dlChannelKind,
  type MacDlRecord,
  type MacUlSample,
  type RachAttempt,
  TIMING_ADVANCE_LCID,
} from './decoders/lteMac.ts';
import { decodeB126, type PdschDemapperSubframe } from './decoders/b126.ts';
import { decodeB12A, type PcfichRecord } from './decoders/b12a.ts';
import { type DciRecord, decodeB16C } from './decoders/b16c.ts';
import { decodeB179, type IntraFreqMeasurement } from './decoders/b179.ts';
import { bindingLimitDbm, decodeX184C, type FedTxAgcRecord } from './decoders/fedTxAgc.ts';
import { decodeX1D0B, type ModemClockSample } from './decoders/modemClock.ts';
import { SFN_CYCLE_MS, TtiAxis } from './ttiAxis.ts';
import { decodeB0C1, decodeB0C2, type Mib } from './decoders/lteRrc.ts';
import {
  decodeB887,
  decodeB888,
  decodeB97F,
  type NrCarrierMeasurement,
  type NrPdschCounters,
  type NrPdschSlot,
} from './decoders/nr.ts';
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
export function runPhy(
  records: readonly LogRecord[],
  timeBase: TimeBase,
  secure: EncryptedCensus,
  tbs: LteTbsLookup,
): PhyRun {
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
  /** The measured absolute-TTI axis every LTE cross-record check is keyed on (src/phy/ttiAxis.ts). */
  ttiAxis: { records: number; latencyMs: number; r: number };
  /** 0xB126 against 0xB173 and the MIB, per the research's three identities. */
  b126: {
    subframes: number;
    prbChecked: number;
    prbMatched: number;
    rankChecked: number;
    rankMatched: number;
    rankTxDiversity: number;
    txPortsChecked: number;
    txPortsMatched: number;
  };
  /** 0xB12A elements and the 4 x CFI identity. */
  b12a: { elements: number; consistent: number; decoded: number };
  /** 0xB16C uplink grants against 0xB139's PUSCH reports four subframes later. */
  b16c: {
    records: number;
    exact: number;
    grantSubframes: number;
    precedesPusch: number;
    fieldsChecked: number;
    fieldsMatched: number;
    assignmentSubframes: number;
    assignmentsOnPdsch: number;
  };
  /** 0xB179's length identity and its serving RSRP against 0xB193's for the same cell. */
  b179: {
    records: number;
    malformed: number;
    servingChecked: number;
    servingWithin1Db: number;
    servingWithin3Db: number;
    servingDeltaSum: number;
  };
  /** 0xB063's walk and its transport blocks against 0xB173's. */
  b063: {
    records: number;
    declared: number;
    walked: number;
    exact: number;
    resynced: number;
    tbChecked: number;
    tbMatched: number;
  };
  /** 0x184C's block walk, its subframe identity against 0xB139's PUSCH reports, and how the live chains' power sat
   *  against their own limit. */
  x184c: {
    records: number;
    framed: number;
    blockSteps: number;
    blockStepsByOne: number;
    blocks: number;
    subframesInRange: number;
    live: number;
    withinLimit: number;
    atLimit: number;
  };
  /** 0x1D0B's sequence number, which must not skip. */
  x1d0b: { records: number; steps: number; stepsByOne: number };
  /** Records of a validated version too short for their own layout, per code. */
  malformed: Record<string, number>;
  /** PHY records without a usable stamp (zero, or before network time in a capture that has it), per code. */
  unstamped: Record<string, number>;
}

/** The sample fields besides tMs and value; only the defined ones are written (plain data for the UI). */
interface SampleExtra {
  perIndex?: (number | null)[];
  mask?: number[];
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
    ttiAxis: { records: 0, latencyMs: 0, r: 0 },
    b126: {
      subframes: 0,
      prbChecked: 0,
      prbMatched: 0,
      rankChecked: 0,
      rankMatched: 0,
      rankTxDiversity: 0,
      txPortsChecked: 0,
      txPortsMatched: 0,
    },
    b12a: { elements: 0, consistent: 0, decoded: 0 },
    b16c: {
      records: 0,
      exact: 0,
      grantSubframes: 0,
      precedesPusch: 0,
      fieldsChecked: 0,
      fieldsMatched: 0,
      assignmentSubframes: 0,
      assignmentsOnPdsch: 0,
    },
    b179: { records: 0, malformed: 0, servingChecked: 0, servingWithin1Db: 0, servingWithin3Db: 0, servingDeltaSum: 0 },
    b063: { records: 0, declared: 0, walked: 0, exact: 0, resynced: 0, tbChecked: 0, tbMatched: 0 },
    x184c: {
      records: 0,
      framed: 0,
      blockSteps: 0,
      blockStepsByOne: 0,
      blocks: 0,
      subframesInRange: 0,
      live: 0,
      withinLimit: 0,
      atLimit: 0,
    },
    x1d0b: { records: 0, steps: 0, stepsByOne: 0 },
    malformed: {},
    unstamped: {},
  };
  /** Unix ms of the time base, when the capture has network time (bins then sit on whole UTC seconds). */
  readonly startUtcMs: number | null;

  // 0xB193
  readonly rsrqTerms: { earfcn: number; rx: number; rsrq: number; rsrp: number; rssi: number }[] = [];
  readonly scells = new Map<
    string,
    { index: number; earfcn: number; pci: number; first: number; last: number; n: number }
  >();
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
  // The absolute-TTI axis and what the first twelve codes contribute to it, kept raw until it is sealed.
  readonly axis = new TtiAxis();
  private readonly dlBlocks: {
    tMs: number;
    tti: number;
    carrier: number;
    harq: number;
    sizeBytes: number;
    nRb: number;
    layers: number;
    transportBlocks: number;
  }[] = [];
  private readonly ulReports: { tMs: number; tti: number; startRb: number; nRb: number; modulation: number }[] = [];
  private nRbByTti = new Map<number, Set<number>>();
  private schedulingByTti = new Map<number, { layers: number; transportBlocks: number }[]>();
  private transportBlockKeys = new Set<string>();
  private pdschTtis = new Set<number>();
  private puschByTti = new Map<number, { startRb: number; nRb: number; modulation: number }[]>();
  private sealed = false;
  /** 0xB0C1: 'earfcn/pci' -> the MIB's antenna count, for the 0xB126 antenna-port check. */
  private readonly mibAntennas = new Map<string, number>();
  /** 0xB193 carrier-0 serving records in time order: which cell 0xB126's sub-records belong to. */
  private readonly servingTimeline: { tMs: number; earfcn: number; pci: number }[] = [];
  /** 0xB193 serving measurements per cell, for the 0xB179 RSRP cross-check. */
  private readonly servingRsrp = new Map<string, { tMs: number; rsrp: number }[]>();
  /** Every cell 0xB193 measured at all: a 0xB179 neighbour outside this set is measured by nothing else. */
  private readonly measuredCells = new Set<string>();
  /** Nearest stamped record time per record index: 0xB179 carries no timestamp of its own. */
  private anchorMs: Float64Array = new Float64Array(0);
  // 0xB126 per serving cell
  readonly antennaCells = new Map<string, {
    earfcn: number;
    pci: number;
    txPorts: Map<number, number>;
    rxAntennas: Map<number, number>;
    ranks: Map<number, number>;
    subframes: number;
  }>();
  // 0xB12A
  readonly cfiCounts = new Map<number, number>();
  cfiNotDecoded = 0;
  // 0xB16C
  readonly grants = { grants: 0, assignments: 0, matched: 0, prbGranted: 0, prbSent: 0 };
  // 0xB063
  readonly macDl = {
    records: 0,
    declared: 0,
    walked: 0,
    exact: 0,
    bytes: 0,
    padding: 0,
    timingAdvance: 0,
    channels: new Map<
      number,
      { kind: 'signalling' | 'data' | 'control' | 'broadcast' | 'other'; bytes: number; sdus: number }
    >(),
  };
  readonly macDlBins = new Map<string, { second: number; carrier: number; bytes: number; padding: number }>();
  // 0x184C
  readonly txChains = new Map<
    number,
    { samples: number; live: number; powers: number[]; limits: number[]; atLimit: number; states: Set<number> }
  >();
  // 0xB179
  readonly neighbourCells = new Map<string, {
    earfcn: number;
    pci: number;
    rsrps: number[];
    rsrqs: number[];
    margins: number[];
    first: number;
    last: number;
  }>();
  // 0x1D0B
  readonly clockSamples: { tMs: number; ticks1024: number; sequence: number }[] = [];

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
    if (extra.mask !== undefined) s.mask = extra.mask;
    if (extra.carrier !== undefined) s.carrier = extra.carrier;
    if (extra.earfcn !== undefined) s.earfcn = extra.earfcn;
    if (extra.pci !== undefined) s.pci = extra.pci;
    if (extra.tag !== undefined) s.tag = extra.tag;
    let list = this.samples.get(metric);
    if (!list) this.samples.set(metric, list = []);
    list.push(s);
  }

  // ----------------------------------------------------------------------------------------------- decode

  decode(records: readonly LogRecord[]): void {
    const byCode = new Map<number, number[]>(PHY_CODES.map((c) => [c, []]));
    records.forEach((r, i) => {
      this.recordsPerCode.set(r.code, (this.recordsPerCode.get(r.code) ?? 0) + 1);
      byCode.get(r.code)?.push(i);
    });
    this.anchorMs = anchorTimes(records, (raw) => this.tMs(raw));
    for (const code of PHY_CODES) {
      // The reference reads each code in time order; ties keep file order.
      const order = byCode.get(code)!;
      order.sort((a, b) => {
        const ra = records[a].timestampRaw, rb = records[b].timestampRaw;
        return ra < rb ? -1 : ra > rb ? 1 : a - b;
      });
      for (const i of order) {
        const r = records[i];
        // 0xB179 carries no DIAG timestamp at all - every one of its records arrives stamped zero - so the nearest
        // stamped record in the trace says roughly when it was written and its own TTI fixes the rest.
        const stamp = this.tMs(r.timestampRaw);
        const t = stamp ?? (code === 0xb179 ? this.anchorMs[i] : NaN);
        if (t === null || Number.isNaN(t)) {
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
        return this.handle(
          code,
          decodeB0C2(b),
          (s) => this.add('lte_band', t, s.band, { carrier: 0, earfcn: s.dlEarfcn, pci: s.pci }),
        );
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
      case 0xb126:
        return this.handle(code, decodeB126(b), (subs) => this.pdschDemapper(subs, t));
      case 0xb12a:
        return this.handle(code, decodeB12A(b), (p) => this.pcfich(p, t));
      case 0xb16c:
        return this.handle(code, decodeB16C(b), (d) => this.dci(d, t));
      case 0xb063:
        return this.handle(code, decodeB063(b), (m) => this.macDownlink(m, r.timestampRaw, t));
      case 0x184c:
        return this.handle(code, decodeX184C(b), (f) => this.frontEndTx(f, t));
      case 0x1d0b:
        return this.handle(code, decodeX1D0B(b), (c) => this.modemClock(c, t));
      case 0xb179: {
        const d = decodeB179(b);
        if (d.kind === 'value') this.stats.b179.records++;
        else if (d.kind === 'malformed') this.stats.b179.malformed++;
        return this.handle(code, d, (m) => this.intraFrequency(m, t));
      }
    }
  }

  // ------------------------------------------------------------------------------------------ the TTI axis
  //
  // Sealed on first use, after the first twelve codes have been read: 0xB173's transport blocks and 0xB139's PUSCH
  // reports both carry a subframe and a timestamp, so they measure the logging latency, and the later codes are
  // keyed on the absolute TTI it unwraps (src/phy/ttiAxis.ts).

  private seal(): void {
    if (this.sealed) return;
    this.sealed = true;
    this.axis.seal();
    this.stats.ttiAxis = { records: this.axis.records, latencyMs: this.axis.latencyMs, r: this.axis.r };
    if (!this.axis.usable) return;
    for (const d of this.dlBlocks) {
      const key = this.axis.absolute(d.tMs, d.tti);
      let sizes = this.nRbByTti.get(key);
      if (!sizes) this.nRbByTti.set(key, sizes = new Set());
      sizes.add(d.nRb);
      const scheduling = this.schedulingByTti.get(key);
      const entry = { layers: d.layers, transportBlocks: d.transportBlocks };
      if (scheduling) scheduling.push(entry);
      else this.schedulingByTti.set(key, [entry]);
      this.pdschTtis.add(key);
      this.transportBlockKeys.add(`${key}/${d.carrier}/${d.harq}/${d.sizeBytes}`);
    }
    for (const u of this.ulReports) {
      const key = this.axis.absolute(u.tMs, u.tti);
      const list = this.puschByTti.get(key);
      const entry = { startRb: u.startRb, nRb: u.nRb, modulation: u.modulation };
      if (list) list.push(entry);
      else this.puschByTti.set(key, [entry]);
    }
  }

  /** The (EARFCN, PCI) serving the phone at `tMs`, from the 0xB193 serving records (0xB126 names no cell). */
  private servingAt(tMs: number): { earfcn: number; pci: number } | null {
    const list = this.servingTimeline;
    if (!list.length) return null;
    let lo = 0, hi = list.length - 1, best = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (list[mid].tMs <= tMs) {
        best = mid;
        lo = mid + 1;
      } else hi = mid - 1;
    }
    // Before the first serving record, the first one is still the best evidence there is.
    const pick = best < 0 ? list[0] : list[best];
    return { earfcn: pick.earfcn, pci: pick.pci };
  }

  private mib(m: Mib, t: number): void {
    const where = { carrier: 0, earfcn: m.earfcn, pci: m.pci };
    this.add('lte_tx_antennas_mib', t, m.txAntennas, where);
    this.add('lte_dl_bandwidth_prb', t, m.dlBandwidthPrb, where);
    this.txAntennas.add(m.txAntennas);
    this.mibAntennas.set(`${m.earfcn}/${m.pci}`, m.txAntennas);
  }

  private measurement(c: CellMeasurement, t: number): void {
    const where: SampleExtra = c.serving
      ? { carrier: c.carrier, earfcn: c.earfcn, pci: c.pci }
      : { earfcn: c.earfcn, pci: c.pci, tag: TAG.neighbour };
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
      if (measured(c, k)) {
        this.rsrqTerms.push({ earfcn: c.earfcn, rx: k, rsrq: c.rsrqRx[k], rsrp: c.rsrpRx[k], rssi: c.rssiRx[k] });
      }
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
    this.measuredCells.add(`${c.earfcn}/${c.pci}`);
    if (c.serving) {
      const key = `${c.earfcn}/${c.pci}`;
      const list = this.servingRsrp.get(key);
      if (list) list.push({ tMs: t, rsrp: c.rsrpFiltered });
      else this.servingRsrp.set(key, [{ tMs: t, rsrp: c.rsrpFiltered }]);
    }
    if (c.serving && c.carrier === 0) this.servingTimeline.push({ tMs: t, earfcn: c.earfcn, pci: c.pci });
    if (c.serving && c.carrier === 0) {
      let counts = this.rxByEarfcn.get(c.earfcn);
      if (!counts) this.rxByEarfcn.set(c.earfcn, counts = new Map());
      counts.set(n, (counts.get(n) ?? 0) + 1);
    }
  }

  private pdsch(r: PdschRecord, raw: bigint, t: number): void {
    const tti = (r.sfn % 1024) * 10 + r.subframe;
    this.axis.observe(t, tti);
    for (const tb of r.blocks) {
      if (tb.rntiType === 0 && tb.qm !== 0) {
        this.dlBlocks.push({
          tMs: t,
          tti,
          carrier: r.carrier,
          harq: tb.harq,
          sizeBytes: tb.tbsBytes,
          nRb: tb.nRb,
          layers: r.layers,
          transportBlocks: r.transportBlocks,
        });
      }
    }
    r.blocks.forEach((tb, j) => {
      if (tb.rntiType !== 0 || tb.qm === 0) return; // C-RNTI traffic only
      const layers =
        (r.transportBlocks === 2 && r.layers === 4) || (r.transportBlocks === 2 && r.layers === 3 && j === 1) ? 2 : 1;
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
      const tag = r.layers === 4 && r.transportBlocks === 1
        ? TAG.txDiversity
        : r.layers === 3
        ? TAG.unverified
        : undefined;
      this.add('lte_dl_layers', t, r.layers, tag ? { carrier: r.carrier, tag } : { carrier: r.carrier });
    }
  }

  private pusch(tx: PuschTransmission, raw: bigint, t: number): void {
    if (tx.nRb === 0) return;
    this.axis.observe(t, tx.tti);
    this.ulReports.push({ tMs: t, tti: tx.tti, startRb: tx.startRb, nRb: tx.nRb, modulation: tx.modulation });
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
      if (ce.lcid === 26 && ce.payload.length > 0) {
        this.add('lte_power_headroom', t, (ce.payload[0] & 63) - 23, { carrier: s.carrier });
      }
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
      const where: SampleExtra = {
        earfcn: c.arfcn,
        pci: cell.pci,
        tag: c.servingPci === cell.pci ? TAG.serving : TAG.neighbour,
      };
      // CC id 255: measured as a candidate before the SCG was added, so on no serving carrier yet.
      if (c.ccId !== 255) where.carrier = c.ccId;
      if (cell.rsrp !== null) this.add('nr_ss_rsrp', t, cell.rsrp, where);
      if (cell.rsrq !== null) this.add('nr_ss_rsrq', t, cell.rsrq, where);
    }
  }

  private nrSlot(s: NrPdschSlot, t: number): void {
    const fits = (mcs: number) => {
      const e = nrMcs('qam256', mcs);
      return e !== null &&
        NR_RE_PER_PRB.some((n) => nrTbsBits(n, s.nRb, e[0], e[1] / 1024, s.layers) === s.tbsBytes * 8);
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

  // --------------------------------------------------------------------------------- the later LTE decoders

  /** 0xB126: the measured antenna configuration, the rank and the PRB allocation, 20 subframes per record. */
  private pdschDemapper(subs: PdschDemapperSubframe[], t: number): void {
    this.seal();
    if (!this.axis.usable) return;
    const b = this.stats.b126;
    for (const sub of subs) {
      const tti = sub.sfn * 10 + sub.subframe;
      const key = this.axis.absolute(t, tti);
      // Each sub-record carries its own subframe, so it is placed at its own instant, not the record's.
      const tSub = key + this.axis.latencyMs;
      b.subframes++;
      const serving = this.servingAt(tSub);
      const where: SampleExtra = { carrier: 0 };
      if (serving) {
        where.earfcn = serving.earfcn;
        where.pci = serving.pci;
      }
      this.add('lte_pdsch_tx_antennas', tSub, sub.txAntennas, where);
      this.add('lte_pdsch_rx_antennas', tSub, sub.rxAntennas, where);
      this.add('lte_dl_rank', tSub, sub.rank, { carrier: 0 });
      this.add('lte_dl_prb_allocation', tSub, sub.nPrb, { carrier: 0, mask: sub.prbMask });

      // Check 1: popcount(bitmap) is an N_RB that 0xB173 reports for the same subframe.
      const sizes = this.nRbByTti.get(key);
      if (sizes) {
        b.prbChecked++;
        if (sizes.has(sub.nPrb)) b.prbMatched++;
      }
      // Check 2: rank equals 0xB173's layer count, with 4 layers and one transport block read as transmit
      // diversity (one layer of data), which is what the 0xB173 decoder already documents.
      // 0xB173 can log two carriers in the same subframe, and 0xB126 follows whichever one was scheduled, so any
      // of the subframe's readings may be the match.
      const scheduled = this.schedulingByTti.get(key);
      if (scheduled) {
        b.rankChecked++;
        if (scheduled.some((e) => e.layers === sub.rank)) b.rankMatched++;
        else if (sub.rank === 1 && scheduled.some((e) => e.layers === 4 && e.transportBlocks === 1)) {
          b.rankMatched++;
          b.rankTxDiversity++;
        }
      }
      // Check 3: the transmit antenna ports equal the MIB's antenna count for the cell that was serving.
      const mib = serving ? this.mibAntennas.get(`${serving.earfcn}/${serving.pci}`) : undefined;
      if (mib !== undefined) {
        b.txPortsChecked++;
        if (mib === sub.txAntennas) b.txPortsMatched++;
      }
      if (serving) {
        const cellKey = `${serving.earfcn}/${serving.pci}`;
        let cell = this.antennaCells.get(cellKey);
        if (!cell) {
          cell = {
            earfcn: serving.earfcn,
            pci: serving.pci,
            txPorts: new Map(),
            rxAntennas: new Map(),
            ranks: new Map(),
            subframes: 0,
          };
          this.antennaCells.set(cellKey, cell);
        }
        cell.subframes++;
        bump(cell.txPorts, sub.txAntennas);
        bump(cell.rxAntennas, sub.rxAntennas);
        bump(cell.ranks, sub.rank);
      }
    }
  }

  /** 0xB12A: the cell's PDCCH load. The record's 20 elements cover two radio frames and which of the two the
   *  header SFN names is not settled, so the per-record CFI is plotted at the record's own time and the histogram
   *  counts every element. */
  private pcfich(r: PcfichRecord, t: number): void {
    const b = this.stats.b12a;
    const seen = new Map<number, number>();
    for (const sub of r.subframes) {
      b.elements++;
      if (sub.consistent) b.consistent++;
      if (sub.cfi === null) {
        this.cfiNotDecoded++;
        continue;
      }
      b.decoded++;
      bump(seen, sub.cfi);
      bump(this.cfiCounts, sub.cfi);
    }
    let mode: number | null = null, best = 0;
    for (const [cfi, n] of seen) {
      if (n > best) {
        best = n;
        mode = cfi;
      }
    }
    if (mode !== null) this.add('lte_pdcch_cfi', t, mode, { carrier: 0 });
  }

  /** 0xB16C: the scheduler's decisions. Only the uplink grant's fields are read; the downlink assignment's
   *  contents were rejected by validation, so it is counted and nothing more. */
  private dci(d: DciRecord, t: number): void {
    this.seal();
    if (!this.axis.usable) return;
    const b = this.stats.b16c;
    b.records++;
    if (d.exact) b.exact++;
    for (const sub of d.subframes) {
      const key = this.axis.absolute(t, sub.tti);
      const tSub = key + this.axis.latencyMs;
      if (sub.downlinkAssignments > 0) {
        this.add('lte_dl_assignments', tSub, sub.downlinkAssignments, { carrier: 0 });
        b.assignmentSubframes++;
        // The 8-byte records land on a subframe where 0xB173 logged a PDSCH: that is what identifies them.
        if (this.pdschTtis.has(key)) b.assignmentsOnPdsch++;
        this.grants.assignments += sub.downlinkAssignments;
      }
      if (!sub.uplinkGrants.length) continue;
      b.grantSubframes++;
      // FDD sends the grant four subframes before the PUSCH it schedules (TS 36.213 8.0).
      const reports = this.puschByTti.get(key + 4);
      if (reports) b.precedesPusch++;
      for (const g of sub.uplinkGrants) {
        this.grants.grants++;
        this.add('lte_ul_grant_prb', tSub, g.nRb, { carrier: 0 });
        this.add('lte_ul_grant_start_rb', tSub, g.startRb, { carrier: 0 });
      }
      if (sub.uplinkGrants.length === 1 && reports && reports.length === 1) {
        const grant = sub.uplinkGrants[0], sent = reports[0];
        b.fieldsChecked++;
        this.grants.matched++;
        this.grants.prbGranted += grant.nRb;
        this.grants.prbSent += sent.nRb;
        if (grant.startRb === sent.startRb && grant.nRb === sent.nRb && grant.modulation === sent.modulation) {
          b.fieldsMatched++;
        }
      }
    }
  }

  /** 0xB063: MAC-level downlink accounting. Never a total - the walk reaches about 80% of the declared transport
   *  blocks, which `coverageShare` states and the UI has to show. */
  private macDownlink(m: MacDlRecord, raw: bigint, t: number): void {
    this.seal();
    const b = this.stats.b063;
    b.records++;
    b.declared += m.declared;
    b.walked += m.blocks.length;
    b.resynced += m.resynced;
    if (m.exact) b.exact++;
    const acc = this.macDl;
    acc.records++;
    acc.declared += m.declared;
    acc.walked += m.blocks.length;
    if (m.exact) acc.exact++;
    for (const tb of m.blocks) {
      acc.bytes += tb.sizeBytes;
      acc.padding += tb.paddingBytes;
      if (this.axis.usable) {
        // Four independent fields have to agree for this to match, which is what pins the header.
        const key = this.axis.absolute(t, tb.sfn * 10 + tb.subframe);
        b.tbChecked++;
        if (this.transportBlockKeys.has(`${key}/${tb.carrier}/${tb.harq}/${tb.sizeBytes}`)) b.tbMatched++;
      }
      for (const sdu of tb.sdus) {
        const kind = dlChannelKind(sdu);
        const entry = acc.channels.get(sdu.lcid) ?? { kind, bytes: 0, sdus: 0 };
        entry.bytes += sdu.lengthBytes;
        entry.sdus++;
        acc.channels.set(sdu.lcid, entry);
        if (sdu.control && sdu.lcid === TIMING_ADVANCE_LCID) acc.timingAdvance++;
      }
      const second = this.second(raw, t), key = `${second}/${tb.carrier}`;
      const bin = this.macDlBins.get(key) ?? { second, carrier: tb.carrier, bytes: 0, padding: 0 };
      bin.bytes += tb.sizeBytes;
      bin.padding += tb.paddingBytes;
      this.macDlBins.set(key, bin);
    }
  }

  /** 0x184C: the front end's own transmit power per chain, and whether it sat at the chain's limit. */
  private frontEndTx(f: FedTxAgcRecord, t: number): void {
    this.seal();
    const b = this.stats.x184c;
    b.records++;
    if (f.exact) b.framed++;
    b.blocks += f.blockCounters.length;
    b.subframesInRange += f.subframesInRange;
    // Consecutive blocks are usually consecutive subframes of the front end's own counter (the modem logs only the
    // subframes it has something to say about, so this is reported beside the framing, never gated on).
    for (let i = 1; i < f.blockCounters.length; i++) {
      b.blockSteps++;
      if ((f.blockCounters[i] - f.blockCounters[i - 1] + SFN_CYCLE_MS) % SFN_CYCLE_MS === 1) b.blockStepsByOne++;
    }
    for (const sample of f.samples) {
      let chain = this.txChains.get(sample.chain);
      if (!chain) {
        chain = { samples: 0, live: 0, powers: [], limits: [], atLimit: 0, states: new Set() };
        this.txChains.set(sample.chain, chain);
      }
      chain.samples++;
      if (!sample.live) continue;
      const limit = bindingLimitDbm(sample);
      const atLimit = sample.powerDbm >= limit - 0.5;
      chain.live++;
      chain.powers.push(sample.powerDbm);
      chain.limits.push(limit);
      chain.states.add(sample.gainState);
      b.live++;
      // The check: a chain cannot transmit above its own limit (0.5 dB of slack for the 0.1 dB quantisation).
      if (sample.powerDbm <= limit + 0.5) b.withinLimit++;
      if (atLimit) {
        chain.atLimit++;
        b.atLimit++;
      }
      const where: SampleExtra = { carrier: 0, tag: chainTag(sample.chain) };
      // The block's counter is the front end's own, not the cell's SFN, so the record's timestamp places the sample.
      const tSample = t;
      this.add(
        'lte_fed_tx_power',
        tSample,
        sample.powerDbm,
        atLimit ? { ...where, tag: `${chainTag(sample.chain)} ${TAG.atLimit}` } : where,
      );
      this.add('lte_fed_tx_limit', tSample, limit, where);
      this.add('lte_pa_gain_state', tSample, sample.gainState, where);
    }
  }

  /** 0x1D0B: the two clocks, kept only to measure the holes in the trace. */
  private modemClock(c: ModemClockSample, t: number): void {
    const b = this.stats.x1d0b;
    b.records++;
    const previous = this.clockSamples[this.clockSamples.length - 1];
    if (previous) {
      b.steps++;
      if (c.sequence - previous.sequence === 1) b.stepsByOne++;
    }
    this.clockSamples.push({ tMs: t, ticks1024: c.ticks1024, sequence: c.sequence });
  }

  /** 0xB179: the intra-frequency neighbours, placed in time by their own TTI (`aboutMs` is only used to decide
   *  which turn of the 10.24 s SFN cycle the record belongs to). */
  private intraFrequency(m: IntraFreqMeasurement, aboutMs: number): void {
    this.seal();
    const t = this.axis.usable ? this.axis.timeOf(m.tti, aboutMs) : aboutMs;
    const b = this.stats.b179;
    // The serving cross-check: 0xB193's own filtered RSRP for the same cell, nearest in time.
    const near = nearestByTime(this.servingRsrp.get(`${m.earfcn}/${m.pci}`), t, 200);
    if (near !== null) {
      const delta = m.rsrp - near.rsrp;
      b.servingChecked++;
      b.servingDeltaSum += delta;
      if (Math.abs(delta) <= 1) b.servingWithin1Db++;
      if (Math.abs(delta) <= 3) b.servingWithin3Db++;
    }
    for (const n of m.neighbours) {
      const where: SampleExtra = { earfcn: m.earfcn, pci: n.pci, tag: TAG.neighbour };
      this.add('lte_neighbour_rsrp_intra', t, n.rsrp, where);
      this.add('lte_neighbour_rsrq_intra', t, n.rsrq, where);
      // The margin against the serving cell measured in the same record: why the phone did or did not move.
      this.add('lte_neighbour_margin', t, n.rsrp - m.rsrp, where);
      const key = `${m.earfcn}/${n.pci}`;
      let cell = this.neighbourCells.get(key);
      if (!cell) {
        cell = { earfcn: m.earfcn, pci: n.pci, rsrps: [], rsrqs: [], margins: [], first: t, last: t };
        this.neighbourCells.set(key, cell);
      }
      cell.rsrps.push(n.rsrp);
      cell.rsrqs.push(n.rsrq);
      cell.margins.push(n.rsrp - m.rsrp);
      cell.first = Math.min(cell.first, t);
      cell.last = Math.max(cell.last, t);
    }
  }

  /** True when no 0xB193 record measured this cell at all: the neighbour has no other source in the capture. */
  onlySourceFor(earfcn: number, pci: number): boolean {
    return !this.measuredCells.has(`${earfcn}/${pci}`);
  }

  /** The MIB's antenna count for an 'earfcn/pci' cell, where the MIB was captured. */
  mibAntennasOf(cell: string): number | undefined {
    return this.mibAntennas.get(cell);
  }

  private nrCounter(c: NrPdschCounters, t: number): void {
    const id = this.stats.b888Identity;
    id.records++;
    if (c.crcPass + c.crcFail === c.decodes && c.passBytes + c.failBytes === c.tbBytes) id.holds++;
    this.nrCounters.push({ tMs: t, c });
  }
}

/** A counter map: `m[key] += 1`. */
function bump(m: Map<number, number>, key: number): void {
  m.set(key, (m.get(key) ?? 0) + 1);
}

/** 0x184C's chain tag as the UI shows it. */
export const chainTag = (chain: number): string => `chain 0x${chain.toString(16).toUpperCase()}`;

/** The nearest entry to `tMs` within `toleranceMs`, from a list in time order, or null. */
function nearestByTime<T extends { tMs: number }>(
  list: readonly T[] | undefined,
  tMs: number,
  toleranceMs: number,
): T | null {
  if (!list || !list.length) return null;
  let lo = 0, hi = list.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (list[mid].tMs < tMs) lo = mid + 1;
    else hi = mid;
  }
  let best = list[lo];
  if (lo > 0 && Math.abs(list[lo - 1].tMs - tMs) < Math.abs(best.tMs - tMs)) best = list[lo - 1];
  return Math.abs(best.tMs - tMs) <= toleranceMs ? best : null;
}

/**
 * The nearest stamped record time for every record position, forward then backward filled. 0xB179 is the one PHY
 * record with no timestamp of its own, and its position in the trace is the only thing that says which turn of the
 * 10.24 s SFN cycle its TTI belongs to.
 */
function anchorTimes(records: readonly LogRecord[], tMs: (raw: bigint) => number | null): Float64Array {
  const out = new Float64Array(records.length).fill(NaN);
  let last = NaN;
  for (let i = 0; i < records.length; i++) {
    const t = tMs(records[i].timestampRaw);
    if (t !== null) last = t;
    out[i] = last;
  }
  let next = NaN;
  for (let i = records.length - 1; i >= 0; i--) {
    const t = tMs(records[i].timestampRaw);
    if (t !== null) next = t;
    if (Number.isNaN(out[i])) out[i] = next;
  }
  return out;
}
