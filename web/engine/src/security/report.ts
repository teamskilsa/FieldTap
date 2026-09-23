// OWNER: security. The local, no-network fake-base-station / IMSI-catcher check. It reads an already-decoded
// CaptureAnalysis and returns a SecurityReport: per-cell verdicts, an overall verdict, and a plain-language
// reason for every finding. It calls nothing, stores nothing and sends nothing — the app's "nothing leaves this
// device" promise holds (tests/policy_test.ts enforces the no-network rule for all of src/).
//
// Grounding. CellGuard reads shallow QMI management packets and cross-checks Apple's cell-location database; we
// decode the actual RRC/NAS trace, so we can look for the *classic* Layer-3 catcher signatures that SnoopSnitch
// and Darshak use on Android: null/absent ciphering, an IMSI asked for in the clear, a forced 2G/3G downgrade,
// a registration accepted with no security, a reject cause that strands the UE, an implausibly strong cell, and
// a cell reached with no mobility context. Each check names the exact decoded field(s) it reads.
//
// Conservatism is the whole design. A false alarm on a real network is worse than a miss, so every rule is tuned
// to leave the real AT&T reference capture (web/app/public/dev/analysis.json) with a 'trusted' verdict, and a
// sophisticated catcher that mimics a real cell will pass. security/README.md documents each rule and threshold.

import type {
  Cell,
  Event,
  Field,
  Journey,
  SecurityCellVerdict,
  SecurityCheckId,
  SecurityFinding,
  SecurityGap,
  SecurityReport,
  SecurityVerdict,
} from '../types.ts';
import type { CaptureAnalysis } from '../types.ts';
import {
  ABNORMAL_REJECT_CAUSES,
  DOWNGRADE_2G,
  DOWNGRADE_3G,
  SECURITY_RULESET,
  STRONG_RSRP_DBM,
  STRONG_RSRP_MIN_SAMPLES,
  STRONG_RSRP_MIN_SHARE,
} from './thresholds.ts';

/** The candidate checks we cannot support from the current decode, kept visible in every report. */
const GAPS: SecurityGap[] = [
  {
    check: 'sibNeighbourList',
    reason:
      'SIB neighbour lists and full measurement configurations are not decoded, so "advertised neighbour" cannot ' +
      'be read directly; the orphan-cell check falls back to measured neighbours and mobility context only.',
  },
  {
    check: 'asSecurityAlgorithm',
    reason:
      'The RRC Security Mode Command is decoded by name but its chosen AS ciphering/integrity algorithm is not ' +
      'exposed, so AS null-algorithm cannot be read; null-algorithm detection uses the NAS Security Mode Command.',
  },
  {
    check: 'sibAuthenticity',
    reason:
      'SIB1/SI are decoded for cell identity but not cross-checked for broadcast tampering (e.g. a spoofed cell ' +
      'barring or PLMN), which would need fields the current SIB decode does not surface.',
  },
];

const ALL_CHECKS: SecurityCheckId[] = [
  'nullCipher',
  'noSecurityEstablished',
  'imsiRequestedInClear',
  'ratDowngrade',
  'acceptedWithoutAuth',
  'abnormalReject',
  'implausibleSignal',
  'orphanCell',
];

export function analyzeSecurity(analysis: CaptureAnalysis): SecurityReport {
  const findings: SecurityFinding[] = [
    ...checkNullCipher(analysis),
    ...checkNoSecurityEstablished(analysis),
    ...checkImsiInClear(analysis),
    ...checkRatDowngrade(analysis),
    ...checkAcceptedWithoutAuth(analysis),
    ...checkAbnormalReject(analysis),
    ...checkImplausibleSignal(analysis),
    ...checkOrphanCell(analysis),
  ];

  const { cells, unattached } = groupByCell(findings, analysis.journey);
  const verdict = worst([...cells.map((c) => c.verdict), ...unattached.map((f) => severityToVerdict(f.severity))]);
  return {
    verdict,
    headline: headlineFor(verdict, findings.length),
    cells,
    findings: unattached,
    checksRun: ALL_CHECKS,
    gaps: GAPS,
    ruleset: SECURITY_RULESET,
  };
}

// --------------------------------------------------------------------------------------------------- the checks

/** Null ciphering / integrity: a NAS Security Mode Command that chose EEA0 or EIA0. Reads the decoded 'Ciphering'
 *  / 'Integrity' fields (signalling/nasfields.ts). A strong catcher tell — a real network never turns encryption
 *  off for normal service (EIA0 is emergency-only). */
