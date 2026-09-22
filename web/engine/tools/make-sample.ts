// The website's "Try the sample": a CaptureAnalysis built from an INVENTED capture, shaped like a real one.
//
// Nothing here comes from anyone's phone. The cells are on the test PLMN 001-01 (3GPP's reserved network) with
// EARFCNs, PCIs and identifiers chosen for the story, the times are round numbers, and the radio series are
// generated from a seeded pseudo-random walk. The synthetic events go through the real call-flow rules
// (flowOf), the real UI mapping (uiSignalling, masked) and the real journey rules, so the sample exercises the
// same code the browser runs and can never drift from the contract.
//
//   deno run -A tools/make-sample.ts                     writes dist/sample-analysis.json
//   deno run -A tools/make-sample.ts --out FILE          somewhere else
//   deno run -A tools/make-sample.ts --stdout            to stdout
//
// The output is byte-stable, so it ships as a fixed static asset the browser can cache.

import { guideState, iso, profileState } from '../src/archive/profile.ts';
import { flowOf } from '../src/signalling/callflow.ts';
import type { FlowEvent, FlowField, ServingCellInfo } from '../src/signalling/flow.ts';
import { uiSignalling } from '../src/signalling/ui.ts';
import { buildJourney, type CaptureFacts, stepAnnotations } from '../src/journey/build.ts';
import { attributeCarriers } from '../src/journey/attribution.ts';
import { PHY_METRICS } from '../src/phy/metrics.ts';
import { availability } from '../src/phy/catalog.ts';
import {
  type Cell,
  type CaptureAnalysis,
  CONTRACT_VERSION,
  type PhyCheck,
  type PhyMetric,
  type PhySample,
  type PhySeries,
  type PhySummary,
  type TraceWindow,
} from '../src/types.ts';

// ------------------------------------------------------------------------------------------- invented facts

/** The story: a capture taken at 12:00:00 UTC on an invented day, 31 s of trace. */
const PRESS_MS = Date.UTC(2026, 0, 15, 12, 0, 0);
const START_MS = PRESS_MS + 14_000; // the kept trace starts 14 s after the press
const DURATION_MS = 31_000;
const INSTALL_MS = PRESS_MS - 2 * 24 * 3_600_000;
const REMOVAL_MS = INSTALL_MS + 7 * 24 * 3_600_000;

/** Band 3 (1,800 MHz) and band 7 (2,600 MHz) LTE, n78 NR: invented cells on the test network 001-01. */
const A: Cell = { earfcn: 1575, pci: 144, nr: false };
const B: Cell = { earfcn: 3050, pci: 271, nr: false };
const NR: Cell = { earfcn: 636_666, pci: 501, nr: true };
const PENDING: Cell = { earfcn: 0xffff_ffff, pci: 0xffff, nr: true };

const SERVING: { cell: Cell; info: ServingCellInfo }[] = [
  { cell: A, info: { pci: 144, downlinkEarfcn: 1575, uplinkEarfcn: 19_575, band: 3, plmn: '001-01', tac: 4660, cellIdentity: 1_118_481, bandwidthMhz: 20 } },
  { cell: B, info: { pci: 271, downlinkEarfcn: 3050, uplinkEarfcn: 21_050, band: 7, plmn: '001-01', tac: 4660, cellIdentity: 1_118_482, bandwidthMhz: 20 } },
];

// --------------------------------------------------------------------------------------- the synthetic flow

const field = (label: string, value: string, children: FlowField[] = []): FlowField => ({ label, value, children });

interface EventSpec {
  tMs: number;
  layer: 'RRC' | 'NAS';
  rat?: 'lte' | 'nr';
  uplink: boolean;
  key: string;
  name: string;
  channel: string;
  cell?: Cell | null;
  fields?: FlowField[];
  cause?: number;
  causeName?: string;
  pduLength?: number;
}

