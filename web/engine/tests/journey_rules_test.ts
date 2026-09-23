// Rules J1-J12 on synthetic call flows (no capture data): the cases the iPhone capture does not exercise, such as
// lost, rejected and unanswered connections, forced moves, a handover with no command, SCG ends other than a
// handover, NR data outliving an inferred end, duplicate failure markers, NR band candidates by PLMN, carrier
// attribution, and plain data throughout.

import { attributeCarriers, buildJourney, type CaptureFacts, stepAnnotations } from '../src/journey/build.ts';
import { nrBandCandidates } from '../src/journey/nrBands.ts';
import { EMPTY_PHY_SUMMARY } from '../src/phy/extract.ts';
import { EMPTY_FLOW, type Flow, type FlowConnection, type FlowEvent, type FlowProcedure, type FlowStep } from '../src/signalling/flow.ts';
import type { Cell, Journey, PhySeries, PhySummary } from '../src/types.ts';
import { assert, assertEquals } from './assert.ts';

const A: Cell = { earfcn: 1_000, pci: 1, nr: false }; // B2
const B: Cell = { earfcn: 5_100, pci: 2, nr: false }; // B12
const NR: Cell = { earfcn: 174_000, pci: 3, nr: true }; // n5/n26 (and n18) on the raster
const PENDING: Cell = { earfcn: 0xffff_ffff, pci: 0xffff, nr: true };

const FACTS: CaptureFacts = { traceDurationMs: 0, traceWindow: null, records: 0, codes: 0, encrypted: { records: 0, codes: 0 }, profile: { status: 'unknown' } };

type E = Partial<FlowEvent> & { t: number; key: string };

function flowOf(evs: E[], parts: { procedures?: FlowProcedure[]; journey?: FlowStep[]; connections?: FlowConnection[]; durationMs?: number; plmn?: string } = {}): Flow {
  const events: FlowEvent[] = evs.map((e, index) => ({
    index,
    record: index + 1,
    logCode: e.layer === 'NAS' ? 0xb0ed : 0xb0c0,
    timestampRaw: 1n,
    sinceStartMs: e.t,
    layer: e.layer ?? 'RRC',
    rat: e.rat ?? 'lte',
    uplink: e.uplink ?? false,
    key: e.key,
    name: e.name ?? e.key,
    summary: e.summary ?? null,
    cell: e.cell === undefined ? A : e.cell,
    channel: e.channel ?? 'DL-DCCH',
    fields: e.fields ?? [],
    cause: e.cause ?? null,
    causeName: e.causeName ?? null,
    protection: null,
    ciphered: false,
    pdu: new Uint8Array(0),
    carrier: null,
    isFailure: e.isFailure ?? false,
    isHandoverCommand: e.isHandoverCommand ?? false,
  }));
  return {
    ...EMPTY_FLOW,
    events,
    procedures: parts.procedures ?? [],
    journey: parts.journey ?? [{ move: 'FIRST_SEEN', from: null, to: A, event: 0, sinceStartMs: evs[0]?.t ?? 0 }],
    connections: parts.connections ?? [],
    cellDetails: parts.plmn ? [{ cell: A, info: { pci: 1, downlinkEarfcn: 1_000, uplinkEarfcn: 19_000, band: 2, plmn: parts.plmn, tac: 1, cellIdentity: null, bandwidthMhz: 10 } }] : [],
    durationMs: parts.durationMs ?? Math.max(0, ...evs.map((e) => e.t)),
  };
}

const proc = (name: string, layer: 'RRC' | 'NAS', first: number, last: number, outcome: FlowProcedure['outcome'] = 'SUCCEEDED', refusal: string | null = null, durationMs = 10): FlowProcedure =>
  ({ name, layer, detail: null, first, last, outcome, durationMs, refusal });

const conn = (first: number, last: number | null, outcome: FlowConnection['outcome'], startMs: number, endMs: number | null, established = true): FlowConnection =>
  ({ first, last, establishmentCause: 'mo-Data', releaseCause: null, outcome, startMs, endMs, established });

