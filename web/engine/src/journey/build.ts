// OWNER: phy-journey agent. STUB from the engine foundation: the final signature of FTJourney's build (rules
// J1-J12 and the v1 amendments in ios/Contract/CONTRACT.md). A pure function of parity CallFlow outputs, the PHY
// summary and the capture facts, so Android can implement the same rules against journey-expected.json.

import type { Flow } from '../signalling/flow.ts';
import type { EncryptedCensus, Journey, PhySummary, ProfileState, Step, TraceWindow } from '../types.ts';

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

export function buildJourney(flow: Flow, _phySummary: PhySummary, _facts: CaptureFacts): Journey {
  return { durationMs: flow.durationMs, states: [], registration: [], cells: [], markers: [], findings: [], tiles: [] };
}

/** J7's reading of each move, keyed by the step's event: shown as a subtitle on the ladder's Move row. */
export function stepAnnotations(_flow: Flow, _journey: Journey): Map<Step['event'], string> {
  return new Map();
}