/** Every LTE RRC message the sample tells its story with, then the NAS inside it, in time order. */
const SPECS: EventSpec[] = [
  { tMs: 120, layer: 'RRC', uplink: true, key: 'rrcConnectionRequest', name: 'RRCConnectionRequest', channel: 'UL-CCCH', cell: A, fields: [field('Establishment cause', 'mo-Data'), field('UE identity', 'S-TMSI 0x1A2B3C4D')] },
  { tMs: 168, layer: 'RRC', uplink: false, key: 'rrcConnectionSetup', name: 'RRCConnectionSetup', channel: 'DL-CCCH', cell: A, fields: [field('SRB1', 'configured')] },
  { tMs: 201, layer: 'RRC', uplink: true, key: 'rrcConnectionSetupComplete', name: 'RRCConnectionSetupComplete', channel: 'UL-DCCH', cell: A, fields: [field('Selected PLMN', '001-01')] },
  {
    tMs: 204,
    layer: 'NAS',
    uplink: true,
    key: 'Attach request',
    name: 'Attach request',
    channel: 'EMM',
    fields: [field('EPS attach type', 'EPS attach'), field('Mobile identity', 'IMSI 001010000000001'), field('UE network capability', 'EEA0 EEA1 EEA2, EIA1 EIA2')],
  },
  { tMs: 388, layer: 'NAS', uplink: false, key: 'Authentication request', name: 'Authentication request', channel: 'EMM', fields: [field('RAND', '00112233445566778899aabbccddeeff'), field('AUTN', 'fedcba98765432100123456789abcdef')] },
  { tMs: 455, layer: 'NAS', uplink: true, key: 'Authentication response', name: 'Authentication response', channel: 'EMM', fields: [field('RES', '0a1b2c3d4e5f6071')] },
  { tMs: 512, layer: 'NAS', uplink: false, key: 'Security mode command', name: 'Security mode command', channel: 'EMM', fields: [field('Ciphering algorithm', 'EEA2'), field('Integrity algorithm', 'EIA2')] },
  { tMs: 548, layer: 'NAS', uplink: true, key: 'Security mode complete', name: 'Security mode complete', channel: 'EMM', fields: [field('IMEISV', '0123456789012345')] },
  { tMs: 615, layer: 'RRC', uplink: false, key: 'securityModeCommand', name: 'SecurityModeCommand', channel: 'DL-DCCH', cell: A, fields: [field('Ciphering algorithm', 'eea2'), field('Integrity algorithm', 'eia2')] },
  { tMs: 646, layer: 'RRC', uplink: true, key: 'securityModeComplete', name: 'SecurityModeComplete', channel: 'UL-DCCH', cell: A },
  { tMs: 688, layer: 'RRC', uplink: false, key: 'ueCapabilityEnquiry', name: 'UECapabilityEnquiry', channel: 'DL-DCCH', cell: A, fields: [field('RAT types', 'eutra, nr, eutra-nr')] },
  { tMs: 742, layer: 'RRC', uplink: true, key: 'ueCapabilityInformation', name: 'UECapabilityInformation', channel: 'UL-DCCH', cell: A, pduLength: 1024 },
  { tMs: 812, layer: 'RRC', uplink: false, key: 'rrcConnectionReconfiguration', name: 'RRCConnectionReconfiguration', channel: 'DL-DCCH', cell: A, fields: [field('DRB to add', 'DRB1 (EPS bearer 5)'), field('Measurement config', 'A2, A3, A5, B1-NR')] },
  { tMs: 848, layer: 'RRC', uplink: true, key: 'rrcConnectionReconfigurationComplete', name: 'RRCConnectionReconfigurationComplete', channel: 'UL-DCCH', cell: A },
  {
    tMs: 906,
    layer: 'NAS',
    uplink: false,
    key: 'Attach accept',
    name: 'Attach accept',
    channel: 'EMM',
    fields: [
      field('EPS attach result', 'EPS only'),
      field('GUTI', '001-01-4660-01-0123456789'),
      field('TAI list', '001-01 TAC 4660'),
      field('Activate default EPS bearer context request', 'EPS bearer 5', [field('APN', 'internet.example'), field('PDN type', 'IPv4v6'), field('PDN address', '10.20.30.40')]),
    ],
  },
  { tMs: 958, layer: 'NAS', uplink: true, key: 'Attach complete', name: 'Attach complete', channel: 'EMM', fields: [field('Activate default EPS bearer context accept', 'EPS bearer 5')] },
  { tMs: 4_120, layer: 'RRC', uplink: false, key: 'rrcConnectionRelease', name: 'RRCConnectionRelease', channel: 'DL-DCCH', cell: A, fields: [field('Release cause', 'other')] },

  // Idle, then data: a service request that brings the NR leg up.
  { tMs: 11_040, layer: 'RRC', uplink: true, key: 'rrcConnectionRequest', name: 'RRCConnectionRequest', channel: 'UL-CCCH', cell: A, fields: [field('Establishment cause', 'mo-Data'), field('UE identity', 'S-TMSI 0x1A2B3C4D')] },
  { tMs: 11_089, layer: 'RRC', uplink: false, key: 'rrcConnectionSetup', name: 'RRCConnectionSetup', channel: 'DL-CCCH', cell: A },
  { tMs: 11_122, layer: 'RRC', uplink: true, key: 'rrcConnectionSetupComplete', name: 'RRCConnectionSetupComplete', channel: 'UL-DCCH', cell: A },
  { tMs: 11_124, layer: 'NAS', uplink: true, key: 'Service request', name: 'Service request', channel: 'EMM', fields: [field('KSI and sequence number', 'KSI 3, sequence 12')] },
  { tMs: 11_198, layer: 'RRC', uplink: false, key: 'securityModeCommand', name: 'SecurityModeCommand', channel: 'DL-DCCH', cell: A, fields: [field('Ciphering algorithm', 'eea2')] },
  { tMs: 11_231, layer: 'RRC', uplink: true, key: 'securityModeComplete', name: 'SecurityModeComplete', channel: 'UL-DCCH', cell: A },
  { tMs: 12_410, layer: 'RRC', uplink: false, key: 'rrcConnectionReconfiguration', name: 'RRCConnectionReconfiguration', channel: 'DL-DCCH', cell: A, fields: [field('NR secondary cell group', 'added'), field('Measurement config', 'B1-NR')] },
  { tMs: 12_412, layer: 'RRC', rat: 'nr', uplink: false, key: 'rrcReconfiguration', name: 'RRCReconfiguration', channel: 'RRCReconfiguration', cell: PENDING, fields: [field('SpCell', 'PSCell')] },
  { tMs: 12_468, layer: 'RRC', rat: 'nr', uplink: true, key: 'rrcReconfigurationComplete', name: 'RRCReconfigurationComplete', channel: 'RRCReconfigurationComplete', cell: NR },
  { tMs: 12_496, layer: 'RRC', uplink: true, key: 'rrcConnectionReconfigurationComplete', name: 'RRCConnectionReconfigurationComplete', channel: 'UL-DCCH', cell: A },

  // A handover to the band-7 cell, then the release that ends the capture.
  { tMs: 21_330, layer: 'RRC', uplink: true, key: 'measurementReport', name: 'MeasurementReport', channel: 'UL-DCCH', cell: A, fields: [field('Measurement id', '3 (A3)'), field('RSRP', '-104 dBm'), field('Neighbour PCI', '271')] },
  {
    tMs: 21_612,
    layer: 'RRC',
    uplink: false,
    key: 'rrcConnectionReconfiguration',
    name: 'RRCConnectionReconfiguration',
    channel: 'DL-DCCH',
    cell: A,
    fields: [field('Handover', 'to PCI 271, EARFCN 3050'), field('Target cell', 'PCI 271')],
  },
  { tMs: 21_669, layer: 'RRC', uplink: true, key: 'rrcConnectionReconfigurationComplete', name: 'RRCConnectionReconfigurationComplete', channel: 'UL-DCCH', cell: B },
  { tMs: 24_880, layer: 'RRC', uplink: true, key: 'measurementReport', name: 'MeasurementReport', channel: 'UL-DCCH', cell: B, fields: [field('Measurement id', '1 (A2)'), field('RSRP', '-97 dBm')] },
  { tMs: 29_402, layer: 'RRC', uplink: false, key: 'rrcConnectionRelease', name: 'RRCConnectionRelease', channel: 'DL-DCCH', cell: B, fields: [field('Release cause', 'other'), field('Redirect', 'none')] },
];

