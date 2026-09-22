// The website's sample (tools/make-sample.ts): a complete CaptureAnalysis, invented end to end. These tests are
// what keeps it honest — the same shape checks a real analysis passes, no identifier from its own synthetic
// story in the output, and nothing that could come from a capture.

import { makeSample } from '../tools/make-sample.ts';
import { CONTRACT_VERSION } from '../src/types.ts';
import { assert, assertEquals } from './assert.ts';

/** The invented identifiers the generator's story puts into the flow: none may reach the sample. */
const INVENTED = ['001010000000001', '0123456789012345', '10.20.30.40', '0x1A2B3C4D', '00112233445566778899aabbccddeeff'];

Deno.test('sample: plain JSON data, the contract shape, and a story the UI can show', () => {
  const a = makeSample();
  assertEquals(a.contract, CONTRACT_VERSION);
  assertEquals(JSON.parse(JSON.stringify(a)), a, 'survives JSON');
  assertEquals(a.problems, []);
  assertEquals([a.profile.status, a.guide.status], ['active', 'active']);
  assertEquals(a.steps.map((s) => s.move), ['FIRST_SEEN', 'HANDOVER']);
  assertEquals(a.connections.map((c) => c.outcome), ['RELEASED', 'RELEASED']);
  assert(a.procedures.every((p) => p.outcome === 'SUCCEEDED'), 'a clean capture');
  assertEquals(Object.keys(a.ladder.rows).sort(), ['ALL', 'NAS', 'RRC']);
  assert(a.ladder.rows.ALL.length === a.ladder.rows.RRC.length + a.ladder.rows.NAS.length, 'every row on a lane');

  // The journey: LTE attach, an NR leg, a handover, and the tiles the Overview shows.
  assertEquals(a.journey.cells.map((c) => c.lane), ['pcell', 'pcell', 'pscell', 'scell']);
  assertEquals(a.journey.states.map((s) => s.state), ['unknown', 'connected', 'idle', 'connected', 'idle']);
  assert(a.journey.markers.some((m) => m.kind === 'handover') && a.journey.markers.some((m) => m.kind === 'scgAdd'), 'moves and the NR leg');
  assert(a.journey.markers.every((m, i, all) => all.findIndex((x) => x.id === m.id) === i), 'marker ids unique');
  assert(a.journey.findings.length >= 5 && a.journey.findings.every((f) => f.text.length > 10), 'findings read as sentences');
  for (const id of ['rrcSetup', 'attach', 'handover', 'scgAdd', 'lteDlPeak', 'nrDlPeak']) {
    assert(a.journey.tiles.some((t) => t.id === id), `tile ${id}`);
  }

  // Radio: every section the Radio page draws, with samples placed on cells.
  assert(a.phy.length >= 10, `${a.phy.length} series`);
  assert(a.phy.every((s) => s.samples.length > 0 && s.samples.every((x) => Number.isFinite(x.tMs))), 'samples are plain numbers');
  assert(a.phy.some((s) => s.samples.some((x) => x.cell)), 'carrier attribution ran');
  assert(a.availability.length > 0 && a.phyChecks.every((c) => c.passed), 'availability and decoder health');
});

Deno.test('sample: invented throughout, and nothing identifying survives the masking', () => {
  const text = JSON.stringify(makeSample());
  for (const id of INVENTED) assert(!text.includes(id), 'an invented identifier reached the sample');
  // Only the reserved test network, and no MCC that belongs to a real operator.
  const plmns = new Set(makeSample().cellDetails.map((c) => c.plmn));
  assertEquals([...plmns], ['001-01']);
  // The real captures' EARFCNs (the ones in the contract fixtures) must never appear in a shipped sample.
  for (const earfcn of [650, 975, 5110, 67086, 174770]) {
    assert(!makeSample().phy.some((s) => s.samples.some((x) => x.earfcn === earfcn || x.cell?.earfcn === earfcn)), `EARFCN ${earfcn} is a real capture's`);
    assert(!makeSample().cellDetails.some((c) => c.downlinkEarfcn === earfcn), `EARFCN ${earfcn} is a real capture's`);
  }
});

Deno.test('sample: the same bytes every time (a fixed asset the site can cache)', () => {
  assertEquals(JSON.stringify(makeSample()), JSON.stringify(makeSample()));
});