/** Every value is plain, JSON-representable data (no undefined): what postMessage and the UI expect. */
function assertPlain(v: unknown, path = 'journey'): void {
  assert(v !== undefined, `${path} is undefined`);
  if (v === null || typeof v !== 'object') return assert(typeof v !== 'number' || Number.isFinite(v), `${path} is ${v}`);
  for (const [k, x] of Object.entries(v)) assertPlain(x, `${path}.${k}`);
}

const kinds = (j: Journey) => j.markers.map((m) => `${m.kind}:${m.severity}`);

Deno.test('journey: J2 connection outcomes (lost is a failure, rejected a failure, no answer a warning)', () => {
  const flow = flowOf(
    [{ t: 0, key: 'rrcConnectionRequest', uplink: true, channel: 'UL-CCCH' }, { t: 50, key: 'rrcConnectionSetup' }, { t: 1_000, key: 'rrcConnectionRequest', uplink: true },
      { t: 1_050, key: 'rrcConnectionReject', isFailure: true }, { t: 2_000, key: 'rrcConnectionRequest', uplink: true }, { t: 3_000, key: 'systemInformationBlockType1', channel: 'BCCH-DL-SCH' }],
    { connections: [conn(0, 1, 'LOST', 0, 500), conn(2, 3, 'REJECTED', 1_000, null, false), conn(4, null, 'NO_ANSWER', 2_000, null, false)] },
  );
  const j = buildJourney(flow, EMPTY_PHY_SUMMARY, FACTS);
  assertEquals(j.states.map((s) => [s.state, s.startMs, s.endMs]), [['connected', 0, 500], ['idle', 500, 3_000]]);
  // The reject event's own failure and the REJECTED connection's merge into one marker at event 3 (J11).
  assertEquals(kinds(j), ['failure:failure', 'failure:failure', 'warning:warning']);
  assertEquals(j.markers.map((m) => m.id), ['failure-1', 'failure-3', 'warning-4']);
  assertEquals(j.markers[0].title, 'Connection lost');
  assertEquals(j.findings.map((f) => f.kind), ['failure', 'failure', 'warning', 'failures', 'traceWindow']);
  assertEquals(j.findings[3].text, '2 failures and 1 warning in this capture.');
  assertEquals(j.tiles.find((t) => t.id === 'abnormalReleases')?.value, '1 of 1 connection');
  assertPlain(j);
});

Deno.test('journey: J3 switched off at the end, without a logged release', () => {
  const detach: E = { t: 1_000, key: 'Detach request', layer: 'NAS', uplink: true, channel: 'EMM', fields: [{ label: 'Switch off', value: 'yes', children: [] }] };
  const flow = flowOf([{ t: 0, key: 'rrcConnectionSetup' }, detach, { t: 1_010, key: 'ulInformationTransfer', uplink: true, channel: 'UL-DCCH' }], {
    connections: [conn(0, null, 'OPEN_AT_END', 0, null)],
    durationMs: 5_000,
  });
  const j = buildJourney(flow, EMPTY_PHY_SUMMARY, FACTS);
  // The UL-DCCH message carrying the detach is not the radio coming back: radio off runs to the end.
  assertEquals(j.states.map((s) => [s.state, s.startMs, s.endMs, s.openAtEnd ?? false]), [['connected', 0, 1_000, false], ['radioOff', 1_000, 5_000, true]]);
  assertEquals(j.findings[0].kind, 'switchedOffAtEnd');
  assert(!j.findings[0].text.includes('back'), j.findings[0].text);
  assertEquals(j.registration.map((r) => r.state), ['unknown', 'deregistered']);
  assertEquals(j.cells.map((c) => [c.startMs, c.endMs, c.endReason ?? '']), [[0, 1_000, 'radioOff']]);
});