/** GPS-epoch modem stamp (1.25 ms units), as the decoder would have read it. */
const stampOf = (tMs: number) => BigInt(Math.round(((START_MS + tMs) - 315_964_800_000) / 1.25)) << 16n;

function events(): FlowEvent[] {
  return SPECS.map((s, index) => {
    const fields = s.fields ?? [];
    const summary = fields.length ? fields.map((f) => `${f.label} ${f.value}`).join(', ') : null;
    const e: FlowEvent = {
      index,
      record: (index + 1) * 37,
      logCode: s.layer === 'NAS' ? 0xb0ec : s.rat === 'nr' ? 0xb821 : 0xb0c0,
      timestampRaw: stampOf(s.tMs),
      sinceStartMs: s.tMs,
      layer: s.layer,
      rat: s.rat ?? 'lte',
      uplink: s.uplink,
      key: s.key,
      name: s.name,
      summary,
      cell: s.cell ?? null,
      channel: s.channel,
      fields,
      cause: s.cause ?? null,
      causeName: s.causeName ?? null,
      protection: null,
      ciphered: false,
      // Invented bytes: the same length the message would have, all zero, so nothing can be read out of them.
      pdu: new Uint8Array(s.pduLength ?? 8 + fields.length * 6),
      carrier: null,
      isFailure: s.cause !== undefined,
      isHandoverCommand: fields.some((f) => f.label === 'Handover'),
    };
    return e;
  });
}

