// The journey layer on top of the parity call flow: rules J1-J12 and the v1 amendments of ios/Contract/CONTRACT.md
// (FTJourney's JourneyBuilder.swift). A pure function of parity CallFlow outputs (steps, connections, procedures,
// events), the PHY summary and the capture facts, so Android can implement the same rules against
// journey-expected.json.

import type { Flow } from '../signalling/flow.ts';
import type { EncryptedCensus, Journey, PhySeries, PhySummary, ProfileState, Step, TraceWindow } from '../types.ts';
import { JourneyContext } from './context.ts';
import { enDc } from './endc.ts';
import { findings } from './findings.ts';
import { pcells, registration, scells, states } from './lanes.ts';
import { markers } from './markers.ts';
import { spoken } from './text.ts';
import { tiles } from './tiles.ts';

export { attributeCarriers, cellForCarrier, pscellAt } from './attribution.ts';

/** The capture facts the findings quote (trace window, record counts, encrypted census, profile). */
export interface CaptureFacts {
  /** D1 time base length (= flow.durationMs). */
  traceDurationMs: number;
  traceWindow: TraceWindow | null;
  records: number;
  codes: number;
  encrypted: EncryptedCensus;
  profile: ProfileState;
  triggerTime?: string;
  /** Mobile country code of the serving PLMN, for NR band candidates ('001' test networks are not narrowed). */
  mcc?: string;
}

/**
 * The journey: state and registration lanes, PCell / PSCell / SCell segments, markers, findings and KPI tiles.
 * `series` (optional) adds the Integrity tiles (LTE DL PHY and NR MAC peaks); pass PhyCapture.series.
 */
export function buildJourney(flow: Flow, phySummary: PhySummary, facts: CaptureFacts, series: readonly PhySeries[] = []): Journey {
  const ctx = new JourneyContext(flow, phySummary, facts.mcc);
  const pcell = pcells(ctx);
  const endc = enDc(ctx, pcell);
  const cells = [...pcell, ...endc.pscells, ...scells(ctx)];
  const marks = markers(ctx, endc.markers);
  const lanes = { durationMs: ctx.endMs, states: states(ctx), registration: registration(ctx), cells, markers: marks };
  return {
    ...lanes,
    findings: findings(flow, lanes, {
      traceDurationMs: facts.traceDurationMs > 0 ? facts.traceDurationMs : ctx.endMs,
      traceWindow: facts.traceWindow,
      encrypted: facts.encrypted,
    }),
    tiles: tiles(flow, marks, cells, series),
  };
}

const MOVES = new Set(['handover', 'reselection', 'reattach', 'redirect', 'reestablishment', 'cellChange']);

/** J7's reading of each move, keyed by the step's event: shown as a subtitle on the ladder's Move row. */
export function stepAnnotations(flow: Flow, journey: Journey): Map<Step['event'], string> {
  const out = new Map<number, string>();
  for (const step of flow.journey) {
    const m = journey.markers.find((x) => MOVES.has(x.kind) && (x.endEvent === step.event || (x.event === step.event && x.endEvent === undefined)));
    if (!m) continue;
    switch (m.kind) {
      case 'handover': {
        let s = 'Handover' + (m.durationMs === undefined ? '' : ` in ${spoken(m.durationMs)}`);
        const release = journey.markers.find((x) => x.kind === 'scgRelease' && x.event === m.event);
        if (release) s += release.inferred ? ', NR leg released (inferred)' : ', NR leg released';
        out.set(step.event, s);
        break;
      }
      case 'reattach':
        out.set(step.event, 'Reselection, after switch-off detach');
        break;
      case 'reselection':
        out.set(step.event, 'Reselection (idle)');
        break;
      default:
        out.set(step.event, m.detail ?? m.title);
    }
  }
  return out;
}
