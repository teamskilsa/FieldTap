// The sample capture: one invented scenario (test PLMN 001-01, made-up cells and counts). Everything shown is
// derived from SCRIPT with the contract's rules (procedures, moves, connections, journey J1-J12, ladder), so no
// number can disagree with another. Times are ms since the time base.
import type {
  CaptureAnalysis, Cell, Connection, Event, Field, Finding, ImportProblem, JourneyCell, JourneyState, LadderRow, Marker,
  PhyMetric, PhySample, PhySeries, Procedure, ProcedureGroup, Step, Tile,
} from '@engine/types';

export type SampleVariant = 'ok' | 'expiredSince' | 'traceGaps' | 'loggingOff' | 'notSysdiagnose';

const B2: Cell = { earfcn: 900, pci: 118, nr: false };
const B66: Cell = { earfcn: 66886, pci: 301, nr: false };
const B12: Cell = { earfcn: 5095, pci: 377, nr: false };
const NR: Cell = { earfcn: 656000, pci: 512, nr: true };
const NRP: Cell = { earfcn: 656000, pci: 0xffff, nr: true }; // D4: header before the SCG cell is assigned
const LTE = [
  { cell: B2, band: 2, mhz: 1960.0, ul: 18900, prb: 50, rx: 4 },
  { cell: B66, band: 66, mhz: 2155.0, ul: 132422, prb: 100, rx: 4 },
  { cell: B12, band: 12, mhz: 737.5, ul: 23095, prb: 50, rx: 2 },
];
const D = 24_600;
const lte = (c: Cell) => LTE.find((l) => l.cell.earfcn === c.earfcn)!;
const same = (a?: Cell, b?: Cell) => !!a && !!b && a.earfcn === b.earfcn && a.pci === b.pci && a.nr === b.nr;
const band = (c: Cell) => (c.nr ? 'n77' : `B${lte(c).band}`);
const short = (c: Cell) => (c.nr ? (c.pci === 0xffff ? 'NR cell pending' : `NR PCI ${c.pci}`) : `${band(c)} PCI ${c.pci}`);
const r1 = (v: number) => Math.round(v * 10) / 10;

/** "0:05.431", as CallFlowPresentation.sinceStart. */
export function sinceStart(ms: number): string {
  const t = Math.round(Math.max(0, ms));
  return `${Math.floor(t / 60_000)}:${String(Math.floor(t / 1000) % 60).padStart(2, '0')}.${String(t % 1000).padStart(3, '0')}`;
}
/** "36.8 ms", "268 ms", "1.86 s", as CallFlowPresentation.duration. */
export function duration(ms: number): string {
  const v = Math.max(0, ms);
  return v < 100 ? `${v.toFixed(1)} ms` : v < 1000 ? `${v.toFixed(0)} ms` : v < 10_000 ? `${(v / 1000).toFixed(2)} s` : `${(v / 1000).toFixed(1)} s`;
}

// Golden masking: identity-labelled fields become '<masked>'; other strings lose IPs, long digit runs, long hex.
const ID = /(^identity$|imsi|imei|tmsi|guti|ue identity|random ?value|address|\bip\b|dns|cell identity)/i;
const scrub = (s: string) => s.replace(/\b\d{1,3}(\.\d{1,3}){3}\b/g, '<masked>').replace(/\+?\d[\d ]{8,}\d/g, '<masked>').replace(/0x[0-9a-f]{8,}/gi, '<masked>');
type F = [string, string, F[]?];
function field([label, value, kids = []]: F, hidden = false): Field {
  const hide = hidden || ID.test(label), children = kids.map((k) => field(k, hide));
  const masked = hide && !children.length ? '<masked>' : scrub(value);
  return { label, value, children, ...(masked !== value ? { masked } : {}) };
}