function checkNullCipher(a: CaptureAnalysis): SecurityFinding[] {
  const out: SecurityFinding[] = [];
  for (const e of a.events) {
    const ciphering = fieldValue(e.fields, 'Ciphering');
    const integrity = fieldValue(e.fields, 'Integrity');
    const nullCipher = ciphering === 'EEA0';
    const nullIntegrity = integrity === 'EIA0';
    if (!nullCipher && !nullIntegrity) continue;
    const evidence: string[] = [];
    if (nullCipher) evidence.push(`${e.name}: Ciphering = EEA0 (null ciphering)`);
    if (nullIntegrity) evidence.push(`${e.name}: Integrity = EIA0 (null integrity)`);
    out.push(finding('nullCipher', 'suspicious', 'Null security algorithm', e, {
      explanation: nullIntegrity
        ? 'The network turned integrity protection off (EIA0). Outside an emergency call this is a hallmark of a fake base station.'
        : 'The network chose null ciphering (EEA0), so traffic would go unencrypted — a hallmark of a fake base station.',
      evidence,
    }));
  }
  return out;
}

/** Accepted with no security established at all: a registration/attach ACCEPT with no Security Mode Command (RRC
 *  or NAS) anywhere in the capture. Reads the Security Mode Command events and the accept events. */
function checkNoSecurityEstablished(a: CaptureAnalysis): SecurityFinding[] {
  const accept = a.events.find((e) => isAccept(e));
  if (!accept) return [];
  if (a.events.some((e) => isSecurityModeCommand(e))) return [];
  return [
    finding('noSecurityEstablished', 'suspicious', 'Accepted with no security', accept, {
      explanation:
        'The network accepted the phone onto the network but never ran a Security Mode Command, so ciphering and ' +
        'integrity were never switched on. A legitimate network always does.',
      evidence: [
        `${accept.name} was seen, but no RRC or NAS Security Mode Command was in the trace`,
      ],
    }),
  ];
}

/** IMSI requested in the clear: an Identity Request for the IMSI before security is established. Reads the
 *  'Identity requested' field. IMEISV/IMEI requests (as in the reference capture) are normal and never flagged. */
function checkImsiInClear(a: CaptureAnalysis): SecurityFinding[] {
  const secIndex = a.events.findIndex((e) => isSecurityModeCommand(e));
  const out: SecurityFinding[] = [];
  for (const e of a.events) {
    const requested = fieldValue(e.fields, 'Identity requested');
    if (!requested || requested.toUpperCase() !== 'IMSI') continue;
    // Only before security is established (or when no security is ever established).
    if (secIndex !== -1 && e.index > a.events[secIndex]!.index) continue;
    out.push(finding('imsiRequestedInClear', 'suspicious', 'IMSI requested in the clear', e, {
      explanation:
        'The network asked for the permanent subscriber identity (IMSI) before any security was set up. A real ' +
        'network uses a temporary identity (GUTI) here; asking for the IMSI in the clear is how a catcher harvests it.',
      evidence: [`${e.name}: Identity requested = IMSI, before any Security Mode Command`],
    }));
  }
  return out;
}

/** RAT downgrade: a redirect/reselection to GERAN (2G) or UTRAN (3G). Reads the RRC 'Redirected to' field
 *  (signalling/lterrc.ts, nrrrc.ts). GERAN is suspicious; UTRAN is a warning (legitimate 3G fallback still
 *  happens on some networks). */
function checkRatDowngrade(a: CaptureAnalysis): SecurityFinding[] {
  const out: SecurityFinding[] = [];
  for (const e of a.events) {
    const to = fieldValue(e.fields, 'Redirected to');
    if (!to) continue;
    const up = to.toUpperCase();
    const is2g = DOWNGRADE_2G.some((t) => up.includes(t));
    const is3g = DOWNGRADE_3G.some((t) => up.includes(t));
    if (!is2g && !is3g) continue;
    out.push(finding('ratDowngrade', is2g ? 'suspicious' : 'warning', is2g ? 'Forced 2G downgrade' : 'Forced 3G downgrade', e, {
      explanation: is2g
        ? 'The network pushed the phone down to 2G (GERAN), which has the weakest security. Forcing a modern phone onto 2G is a classic catcher move to make interception easier.'
        : 'The network redirected the phone to 3G (UTRAN). This can be a legitimate fallback, but a forced downgrade is also how a catcher escapes LTE/NR security.',
      evidence: [`${e.name}: Redirected to = ${to}`],
    }));
  }
  return out;
}