// ---------------------------------------------------------------------------------------- invented radio data

/** Deterministic: the sample is the same file every time it is generated. */
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1_664_525 + 1_013_904_223) >>> 0;
    return s / 4_294_967_296;
  };
}

interface WalkSpec {
  metric: PhyMetric;
  from: number;
  to: number;
  jitter: number;
  everyMs: number;
  decimals?: number;
  min?: number;
  max?: number;
  carrier?: number;
  pci?: number;
  earfcn?: number;
  startMs?: number;
  endMs?: number;
  tag?: string;
}

/** A series that drifts from `from` to `to` with a little noise: the shape a radio KPI has, none of its values. */
function walk(spec: WalkSpec, seed: number): PhySeries {
  const random = rng(seed);
  const start = spec.startMs ?? 0;
  const end = spec.endMs ?? DURATION_MS;
  const samples: PhySample[] = [];
  for (let t = start; t <= end; t += spec.everyMs) {
    const p = (t - start) / Math.max(1, end - start);
    const noise = (random() - 0.5) * 2 * spec.jitter;
    let v = spec.from + (spec.to - spec.from) * p + noise;
    if (spec.min !== undefined) v = Math.max(spec.min, v);
    if (spec.max !== undefined) v = Math.min(spec.max, v);
    const factor = 10 ** (spec.decimals ?? 1);
    const sample: PhySample = { tMs: Math.round(t * 10) / 10, value: Math.round(v * factor) / factor };
    if (spec.carrier !== undefined) sample.carrier = spec.carrier;
    if (spec.pci !== undefined) sample.pci = spec.pci;
    if (spec.earfcn !== undefined) sample.earfcn = spec.earfcn;
    if (spec.tag !== undefined) sample.tag = spec.tag;
    samples.push(sample);
  }
  const info = PHY_METRICS[spec.metric];
  const series: PhySeries = {
    metric: spec.metric,
    title: info.title,
    unit: info.unit,
    section: info.section,
    confidence: info.confidence,
    code: info.code,
    samples,
  };
  if (info.badges) series.badges = [...info.badges];
  return series;
}

