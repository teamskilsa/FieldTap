// Turns what the decoders collected into the capture: the per-second bins, the NR BLER and MAC throughput from the
// cumulative 0xB888 counters, the RSRQ identity with N_RB inferred per EARFCN, the summary the journey reads, the
// self-checks and the availability entries.

import type {
  AntennaConfig,
  Availability,
  CarrierActivity,
  EncryptedCensus,
  FrontEndUplink,
  MacDlAccounting,
  MacDlChannel,
  NeighbourCell,
  PdcchLoad,
  PhyCheck,
  PhySeries,
  PhySummary,
  TraceClock,
  TxChain,
} from '../types.ts';
import type { Extraction, PhyRun, PhyStats } from './extract.ts';
import { DL_CONTROL_ELEMENTS } from './decoders/lteMac.ts';
import { CLOCK_1024_HZ } from './decoders/modemClock.ts';
import { PHY_METRIC_ORDER, PHY_METRICS, VALIDATED_VERSIONS } from './metrics.ts';

/** The LTE channel bandwidths (TS 36.101 table 5.6-1) in PRB. */
export const LTE_BANDWIDTHS_PRB: readonly number[] = [6, 15, 25, 50, 75, 100];

/** The bandwidth whose 10log10(N_RB) is closest to `db` (the median of RSRQ - RSRP + RSSI on one EARFCN). */
export function snapBandwidthPrb(db: number): number {
  let best = LTE_BANDWIDTHS_PRB[0];
  for (const n of LTE_BANDWIDTHS_PRB) {
    if (Math.abs(10 * Math.log10(n) - db) < Math.abs(10 * Math.log10(best) - db)) best = n;
  }
  return best;
}

export function median(v: readonly number[]): number {
  if (!v.length) return NaN;
  const s = [...v].sort((a, b) => a - b);
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
}

/** [min, max] without spreading a long array into arguments. */
function range(v: readonly number[]): [number, number] {
  let lo = Infinity, hi = -Infinity;
  for (const x of v) {
    if (x < lo) lo = x;
    if (x > hi) hi = x;
  }
  return [lo, hi];
}

export type ChecksOf = (stats: PhyStats, tbsAvailable: boolean) => PhyCheck[];
export type AvailabilityOf = (
  recordsPerCode: ReadonlyMap<number, number>,
  secure: EncryptedCensus,
  tbsAvailable: boolean,
  misses: { code: string; versions: string[]; records: number }[],
  durationMs: number,
) => Availability[];

export function finish(x: Extraction, secure: EncryptedCensus, checks: ChecksOf, availability: AvailabilityOf): PhyRun {
  addBins(x);
  addNrCounterDeltas(x);
  inferRsrqIdentity(x);

  const series: PhySeries[] = [];
  for (const metric of PHY_METRIC_ORDER) {
    let samples = x.samples.get(metric) ?? [];
    if (!samples.length) continue;
    // The CSI series merge 0xB14E and 0xB14D samples: one time order (stable, so 0xB14E first on ties).
    if (metric === 'lte_cqi_wideband_cw0' || metric === 'lte_ri' || metric === 'lte_pmi_wideband') {
      samples = samples.map((s, i) => ({ s, i })).sort((a, b) => a.s.tMs - b.s.tMs || a.i - b.i).map((e) => e.s);
    }
    const i = PHY_METRICS[metric];
    const s: PhySeries = {
      metric,
      title: i.title,
      unit: i.unit,
      section: i.section,
      confidence: i.confidence,
      code: i.code,
      samples,
    };
    const version = VALIDATED_VERSIONS[i.code];
    if (version) s.version = version;
    if (i.badges) s.badges = [...i.badges];
    series.push(s);
  }

  const summary: PhySummary = {
    scellActivity: [...x.scells.values()]
      .sort((a, b) => a.index - b.index || a.earfcn - b.earfcn || a.pci - b.pci)
      .map((v) => ({
        index: v.index,
        earfcn: v.earfcn,
        pci: v.pci,
        firstMs: v.first,
        lastMs: v.last,
        records: v.n,
        source: '0xB193 serving records with SCell index',
      })),
    rach: x.rach,
    txAntennasMib: [...x.txAntennas].sort((a, b) => a - b),
    rxAntennasByEarfcn: Object.fromEntries(
      [...x.rxByEarfcn.entries()].sort((a, b) => a[0] - b[0]).map(([e, counts]) => [
        String(e),
        Object.fromEntries([...counts.entries()].sort((a, b) => a[0] - b[0]).map(([n, c]) => [String(n), c])),
      ]),
    ),
  };
  const antennas = measuredAntennas(x);
  if (antennas.length) summary.measuredAntennas = antennas;
  const neighbours = intraFreqNeighbours(x);
  if (neighbours.length) summary.intraFreqNeighbours = neighbours;
  const mac = macDlAccounting(x);
  if (mac) summary.macDl = mac;
  const frontEnd = frontEndUplink(x);
  if (frontEnd) summary.uplinkFrontEnd = frontEnd;
  const pdcch = pdcchLoad(x);
  if (pdcch) summary.pdcchLoad = pdcch;
  if (x.grants.grants > 0 || x.grants.assignments > 0) {
    summary.uplinkGrants = {
      grants: x.grants.grants,
      assignments: x.grants.assignments,
      matched: x.grants.matched,
      prbGranted: x.grants.prbGranted,
      prbSent: x.grants.prbSent,
      source: '0xB16C uplink grants matched to the 0xB139 PUSCH report four subframes later',
    };
  }
  const clock = traceClock(x);
  if (clock) summary.traceClock = clock;
  if (x.nrTimes.length) {
    // 0xB887 names only the PCI (and a carrier index): the journey attributes the NR-ARFCN.
    const [firstMs, lastMs] = range(x.nrTimes);
    const nr: CarrierActivity = {
      index: 0,
      firstMs,
      lastMs,
      records: x.nrTimes.length,
      source: '0xB887',
    };
    if (x.nrPcis.size === 1) nr.pci = [...x.nrPcis][0];
    summary.nrDlActivity = nr;
  }

  const misses = [...x.missVersions.entries()].map(([code, versions]) => ({
    code,
    versions: [...versions].sort(),
    records: [...versions].reduce((n, v) => n + (x.versionMisses[`${code} ${v}`] ?? 0), 0),
  }));
  const tbsAvailable = x.tbs.isAvailable;
  return {
    capture: {
      series,
      summary,
      encrypted: secure,
      checks: checks(x.stats, tbsAvailable),
      versionMisses: { ...x.versionMisses },
      availability: availability(x.recordsPerCode, secure, tbsAvailable, misses, x.timeBase.durationMs),
    },
    stats: x.stats,
  };
}