// ------------------------------------------------------------------------------------------------ the script
const NAME: Record<string, string> = {
  systemInformationBlockType1: 'SIB1', systemInformation: 'System Information', rrcConnectionRequest: 'RRC Connection Request',
  rrcConnectionSetup: 'RRC Connection Setup', rrcConnectionSetupComplete: 'RRC Connection Setup Complete',
  securityModeCommand: 'Security Mode Command', securityModeComplete: 'Security Mode Complete', ueCapabilityEnquiry: 'UE Capability Enquiry',
  ueCapabilityInformation: 'UE Capability Information', rrcConnectionReconfiguration: 'RRC Connection Reconfiguration',
  rrcConnectionReconfigurationComplete: 'RRC Connection Reconfiguration Complete', measurementReport: 'Measurement Report',
  ulInformationTransfer: 'UL Information Transfer', rrcConnectionRelease: 'RRC Connection Release',
  'scgFailureInformationNR-r15': 'SCG Failure Information NR', rrcReconfiguration: 'RRC Reconfiguration', rrcReconfigurationComplete: 'RRC Reconfiguration Complete',
};
const ESM = ['PDN connectivity request', 'Activate default EPS bearer context request', 'Activate default EPS bearer context accept'];
const RCR = 'rrcConnectionReconfiguration', RCC = 'rrcConnectionReconfigurationComplete', MR = 'measurementReport';
const IMSI = '001010000012345';
// [ms, up?, key, cell, summary?, fields?, flag?]. RRC when the key is in NAME (NR RRC on an NR cell), else NAS.
type Line = [number, 0 | 1, string, Cell, (string | undefined)?, (F[] | undefined)?, ('ho' | 'fail' | 'ciph')?];
const SCRIPT: Line[] = [
  [184.0, 0, 'systemInformationBlockType1', B2, 'PLMN 001-01, not barred'],
  [229.5, 0, 'systemInformation', B2, 'SIB2, SIB3'],
  [410.0, 1, 'rrcConnectionRequest', B2, 'mo-Data', [['Establishment cause', 'mo-Data'], ['UE identity', 's-TMSI', [['M-TMSI', '0x5c1d0e2f']]]]],
  [441.2, 0, 'rrcConnectionSetup', B2],
  [452.6, 1, 'rrcConnectionSetupComplete', B2, 'carries Service request'],
  [452.6, 1, 'Service request', B2, 'KSI 2'],
  [470.9, 0, 'securityModeCommand', B2, 'EEA2 / EIA2'],
  [476.3, 1, 'securityModeComplete', B2],
  [488.0, 0, RCR, B2, 'DRB add, measConfig'],
  [494.7, 1, RCC, B2],
  [1902.4, 1, MR, B2, 'measId 1: serving RSRP -101 dBm', [['Measurement ID', '1'], ['Serving RSRP', '-101 dBm']]],
  [3120.0, 1, 'Detach request', B2, 'EPS detach, switch off', [['Detach type', 'EPS detach'], ['Switch off', 'yes']]],
  [3120.4, 1, 'ulInformationTransfer', B2, 'carries Detach request'],
  [3164.8, 0, 'rrcConnectionRelease', B2, 'cause other', [['Release cause', 'other']]],
  [5020.3, 0, 'systemInformationBlockType1', B66, 'PLMN 001-01, not barred'],
  [5041.8, 0, 'systemInformation', B66, 'SIB2, SIB3, SIB5'],
  [5388.0, 1, 'rrcConnectionRequest', B66, 'mo-Signalling', [['Establishment cause', 'mo-Signalling'], ['UE identity', 'random value', [['Random value', '0x2a917c0b35']]]]],
  [5418.3, 0, 'rrcConnectionSetup', B66],
  [5431.0, 1, 'rrcConnectionSetupComplete', B66, 'carries Attach request'],
  [5431.0, 1, 'Attach request', B66, `EPS attach, IMSI ${IMSI}`, [['Attach type', 'EPS attach'], ['Identity', 'IMSI', [['IMSI', IMSI]]]]],
  [5431.0, 1, 'PDN connectivity request', B66, 'APN ims, IPv4v6', [['APN', 'ims'], ['PDN type', 'IPv4v6']]],
  [5468.2, 0, 'Identity request', B66, 'IMSI', [['Identity requested', 'IMSI']]],
  [5475.9, 1, 'Identity response', B66, `IMSI ${IMSI}`, [['Identity', 'IMSI', [['IMSI', IMSI]]]]],
  [5512.6, 0, 'Authentication request', B66, 'KSI 0'],
  [5531.3, 1, 'Authentication response', B66],
  [5540.8, 0, 'Security mode command', B66, 'EEA2 / EIA2'],
  [5546.1, 1, 'Security mode complete', B66],
  [5561.0, 0, 'securityModeCommand', B66, 'EEA2 / EIA2'],
  [5566.2, 1, 'securityModeComplete', B66],
  [5574.9, 0, 'ueCapabilityEnquiry', B66, 'eutra, eutra-nr, nr'],
  [5583.5, 1, 'ueCapabilityInformation', B66, 'EN-DC B66 + n77, 4 Rx'],
  [5699.4, 0, RCR, B66, 'DRB add, carries Attach accept'],
  [5699.4, 0, 'Attach accept', B66, 'GUTI 001-01-0x8001-0x7e3a5b21, T3412 54 min',
    [['Attach result', 'EPS only'], ['Identity', 'GUTI', [['M-TMSI', '0x7e3a5b21']]], ['T3412', '54 min']]],
  [5699.4, 0, 'Activate default EPS bearer context request', B66, 'EPS bearer 5, APN ims, QCI 5',
    [['EPS bearer identity', '5'], ['APN', 'ims'], ['QCI', '5'], ['PDN address', '10.45.0.7']]],
  [5712.0, 1, RCC, B66],
  [5741.7, 1, 'ulInformationTransfer', B66, 'carries Attach complete'],
  [5741.7, 1, 'Attach complete', B66],
  [5741.7, 1, 'Activate default EPS bearer context accept', B66, 'EPS bearer 5'],
  [6254.0, 1, 'ciphered', B66, undefined, undefined, 'ciph'],
  [9712.5, 1, MR, B66, 'measId 7 (B1-NR): NR PCI 512, SS-RSRP -96 dBm'],
  [9806.2, 0, RCR, B66, 'nr-Config: SCG add, NR PCI 512'],
  [9806.9, 0, 'rrcReconfiguration', NRP, 'spCell NR-ARFCN 656000 PCI 512'],
  [9818.6, 1, RCC, B66],
  [9819.7, 1, 'rrcReconfigurationComplete', NR],
  [12511.3, 0, 'rrcReconfiguration', NR, 'SCG modify: BWP switch'],
  [12520.0, 1, 'rrcReconfigurationComplete', NR],
  [14488.6, 1, 'scgFailureInformationNR-r15', B66, 't310-Expiry', [['Failure type', 't310-Expiry']], 'fail'],
  [14530.2, 0, RCR, B66, 'nr-Config: release'],
  [14541.0, 1, RCC, B66],
  [15988.1, 1, MR, B66, 'measId 7 (B1-NR): NR PCI 512, SS-RSRP -99 dBm'],
  [16120.4, 0, RCR, B66, 'nr-Config: SCG add, NR PCI 512'],
  [16121.1, 0, 'rrcReconfiguration', NRP, 'spCell NR-ARFCN 656000 PCI 512'],
  [16133.0, 1, RCC, B66],
  [16134.9, 1, 'rrcReconfigurationComplete', NR],
  [17104.6, 1, MR, B66, 'measId 3 (A3): B12 PCI 377, RSRP -95 dBm'],
  [17230.0, 0, RCR, B66, 'handover to B12 PCI 377', [['Handover', 'target PCI 377, EARFCN 5095']], 'ho'],
  [17266.8, 1, RCC, B12],
  [17301.5, 0, RCR, B12, 'SCell add: B2 PCI 118, B66 PCI 301'],
  [17310.2, 1, RCC, B12],
  [19640.0, 1, MR, B12, 'measId 2 (A3): B2 PCI 118, RSRP -93 dBm'],
  [21904.0, 0, RCR, B12, 'handover to B2 PCI 118, SCells released', [['Handover', 'target PCI 118, EARFCN 900']], 'ho'],
  [21933.4, 1, RCC, B2],
  [22480.7, 1, MR, B2, 'measId 1: serving RSRP -97 dBm'],
];
// PHY-only facts: RACH responses (0xB062), SCell activity (0xB173 carrier index), NR DL activity (0xB887).
const RACH = [{ tMs: 402.1, ta: 3, cell: B2 }, { tMs: 5380.2, ta: 5, cell: B66 }, { tMs: 17259.9, ta: 9, cell: B12 }, { tMs: 21927.0, ta: 2, cell: B2 }];
const SCELLS = [{ index: 1, cell: B2, firstMs: 17652.4, lastMs: 21897.6 }, { index: 2, cell: B66, firstMs: 17655.1, lastMs: 21898.0 }];
const NR_PHY: [number, number][] = [[9861.0, 14471.3], [16190.0, 17212.5]];

function channelOf(key: string, up: boolean, nr: boolean) {
  if (nr) return key === 'rrcReconfiguration' ? 'RRCReconfiguration' : 'RRCReconfigurationComplete';
  if (key.startsWith('systemInformation')) return 'BCCH-DL-SCH';
  return /^rrcConnection(Request|Setup)$/.test(key) ? (up ? 'UL-CCCH' : 'DL-CCCH') : up ? 'UL-DCCH' : 'DL-DCCH';
}
function buildEvents(startUtcMs: number): Event[] {
  return SCRIPT.map(([t, up, key, cell, summary, fs = [], flag], index) => {
    const rrc = key in NAME, sub = ESM.includes(key) || flag === 'ciph' ? 'ESM' : 'EMM';
    const carrierLine = rrc ? undefined : SCRIPT.find((l) => l[0] === t && l[1] === up && l[2] in NAME);
    const sm = summary === undefined ? undefined : scrub(summary), n = 12 + ((index * 7) % 40);
    return {
      index, record: 4000 + index * 1187, logCode: cell.nr ? '0xB821' : rrc ? '0xB0C0' : up ? '0xB0ED' : '0xB0EC',
      sinceStartMs: t, utcMs: startUtcMs + t, layer: rrc ? 'RRC' : 'NAS', rat: cell.nr ? 'NR' : 'LTE', uplink: !!up,
      channel: rrc ? channelOf(key, !!up, cell.nr) : sub, key, name: rrc ? NAME[key]! : flag === 'ciph' ? 'Ciphered ESM message' : key,
      summary, ...(sm !== summary ? { summaryMasked: sm } : {}), cell, fields: fs.map((f) => field(f)),
      ciphered: flag === 'ciph', isFailure: flag === 'fail', isHandoverCommand: flag === 'ho',
      // NAS rides in the RRC message logged at the same moment, else in an Information Transfer.
      carrier: rrc || flag ? undefined : carrierLine ? `carried in ${channelOf(carrierLine[2], !!up, false)} ${NAME[carrierLine[2]]}`
        : `carried in ${up ? 'UL-DCCH UL' : 'DL-DCCH DL'} Information Transfer`,
      pduLength: n, pduHex: Array.from({ length: n }, (_, i) => ((index * 31 + i * 17) & 0xff).toString(16).padStart(2, '0')).join(''),
    };
  });
}

