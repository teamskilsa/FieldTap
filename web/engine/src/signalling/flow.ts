// OWNER: signalling agent. The call flow as CallFlow.kt builds it at contract v1 (ios/Contract/src-v1), field for
// field, so the golden dump (golden.ts, callflow-golden.json) is a direct serialisation. Absent values are null,
// as in the golden. It holds decoded identifiers and PDU bytes: ui.ts maps it to the UI's types, masked unless
// reveal is asked for.

import type { Cell, ConnectionOutcome, Layer, Move, Outcome } from '../types.ts';

export type { Cell, ConnectionOutcome, Layer, Move, Outcome };

export interface FlowField {
  label: string;
  value: string;
  children: FlowField[];
}

export interface FlowProtection {
  headerType: number;
  mac: number;
  sequence: number;
}

export interface FlowEvent {
  index: number;
  /** 1-based position of the log record in the file, counting every record. */
  record: number;
  logCode: number;
  timestampRaw: bigint;
  sinceStartMs: number;
  layer: Layer;
  rat: 'lte' | 'nr';
  uplink: boolean;
  key: string;
  name: string;
  summary: string | null;
  cell: Cell | null;
  channel: string;
  fields: FlowField[];
  cause: number | null;
  causeName: string | null;
  protection: FlowProtection | null;
  ciphered: boolean;
  pdu: Uint8Array;
  carrier: string | null;
  isFailure: boolean;
  isHandoverCommand: boolean;
}

export interface FlowProcedure {
  name: string;
  layer: Layer;
  detail: string | null;
  first: number;
  last: number;
  outcome: Outcome;
  durationMs: number;
  refusal: string | null;
}

export interface FlowStep {
  move: Move;
  from: Cell | null;
  to: Cell;
  event: number;
  sinceStartMs: number;
}

export interface FlowConnection {
  first: number;
  last: number | null;
  establishmentCause: string | null;
  releaseCause: string | null;
  outcome: ConnectionOutcome;
  startMs: number;
  endMs: number | null;
  established: boolean;
}

/** CellInfo.Serving: what the serving-cell record (0xB0C2) said about a cell. */
export interface ServingCellInfo {
  pci: number;
  downlinkEarfcn: number;
  uplinkEarfcn: number;
  band: number;
  plmn: string;
  tac: number;
  cellIdentity: number | null;
  bandwidthMhz: number | null;
}

export interface Flow {
  events: FlowEvent[];
  procedures: FlowProcedure[];
  /** Cell steps (CallFlow.Flow.journey). */
  journey: FlowStep[];
  /** Cells whose system information was read but never signalled on. */
  searched: Cell[];
  connections: FlowConnection[];
  /** In first-seen order, as the Kotlin LinkedHashMap. */
  cellDetails: { cell: Cell; info: ServingCellInfo }[];
  /** Every log record in the file. */
  records: number;
  /** Signalling records not shown. */
  undecoded: number;
  crcErrors: number;
  durationMs: number;
  /** Unix ms of the first counted record, or null without network time. */
  startUtcMs: number | null;
  failures: number;
}

export const EMPTY_FLOW: Flow = {
  events: [],
  procedures: [],
  journey: [],
  searched: [],
  connections: [],
  cellDetails: [],
  records: 0,
  undecoded: 0,
  crcErrors: 0,
  durationMs: 0,
  startUtcMs: null,
  failures: 0,
};
