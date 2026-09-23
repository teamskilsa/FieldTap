// A parity Flow read back from a contract golden (callflow-golden.json and the OnePlus goldens), so the journey is
// tested against the Kotlin call flow without waiting for the TypeScript one. The goldens are masked: no PDU bytes
// (a zero-filled PDU of pduLength stands in) and cellIdentity '<masked>' (read as null). startUtcMs is derived from
// events[0] the way reduce_phy.py does, since the golden says only startUtcKnown.

import { GPS_EPOCH_UTC_MS, modemMs } from '../src/diag/timebase.ts';
import type { Flow, FlowField } from '../src/signalling/flow.ts';
import { readJson } from '../tools/golden.ts';

// deno-lint-ignore no-explicit-any
type Json = any;

const field = (f: Json): FlowField => ({ label: f.label, value: f.value, children: (f.children ?? []).map(field) });

export function flowFromGolden(g: Json): Flow {
  const events = g.events.map((e: Json) => ({
    index: e.index,
    record: e.record,
    logCode: parseInt(e.logCode, 16),
    timestampRaw: BigInt(e.timestampRaw),
    sinceStartMs: e.sinceStartMs,
    layer: e.layer,
    rat: e.rat,
    uplink: e.uplink,
    key: e.key,
    name: e.name,
    summary: e.summary,
    cell: e.cell,
    channel: e.channel,
    fields: e.fields.map(field),
    cause: e.cause,
    causeName: e.causeName,
    protection: e.protection ? { headerType: e.protection.headerType, mac: e.protection.mac ?? 0, sequence: e.protection.sequence } : null,
    ciphered: e.ciphered,
    pdu: new Uint8Array(e.pduLength ?? 0),
    carrier: e.carrier,
    isFailure: e.isFailure,
    isHandoverCommand: e.isHandoverCommand,
  }));
  const e0 = events[0];
  const startUtcMs = g.flow.startUtcKnown && e0 ? Math.trunc(GPS_EPOCH_UTC_MS + modemMs(e0.timestampRaw) - e0.sinceStartMs) : null;
  return {
    events,
    procedures: g.procedures,
    journey: g.journey,
    searched: g.searched,
    connections: g.connections,
    cellDetails: g.cellDetails.map((d: Json) => ({
      cell: d.cell,
      info: {
        pci: d.pci,
        downlinkEarfcn: d.downlinkEarfcn,
        uplinkEarfcn: d.uplinkEarfcn,
        band: d.band,
        plmn: d.plmn,
        tac: d.tac,
        cellIdentity: typeof d.cellIdentity === 'number' ? d.cellIdentity : null,
        bandwidthMhz: d.bandwidthMhz,
      },
    })),
    records: g.flow.records,
    undecoded: g.flow.undecoded,
    crcErrors: g.flow.crcErrors,
    durationMs: g.flow.durationMs,
    startUtcMs,
    failures: g.flow.failures,
  };
}

export async function loadGoldenFlow(path: string): Promise<Flow> {
  return flowFromGolden(await readJson(path));
}
