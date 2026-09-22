// The comparator for journey-expected.json, whose schema is not the Journey type (as FTJourneyTests'
// JourneyExpectation.swift reads it): cells are [earfcn, pci] pairs, the PSCell says 'arfcn', markers carry
// 'completeEvent' and 'stepMove', findings are category names that repeat, and tiles are pairs or counts. Only
// keys present in the fixture are compared. Tolerance: 1 ms for event-derived times, 100 ms for PHY-derived ones.
//
// The fixture predates the v1 amendments, which this applies instead of regenerating it (CONTRACT.md):
// - markers are compared in the contract order, a stable sort by tMs then kind rank (the fixture lists the
//   attach at 2592.758 after the RRC setup at 2593.419);
// - ids are not in the fixture: uniqueness is tested separately;
// - 'procedures' / 'proceduresAnswered' are counts of the flow, not tiles (src/types.ts has no such tile);
//   every other fixture tile must exist, and the journey may add only the tiles the amendments introduced
//   (serviceRequest, registration) when the flow has those procedures, and the PHY peaks when given series.

import type { Flow } from '../src/signalling/flow.ts';
import type { Journey, MarkerKind } from '../src/types.ts';
import { kindRank } from '../src/journey/markers.ts';

// deno-lint-ignore no-explicit-any
type Json = any;

export const EVENT_TOLERANCE = 1.0;
export const PHY_TOLERANCE = 100.0;

/** The fixture's marker rows in the contract order. */
export function contractOrder(markers: Json[]): Json[] {
  return markers.map((m, i) => ({ m, i })).sort((a, b) =>
    a.m.tMs - b.m.tMs || kindRank(a.m.kind as MarkerKind) - kindRank(b.m.kind as MarkerKind) || a.i - b.i
  ).map((x) => x.m);
}

