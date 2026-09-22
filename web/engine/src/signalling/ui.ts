// The call flow as the UI's types carry it (src/types.ts: events, procedures, steps, connections, cell details,
// ladder), masked unless the caller asks to reveal identifiers.
//
// Masking design. The golden rules (mask.ts) decide what an identifier is. By default (`reveal` false) nothing
// unmasked crosses into the UI types at all:
// - every Field.value, Event.summary, Procedure.detail and Procedure.refusal holds the masked text;
// - the matching `masked` / `summaryMasked` / `detailMasked` / `refusalMasked` is set (to the same masked text)
//   exactly where masking changed something, so it doubles as the "sensitive" flag the UI badges;
// - Event.pduHex and CellDetail.cellIdentity are left out. TAC stays (the golden keeps it): the UI hides it
//   while masked, by the stricter display rule, together with the cell identity.
// With `reveal` true the values are the decoded ones, the masked forms sit beside them, and the bytes and cell
// identity are included. The worker keeps the Flow and re-maps it with reveal only when the user confirms, so a
// masked analysis can be copied, shared or logged without leaking what the capture holds.

import { hexCode } from '../diag/record.ts';
import { utcMs } from '../diag/timebase.ts';
import type { CellDetail, Connection, Event, Field, Ladder, Procedure, Step } from '../types.ts';
import type { Flow, FlowEvent, FlowField, FlowProcedure } from './flow.ts';
import { headerName } from './golden.ts';
import { maskedValue, scrub } from './mask.ts';
import { hexString, ladder } from './presentation.ts';

export interface UiOptions {
  /** Deliver identifiers as decoded (after the user confirmed). Default false: masked. */
  reveal?: boolean;
  /** The journey's step subtitles (journey/build.ts stepAnnotations), keyed by step.event. */
  annotations?: ReadonlyMap<number, string>;
}

/** The signalling part of a CaptureAnalysis. */
export interface UiSignalling {
  events: Event[];
  procedures: Procedure[];
  steps: Step[];
  connections: Connection[];
  cellDetails: CellDetail[];
  ladder: Ladder;
}

export function uiSignalling(flow: Flow, options: UiOptions = {}): UiSignalling {
  const reveal = options.reveal ?? false;
  const annotations = options.annotations ?? new Map<number, string>();
  return {
    events: flow.events.map((e) => uiEvent(e, reveal)),
    procedures: flow.procedures.map((p) => uiProcedure(p, reveal)),
    steps: flow.journey.map((s) => {
      const out: Step = { move: s.move, to: s.to, event: s.event, sinceStartMs: s.sinceStartMs };
      if (s.from) out.from = s.from;
      const a = annotations.get(s.event);
      if (a !== undefined) out.annotation = a;
      return out;
    }),
    connections: flow.connections.map((c) => {
      const out: Connection = { first: c.first, outcome: c.outcome, established: c.established, startMs: c.startMs };
      if (c.last !== null) out.last = c.last;
      if (c.establishmentCause !== null) out.establishmentCause = c.establishmentCause;
      if (c.releaseCause !== null) out.releaseCause = c.releaseCause;
      if (c.endMs !== null) out.endMs = c.endMs;
      return out;
    }),
    cellDetails: flow.cellDetails.map(({ cell, info }) => {
      const out: CellDetail = {
        cell,
        pci: info.pci,
        downlinkEarfcn: info.downlinkEarfcn,
        uplinkEarfcn: info.uplinkEarfcn,
        band: info.band,
        plmn: info.plmn,
        tac: info.tac,
      };
      if (reveal && info.cellIdentity !== null) out.cellIdentity = info.cellIdentity;
      if (info.bandwidthMhz !== null) out.bandwidthMhz = info.bandwidthMhz;
      return out;
    }),
    ladder: ladder(flow),
  };
}

/** A field for the UI: masked text in `value` unless revealed; `masked` wherever masking changes it. */
export function uiField(f: FlowField, reveal: boolean, parentMasked = false): Field {
  const { value: masked, masked: identity } = maskedValue(f, parentMasked);
  const out: Field = { label: f.label, value: reveal ? f.value : masked, children: f.children.map((c) => uiField(c, reveal, identity)) };
  if (masked !== f.value) out.masked = masked;
  return out;
}

/** [shown, masked-if-different] for a free-text string. */
function text(s: string, reveal: boolean): [string, string | undefined] {
  const masked = scrub(s);
  return [reveal ? s : masked, masked !== s ? masked : undefined];
}

export function uiEvent(e: FlowEvent, reveal: boolean): Event {
  const out: Event = {
    index: e.index,
    record: e.record,
    logCode: hexCode(e.logCode),
    sinceStartMs: e.sinceStartMs,
    layer: e.layer,
    rat: e.rat === 'nr' ? 'NR' : 'LTE',
    uplink: e.uplink,
    channel: e.channel,
    key: e.key,
    name: e.name,
    fields: e.fields.map((f) => uiField(f, reveal)),
    ciphered: e.ciphered,
    isFailure: e.isFailure,
    isHandoverCommand: e.isHandoverCommand,
    pduLength: e.pdu.length,
  };
  const utc = utcMs(e.timestampRaw);
  if (utc !== null) out.utcMs = utc;
  if (e.summary !== null) {
    const [shown, masked] = text(e.summary, reveal);
    out.summary = shown;
    if (masked !== undefined) out.summaryMasked = masked;
  }
  if (e.cell) out.cell = e.cell;
  if (e.cause !== null) out.cause = e.cause;
  if (e.causeName !== null) out.causeName = e.causeName;
  if (e.protection) {
    const p = e.protection;
    out.protection = { headerType: p.headerType, headerName: headerName(p.headerType), sequence: p.sequence, mac: p.mac };
  }
  if (e.carrier !== null) out.carrier = e.carrier;
  // The bytes hold every identifier the fields do, unmasked: only when revealed.
  if (reveal && e.pdu.length) out.pduHex = hexString(e.pdu);
  return out;
}

export function uiProcedure(p: FlowProcedure, reveal: boolean): Procedure {
  const out: Procedure = { name: p.name, layer: p.layer, first: p.first, last: p.last, outcome: p.outcome, durationMs: p.durationMs };
  if (p.detail !== null) {
    const [shown, masked] = text(p.detail, reveal);
    out.detail = shown;
    if (masked !== undefined) out.detailMasked = masked;
  }
  if (p.refusal !== null) {
    const [shown, masked] = text(p.refusal, reveal);
    out.refusal = shown;
    if (masked !== undefined) out.refusalMasked = masked;
  }
  return out;
}