/** DL BLER and PHY throughput (CRC-pass TBS) and UL scheduled TBS, per (whole second, carrier index). */
function addBins(x: Extraction): void {
  const byKey = <T extends { second: number; carrier: number }>(m: Map<string, T>) =>
    [...m.values()].sort((a, b) => a.second - b.second || a.carrier - b.carrier);
  for (const b of byKey(x.dlBins)) {
    const t = x.binCentre(b.second);
    x.add('lte_dl_bler', t, (100 * b.fail) / b.n, { carrier: b.carrier });
    x.add('lte_dl_phy_throughput', t, b.bits / 1e6, { carrier: b.carrier });
  }
  for (const b of byKey(x.ulBins)) {
    x.add('lte_ul_phy_throughput', x.binCentre(b.second), b.bits / 1e6, { carrier: b.carrier });
  }
  // 0xB063: bytes that reached the MAC, and the padding inside the same grants. Partial by construction - the walk
  // reaches about 80% of the declared transport blocks - which is why these are bytes, not a throughput.
  for (const b of byKey(x.macDlBins)) {
    const t = x.binCentre(b.second);
    x.add('lte_mac_dl_bytes', t, b.bytes, { carrier: b.carrier });
    x.add('lte_mac_dl_padding', t, b.padding, { carrier: b.carrier });
  }
}

/** 0xB126 per serving cell: the majority reading of each field, with the MIB's own figure beside it. */
function measuredAntennas(x: Extraction): AntennaConfig[] {
  const out: AntennaConfig[] = [];
  for (const [key, cell] of [...x.antennaCells.entries()].sort()) {
    const tx = mode(cell.txPorts), rx = mode(cell.rxAntennas);
    if (tx === null || rx === null) continue;
    const config: AntennaConfig = {
      earfcn: cell.earfcn,
      pci: cell.pci,
      txPorts: tx,
      rxAntennas: rx,
      subframes: cell.subframes,
      rankHistogram: histogram(cell.ranks),
      source: `0xB126 v${VALIDATED_VERSIONS['0xB126']}, ${cell.subframes} subframes while this cell was serving`,
    };
    const mib = x.mibAntennasOf(key);
    if (mib !== undefined) config.mibTxAntennas = mib;
    out.push(config);
  }
  return out.sort((a, b) => b.subframes - a.subframes);
}