/** Accepted without authentication: an accept with no Authentication message and no prior security context (the
 *  initial NAS request was not integrity protected). Reads the accept events, the Authentication events, and the
 *  Protection header of the initial request. A legitimate context-reuse (integrity-protected request, as in the
 *  reference capture) is never flagged, and a genuine first attach runs plaintext Authentication, which is seen. */
function checkAcceptedWithoutAuth(a: CaptureAnalysis): SecurityFinding[] {
  const accept = a.events.find((e) => isAccept(e));
  if (!accept) return [];
  const hasAuth = a.events.some((e) => /authentication (request|response)/i.test(e.name));
  if (hasAuth) return [];
  const contextProven = a.events.some((e) => isInitialNasRequest(e) && !!e.protection && /integrit/i.test(e.protection.headerName));
  if (contextProven) return [];
  return [
    finding('acceptedWithoutAuth', 'suspicious', 'Accepted without authentication', accept, {
      explanation:
        'The phone was accepted onto the network without any authentication exchange and without a pre-existing ' +
        'security context. A network that cannot authenticate the phone (because it does not hold the keys) is a ' +
        'fake base station.',
      evidence: [
        `${accept.name} was seen`,
        'no Authentication Request/Response was in the trace',
        'the initial NAS request was not integrity protected (no prior security context)',
      ],
    }),
  ];
}

/** Abnormal reject cause: a NAS reject whose EMM/5GMM cause forces the phone off a legitimate network. Reads
 *  Event.cause / causeName on reject messages. Our edge over CellGuard's QMI reject: the real decoded cause. */
function checkAbnormalReject(a: CaptureAnalysis): SecurityFinding[] {
  const out: SecurityFinding[] = [];
  for (const e of a.events) {
    if (e.layer !== 'NAS' || e.cause == null) continue;
    if (!/reject/i.test(e.name) && !/reject/i.test(e.key)) continue;
    if (!ABNORMAL_REJECT_CAUSES.has(e.cause)) continue;
    out.push(finding('abnormalReject', 'suspicious', 'Network-stranding reject', e, {
      explanation:
        `The network rejected the phone with cause #${e.cause}${e.causeName ? ` (${e.causeName})` : ''}, which ` +
        'strands it or pushes it onto a forbidden list. A fake base station uses these causes to deny service and ' +
        'force the phone onto a weaker network.',
      evidence: [`${e.name}: cause #${e.cause}${e.causeName ? ` ${e.causeName}` : ''}`],
    }));
  }
  return out;
}

/** Implausibly strong serving cell: a serving RSRP above the per-RAT threshold, sustained over several samples.
 *  Reads the PHY lte_rsrp / lte_rsrp_filtered / nr_ss_rsrp series and their carrier attribution. A single spike
 *  is ignored; the reference capture peaks at about -81.8 dBm, far below the threshold. */
function checkImplausibleSignal(a: CaptureAnalysis): SecurityFinding[] {
  const out: SecurityFinding[] = [];
  const series = [
    { metric: 'lte_rsrp', threshold: STRONG_RSRP_DBM.lte, rat: 'LTE' },
    { metric: 'lte_rsrp_filtered', threshold: STRONG_RSRP_DBM.lte, rat: 'LTE' },
    { metric: 'nr_ss_rsrp', threshold: STRONG_RSRP_DBM.nr, rat: 'NR' },
  ] as const;
  const flagged = new Set<string>();
  for (const spec of series) {
    const s = a.phy.find((x) => x.metric === spec.metric);
    if (!s) continue;
    const values = s.samples.filter((x) => x.value != null);
    if (!values.length) continue;
    const over = values.filter((x) => (x.value as number) > spec.threshold);
    if (over.length < STRONG_RSRP_MIN_SAMPLES || over.length / values.length < STRONG_RSRP_MIN_SHARE) continue;
    const peak = over.reduce((m, x) => ((x.value as number) > m ? (x.value as number) : m), -Infinity);
    const cell = over.find((x) => x.cell)?.cell ?? pcellCell(a.journey, over[0]!.tMs) ?? undefined;
    const key = cell ? cellKey(cell) : spec.metric;
    if (flagged.has(key)) continue;
    flagged.add(key);
    const f = finding('implausibleSignal', 'warning', 'Implausibly strong signal', undefined, {
      explanation:
        `The serving cell's signal reached ${peak.toFixed(1)} dBm over ${over.length} samples — stronger than any ` +
        'normal macro cell delivers, which is what a small transmitter close by (a possible catcher) looks like. ' +
        'It can also just mean you were beside a real cell tower.',
      evidence: [`${spec.metric}: ${over.length} samples above ${spec.threshold} dBm, peak ${peak.toFixed(1)} dBm`],
    });
    if (cell) f.cell = cell;
    const tMs = over[0]!.tMs;
    if (tMs != null) f.tMs = tMs;
    out.push(f);
  }
  return out;
}