// ------------------------------------------------------------------------------ CallFlow rules (Kotlin, v1)
const RULES: [string, string[], string[]][] = [
  ['RRC connection setup', ['rrcConnectionRequest'], ['rrcConnectionSetupComplete']],
  ['AS security', ['securityModeCommand'], ['securityModeComplete']],
  ['UE capability', ['ueCapabilityEnquiry'], ['ueCapabilityInformation']],
  ['RRC reconfiguration', [RCR, 'rrcReconfiguration'], [RCC, 'rrcReconfigurationComplete']],
  ['Attach', ['Attach request'], ['Attach accept']],
  ['Service request', ['Service request'], ['Service accept', 'securityModeCommand']],
  ['Detach', ['Detach request'], ['Detach accept']],
  ['Authentication', ['Authentication request'], ['Authentication response']],
  ['NAS security', ['Security mode command'], ['Security mode complete']],
  ['Identity', ['Identity request'], ['Identity response']],
  ['PDN connectivity', ['PDN connectivity request'], ['Activate default EPS bearer context accept']],
];
function buildProcedures(ev: Event[]): Procedure[] {
  const done: Procedure[] = [];
  let open: { rule: (typeof RULES)[number]; name: string; start: Event }[] = [];
  const close = (o: (typeof open)[number], end: Event) => {
    open = open.filter((x) => x !== o);
    const s = o.start.summary, dm = s === undefined ? undefined : scrub(s);
    done.push({ name: o.name, layer: o.start.layer, detail: s, ...(dm !== s ? { detailMasked: dm } : {}), first: o.start.index, last: end.index,
      outcome: 'SUCCEEDED', durationMs: r1(end.sinceStartMs - o.start.sinceStartMs) });
  };
  for (const e of ev) {
    for (const o of [...open]) if (o.start.rat === e.rat && o.rule[2].includes(e.key)) close(o, e); // D3: same RAT only
    const rule = RULES.find((r) => r[1].includes(e.key));
    if (!rule) continue;
    const o = { rule, name: rule[0] === 'RRC reconfiguration' && e.isHandoverCommand ? 'Handover' : rule[0], start: e };
    open.push(o);
    if (rule[0] === 'Detach' && e.fields.some((f) => f.label === 'Switch off' && f.value === 'yes')) close(o, e);
  }
  if (open.length) throw new Error('sample: unanswered procedure');
  return done.sort((a, b) => a.first - b.first);
}
function buildSteps(ev: Event[]): Step[] {
  const steps: Step[] = [];
  let cur: Cell | undefined, connected = false, ho = false;
  for (const e of ev) {
    if (e.layer !== 'RRC' || !/CCCH|DCCH|PCCH/.test(e.channel) || !e.cell) continue;
    if (!cur) steps.push({ move: 'FIRST_SEEN', to: e.cell, event: e.index, sinceStartMs: e.sinceStartMs });
    else if (!same(cur, e.cell)) {
      const move = ho ? 'HANDOVER' : !connected || e.key === 'rrcConnectionRequest' ? 'RESELECTION' : 'CELL_CHANGE';
      steps.push({ move, from: cur, to: e.cell, event: e.index, sinceStartMs: e.sinceStartMs,
        ...(move === 'RESELECTION' ? { annotation: 'Reselection, after switch-off detach' } : {}) });
      ho = false;
      if (move === 'RESELECTION') connected = false;
    }
    cur = e.cell;
    if (e.key === 'rrcConnectionRelease') connected = ho = false;
    else if (e.isHandoverCommand) ho = true;
    else if (e.key === 'rrcConnectionSetup' || e.channel.endsWith('DCCH')) connected = true;
  }
  return steps;
}
function buildConnections(ev: Event[]): Connection[] {
  const out: Connection[] = [];
  let req: Event | undefined, open: Event | undefined;
  const cause = (e: Event) => e.fields.find((f) => f.label === 'Establishment cause')?.value;
  for (const e of ev) {
    if (e.key === 'rrcConnectionRequest') req = e;
    else if (e.key === 'rrcConnectionSetup') { open = req ?? e; req = undefined; }
    else if (e.key === 'rrcConnectionRelease' && open) {
      out.push({ first: open.index, last: e.index, establishmentCause: cause(open), releaseCause: e.fields[0]?.value, outcome: 'RELEASED',
        established: true, startMs: open.sinceStartMs, endMs: e.sinceStartMs });
      open = undefined;
    }
  }
  if (open) out.push({ first: open.index, establishmentCause: cause(open), outcome: 'OPEN_AT_END', established: true, startMs: open.sinceStartMs });
  return out;
}

