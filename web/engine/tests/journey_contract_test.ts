// src/journey against the capture-derived contract fixtures (fixture-gated, read in place from $FT_FIXTURES):
// the iPhone 17 capture's journey-expected.json, built from the Kotlin call flow (callflow-golden.json) and the v1
// PHY summary, and the two OnePlus goldens; then the same journey from the engine's own PHY extraction, and the
// carrier attribution of the PHY samples through it.

import { attributeCarriers, buildJourney, type CaptureFacts, cellForCarrier, pscellAt, stepAnnotations } from '../src/journey/build.ts';
import { kindRank } from '../src/journey/markers.ts';
import { EMPTY_PHY_SUMMARY } from '../src/phy/extract.ts';
import { readFlow } from '../src/signalling/callflow.ts';
import type { Flow } from '../src/signalling/flow.ts';
import type { Journey, PhySummary } from '../src/types.ts';
import { fixture, gate } from '../tools/fixtures.ts';
import { readJson } from '../tools/golden.ts';
import { assert, assertEquals } from './assert.ts';
import { loadGoldenFlow } from './golden_flow.ts';
import { journeyDifferences } from './journey_expected.ts';
import { loadCapture, QMDL, TBS_REFERENCE } from './phy_support.ts';

const GOLDEN = fixture('contract/callflow-golden.json');
const SUMMARY = fixture('contract/phy-summary-v1.json');
const EXPECTED = fixture('contract/journey-expected.json');
const ONEPLUS_5G = fixture('contract/oneplus-5g-registration.json');
const ONEPLUS_CALLBOX = fixture('contract/oneplus-callbox-service-request.json');

/** The facts the contract was written for: the D1 trace length and the modem's encrypted census. */
const IPHONE_FACTS: CaptureFacts = {
  traceDurationMs: 26_959.395,
  traceWindow: null,
  records: 92_133,
  codes: 224,
  encrypted: { records: 23_764, codes: 61 },
  profile: { status: 'active' },
};

// deno-lint-ignore no-explicit-any
type Json = any;

async function summaryV1(): Promise<PhySummary> {
  const s: Json = await readJson(SUMMARY);
  delete s.encrypted; // the v1 fixture carries the census; PhySummary does not
  if (s.nrDlActivity?.earfcn === null) delete s.nrDlActivity.earfcn;
  return s;
}

async function iphone(): Promise<{ flow: Flow; journey: Journey }> {
  const flow = await loadGoldenFlow(GOLDEN);
  return { flow, journey: buildJourney(flow, await summaryV1(), IPHONE_FACTS) };
}

const onePlusFacts = (flow: Flow): CaptureFacts => ({
  traceDurationMs: 0,
  traceWindow: null,
  records: flow.records,
  codes: 0,
  encrypted: { records: 0, codes: 0 },
  profile: { status: 'unknown' },
});

Deno.test({
  name: 'journey: the iPhone capture matches journey-expected.json (J1-J12, v1 amendments)',
  ignore: gate(GOLDEN, SUMMARY, EXPECTED),
  fn: async () => {
    const { flow, journey } = await iphone();
    const want = await readJson(EXPECTED);
    assertEquals(journeyDifferences(journey, flow, want), []);
    // The counts the contract names, stated outright so a comparator bug cannot hide them.
    assertEquals(journey.states.map((s) => s.state), ['unknown', 'connected', 'radioOff', 'idle', 'connected']);
    assertEquals(journey.registration.map((r) => [r.state, r.assumed]), [['registered', true], ['deregistered', false], ['registered', false]]);
    assertEquals(journey.cells.map((c) => `${c.lane} ${c.band}`), ['pcell B2', 'pcell B66', 'pcell B12', 'pcell B2', 'pscell n5/n26', 'scell B2', 'scell B2', 'scell B66']);
    assertEquals(journey.markers.length, 13);
    assertEquals(journey.markers.filter((m) => m.severity !== 'info').length, 0);
    assertEquals(journey.findings.length, 10);
  },
});