Deno.test('journey: J7 forced moves are warnings; a handover with no command is inferred', () => {
  const flow = flowOf(
    [{ t: 0, key: 'rrcConnectionSetup' }, { t: 1_000, key: 'rrcConnectionReconfigurationComplete', cell: B, uplink: true }, { t: 3_000, key: 'x', cell: A }, { t: 4_000, key: 'y', cell: B },
      { t: 6_000, key: 'rrcConnectionReestablishmentRequest', cell: A, uplink: true }],
    {
      journey: [
        { move: 'FIRST_SEEN', from: null, to: A, event: 0, sinceStartMs: 0 },
        { move: 'HANDOVER', from: A, to: B, event: 1, sinceStartMs: 1_000 },
        { move: 'REDIRECT', from: B, to: A, event: 2, sinceStartMs: 3_000 },
        { move: 'CELL_CHANGE', from: A, to: B, event: 3, sinceStartMs: 4_000 },
        { move: 'REESTABLISHMENT', from: B, to: A, event: 4, sinceStartMs: 6_000 },
      ],
      connections: [conn(0, null, 'OPEN_AT_END', 0, null)],
    },
  );
  const j = buildJourney(flow, EMPTY_PHY_SUMMARY, FACTS);
  assertEquals(kinds(j), ['handover:info', 'redirect:warning', 'cellChange:warning', 'reestablishment:warning']);
  const ho = j.markers[0];
  assertEquals([ho.inferred, ho.event, ho.tMs, ho.arrivalMs], [true, 1, 1_000, 1_000]);
  assertEquals(j.findings.filter((f) => f.kind === 'warning').map((f) => f.text), [
    'Redirect B12 PCI 2 → B2 PCI 1 at 0:03.000.',
    'Cell change B2 PCI 1 → B12 PCI 2 at 0:04.000: changed cell while connected without a logged handover.',
    'Re-establishment B12 PCI 2 → B2 PCI 1 at 0:06.000.',
  ]);
  assertEquals(j.tiles.find((t) => t.id === 'abnormalReleases')?.succeeded, 1, 'a re-establishment request is abnormal');
  assertEquals(stepAnnotations(flow, j).get(2), 'The network released the connection and sent the phone to another cell.');
});

Deno.test('journey: J8 SCG add, modify, and an end at the LTE release; NR data outliving it is a warning', () => {
  const evs: E[] = [
    { t: 0, key: 'rrcConnectionSetup' },
    { t: 1_000, key: 'rrcReconfiguration', rat: 'nr', cell: PENDING },
    { t: 1_020, key: 'rrcReconfigurationComplete', rat: 'nr', cell: NR, uplink: true },
    { t: 2_000, key: 'rrcReconfiguration', rat: 'nr', cell: NR },
    { t: 3_000, key: 'rrcConnectionRelease' },
  ];
  const flow = flowOf(evs, { connections: [conn(0, 4, 'RELEASED', 0, 3_000)], plmn: '311-480' });
  const phy: PhySummary = { ...EMPTY_PHY_SUMMARY, nrDlActivity: { index: 0, pci: 3, firstMs: 1_100, lastMs: 3_900, records: 10, source: '0xB887' } };
  const j = buildJourney(flow, phy, FACTS);
  const ps = j.cells.find((c) => c.lane === 'pscell')!;
  assertEquals([ps.cell, ps.startMs, ps.addedMs, ps.endMs, ps.endInferred, ps.endReason, ps.phyLastMs, ps.band], [NR, 1_000, 1_020, 3_000, true, 'LTE RRC release (event 4)', 3_900, 'n5/n26']);
  assertEquals(kinds(j), ['scgAdd:info', 'scgModify:info', 'scgRelease:info', 'rrcRelease:info']);
  assertEquals(j.markers[0].endEvent, 2);
  assert(j.findings.some((f) => f.kind === 'scgPhyOutlived' && f.severity === 'warning' && f.text === "NR data continued 0.90 s after the NR leg's inferred end at 0:03.000."), JSON.stringify(j.findings));
  assertEquals(j.tiles.find((t) => t.id === 'scgAdd')?.value, 'n5/n26');
  // NR DL samples are attributed to the PSCell through its last NR PHY record, past the inferred end.
  const nrSeries: PhySeries = { metric: 'nr_dl_mcs', title: '', unit: '', section: 'nr', confidence: 'high', samples: [{ tMs: 3_500, value: 5, carrier: 0, pci: 3 }, { tMs: 4_500, value: 5, carrier: 0, pci: 3 }] };
  const [got] = attributeCarriers([nrSeries], j);
  assertEquals(got.samples.map((s) => s.cell ?? null), [NR, null]);
});