// ----------------------------------------------------------------------------------------------- the journey
function buildJourney(ev: Event[], procs: Procedure[], steps: Step[], conns: Connection[]) {
  const at = (i: number) => ev[i]!;
  const P = (n: string) => procs.filter((p) => p.name === n);
  const detach = ev.find((e) => e.key === 'Detach request' && e.fields.some((f) => f.label === 'Switch off'))!;
  const release = ev.find((e) => e.key === 'rrcConnectionRelease' && e.sinceStartMs >= detach.sinceStartMs && e.sinceStartMs - detach.sinceStartMs <= 2000);
  const off = release?.sinceStartMs ?? detach.sinceStartMs; // J3
  const back = ev.find((e) => e.layer === 'RRC' && e.sinceStartMs > off)!.sinceStartMs;
  const states: JourneyState[] = [{ state: 'unknown', startMs: 0, endMs: ev.find((e) => e.layer === 'RRC')!.sinceStartMs }];
  const push = (s: JourneyState) => {
    const end = states[states.length - 1]!.endMs;
    if (s.startMs > end) states.push({ state: 'idle', startMs: end, endMs: s.startMs }); // J4
    states.push(s);
  };
  conns.forEach((c, i) => {
    if (c.startMs > back && !states.some((s) => s.state === 'radioOff')) push({ state: 'radioOff', startMs: off, endMs: back, source: 'switch-off detach' });
    push({ state: 'connected', startMs: c.startMs, endMs: c.endMs ?? D, source: `connection ${i} ${c.outcome}`, ...(c.endMs === undefined ? { openAtEnd: true } : {}) });
  });
  const attach = P('Attach')[0]!, registered = at(attach.last).sinceStartMs; // J5
  const registration = [{ state: 'registered' as const, startMs: 0, endMs: detach.sinceStartMs, assumed: true },
    { state: 'deregistered' as const, startMs: detach.sinceStartMs, endMs: registered, assumed: false },
    { state: 'registered' as const, startMs: registered, endMs: D, assumed: false }];
  const mhz = (c: Cell) => (c.nr ? 3840.0 : lte(c).mhz);
  let prevEnd = 0;
  const cells: JourneyCell[] = steps.map((st, i) => { // J6
    const next = steps[i + 1];
    const firstOn = ev.find((e) => e.layer === 'RRC' && same(e.cell, st.to) && e.sinceStartMs >= prevEnd)!.sinceStartMs;
    const end = next ? (off > st.sinceStartMs && off < next.sinceStartMs ? off : next.sinceStartMs) : D;
    prevEnd = end;
    return { lane: 'pcell', index: i, cell: st.to, band: band(st.to), dlMhz: mhz(st.to), startMs: Math.min(st.sinceStartMs, firstOn), endMs: end,
      endInferred: false, source: 'rrc', ...(next ? { endReason: end === off ? 'radio off (switch-off detach)' : `handover to ${band(next.to)}` } : { openAtEnd: true }),
      startReason: st.move === 'FIRST_SEEN' ? 'first seen' : st.move === 'RESELECTION' ? 're-attach after radio off' : `handover from ${band(st.from!)}` };
  });
  // J8: an NR reconfiguration on a pending cell starts an SCG; it ends at an SCG failure or the next LTE handover command.
  ev.filter((e) => e.rat === 'NR' && e.key === 'rrcReconfiguration' && e.cell?.pci === 0xffff).forEach((add, k) => {
    const done = ev.find((e) => e.rat === 'NR' && e.index > add.index && e.cell?.pci !== 0xffff)!;
    const endEv = ev.find((e) => e.index > add.index && (e.isFailure || e.isHandoverCommand));
    const ho = !!endEv?.isHandoverCommand;
    cells.push({ lane: 'pscell', index: k, cell: done.cell!, band: 'n77', bandCandidates: [77], dlMhz: 3840.0, startMs: add.sinceStartMs,
      endMs: endEv?.sinceStartMs ?? D, addedMs: done.sinceStartMs, endInferred: ho, source: 'rrc', startReason: 'SCG addition',
      endReason: ho ? 'LTE handover command (SCG released)' : `SCG failure (${endEv?.summary})`, ...(ho ? { phyLastMs: NR_PHY[k]![1] } : {}) });
  });
  for (const c of SCELLS) cells.push({ lane: 'scell', index: c.index, cell: c.cell, band: band(c.cell), dlMhz: mhz(c.cell), startMs: c.firstMs, // J9
    endMs: c.lastMs, endInferred: false, source: 'phy', startReason: 'SCell active (from PHY)', endReason: 'SCell inactive (from PHY)' });

  const m: Marker[] = RACH.map((r) => ({ id: `rach-${r.tMs.toFixed(1)}`, kind: 'rach', tMs: r.tMs, severity: 'info', title: `Random access on ${short(r.cell)}`,
    detail: `TA ${r.ta}, about ${Math.round(r.ta * 78.12)} m from the cell`, ta: r.ta, distanceM: r1(r.ta * 78.12) })); // J10
  for (const p of P('RRC connection setup')) m.push({ id: `rrcSetup-${p.first}`, kind: 'rrcSetup', tMs: at(p.first).sinceStartMs, event: p.first, endEvent: p.last,
    severity: 'info', title: `RRC connection set up on ${short(at(p.first).cell!)}`, detail: `${p.detail}, ${duration(p.durationMs)}`, durationMs: p.durationMs });
  m.push({ id: `detachSwitchOff-${detach.index}`, kind: 'detachSwitchOff', tMs: detach.sinceStartMs, event: detach.index, severity: 'info',
    title: 'Switched off (switch-off detach)', detail: `Radio off for ${duration(back - off)}` });
  if (release) m.push({ id: `rrcRelease-${release.index}`, kind: 'rrcRelease', tMs: off, event: release.index, severity: 'info', title: 'RRC connection released', detail: 'cause other' });
  const re = steps.find((s) => s.move === 'RESELECTION')!; // J7: a reselection after radio off, then an Attach, is a re-attach
  m.push({ id: `reattach-${re.event}`, kind: 'reattach', tMs: re.sinceStartMs, event: re.event, severity: 'info', from: re.from, to: re.to,
    title: `Re-attached on ${short(re.to)}`, detail: `Attach accepted in ${duration(attach.durationMs)}` });
  m.push({ id: `attach-${attach.first}`, kind: 'attach', tMs: at(attach.first).sinceStartMs, event: attach.first, endEvent: attach.last, severity: 'info',
    title: 'Attach accepted', detail: duration(attach.durationMs), durationMs: attach.durationMs });
  for (const c of cells.filter((x) => x.lane === 'pscell')) {
    const add = ev.find((e) => e.rat === 'NR' && e.sinceStartMs === c.startMs)!, p = procs.find((x) => x.first === add.index)!;
    m.push({ id: `scgAdd-${add.index}`, kind: 'scgAdd', tMs: c.startMs, event: add.index, endEvent: p.last, severity: 'info', to: c.cell,
      title: `5G NR leg added: n77 PCI ${c.cell.pci}`, detail: `NR-ARFCN ${c.cell.earfcn}, ${duration(p.durationMs)}`, durationMs: p.durationMs });
    const endEv = ev.find((e) => e.sinceStartMs === c.endMs)!;
    if (c.endInferred) m.push({ id: `scgRelease-${endEv.index}`, kind: 'scgRelease', tMs: c.endMs, event: endEv.index, severity: 'info', inferred: true,
      title: 'NR leg released at the handover (inferred)' });
  }
  for (const e of ev.filter((x) => x.rat === 'NR' && x.key === 'rrcReconfiguration' && x.cell?.pci !== 0xffff))
    m.push({ id: `scgModify-${e.index}`, kind: 'scgModify', tMs: e.sinceStartMs, event: e.index, severity: 'info', title: 'NR leg reconfigured', detail: e.summary });
  for (const e of ev.filter((x) => x.isFailure)) // J11
    m.push({ id: `failure-${e.index}`, kind: 'failure', tMs: e.sinceStartMs, event: e.index, severity: 'failure', title: `SCG failure: ${e.summary}`, detail: 'The 5G NR leg was lost' });
  for (const p of P('Handover')) m.push({ id: `handover-${p.first}`, kind: 'handover', tMs: at(p.first).sinceStartMs, event: p.first, endEvent: p.last,
    severity: 'info', from: at(p.first).cell, to: at(p.last).cell, arrivalMs: at(p.last).sinceStartMs, durationMs: p.durationMs,
    title: `Handover ${band(at(p.first).cell!)} → ${short(at(p.last).cell!)}`, detail: duration(p.durationMs) });
  const RANK = ['failure', 'detachSwitchOff', 'reattach', 'handover', 'scgRelease', 'scgAdd', 'scgModify', 'rrcSetup', 'attach', 'rrcRelease', 'rach'];
  m.sort((a, b) => a.tMs - b.tMs || RANK.indexOf(a.kind) - RANK.indexOf(b.kind));
  return { states, registration, cells, markers: m, detach, off, back, attach };
}