Deno.test({
  name: 'journey: the iPhone capture reads right (finding text, tiles, ladder annotations)',
  ignore: gate(GOLDEN, SUMMARY),
  fn: async () => {
    const { flow, journey } = await iphone();
    assertEquals(journey.findings.map((f) => f.text), [
      'Switched off (switch-off detach) on B2 PCI 80 at 0:01.813; radio back 0.56 s later.',
      'Re-attached on B66 PCI 80 (EARFCN 67086) in 335 ms.',
      'IMS PDN connected in 240 ms.',
      '5G NR leg added at 0:13.799 (NR-ARFCN 174770, PCI 80, n5/n26).',
      'Handover B66 PCI 80 → B12 PCI 235 in 44 ms.',
      'Carrier aggregation: 3 SCells on PCI 235 (B2, B2, B66), from 0:15.391.',
      'Handover B12 PCI 235 → B2 PCI 80 in 26 ms.',
      'No failures: 34 procedures, all answered.',
      "23,764 records in 61 log codes were encrypted by the modem and can't be read.",
      'Trace covers 27.0 s.',
    ]);
    const tiles = Object.fromEntries(journey.tiles.map((t) => [t.id, t]));
    // The ladder's own strings (CallFlowPresentation.duration), as the procedure groups show them.
    assertEquals(tiles.rrcSetup.value, '70.2 ms');
    assertEquals(tiles.attach.value, '335 ms');
    assertEquals(tiles.pdn.value, '240 ms');
    assertEquals(tiles.handover.value, 'median 34.9 ms');
    assertEquals([tiles.handover.group, tiles.handover.succeeded, tiles.handover.attempts], ['Mobility', 2, 2]);
    assertEquals([tiles.scgAdd.group, tiles.scgAdd.value], ['EN-DC', 'n5/n26']);
    assertEquals(tiles.abnormalReleases.value, '0 of 2 connections');
    assert(!('serviceRequest' in tiles) && !('registration' in tiles), 'no such procedures in this capture');
    const notes = stepAnnotations(flow, journey);
    assertEquals([...notes.entries()], [
      [10, 'Reselection, after switch-off detach'],
      [83, 'Handover in 44 ms, NR leg released (inferred)'],
      [117, 'Handover in 26 ms'],
    ]);
  },
});

Deno.test({
  name: 'journey: marker and finding ids are unique, and markers are ordered by time then kind',
  ignore: gate(GOLDEN, SUMMARY),
  fn: async () => {
    const { journey } = await iphone();
    const ids = journey.markers.map((m) => m.id);
    assertEquals(new Set(ids).size, ids.length);
    assertEquals(new Set(journey.findings.map((f) => f.id)).size, journey.findings.length);
    assertEquals(ids.slice(0, 5), ['detachSwitchOff-2', 'rrcRelease-5', 'attach-10', 'reattach-10', 'rrcSetup-11']);
    assert(ids.includes('handover-82') && ids.includes('rach-2659.6') && ids.includes('scgRelease-82'), ids.join(' '));
    assertEquals(journey.findings.filter((f) => f.kind === 'handover').map((f) => f.id), ['handover-82', 'handover-116']);
    for (let i = 1; i < journey.markers.length; i++) {
      const a = journey.markers[i - 1], b = journey.markers[i];
      assert(a.tMs < b.tMs || (a.tMs === b.tMs && kindRank(a.kind) <= kindRank(b.kind)), `${a.id} before ${b.id}`);
    }
  },
});