const WALKS: WalkSpec[] = [
  { metric: 'lte_rsrp', from: -92, to: -108, jitter: 2.5, everyMs: 120, carrier: 0, earfcn: 1575, pci: 144, endMs: 21_600 },
  { metric: 'lte_rsrp', from: -89, to: -95, jitter: 2, everyMs: 120, carrier: 0, earfcn: 3050, pci: 271, startMs: 21_700 },
  { metric: 'lte_rsrq_filtered', from: -9, to: -13, jitter: 0.8, everyMs: 240, carrier: 0 },
  { metric: 'lte_rssi', from: -62, to: -71, jitter: 1.5, everyMs: 240, carrier: 0 },
  { metric: 'lte_rsrp_filtered', from: -91, to: -106, jitter: 1.2, everyMs: 480, carrier: 0 },
  { metric: 'lte_dl_prb', from: 84, to: 44, jitter: 14, everyMs: 60, decimals: 0, min: 0, max: 100, carrier: 0 },
  { metric: 'nr_dl_prb', from: 210, to: 120, jitter: 30, everyMs: 50, decimals: 0, min: 0, max: 273, carrier: 0, startMs: 12_500, endMs: 21_600 },
  { metric: 'lte_dl_mcs', from: 22, to: 14, jitter: 4, everyMs: 60, decimals: 0, min: 0, max: 28, carrier: 0 },
  { metric: 'lte_dl_bler', from: 2, to: 9, jitter: 3, everyMs: 1_000, decimals: 1, min: 0, max: 100, carrier: 0 },
  { metric: 'lte_dl_phy_throughput', from: 48, to: 21, jitter: 9, everyMs: 1_000, min: 0, carrier: 0 },
  { metric: 'lte_pusch_tx_power_required', from: -4, to: 14, jitter: 3, everyMs: 200, decimals: 0, min: -40, max: 23, carrier: 0 },
  { metric: 'lte_timing_advance_rar', from: 11, to: 19, jitter: 2, everyMs: 1_000, decimals: 0, min: 0, carrier: 0 },
  { metric: 'nr_ss_rsrp', from: -84, to: -93, jitter: 2, everyMs: 200, startMs: 12_500, endMs: 21_600, pci: 501 },
  { metric: 'nr_dl_mcs', from: 20, to: 16, jitter: 4, everyMs: 50, decimals: 0, min: 0, max: 27, carrier: 0, startMs: 12_500, endMs: 21_600 },
  { metric: 'nr_dl_mac_throughput', from: 120, to: 64, jitter: 22, everyMs: 50, min: 0, carrier: 0, startMs: 12_500, endMs: 21_600 },
];

function phySeries(): PhySeries[] {
  const out: PhySeries[] = [];
  WALKS.forEach((spec, i) => {
    const made = walk(spec, 1_000 + i * 17);
    const existing = out.find((s) => s.metric === made.metric);
    if (existing) existing.samples = [...existing.samples, ...made.samples].sort((a, b) => a.tMs - b.tMs);
    else out.push(made);
  });
  return out;
}

const PHY_SUMMARY: PhySummary = {
  scellActivity: [{ index: 1, earfcn: 3050, pci: 271, firstMs: 12_600, lastMs: 21_400, records: 1_480, source: '0xB193' }],
  nrDlActivity: { index: 0, firstMs: 12_500, lastMs: 21_600, records: 2_900, source: '0xB887' },
  rach: [
    { tMs: 118.4, ta: 11, distanceM: 859.4, ulEarfcn: 19_575, preambleTargetDbm: -104 },
    { tMs: 21_668.2, ta: 17, distanceM: 1328.1, ulEarfcn: 21_050, preambleTargetDbm: -101 },
  ],
  txAntennasMib: [2],
  rxAntennasByEarfcn: { '1575': { '4': 1_200, '2': 90 }, '3050': { '4': 430 } },
};

