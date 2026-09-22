// OWNER: integrator (seeded by the engine foundation). Maps the parity Flow (null-for-absent, bigint stamps, PDU
// bytes) to the UI's plain types, adding the masked form of every string masking would change.

import { hexCode } from './diag/record.ts';
import { utcMs } from './diag/timebase.ts';
import { maskedValue, scrub } from './signalling/mask.ts';
import type { Flow, FlowEvent, FlowField, FlowProcedure } from './signalling/flow.ts';
import type { CellDetail, Connection, Event, Field, Procedure, Step } from './types.ts';

const HEADER_NAMES: Record<number, string> = {
  1: 'integrity protected',
  2: 'integrity protected and ciphered',
  3: 'integrity protected, new security context',
  4: 'integrity protected and ciphered, new security context',
};

export function uiField(f: FlowField, parentMasked = false): Field {
  const { value: masked, masked: isIdentity } = maskedValue(f, parentMasked);
  const out: Field = { label: f.label, value: f.value, children: f.children.map((c) => uiField(c, isIdentity)) };
  if (masked !== f.value) out.masked = masked;
  return out;
}

export function uiEvent(e: FlowEvent): Event {
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
    fields: e.fields.map((f) => uiField(f)),
    ciphered: e.ciphered,
    isFailure: e.isFailure,
    isHandoverCommand: e.isHandoverCommand,
    pduLength: e.pdu.length,
  };
  const utc = utcMs(e.timestampRaw);
  if (utc !== null) out.utcMs = utc;
  if (e.summary !== null) {
    out.summary = e.summary;
    const masked = scrub(e.summary);
    if (masked !== e.summary) out.summaryMasked = masked;
  }
  if (e.cell) out.cell = e.cell;
  if (e.cause !== null) out.cause = e.cause;
  if (e.causeName !== null) out.causeName = e.causeName;
  if (e.protection) {
    const p = e.protection;
    out.protection = { headerType: p.headerType, headerName: HEADER_NAMES[p.headerType] ?? `type ${p.headerType}`, sequence: p.sequence, mac: p.mac };
  }
  if (e.carrier !== null) out.carrier = e.carrier;
  if (e.pdu.length) out.pduHex = hex(e.pdu);
  return out;
}

export function uiProcedure(p: FlowProcedure): Procedure {
  const out: Procedure = { name: p.name, layer: p.layer, first: p.first, last: p.last, outcome: p.outcome, durationMs: p.durationMs };
  if (p.detail !== null) {
    out.detail = p.detail;
    const m = scrub(p.detail);
    if (m !== p.detail) out.detailMasked = m;
  }
  if (p.refusal !== null) {
    out.refusal = p.refusal;
    const m = scrub(p.refusal);
    if (m !== p.refusal) out.refusalMasked = m;
  }
  return out;
}

export function uiSteps(flow: Flow, annotations: Map<number, string>): Step[] {
  return flow.journey.map((s) => {
    const out: Step = { move: s.move, to: s.to, event: s.event, sinceStartMs: s.sinceStartMs };
    if (s.from) out.from = s.from;
    const a = annotations.get(s.event);
    if (a) out.annotation = a;
    return out;
  });
}

export function uiConnections(flow: Flow): Connection[] {
  return flow.connections.map((c) => {
    const out: Connection = { first: c.first, outcome: c.outcome, established: c.established, startMs: c.startMs };
    if (c.last !== null) out.last = c.last;
    if (c.establishmentCause !== null) out.establishmentCause = c.establishmentCause;
    if (c.releaseCause !== null) out.releaseCause = c.releaseCause;
    if (c.endMs !== null) out.endMs = c.endMs;
    return out;
  });
}

export function uiCellDetails(flow: Flow): CellDetail[] {
  return flow.cellDetails.map(({ cell, info }) => {
    const out: CellDetail = {
      cell,
      pci: info.pci,
      downlinkEarfcn: info.downlinkEarfcn,
      uplinkEarfcn: info.uplinkEarfcn,
      band: info.band,
      plmn: info.plmn,
      tac: info.tac,
    };
    if (info.cellIdentity !== null) out.cellIdentity = info.cellIdentity;
    if (info.bandwidthMhz !== null) out.bandwidthMhz = info.bandwidthMhz;
    return out;
  });
}

function hex(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, '0');
  return s;
}