Deno.test({
  name: 'journey: OnePlus 5G registration (test PLMN, overlapping NR bands, a rejected registration)',
  ignore: gate(ONEPLUS_5G),
  fn: async () => {
    const flow = await loadGoldenFlow(ONEPLUS_5G);
    const j = buildJourney(flow, EMPTY_PHY_SUMMARY, onePlusFacts(flow));
    const pcells = j.cells.filter((c) => c.lane === 'pcell');
    assertEquals(pcells.map((c) => [c.cell.earfcn, c.cell.pci, c.cell.nr]), [[647_328, 417, true], [501_390, 152, true]]);
    // PLMN 001-01 is a test network: not narrowed, and 3709.92 MHz is in both n77 and n78.
    assertEquals(pcells.map((c) => c.bandCandidates), [[77, 78], [41, 90]]);
    assertEquals(pcells.map((c) => c.band), ['n77/n78', 'n41/n90']);
    assertEquals(pcells[0].dlMhz, 3709.92);
    assertEquals(pcells[1].openAtEnd, true);
    // The golden's duration is negative (repo main); the lanes run to the last event instead.
    assertEquals(j.durationMs, 188_150.065);
    const failures = j.markers.filter((m) => m.severity === 'failure');
    assertEquals(failures.map((m) => [m.kind, m.event, m.title]), [['failure', 2, 'Registration failed'], ['failure', 7, 'Registration reject']]);
    const told = j.findings.filter((f) => f.kind === 'failure');
    assertEquals(told.map((f) => f.text), ['Registration rejected on n77/n78 PCI 417 after 110 ms at 0:00.204: #27 N1 mode not allowed.']);
    assertEquals(j.findings.map((f) => [f.id, f.kind]), [['failure-7', 'failure'], ['reselection-9', 'other'], ['failures', 'failures'], ['traceWindow', 'traceWindow']]);
    assertEquals(j.findings[1].text, 'Reselection n77/n78 PCI 417 → n41/n90 PCI 152 (idle) at 3:06.230.');
    assertEquals(j.findings[2].text, '1 failure in this capture.');
    assertEquals(j.registration.map((r) => r.state), ['unknown', 'deregistered']);
    assertEquals(j.registration[1].startMs, 203.863);
    const tiles = Object.fromEntries(j.tiles.map((t) => [t.id, t]));
    assertEquals([tiles.registration.succeeded, tiles.registration.attempts], [0, 1]);
    assertEquals([tiles.rrcSetup.succeeded, tiles.rrcSetup.attempts], [1, 1]);
  },
});

Deno.test({
  name: 'journey: OnePlus callbox (service request tile, switched off at the very end)',
  ignore: gate(ONEPLUS_CALLBOX),
  fn: async () => {
    const flow = await loadGoldenFlow(ONEPLUS_CALLBOX);
    const j = buildJourney(flow, EMPTY_PHY_SUMMARY, onePlusFacts(flow));
    assertEquals(j.markers.filter((m) => m.severity !== 'info'), []);
    const tiles = Object.fromEntries(j.tiles.map((t) => [t.id, t]));
    assertEquals([tiles.serviceRequest.succeeded, tiles.serviceRequest.attempts, tiles.serviceRequest.value], [1, 1, '98.6 ms']);
    assertEquals([tiles.pdn.succeeded, tiles.pdn.attempts], [1, 1]);
    // J3: switched off at the end, so radio off runs to the end and no restart is claimed.
    const last = j.states[j.states.length - 1];
    assertEquals([last.state, last.openAtEnd, last.startMs], ['radioOff', true, 118_338.426]);
    const off = j.findings.find((f) => f.kind === 'switchedOffAtEnd')!;
    assertEquals(off.text, 'Switched off at the end: switch-off detach on B3 PCI 3 at 1:58.316.');
    assert(!j.findings.some((f) => f.kind === 'radioOffOn'));
    // The first NAS procedure is a Service request: registered (assumed) until the switch-off detach.
    assertEquals(j.registration.map((r) => [r.state, r.assumed]), [['registered', true], ['deregistered', false]]);
    assertEquals(j.findings.find((f) => f.kind === 'imsPdn')?.text, 'IMS PDN connected in 29 ms.');
    assertEquals(j.findings.map((f) => f.kind), ['imsPdn', 'switchedOffAtEnd', 'noFailures', 'traceWindow']);
  },
});