/** 0xB179 per neighbour cell, strongest first. */
function intraFreqNeighbours(x: Extraction): NeighbourCell[] {
  const out: NeighbourCell[] = [];
  for (const cell of x.neighbourCells.values()) {
    out.push({
      earfcn: cell.earfcn,
      pci: cell.pci,
      measurements: cell.rsrps.length,
      rsrpBestDbm: round(Math.max(...cell.rsrps), 2),
      rsrpMedianDbm: round(median(cell.rsrps), 2),
      rsrqMedianDb: round(median(cell.rsrqs), 2),
      marginBestDb: round(Math.max(...cell.margins), 2),
      marginMedianDb: round(median(cell.margins), 2),
      firstMs: cell.first,
      lastMs: cell.last,
      onlySource: x.onlySourceFor(cell.earfcn, cell.pci),
    });
  }
  return out.sort((a, b) => b.rsrpBestDbm - a.rsrpBestDbm || a.pci - b.pci);
}

/** 0xB063's accounting, with the coverage figure it must always be read with. */
function macDlAccounting(x: Extraction): MacDlAccounting | null {
  const m = x.macDl;
  if (!m.records) return null;
  const channels: MacDlChannel[] = [...m.channels.entries()]
    .sort((a, b) => b[1].bytes - a[1].bytes || a[0] - b[0])
    .map(([lcid, v]) => ({
      lcid,
      kind: v.kind,
      name: v.kind === 'control'
        ? DL_CONTROL_ELEMENTS[lcid] ?? `Control element ${lcid}`
        : v.kind === 'broadcast'
        ? 'CCCH (broadcast)'
        : v.kind === 'signalling'
        ? `DCCH ${lcid} (signalling)`
        : v.kind === 'data'
        ? `DTCH ${lcid} (user data)`
        : `LCID ${lcid} (not a 3GPP downlink channel)`,
      bytes: v.bytes,
      sdus: v.sdus,
    }));
  return {
    records: m.records,
    declaredBlocks: m.declared,
    walkedBlocks: m.walked,
    coverageShare: m.declared > 0 ? m.walked / m.declared : 0,
    exactWalks: m.exact,
    bytes: m.bytes,
    paddingBytes: m.padding,
    paddingShare: m.bytes > 0 ? m.padding / m.bytes : 0,
    channels,
    timingAdvanceCommands: m.timingAdvance,
  };
}

/** 0x184C per chain, and whether the phone was transmit-limited. */
function frontEndUplink(x: Extraction): FrontEndUplink | null {
  const s = x.stats.x184c;
  if (!s.records) return null;
  const chains: TxChain[] = [...x.txChains.entries()].sort((a, b) => a[0] - b[0]).map(([chain, v]) => {
    const c: TxChain = {
      chain: `0x${chain.toString(16).toUpperCase()}`,
      samples: v.samples,
      liveSamples: v.live,
      maxPowerDbm: v.powers.length ? round(Math.max(...v.powers), 1) : 0,
      medianPowerDbm: v.powers.length ? round(median(v.powers), 1) : 0,
      atLimitSamples: v.atLimit,
      gainStates: [...v.states].sort((p, q) => p - q),
    };
    if (v.limits.length) c.limitDbm = round(median(v.limits), 1);
    return c;
  });
  const live = chains.filter((c) => c.liveSamples > 0).sort((a, b) => b.liveSamples - a.liveSamples);
  const out: FrontEndUplink = {
    records: s.records,
    framedRecords: s.framed,
    liveSamples: s.live,
    atLimitSamples: s.atLimit,
    atLimitShare: s.live > 0 ? s.atLimit / s.live : 0,
    chains,
    source: `0x184C v${VALIDATED_VERSIONS['0x184C']}, front-end Tx AGC: the chain's own power against its own limit`,
  };
  if (live.length) out.liveChain = live[0].chain;
  return out;
}

/** 0xB12A's CFI histogram: the cell's control-channel load, independent of this phone's traffic. */
function pdcchLoad(x: Extraction): PdcchLoad | null {
  const decoded = [...x.cfiCounts.values()].reduce((n, v) => n + v, 0);
  if (!decoded && !x.cfiNotDecoded) return null;
  return {
    subframes: decoded,
    cfi: histogram(x.cfiCounts),
    cfi3Share: decoded > 0 ? (x.cfiCounts.get(3) ?? 0) / decoded : 0,
    notDecoded: x.cfiNotDecoded,
  };
}