// ------------------------------------------------------------------------------------------------ radio model
const wob = (t: number, k: number) => Math.sin(t / 377 + k) * 0.6 + Math.sin(t / 1311 + 2 * k) * 1.1; // deterministic noise
const mod = (mcs: number) => (mcs >= 20 ? '256QAM' : mcs >= 11 ? '64QAM' : mcs >= 5 ? '16QAM' : 'QPSK');
const every = (a: number, b: number, step: number) => Array.from({ length: Math.max(0, Math.floor((b - a) / step) + 1) }, (_, i) => r1(a + i * step));
function buildPhy(cells: JourneyCell[]) {
  const RSRP: [number, number][] = [[-100, -102], [-86, -97], [-90, -94], [-94, -89]]; // start/end dBm per PCell segment
  const segs = cells.filter((c) => c.lane === 'pcell').map((c, i) => ({ cell: c.cell, from: c.startMs, to: c.endMs, rsrp: RSRP[i]! }));
  type Seg = (typeof segs)[number];
  const rsrp = (g: Seg, t: number) => g.rsrp[0] + ((g.rsrp[1] - g.rsrp[0]) * (t - g.from)) / (g.to - g.from) + wob(t, g.cell.pci);
  const rsrq = (g: Seg, t: number) => -9 - Math.max(0, -90 - rsrp(g, t)) * 0.35;
  const cqi = (g: Seg, t: number) => Math.max(3, Math.min(15, Math.round((rsrp(g, t) + 118) / 2.2)));
  const mcs = (g: Seg, t: number) => Math.max(2, Math.min(27, Math.round(cqi(g, t) * 1.8 + wob(t, 9) * 1.5)));
  const ri = (g: Seg, t: number) => (lte(g.cell).rx === 4 && cqi(g, t) >= 9 ? 2 : 1);
  const pusch = (g: Seg, t: number) => r1(Math.min(26, -rsrp(g, t) - 78));
  const on = (step: number, f: (g: Seg, t: number) => Omit<PhySample, 'tMs'> | null) =>
    segs.flatMap((g) => every(g.from + 20, g.to - 5, step).flatMap((t) => { const v = f(g, t); return v ? [{ tMs: t, ...v }] : []; }));
  const S = (metric: PhyMetric, title: string, unit: string, section: PhySeries['section'], code: string, samples: PhySample[], extra: Partial<PhySeries> = {}): PhySeries =>
    ({ metric, title, unit, section, confidence: 'high', code, samples, ...extra });
  // One LTE transport block per carrier every 40 ms stands for that 40 ms; 1 in 97 is a retransmission (MCS 29-31).
  const tbs: PhySample[] = on(40, (g, t) => ({ value: mcs(g, t), carrier: 0, cell: g.cell, tag: mod(mcs(g, t)) }))
    .concat(SCELLS.flatMap((c) => every(c.firstMs, c.lastMs, 40).map((t) => {
      const v = Math.max(2, Math.min(27, Math.round(21 + wob(t, c.index * 5) * 2)));
      return { tMs: t, value: v, carrier: c.index, cell: c.cell, tag: mod(v) };
    }))).sort((a, b) => a.tMs - b.tMs);
  tbs.forEach((x, i) => { if (i % 97 === 13) { x.value = 29 + (i % 3); x.tag = 'retx'; } });
  const bins = new Map<string, { tMs: number; carrier: number; cell: Cell; bits: number }>(); // per whole second and carrier
  for (const x of tbs) {
    if (x.tag === 'retx' || !x.cell) continue;
    const sec = Math.floor(x.tMs / 1000), key = `${sec}:${x.carrier}`, g = segs.find((s) => x.tMs >= s.from && x.tMs <= s.to);
    const layers = x.carrier === 0 && g ? ri(g, x.tMs) : 2;
    const b = bins.get(key) ?? { tMs: sec * 1000 + 500, carrier: x.carrier ?? 0, cell: x.cell, bits: 0 };
    b.bits += lte(x.cell).prb * 0.8 * layers * ((x.value ?? 0) * 12 + 60) * 25;
    bins.set(key, b);
  }
  const dl = [...bins.values()].map((b) => ({ tMs: b.tMs, value: r1(b.bits / 1e6), carrier: b.carrier, cell: b.cell })).sort((a, b) => a.tMs - b.tMs || a.carrier - b.carrier);
  const nrT = NR_PHY.flatMap(([a, b]) => every(a, b, 20));
  const nrRsrp = (t: number) => (t < 14_600 ? -95 - Math.max(0, (t - 12_800) / 1_700) * 16 : -101) + wob(t, 4); // falls before the SCG failure
  const nrMcs = (t: number) => Math.max(1, Math.min(27, Math.round((nrRsrp(t) + 122) * 1.05 + wob(t, 6))));
  const nrBins = new Map<number, number>();
  for (const t of nrT) nrBins.set(Math.floor(t / 1000), (nrBins.get(Math.floor(t / 1000)) ?? 0) + 273 * 0.7 * 2 * (nrMcs(t) * 14 + 40) * 40);
  const series = [
    S('lte_rsrp_per_rx', 'RSRP per receive antenna', 'dBm', 'signal', '0xB193', on(80, (g, t) => {
      const per = [0, -1.8, -4.1, -5.6].map((d, i) => (i < lte(g.cell).rx ? r1(rsrp(g, t) + d + wob(t, i + 3) * 0.4) : null));
      return { value: per[0] ?? null, perIndex: per, carrier: 0, cell: g.cell };
    })),
    S('lte_rsrp_filtered', 'Serving RSRP (filtered)', 'dBm', 'signal', '0xB193', on(80, (g, t) => ({ value: r1(rsrp(g, t)), carrier: 0, cell: g.cell }))),
    S('lte_rsrq_filtered', 'Serving RSRQ (filtered)', 'dB', 'signal', '0xB193', on(80, (g, t) => ({ value: r1(rsrq(g, t)), carrier: 0, cell: g.cell }))),
    S('lte_rssi', 'RSSI', 'dBm', 'signal', '0xB193', on(80, (g, t) => ({ value: r1(rsrp(g, t) - rsrq(g, t) + 10 * Math.log10(lte(g.cell).prb)), carrier: 0, cell: g.cell }))),
    S('lte_neighbour_rsrp', 'Neighbour RSRP', 'dBm', 'signal', '0xB193', on(400, (g, t) =>
      same(g.cell, B66) && t > 14_000 ? { value: r1(-112 + (t - 14_000) / 190 + wob(t, 7)), pci: 377, earfcn: 5095, tag: 'PCI 377' } : null)),
    S('lte_dl_mcs', 'DL MCS per transport block', 'index', 'downlink', '0xB173', tbs),
    S('lte_dl_prb', 'DL PRBs per transport block', 'PRB', 'downlink', '0xB173', tbs.filter((x) => x.tag !== 'retx').map((x) => ({ tMs: x.tMs,
      value: Math.round(lte(x.cell!).prb * (0.55 + 0.3 * Math.abs(Math.sin(x.tMs / 510)))), carrier: x.carrier, cell: x.cell }))),
    S('lte_dl_bler', 'DL BLER per second', '%', 'downlink', '0xB173', dl.filter((x) => x.carrier === 0).map((x) => ({ tMs: x.tMs, value: r1(Math.max(0, 6 + wob(x.tMs, 2) * 3)), carrier: 0 }))),
    S('lte_dl_phy_throughput', 'DL PHY throughput per second', 'Mbit/s', 'downlink', '0xB173', dl),
    S('lte_dl_layers', 'DL layers used', 'layers', 'downlink', '0xB173', on(200, (g, t) => ({ value: ri(g, t), carrier: 0 }))),
    S('lte_ul_prb', 'UL PRBs', 'PRB', 'uplink', '0xB139', on(120, (_, t) => ({ value: Math.max(1, Math.round(8 + wob(t, 11) * 5)) }))),
    S('lte_ul_mcs_derived', 'UL MCS', 'index', 'uplink', '0xB139', on(120, (g, t) => ({ value: Math.min(20, Math.round(cqi(g, t) * 1.2)) })), { confidence: 'derived', badges: ['derived'] }),
    S('lte_pusch_tx_power_required', 'Required PUSCH power', 'dBm', 'uplink', '0xB139', on(120, (g, t) => ({ value: pusch(g, t) })), { badges: ['before Pcmax'] }),
    S('lte_power_headroom', 'Power headroom', 'dB', 'uplink', '0xB064', on(400, (g, t) => ({ value: Math.round(23 - pusch(g, t)) }))),
    S('lte_ul_phy_throughput', 'UL scheduled per second', 'Mbit/s', 'uplink', '0xB139', dl.filter((x) => x.carrier === 0).map((x) => ({ tMs: x.tMs, value: r1(x.value * 0.11) })), { badges: ['UL scheduled'] }),
    S('lte_cqi_wideband_cw0', 'Wideband CQI (codeword 0)', 'index', 'csi', '0xB14E', on(80, (g, t) => ({ value: cqi(g, t), carrier: 0 }))),
    S('lte_ri', 'Rank indicator', 'rank', 'csi', '0xB14E', on(160, (g, t) => ({ value: ri(g, t), carrier: 0 }))),
    S('lte_pmi_wideband', 'Wideband PMI', 'index', 'csi', '0xB14D', on(320, (_, t) => ({ value: Math.abs(Math.round(wob(t, 13) * 2)) % 4 })), { confidence: 'medium', badges: ['medium confidence'] }),
    S('nr_ss_rsrp', 'NR SS-RSRP', 'dBm', 'nr', '0xB97F', NR_PHY.flatMap(([a, b]) => every(a, b, 160)).map((t) => ({ tMs: t, value: r1(nrRsrp(t)), pci: 512, tag: 'PCI 512' }))),
    S('nr_dl_mcs', 'NR DL MCS per slot', 'index', 'nr', '0xB887', nrT.map((t) => ({ tMs: t, value: nrMcs(t), carrier: 0, tag: mod(nrMcs(t)) }))),
    S('nr_dl_layers', 'NR DL layers', 'layers', 'nr', '0xB887', nrT.filter((_, i) => i % 5 === 0).map((t) => ({ tMs: t, value: nrRsrp(t) > -104 ? 2 : 1, carrier: 0 }))),
    S('nr_dl_mac_throughput', 'NR DL MAC throughput per second', 'Mbit/s', 'nr', '0xB888', [...nrBins].map(([s, bits]) => ({ tMs: s * 1000 + 500, value: r1(bits / 1e6), carrier: 0 }))),
    S('lte_timing_advance_rar', 'Timing advance at random access', 'TA', 'rach', '0xB062', RACH.map((r) => ({ tMs: r.tMs, value: r.ta, earfcn: r.cell.earfcn, pci: r.cell.pci }))),
    S('lte_rx_antennas_measured', 'Rx antennas measured', 'antennas', 'antennas', '0xB193', on(400, (g) => ({ value: lte(g.cell).rx, carrier: 0, cell: g.cell }))),
  ];
  const perSec = new Map<number, number>();
  for (const b of dl) perSec.set(b.tMs, (perSec.get(b.tMs) ?? 0) + b.value);
  return { series, tbs, nrT, ltePeak: Math.max(...perSec.values()), nrPeak: Math.max(...[...nrBins.values()].map((b) => b / 1e6)) };
}