Deno.test({
  name: "journey: from the engine's own PHY extraction, and every carrier-indexed PHY sample attributed to a cell",
  ignore: gate(GOLDEN, EXPECTED, QMDL, TBS_REFERENCE),
  fn: async () => {
    const flow = await loadGoldenFlow(GOLDEN);
    const { run } = await loadCapture();
    const journey = buildJourney(flow, run.capture.summary, IPHONE_FACTS, run.capture.series);
    const want: Json = await readJson(EXPECTED);
    // TA x 78.12 m here, 78.125 in the fixture (TA 19: 1484.3 vs 1484.4 m); everything else is as the contract.
    const diffs = journeyDifferences(journey, flow, want).filter((d) => !/^markers\[12\] \(rach\)\.distanceM: 1484\.3 != 1484\.4$/.test(d));
    assertEquals(diffs, []);
    const tiles = Object.fromEntries(journey.tiles.map((t) => [t.id, t]));
    assertEquals([tiles.lteDlPeak.group, tiles.nrDlPeak.group], ['Integrity', 'Integrity']);
    assert(tiles.nrDlPeak.value === '11.3 Mbit/s', tiles.nrDlPeak.value);

    const series = attributeCarriers(run.capture.series, journey);
    const by = Object.fromEntries(series.map((s) => [s.metric, s]));
    // Carrier 0 is the PCell of the moment, carrier k the SCell of index k; NR DL goes to the PSCell.
    const at = (m: string, t: number, carrier?: number) =>
      by[m].samples.find((x) => x.tMs >= t && (carrier === undefined || x.carrier === carrier))?.cell;
    assertEquals(at('lte_dl_mcs', 10_000, 0), { earfcn: 67_086, pci: 80, nr: false });
    assertEquals(at('lte_dl_mcs', 18_000, 0), { earfcn: 5110, pci: 235, nr: false });
    assertEquals(at('lte_dl_mcs', 16_000, 2), { earfcn: 975, pci: 235, nr: false });
    assertEquals(at('lte_ul_prb', 23_000, 0), { earfcn: 650, pci: 80, nr: false });
    assertEquals(at('nr_dl_mcs', 14_000), { earfcn: 174_770, pci: 80, nr: true });
    assertEquals(at('nr_dl_bler', 14_000), { earfcn: 174_770, pci: 80, nr: true });
    assertEquals(cellForCarrier(journey, 1, 18_000), undefined, 'SCell 1 was released at about 16.1 s');
    assertEquals(pscellAt(journey, 20_000), undefined);
    // Every carrier-indexed and NR DL sample is placed: by the lanes, or where no lane covers it (before the first
    // RRC message, just after a release, at an SCell window's edges) by the nearest 0xB193 serving record.
    const unplaced = series.filter((s) => s.samples.some((x) => x.cell)).map((s) => [s.metric, s.samples.filter((x) => !x.cell).length]).filter(([, n]) => n);
    assertEquals(unplaced, []);
    assertEquals(series.filter((s) => s.samples.some((x) => x.cell)).length, 31, '23 carrier-indexed + 8 NR DL series');
    assertEquals(at('lte_ul_prb', 0, 0), { earfcn: 650, pci: 80, nr: false }, 'before the first RRC message: from 0xB193');
    // Samples that name their own cell are left alone.
    assert(by.lte_rsrp.samples.every((x) => x.cell === undefined));
  },
});

Deno.test({
  name: "journey: end to end on the rebuilt log, from the engine's own call flow (signalling/) and PHY extraction",
  ignore: gate(EXPECTED, QMDL, TBS_REFERENCE),
  fn: async () => {
    const { records, run } = await loadCapture();
    const flow = readFlow(records, 0);
    const journey = buildJourney(flow, run.capture.summary, { ...IPHONE_FACTS, mcc: flow.cellDetails[0]?.info.plmn.split('-')[0] ?? '' }, run.capture.series);
    const want: Json = await readJson(EXPECTED);
    const diffs = journeyDifferences(journey, flow, want).filter((d) => !/^markers\[12\] \(rach\)\.distanceM: 1484\.3 != 1484\.4$/.test(d));
    assertEquals(diffs, []);
  },
});