export function journeyDifferences(journey: Journey, flow: Flow, want: Json): string[] {
  const out: string[] = [];
  const near = (path: string, got: number | undefined, w: number | undefined, tol = EVENT_TOLERANCE) => {
    if (w === undefined) return;
    if (got === undefined) out.push(`${path}: missing, want ${w}`);
    else if (!(Math.abs(got - w) <= tol)) out.push(`${path}: ${got} != ${w}`);
  };
  const same = (path: string, got: unknown, w: unknown) => {
    if (w === undefined) return;
    if (JSON.stringify(got) !== JSON.stringify(w)) out.push(`${path}: ${JSON.stringify(got)} != ${JSON.stringify(w)}`);
  };
  const len = (path: string, got: unknown[], w: unknown[]) => {
    if (got.length !== w.length) out.push(`${path}.length: ${got.length} != ${w.length}`);
  };

  near('durationMs', journey.durationMs, want.durationMs);

  len('states', journey.states, want.lanes.state);
  want.lanes.state.forEach((w: Json, i: number) => {
    const g = journey.states[i];
    if (!g) return;
    same(`states[${i}].state`, g.state, w.state);
    near(`states[${i}].startMs`, g.startMs, w.startMs);
    near(`states[${i}].endMs`, g.endMs, w.endMs);
    same(`states[${i}].source`, g.source, w.source);
    same(`states[${i}].openAtEnd`, g.openAtEnd ?? false, w.openAtEnd);
  });
  len('registration', journey.registration, want.lanes.registration);
  want.lanes.registration.forEach((w: Json, i: number) => {
    const g = journey.registration[i];
    if (!g) return;
    same(`registration[${i}].state`, g.state, w.state);
    near(`registration[${i}].startMs`, g.startMs, w.startMs);
    near(`registration[${i}].endMs`, g.endMs, w.endMs);
    same(`registration[${i}].assumed`, g.assumed, w.assumed);
  });

  for (const [lane, tol] of [['pcell', EVENT_TOLERANCE], ['pscell', EVENT_TOLERANCE], ['scell', PHY_TOLERANCE]] as const) {
    const got = journey.cells.filter((c) => c.lane === lane);
    const ws: Json[] = want.lanes[lane];
    len(lane, got, ws);
    ws.forEach((w, i) => {
      const g = got[i];
      if (!g) return;
      const p = `${lane}[${i}]`;
      same(`${p}.index`, g.index, w.index);
      same(`${p}.earfcn`, g.cell.earfcn, w.earfcn ?? w.arfcn);
      same(`${p}.pci`, g.cell.pci, w.pci);
      same(`${p}.band`, g.band, w.band);
      same(`${p}.bandCandidates`, g.bandCandidates, w.bandCandidates);
      near(`${p}.dlMhz`, g.dlMhz, w.dlMhz, 0.001);
      near(`${p}.startMs`, g.startMs, w.startMs, tol);
      near(`${p}.endMs`, g.endMs, w.endMs, tol);
      near(`${p}.addedMs`, g.addedMs, w.addedMs);
      same(`${p}.endInferred`, g.endInferred, w.endInferred);
      same(`${p}.openAtEnd`, g.openAtEnd ?? false, w.openAtEnd);
      same(`${p}.startReason`, g.startReason, w.startReason);
      same(`${p}.endReason`, g.endReason, w.endReason);
      near(`${p}.phyLastMs`, g.phyLastMs, w.phyLastMs, PHY_TOLERANCE);
      if (w.source !== undefined) same(`${p}.source`, g.source, String(w.source).startsWith('PHY') ? 'phy' : String(w.source).startsWith('RRC') ? 'rrc' : 'inferred');
    });
  }

  const ms = contractOrder(want.markers);
  len('markers', journey.markers, ms);
  ms.forEach((w, i) => {
    const g = journey.markers[i];
    if (!g) return;
    const p = `markers[${i}] (${w.kind})`;
    same(`${p}.kind`, g.kind, w.kind);
    near(`${p}.tMs`, g.tMs, w.tMs, w.kind === 'rach' ? PHY_TOLERANCE : EVENT_TOLERANCE);
    same(`${p}.event`, g.event, w.event);
    same(`${p}.endEvent`, g.endEvent, w.endEvent ?? w.completeEvent);
    near(`${p}.arrivalMs`, g.arrivalMs, w.arrivalMs);
    near(`${p}.durationMs`, g.durationMs, w.durationMs);
    same(`${p}.ta`, g.ta, w.ta);
    near(`${p}.distanceM`, g.distanceM, w.distanceM, 0.05);
    same(`${p}.inferred`, g.inferred, w.inferred);
    same(`${p}.severity`, g.severity, w.severity);
    same(`${p}.from`, g.from && [g.from.earfcn, g.from.pci], w.from);
    same(`${p}.to`, g.to && [g.to.earfcn, g.to.pci], w.to);
    if (w.stepMove !== undefined && !flow.journey.some((s) => s.move === w.stepMove && s.event === g.event)) {
      out.push(`${p}.stepMove: no ${w.stepMove} step at event ${g.event}`);
    }
  });
  const failures = journey.markers.filter((m) => m.severity === 'failure').length;
  if (failures !== want.failureMarkers) out.push(`failureMarkers: ${failures} != ${want.failureMarkers}`);

  same('findings', journey.findings.map((f) => f.kind), want.findings);

  const wanted = new Set<string>();
  for (const [name, value] of Object.entries(want.tiles as Record<string, Json>)) {
    if (name === 'procedures' || name === 'proceduresAnswered') {
      const n = name === 'procedures' ? flow.procedures.length : flow.procedures.filter((p) => p.outcome !== 'UNANSWERED').length;
      if (n !== value) out.push(`tiles.${name} (flow): ${n} != ${value}`);
      continue;
    }
    wanted.add(name);
    const t = journey.tiles.find((x) => x.id === name);
    if (!t) {
      out.push(`tiles.${name}: missing`);
      continue;
    }
    if (Array.isArray(value)) {
      if (t.succeeded !== value[0] || t.attempts !== value[1]) out.push(`tiles.${name}: ${t.succeeded}/${t.attempts} != ${value[0]}/${value[1]}`);
    } else if (t.succeeded !== value) out.push(`tiles.${name}: ${t.succeeded} != ${value}`);
  }
  const allowed = new Set(['serviceRequest', 'registration', 'lteDlPeak', 'nrDlPeak']);
  const extra = journey.tiles.map((t) => t.id).filter((id) => !wanted.has(id) && !allowed.has(id));
  if (extra.length) out.push(`tiles not in the fixture: ${extra.join(', ')}`);
  return out;
}