// ---------------------------------------------------------------------------------------------------- ladder
function ladderRows(ev: Event[], procs: Procedure[], steps: Step[], filter: 'ALL' | 'RRC' | 'NAS'): LadderRow[] {
  const shown = ev.filter((e) => filter === 'ALL' || e.layer === filter);
  const moves = new Map<number, Step>(filter === 'NAS' ? [] : steps.filter((s) => s.move !== 'FIRST_SEEN').map((s) => [s.event, s]));
  const starts = (e: Event) => procs.some((p) => p.first === e.index);
  const rows: LadderRow[] = [];
  for (let i = 0; i < shown.length;) {
    const e = shown[i]!, mv = moves.get(e.index);
    if (mv) rows.push({ type: 'move', key: `move-${e.index}`, step: steps.indexOf(mv), move: mv.move, to: short(mv.to), band: band(mv.to), downlink: `${lte(mv.to).mhz.toFixed(1)} MHz` });
    procs.forEach((p, n) => { if (p.first === e.index && (filter === 'ALL' || p.layer === filter))
      rows.push({ type: 'procedure', key: `procedure-${n}`, procedure: n, name: p.name, outcome: p.outcome, duration: duration(p.durationMs) }); });
    let end = i + 1; // fold runs of broadcast messages
    if (e.channel.startsWith('BCCH')) while (end < shown.length && shown[end]!.channel.startsWith('BCCH') && !moves.has(shown[end]!.index) && !starts(shown[end]!)) end++;
    const run = shown.slice(i + 1, end), cs = [...new Set([e, ...run].map((x) => short(x.cell!)))], prev = shown[i - 1];
    rows.push({ type: 'message', key: `event-${e.index}`, event: e.index, repeats: run.map((x) => x.index), name: e.name, count: 1 + run.length,
      mixed: run.some((x) => x.key !== e.key || !same(x.cell, e.cell)), cells: cs.slice(0, 2).join(', ') + (cs.length > 2 ? ` +${cs.length - 2}` : ''),
      cellCount: cs.length, since: sinceStart(e.sinceStartMs), ...(prev ? { gap: duration(e.sinceStartMs - prev.sinceStartMs) } : {}) });
    i = end;
  }
  return rows;
}
function groups(procs: Procedure[]): ProcedureGroup[] {
  return [...new Set(procs.map((p) => p.name))].map((name) => {
    const idx = procs.flatMap((p, i) => (p.name === name ? [i] : []));
    const ok = idx.map((i) => procs[i]!).filter((p) => p.outcome === 'SUCCEEDED').map((p) => p.durationMs).sort((a, b) => a - b), mid = ok.length >> 1;
    const median = ok.length ? (ok.length % 2 ? ok[mid]! : (ok[mid - 1]! + ok[mid]!) / 2) : undefined;
    return { name, layer: procs[idx[0]!]!.layer, n: idx.length, succeeded: ok.length, failed: 0, unanswered: 0,
      ...(median === undefined ? {} : { median: duration(median) }), procedures: idx };
  });
}