Deno.test('journey: J8 an SCG failure ends the leg as logged, and J11 marks it', () => {
  const flow = flowOf([
    { t: 0, key: 'rrcConnectionSetup' },
    { t: 1_000, key: 'rrcReconfiguration', rat: 'nr', cell: NR },
    { t: 2_000, key: 'scgFailureInformationNR', uplink: true, isFailure: true, cause: 3, causeName: 'synchReconfigFailureSCG' },
  ], { connections: [conn(0, null, 'OPEN_AT_END', 0, null)] });
  const j = buildJourney(flow, EMPTY_PHY_SUMMARY, FACTS);
  const ps = j.cells.find((c) => c.lane === 'pscell')!;
  assertEquals([ps.endMs, ps.endInferred, ps.endReason], [2_000, false, 'SCG failure (event 2)']);
  assertEquals(kinds(j), ['scgAdd:info', 'failure:failure']);
  assertEquals(j.markers[1].detail, '#3 synchReconfigFailureSCG');
});

Deno.test('journey: J11 duplicate failure markers at one event merge, keeping the highest severity', () => {
  const flow = flowOf([{ t: 0, key: 'Service request', layer: 'NAS', uplink: true }, { t: 100, key: 'Service reject', layer: 'NAS', isFailure: true, cause: 9, causeName: 'UE identity cannot be derived' }], {
    procedures: [proc('Service request', 'NAS', 0, 1, 'FAILED', '#9 UE identity cannot be derived', 100), proc('Service request', 'NAS', 1, 1, 'UNANSWERED')],
  });
  const j = buildJourney(flow, EMPTY_PHY_SUMMARY, FACTS);
  // Event 1: the reject's failure and an unanswered procedure's warning merge into the failure.
  assertEquals(j.markers.map((m) => [m.id, m.severity]), [['failure-0', 'failure'], ['failure-1', 'failure']]);
  // The failed procedure is told once, at its reject.
  assertEquals(j.findings.filter((f) => f.kind === 'failure').map((f) => f.text), ['Service rejected on B2 PCI 1 after 100 ms at 0:00.100: #9 UE identity cannot be derived.']);
  assertEquals(j.registration[0], { state: 'registered', startMs: 0, endMs: 100, assumed: true });
  const tile = j.tiles.find((t) => t.id === 'serviceRequest')!;
  assertEquals([tile.succeeded, tile.attempts, tile.event, tile.value], [0, 2, 0, undefined]);
});

Deno.test('journey: marker text that quotes the flow is scrubbed (no masked variant exists for it)', () => {
  const flow = flowOf([{ t: 0, key: 'Attach request', layer: 'NAS', uplink: true }, { t: 50, key: 'Attach reject', layer: 'NAS', isFailure: true, summary: 'for 001010123456789' }], {
    procedures: [proc('Attach', 'NAS', 0, 1, 'FAILED', 'rejected 10.0.0.1')],
  });
  const j = buildJourney(flow, EMPTY_PHY_SUMMARY, FACTS);
  const text = JSON.stringify(j);
  assert(!text.includes('001010123456789') && !text.includes('10.0.0.1'), text);
  assert(text.includes('<masked>'));
});