/** 0x1D0B: where the trace has holes, and how many seconds of it were never written. */
function traceClock(x: Extraction): TraceClock | null {
  const samples = x.clockSamples;
  if (!samples.length) return null;
  const gaps: { tMs: number; missingMs: number }[] = [];
  for (let i = 1; i < samples.length; i++) {
    const delta = samples[i].ticks1024 - samples[i - 1].ticks1024;
    // A record covers 10 ms, so the counter steps by 10 or 11. A step past 100 counts is about 100 ms of trace that
    // was never written; smaller steps are the sampler pausing and are not worth calling a hole.
    if (delta > 100) gaps.push({ tMs: samples[i - 1].tMs, missingMs: round((delta / CLOCK_1024_HZ) * 1000, 0) });
  }
  return {
    records: samples.length,
    gaps,
    missingMs: gaps.reduce((n, g) => n + g.missingMs, 0),
    sequenceSteps: x.stats.x1d0b.stepsByOne,
    sequenceStepsExpected: x.stats.x1d0b.steps,
  };
}

/** The most common key of a counter map, or null when it is empty. */
function mode(counts: ReadonlyMap<number, number>): number | null {
  let best: number | null = null, n = -1;
  for (const [k, v] of counts) {
    if (v > n) {
      n = v;
      best = k;
    }
  }
  return best;
}

const histogram = (counts: ReadonlyMap<number, number>): Record<string, number> =>
  Object.fromEntries([...counts.entries()].sort((a, b) => a[0] - b[0]).map(([k, v]) => [String(k), v]));

const round = (v: number, digits: number): number => {
  const f = 10 ** digits;
  return Math.round(v * f) / f;
};

/** NR BLER and MAC throughput between 0xB888 records more than 50 ms apart whose decode counter grew, and the
 *  cross-check of the 0xB887 sums against the counter deltas over the 0xB887 window. */
function addNrCounterDeltas(x: Extraction): void {
  let prev: { tMs: number; c: Extraction['nrCounters'][number]['c'] } | null = null;
  for (const { tMs, c } of x.nrCounters) {
    if (prev && c.decodes > prev.c.decodes) {
      const dt = tMs - prev.tMs;
      if (dt > 50) {
        const n = c.decodes - prev.c.decodes;
        x.add('nr_dl_bler', tMs, (100 * (c.crcFail - prev.c.crcFail)) / n, { carrier: c.carrier });
        x.add('nr_dl_mac_throughput', tMs, ((c.passBytes - prev.c.passBytes) * 8) / (dt / 1000) / 1e6, {
          carrier: c.carrier,
        });
        prev = { tMs, c };
      }
    } else if (!prev || c.decodes < prev.c.decodes) {
      // The first record, or a counter reset.
      prev = { tMs, c };
    }
  }
  if (!x.nrTimes.length || !x.nrCounters.length) return;
  const [first, last] = range(x.nrTimes);
  const before = x.nrCounters.filter((e) => e.tMs < first - 1);
  if (!before.length) return;
  const a = before[before.length - 1].c;
  const z = (x.nrCounters.find((e) => e.tMs >= last) ?? x.nrCounters[x.nrCounters.length - 1]).c;
  x.stats.nr.deltaDecodes = z.decodes - a.decodes;
  x.stats.nr.deltaCrcFail = z.crcFail - a.crcFail;
  x.stats.nr.deltaPassBytes = z.passBytes - a.passBytes;
}

/** RSRQ = RSRP - RSSI + 10log10(N_RB) per Rx antenna, with N_RB inferred per EARFCN by snapping the median of
 *  RSRQ - RSRP + RSSI to the nearest LTE bandwidth (no cell table: 0xB0C1 names only the PCell's). */
function inferRsrqIdentity(x: Extraction): void {
  const byEarfcn = new Map<number, number[]>();
  for (const t of x.rsrqTerms) {
    const v = byEarfcn.get(t.earfcn) ?? [];
    v.push(t.rsrq - t.rsrp + t.rssi);
    byEarfcn.set(t.earfcn, v);
  }
  const s = x.stats;
  for (const [e, v] of [...byEarfcn.entries()].sort((a, b) => a[0] - b[0])) {
    s.inferredPrb.set(e, snapBandwidthPrb(median(v)));
  }
  const residuals = new Map<number, number[]>();
  for (const t of x.rsrqTerms) {
    const prb = s.inferredPrb.get(t.earfcn) ?? 50;
    const r = t.rsrq - (t.rsrp - t.rssi + 10 * Math.log10(prb));
    const v = residuals.get(t.rx) ?? [];
    v.push(r);
    residuals.set(t.rx, v);
    s.rsrqResiduals++;
    if (Math.abs(r) <= 0.25) s.rsrqWithinQuarterDb++;
  }
  for (const [rx, v] of [...residuals.entries()].sort((a, b) => a[0] - b[0])) {
    const mean = v.reduce((a, b) => a + b, 0) / v.length;
    const sd = Math.sqrt(v.reduce((a, b) => a + (b - mean) ** 2, 0) / v.length);
    s.rsrqResidual.set(rx, { mean, sd, n: v.length });
  }
}