/** Orphan cell: an LTE serving cell (or connection cell) the phone connected on that is not the first cell it
 *  camped on, was reached by no handover or reselection, and appears in no neighbour evidence (measured
 *  neighbours, intra-frequency neighbours, or cellDetails). Reads journey.cells, steps, connections, measurement
 *  reports and phySummary.intraFreqNeighbours. Warning only: a redirect to a genuine but unmeasured cell can look
 *  the same, so this alone is weak — it earns its weight next to a downgrade or a null-cipher finding. */
function checkOrphanCell(a: CaptureAnalysis): SecurityFinding[] {
  const neighbourEvidence = neighbourCellKeys(a);
  // Cells reached legitimately: first-seen, handover or reselection targets, plus everything in cellDetails.
  const legit = new Set<string>();
  for (const s of a.steps) {
    if (s.move === 'FIRST_SEEN' || s.move === 'HANDOVER' || s.move === 'RESELECTION') legit.add(cellKey(s.to));
  }
  for (const c of a.cellDetails) legit.add(cellKey(c.cell));

  // The first LTE serving cell in time is the anchor and is never an orphan.
  const ltePcells = a.journey.cells.filter((c) => c.lane === 'pcell' && !c.cell.nr);
  const firstServing = ltePcells.reduce<typeof ltePcells[number] | null>((m, c) => (!m || c.startMs < m.startMs ? c : m), null);

  const candidates = new Map<string, { cell: Cell; startMs: number }>();
  for (const c of ltePcells) {
    if (firstServing && c === firstServing) continue;
    candidates.set(cellKey(c.cell), { cell: c.cell, startMs: c.startMs });
  }
  for (const conn of a.connections) {
    const e = a.events[conn.first];
    if (!e?.cell || e.cell.nr) continue;
    if (firstServing && cellKey(e.cell) === cellKey(firstServing.cell)) continue;
    if (!candidates.has(cellKey(e.cell))) candidates.set(cellKey(e.cell), { cell: e.cell, startMs: conn.startMs });
  }

  const out: SecurityFinding[] = [];
  for (const [key, c] of candidates) {
    if (legit.has(key) || neighbourEvidence.has(key) || neighbourEvidence.has(pciKey(c.cell))) continue;
    const f = finding('orphanCell', 'warning', 'Cell reached without mobility context', undefined, {
      explanation:
        'The phone connected on this cell without a normal handover or reselection into it, and it was never ' +
        'measured as a neighbour. That can happen with ordinary load-balancing, but it is also how a catcher ' +
        'inserts a cell the real network never advertised.',
      evidence: [
        `EARFCN ${c.cell.earfcn} PCI ${c.cell.pci}: no handover/reselection step, not in any neighbour measurement`,
      ],
    });
    f.cell = c.cell;
    if (c.startMs != null) f.tMs = c.startMs;
    out.push(f);
  }
  return out;
}

// ------------------------------------------------------------------------------------------------- aggregation

function groupByCell(
  findings: SecurityFinding[],
  journey: Journey,
): { cells: SecurityCellVerdict[]; unattached: SecurityFinding[] } {
  const byCell = new Map<string, SecurityFinding[]>();
  const unattached: SecurityFinding[] = [];
  for (const f of findings) {
    if (!f.cell) {
      unattached.push(f);
      continue;
    }
    const key = cellKey(f.cell);
    const list = byCell.get(key) ?? [];
    list.push(f);
    byCell.set(key, list);
  }
  const cells: SecurityCellVerdict[] = [];
  for (const [, list] of byCell) {
    const cell = list[0]!.cell!;
    list.sort((a, b) => severityRank(b.severity) - severityRank(a.severity));
    const verdict = worst(list.map((f) => severityToVerdict(f.severity)));
    const v: SecurityCellVerdict = { cell, verdict, findings: list };
    const band = bandOf(cell, journey);
    if (band) v.band = band;
    cells.push(v);
  }
  cells.sort((a, b) => verdictRank(b.verdict) - verdictRank(a.verdict));
  return { cells, unattached };
}