Deno.test('journey: NR band candidates list overlaps and narrow only for North American PLMNs', () => {
  assertEquals(nrBandCandidates(647_328, 1), [77, 78]);
  assertEquals(nrBandCandidates(501_390, 999), [41, 90]);
  assertEquals(nrBandCandidates(174_770, null), [5, 18, 26]);
  assertEquals(nrBandCandidates(174_770, 310), [5, 26], 'n18 is a Japanese band');
  assertEquals(nrBandCandidates(174_770, 440), [5, 18, 26]);
  assertEquals(nrBandCandidates(3_279_165, 310), []);
  // Test PLMN 001-01 from the serving cell record: the PSCell keeps every candidate.
  const flow = flowOf([{ t: 0, key: 'rrcConnectionSetup' }, { t: 10, key: 'rrcReconfiguration', rat: 'nr', cell: NR }], { connections: [conn(0, null, 'OPEN_AT_END', 0, null)], plmn: '001-01' });
  assertEquals(buildJourney(flow, EMPTY_PHY_SUMMARY, FACTS).cells.find((c) => c.lane === 'pscell')?.band, 'n5/n18/n26');
  assertEquals(buildJourney(flow, EMPTY_PHY_SUMMARY, { ...FACTS, mcc: '310' }).cells.find((c) => c.lane === 'pscell')?.band, 'n5/n26', 'the facts MCC wins');
});

Deno.test('journey: carrier attribution maps an index to the PCell or SCell of the moment', () => {
  const flow = flowOf([{ t: 0, key: 'rrcConnectionSetup' }, { t: 1_000, key: 'rrcConnectionReconfigurationComplete', cell: B, uplink: true }], {
    journey: [{ move: 'FIRST_SEEN', from: null, to: A, event: 0, sinceStartMs: 0 }, { move: 'HANDOVER', from: A, to: B, event: 1, sinceStartMs: 1_000 }],
    connections: [conn(0, null, 'OPEN_AT_END', 0, null)],
    durationMs: 3_000,
  });
  const phy: PhySummary = { ...EMPTY_PHY_SUMMARY, scellActivity: [{ index: 1, earfcn: 67_000, pci: 9, firstMs: 1_500, lastMs: 2_000, records: 5, source: '0xB193' }] };
  const j = buildJourney(flow, phy, FACTS);
  const S1: Cell = { earfcn: 67_000, pci: 9, nr: false };
  const s = (tMs: number, carrier: number) => ({ tMs, value: 1, carrier });
  const series: PhySeries[] = [
    { metric: 'lte_dl_mcs', title: '', unit: '', section: 'downlink', confidence: 'high', samples: [s(-100, 0), s(500, 0), s(1_000, 0), s(1_600, 1), s(2_600, 1), s(2_990, 0)] },
    // A serving measurement names its own cell; the records place carrier 1 when no lane covers it.
    { metric: 'lte_rsrp', title: '', unit: '', section: 'signal', confidence: 'high', samples: [{ tMs: 2_550, value: -90, carrier: 1, earfcn: 67_000, pci: 9 }] },
  ];
  const [dl, rsrp] = attributeCarriers(series, j);
  assertEquals(dl.samples.map((x) => x.cell ?? null), [null, A, B, S1, S1, B]);
  assertEquals(rsrp, series[1], 'left alone');
  assertPlain(dl);
});

Deno.test('journey: an empty flow still gives a complete, plain journey', () => {
  const j = buildJourney(EMPTY_FLOW, EMPTY_PHY_SUMMARY, FACTS);
  assertEquals(j.states, [{ state: 'unknown', startMs: 0, endMs: 0 }]);
  assertEquals(j.registration, [{ state: 'unknown', startMs: 0, endMs: 0, assumed: false }]);
  assertEquals([j.cells, j.markers], [[], []]);
  assertEquals(j.findings.map((f) => f.text), ['No failures logged.', 'Trace covers 0.0 s.']);
  assertEquals(j.tiles.map((t) => t.id), ['abnormalReleases']);
  assertPlain(j);
});

Deno.test('journey: the trace-window finding coaches with the window after the press', () => {
  const window = { startUtc: '', endUtc: '', afterPressStartS: -4, afterPressEndS: 18.5, filesKept: 10, filesOnPhone: 30, filesOverwritten: 20, filesMissing: 0 };
  const j = buildJourney(EMPTY_FLOW, EMPTY_PHY_SUMMARY, { ...FACTS, traceDurationMs: 22_500, traceWindow: window });
  assertEquals(j.findings.at(-1)?.text, 'Trace covers 22.5 s (from 0:04 before to 0:18 after you pressed the buttons; 20 of 30 trace files had already been overwritten).');
});