const PHY_CHECKS: PhyCheck[] = [
  { id: 'b193RsrqIdentity', code: '0xB193', passed: true, measured: '99.8% within 0.25 dB (sample capture)', expectation: 'RSRQ = RSRP - RSSI + 10 log10(N_RB)' },
  { id: 'b887TbsFormula', code: '0xB887', passed: true, measured: '410 of 410 new transmissions match', expectation: 'TBS from TS 38.214 5.1.3.2' },
  { id: 'b062Rach', code: '0xB062', passed: true, measured: '2 of 2 responses carry a timing advance', expectation: 'every RACH response has a TA' },
];

// ------------------------------------------------------------------------------------------------- assembly

/** The whole sample: invented events through the real rules. */
export function makeSample(fileName = 'sample_sysdiagnose.tar.gz'): CaptureAnalysis {
  const flow = flowOf(events(), SERVING, {
    records: 214_500,
    undecoded: 3,
    crcErrors: 0,
    durationMs: DURATION_MS,
    startUtcMs: START_MS,
  });
  const traceWindow: TraceWindow = {
    startUtc: iso(START_MS),
    endUtc: iso(START_MS + DURATION_MS),
    afterPressStartS: 14,
    afterPressEndS: 45,
    filesKept: 130,
    filesOnPhone: 198,
    filesOverwritten: 68,
    filesMissing: 0,
  };
  const profile = profileState([], PRESS_MS);
  Object.assign(profile, {
    status: 'active',
    identifier: 'com.apple.basebandlogging',
    displayName: 'Baseband and Telephony Logging',
    installDate: iso(INSTALL_MS),
    removalDate: iso(REMOVAL_MS),
    lifetimeDays: 7,
    observedAt: iso(PRESS_MS),
  });
  const guide = guideState({ profile, hasTrace: true, loggingEnabled: true, unreadable: false }, PRESS_MS + 60_000);

  const series = phySeries();
  const facts: CaptureFacts = {
    traceDurationMs: DURATION_MS,
    traceWindow,
    records: 214_500,
    codes: 196,
    encrypted: { records: 21_400, codes: 58 },
    profile,
    triggerTime: iso(PRESS_MS),
    mcc: '001',
  };
  const journey = buildJourney(flow, PHY_SUMMARY, facts, series);
  const ui = uiSignalling(flow, { annotations: stepAnnotations(flow, journey) });
  const perCode = new Map<number, number>([[0xb193, 4_800], [0xb173, 9_100], [0xb139, 6_200], [0xb887, 3_050], [0xb062, 2]]);

  return {
    contract: CONTRACT_VERSION,
    fileName,
    triggerTime: iso(PRESS_MS),
    traceWindow,
    profile,
    guide,
    problems: [],
    records: 214_500,
    codes: 196,
    encryptedRecords: 21_400,
    encrypted: { records: 21_400, codes: 58 },
    crcErrors: 0,
    durationMs: DURATION_MS,
    startUtc: iso(START_MS),
    ...ui,
    journey,
    phy: attributeCarriers(series, journey),
    phySummary: PHY_SUMMARY,
    phyChecks: PHY_CHECKS,
    versionMisses: {},
    availability: availability(perCode, { records: 21_400, codes: 58 }, true, []),
    timings: { reading: 900, extracting: 10, deframing: 880, decoding: 40, radio: 60 },
  };
}

/** Where the website's asset is built, next to the engine bundle. */
export const SAMPLE_PATH = new URL('../dist/sample-analysis.json', import.meta.url).pathname;

if (import.meta.main) {
  const i = Deno.args.indexOf('--out');
  const json = JSON.stringify(makeSample(), null, 2) + '\n';
  if (Deno.args.includes('--stdout')) {
    console.log(json);
  } else {
    const out = i >= 0 ? Deno.args[i + 1]! : SAMPLE_PATH;
    await Deno.mkdir(out.slice(0, out.lastIndexOf('/')), { recursive: true });
    await Deno.writeTextFile(out, json);
    console.error(`${out.split('/').pop()}  ${(json.length / 1024).toFixed(1)} kB`);
  }
}