function headlineFor(verdict: SecurityVerdict, n: number): string {
  if (verdict === 'trusted') {
    return 'No fake-base-station signatures found. The network authenticated and encrypted as expected.';
  }
  if (verdict === 'warning') {
    return `${n} thing${n === 1 ? '' : 's'} worth a look — most have an ordinary explanation. Read the reasons before drawing a conclusion.`;
  }
  return 'This capture carries Layer-3 signatures associated with fake base stations. Review each finding — this is evidence to check, not proof.';
}

// ------------------------------------------------------------------------------------------------------- helpers

function finding(
  check: SecurityCheckId,
  severity: SecurityFinding['severity'],
  title: string,
  event: Event | undefined,
  rest: { explanation: string; evidence: string[] },
): SecurityFinding {
  const f: SecurityFinding = {
    id: event ? `${check}-${event.index}` : check,
    check,
    severity,
    title,
    explanation: rest.explanation,
    evidence: rest.evidence,
  };
  if (event) {
    f.event = event.index;
    f.tMs = event.sinceStartMs;
    if (event.cell) f.cell = event.cell;
  }
  return f;
}

/** The first matching field's value, searched depth-first through the field tree. */
function fieldValue(fields: readonly Field[], label: string): string | null {
  for (const f of fields) {
    if (f.label === label) return f.value;
    const child = fieldValue(f.children, label);
    if (child !== null) return child;
  }
  return null;
}

function isAccept(e: Event): boolean {
  return /^(attach accept|tracking area update accept|registration accept|service accept)$/i.test(e.name);
}

function isSecurityModeCommand(e: Event): boolean {
  return e.key === 'securityModeCommand' || /^security mode command$/i.test(e.name);
}

function isInitialNasRequest(e: Event): boolean {
  return /^(attach request|tracking area update request|registration request|service request|extended service request)$/i.test(e.name);
}

function neighbourCellKeys(a: CaptureAnalysis): Set<string> {
  const keys = new Set<string>();
  // Measured intra-frequency neighbours (0xB179).
  for (const n of a.phySummary.intraFreqNeighbours ?? []) {
    keys.add(`${n.earfcn}/${n.pci}`);
    keys.add(`pci:${n.pci}`);
  }
  // PHY neighbour series that name a PCI in the tag or in pci.
  for (const s of a.phy) {
    if (!s.metric.startsWith('lte_neighbour')) continue;
    for (const x of s.samples) {
      if (x.pci != null) keys.add(`pci:${x.pci}`);
      const m = x.tag?.match(/(\d{1,3})/);
      if (m) keys.add(`pci:${Number(m[1])}`);
    }
  }
  // Neighbour PCIs named in decoded measurement-report fields ('PCI 388').
  for (const e of a.events) {
    if (e.key !== 'measurementReport') continue;
    collectPciLabels(e.fields, keys);
  }
  return keys;
}

function collectPciLabels(fields: readonly Field[], keys: Set<string>): void {
  for (const f of fields) {
    const m = f.label.match(/^PCI\s+(\d{1,3})$/);
    if (m) keys.add(`pci:${Number(m[1])}`);
    collectPciLabels(f.children, keys);
  }
}

function pcellCell(journey: Journey, tMs: number): Cell | null {
  const c = journey.cells.find((x) => x.lane === 'pcell' && tMs >= x.startMs && tMs <= x.endMs);
  return c?.cell ?? null;
}

function bandOf(cell: Cell, journey: Journey): string | undefined {
  return journey.cells.find((c) => c.cell.earfcn === cell.earfcn && c.cell.pci === cell.pci)?.band;
}

const cellKey = (c: Cell): string => `${c.earfcn}/${c.pci}${c.nr ? '/nr' : ''}`;
const pciKey = (c: Cell): string => `pci:${c.pci}`;

const severityRank = (s: SecurityFinding['severity']): number => (s === 'suspicious' ? 2 : s === 'warning' ? 1 : 0);
const verdictRank = (v: SecurityVerdict): number => (v === 'suspicious' ? 2 : v === 'warning' ? 1 : 0);
const severityToVerdict = (s: SecurityFinding['severity']): SecurityVerdict =>
  s === 'suspicious' ? 'suspicious' : s === 'warning' ? 'warning' : 'trusted';

function worst(verdicts: SecurityVerdict[]): SecurityVerdict {
  return verdicts.reduce<SecurityVerdict>((m, v) => (verdictRank(v) > verdictRank(m) ? v : m), 'trusted');
}