// ---------------------------------------------------------------------------------------------- the analysis
const DAY = 86_400_000, HOUR = 3_600_000;
function archiveName(press: number) { // the phone's local time and UTC offset, as iOS names it
  const d = new Date(press), p = (n: number) => String(n).padStart(2, '0'), o = -d.getTimezoneOffset();
  return `sysdiagnose_${d.getFullYear()}.${p(d.getMonth() + 1)}.${p(d.getDate())}_${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}` +
    `${o >= 0 ? '+' : '-'}${p(Math.floor(Math.abs(o) / 60))}${p(Math.abs(o) % 60)}_iPhone-OS_iPhone_SAMPLE.tar.gz`;
}

/** The sample, relative to `now` so the profile dates always read the same way. */
export function createSampleAnalysis(opts: { now?: number; variant?: SampleVariant } = {}): CaptureAnalysis {
  const now = opts.now ?? Date.now(), v = opts.variant ?? 'ok', iso = (ms: number) => new Date(ms).toISOString();
  const press = Math.floor((now - (v === 'expiredSince' ? 5 * HOUR : 8_040_000)) / 1000) * 1000;
  const removal = (v === 'expiredSince' ? press - 6 * DAY - 22 * HOUR : press - 2 * DAY - 18_720_000) + 7 * DAY;
  const blocking = v === 'loggingOff' || v === 'notSysdiagnose', soon = removal - press < DAY;
  const profile = blocking ? { status: v === 'loggingOff' ? 'missing' as const : 'unknown' as const } : {
    status: soon ? 'expiringSoon' as const : 'active' as const, identifier: 'com.apple.basebandlogging', displayName: 'Baseband and Telephony Logging',
    installDate: iso(removal - 7 * DAY), removalDate: iso(removal), lifetimeDays: 7, observedAt: iso(press) };
  const gs = blocking ? (v === 'loggingOff' ? 'off' as const : 'unknown' as const) : now >= removal ? 'expired' as const : removal - now < DAY ? 'expiringSoon' as const : 'active' as const;
  const guide = { status: gs, ...(blocking ? {} : { removalDate: iso(removal), daysLeft: Math.max(0, Math.floor((removal - now) / DAY)) }), needsAttention: gs !== 'active', evaluatedAt: iso(now) };
  const problems: ImportProblem[] = [];
  if (v === 'notSysdiagnose') problems.push({ kind: 'notASysdiagnose', blocking: true, message: 'This file is not an iPhone sysdiagnose (.tar.gz).' });
  if (v === 'loggingOff') problems.push({ kind: 'loggingNotEnabled', blocking: true, message: 'Modem logging was off when this sysdiagnose was taken.' },
    { kind: 'noBasebandTrace', blocking: true, message: 'The archive holds no modem trace. Install Apple\'s Baseband profile, then record again.' });
  if (soon && !blocking) problems.push({ kind: 'profileExpiresSoon', blocking: false, date: iso(removal), message: 'The logging profile was about to expire when you recorded this. Reinstall it before your next capture.' });
  if (v === 'traceGaps') problems.push({ kind: 'traceGaps', blocking: false, detail: '2', message: '2 trace files are missing inside the kept window, so messages near them may be cut.' });
  const base = { contract: 'fieldtap-web/1' as const, fileName: archiveName(press), triggerTime: iso(press), profile, guide, problems, crcErrors: 0,
    timings: { reading: 3810, extracting: 420, deframing: 2350, decoding: 610, radio: 890 } };
  if (blocking) return { ...base, traceWindow: null, records: 0, codes: 0, encryptedRecords: 0, encrypted: { records: 0, codes: 0 }, durationMs: 0,
    events: [], procedures: [], steps: [], connections: [], cellDetails: [], ladder: { rows: { ALL: [], RRC: [], NAS: [] }, lanes: { phone: 'UE', ran: 'eNB', core: 'MME' }, procedureGroups: [] },
    journey: { durationMs: 0, states: [], registration: [], cells: [], markers: [], findings: [], tiles: [] },
    phy: [], phySummary: { scellActivity: [], rach: [], txAntennasMib: [], rxAntennasByEarfcn: {} }, phyChecks: [], versionMisses: {}, availability: [] };

  const startUtcMs = press + 6000; // the first kept trace file starts 6 s after the press
  const events = buildEvents(startUtcMs), procedures = buildProcedures(events), steps = buildSteps(events), connections = buildConnections(events);
  const j = buildJourney(events, procedures, steps, connections), phy = buildPhy(j.cells), at = (i: number) => events[i]!;
  const P = (n: string) => procedures.filter((p) => p.name === n), grp = groups(procedures), med = (n: string) => grp.find((g) => g.name === n)?.median ?? '—';
  const nr = j.cells.filter((c) => c.lane === 'pscell'), fail = events.find((e) => e.isFailure)!, pdn = P('PDN connectivity')[0]!;
  const scgAdds = procedures.filter((p) => at(p.first).rat === 'NR' && at(p.first).cell?.pci === 0xffff);
  const miss = v === 'traceGaps' ? 2 : 0, encrypted = { records: 17_905, codes: 54 };
  const traceWindow = { startUtc: iso(startUtcMs), endUtc: iso(startUtcMs + D + 300), afterPressStartS: 6, afterPressEndS: r1(6 + (D + 300) / 1000),
    filesKept: 124 - miss, filesOnPhone: 203, filesOverwritten: 79, filesMissing: miss };
  const findings: Finding[] = [
    { id: `radioOffOn-${j.detach.index}`, kind: 'radioOffOn' as const, severity: 'info' as const, tMs: j.detach.sinceStartMs, event: j.detach.index,
      text: `Switched off on ${short(j.detach.cell!)} at ${sinceStart(j.detach.sinceStartMs)}; radio back ${duration(j.back - j.off)} later` },
    { id: `reattach-${j.attach.first}`, kind: 'reattach' as const, severity: 'info' as const, tMs: at(j.attach.first).sinceStartMs, event: j.attach.first,
      text: `Re-attached on ${short(at(j.attach.first).cell!)} (EARFCN ${at(j.attach.first).cell!.earfcn}): Attach accepted in ${duration(j.attach.durationMs)}` },
    { id: `imsPdn-${pdn.first}`, kind: 'imsPdn' as const, severity: 'info' as const, tMs: at(pdn.first).sinceStartMs, event: pdn.first, text: `IMS PDN connected in ${duration(pdn.durationMs)}` },
    { id: `endcAdded-${scgAdds[0]!.first}`, kind: 'endcAdded' as const, severity: 'info' as const, tMs: nr[0]!.startMs, event: scgAdds[0]!.first,
      text: `5G NR leg added at ${sinceStart(nr[0]!.startMs)} (n77, NR-ARFCN ${NR.earfcn}, PCI ${NR.pci})` },
    { id: `failure-${fail.index}`, kind: 'failure' as const, severity: 'failure' as const, tMs: fail.sinceStartMs, event: fail.index,
      text: `NR leg lost at ${sinceStart(fail.sinceStartMs)}: SCG failure (${fail.summary}); re-added ${duration(nr[1]!.startMs - fail.sinceStartMs)} later` },
    ...P('Handover').map((p) => ({ id: `handover-${p.first}`, kind: 'handover' as const, severity: 'info' as const, tMs: at(p.first).sinceStartMs, event: p.first,
      text: `Handover ${band(at(p.first).cell!)} → ${short(at(p.last).cell!)} in ${duration(p.durationMs)}` })),
    { id: `carrierAggregation-${SCELLS[0]!.firstMs}`, kind: 'carrierAggregation' as const, severity: 'info' as const, tMs: SCELLS[0]!.firstMs,
      text: `Carrier aggregation on B12: ${SCELLS.length} SCells (${SCELLS.map((c) => short(c.cell)).join(', ')})` },
  ].sort((a, b) => a.tMs - b.tMs);
  findings.push( // J12: the fixed tail
    { id: 'failures', kind: 'failures', severity: 'failure', text: `1 failure (SCG failure at ${sinceStart(fail.sinceStartMs)}); all ${procedures.length} procedures were answered` },
    { id: 'encryptedRecords', kind: 'encryptedRecords', severity: 'info', text: `${encrypted.records.toLocaleString('en-US')} records in ${encrypted.codes} NR PHY codes are encrypted by the modem` },
    { id: 'traceWindow', kind: 'traceWindow', severity: 'info', text: `The trace covers ${traceWindow.afterPressStartS}–${Math.floor(traceWindow.afterPressEndS)} s after you pressed the buttons (${duration(D)}); ${traceWindow.filesOverwritten} older files were overwritten` });
  const tile = (id: string, group: Tile['group'], title: string, ps: Procedure[], value: string): Tile =>
    ({ id, group, title, succeeded: ps.filter((p) => p.outcome === 'SUCCEEDED').length, attempts: ps.length, value, ...(ps[0] ? { event: ps[0].first } : {}) });
  const lost = connections.filter((c) => c.outcome === 'LOST').length, addMs = scgAdds.map((p) => p.durationMs).sort((a, b) => a - b);
  const tiles: Tile[] = [
    tile('rrcSetup', 'Accessibility', 'RRC setup', P('RRC connection setup'), med('RRC connection setup')),
    tile('serviceRequest', 'Accessibility', 'Service request', P('Service request'), med('Service request')),
    tile('attach', 'Accessibility', 'Attach', P('Attach'), med('Attach')),
    tile('pdn', 'Accessibility', 'PDN connectivity', P('PDN connectivity'), med('PDN connectivity')),
    tile('handover', 'Mobility', 'Handover', P('Handover'), med('Handover')),
    tile('scgAdd', 'EN-DC', 'SCG addition', scgAdds, duration((addMs[0]! + addMs[addMs.length - 1]!) / 2)),
    { id: 'abnormalReleases', group: 'Retainability', title: 'Abnormal releases', succeeded: connections.length - lost, attempts: connections.length, value: String(lost) },
    { id: 'lteDlPeak', group: 'Integrity', title: 'LTE DL PHY peak', succeeded: 0, attempts: 0, value: `${phy.ltePeak.toFixed(1)} Mbit/s` },
    { id: 'nrDlPeak', group: 'Integrity', title: 'NR DL MAC peak', succeeded: 0, attempts: 0, value: `${phy.nrPeak.toFixed(1)} Mbit/s` },
  ];
  return {
    ...base, traceWindow, records: 81_240, codes: 208, encrypted, encryptedRecords: encrypted.records, durationMs: D, startUtc: iso(startUtcMs),
    events, procedures, steps, connections,
    cellDetails: LTE.map((l, i) => ({ cell: l.cell, pci: l.cell.pci, downlinkEarfcn: l.cell.earfcn, uplinkEarfcn: l.ul, band: l.band, plmn: '001-01',
      tac: 0x0101 + i, cellIdentity: 0x01a2b300 + i, bandwidthMhz: l.prb / 5 })),
    ladder: { rows: { ALL: ladderRows(events, procedures, steps, 'ALL'), RRC: ladderRows(events, procedures, steps, 'RRC'), NAS: ladderRows(events, procedures, steps, 'NAS') },
      lanes: { phone: 'UE', ran: 'RAN', core: 'Core' }, procedureGroups: grp },
    journey: { durationMs: D, states: j.states, registration: j.registration, cells: j.cells, markers: j.markers, findings, tiles },
    phy: phy.series,
    phySummary: {
      scellActivity: SCELLS.map((c) => ({ index: c.index, earfcn: c.cell.earfcn, pci: c.cell.pci, firstMs: c.firstMs, lastMs: c.lastMs,
        records: phy.tbs.filter((t) => t.carrier === c.index).length, source: '0xB173' })),
      nrDlActivity: { index: 0, firstMs: NR_PHY[0]![0], lastMs: NR_PHY[1]![1], records: phy.nrT.length, source: '0xB887' },
      rach: RACH.map((r) => ({ tMs: r.tMs, ta: r.ta, distanceM: r1(r.ta * 78.12), ulEarfcn: lte(r.cell).ul })),
      txAntennasMib: [4],
      rxAntennasByEarfcn: Object.fromEntries(LTE.map((l) => [String(l.cell.earfcn), { [String(l.rx)]: phy.series[0]!.samples.filter((x) => same(x.cell, l.cell)).length }])),
    },
    phyChecks: [
      { id: 'rsrq-identity', code: '0xB193', passed: true, measured: `${phy.series[2]!.samples.length} records, sd 0.00 dB`, expectation: 'RSRQ = RSRP − RSSI + 10·log10(N_RB)' },
      { id: 'tbs-table', code: '0xB173', passed: true, measured: `${phy.tbs.length} of ${phy.tbs.length} TBs`, expectation: 'Every TBS is in the 36.213 table' },
    ],
    versionMisses: {},
    availability: [
      { id: 'signalling', title: 'LTE and NR RRC, NAS signalling', status: 'available', reason: 'Decoded from the plain modem records.' },
      { id: 'lte-phy', title: 'LTE signal, MCS, PRBs, CQI, rank, UL power', status: 'available', reason: 'Plain PHY records with validated versions.' },
      { id: 'nr-sinr', title: 'NR SINR and firmware CSI', status: 'encryptedByModem', reason: 'The modem encrypts these records; only their headers can be read.', codes: ['0xB8DD', '0xB8E2'] },
      { id: 'lte-sinr', title: 'LTE SINR', status: 'notFoundInPlainLogs', reason: 'No plain record decoded so far carries it.' },
      { id: 'nr-ul', title: 'NR uplink schedule and power', status: 'notDecodedYet', reason: 'Plain records, on the roadmap.', codes: ['0xB883', '0xB884'] },
      { id: 'live', title: 'Live values, or more than about half a minute', status: 'notOnIPhone', reason: 'iOS gives apps no modem data; the trace comes only in a sysdiagnose, and the modem keeps about 128 MB.' },
    ],
  };
}
