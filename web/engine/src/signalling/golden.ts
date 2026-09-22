// Port of ios/Contract/tools/GoldenDump.kt and PresDump.kt: a Flow serialised exactly as the Kotlin writes the
// contract fixtures (callflow-golden.json and friends, presentation-golden.json), byte for byte, so parity can be
// checked both structurally (tools/golden.ts) and by md5. Masked by the golden rules (mask.ts): no PDU bytes, no
// identifier values; cellIdentity is always '<masked>'. Browser-safe: it only builds strings.

import { hexCode } from '../diag/record.ts';
import type { Cell, Flow, FlowField } from './flow.ts';
import { fixed, javaDouble } from './javafmt.ts';
import { maskField, MASKED, scrubNullable } from './mask.ts';
import { cellCount, cellsOf, duration, downlinkMhz, band, FILTERS, flowProcedureGroups, flowRows, gap, lanes, messageCount, messageMixed, shortCell, sinceStart } from './presentation.ts';

/** GoldenDump's source block: what the qmdl reader saw. `file` is ignored by the comparator. */
export interface GoldenSource {
  file: string;
  bytes: number;
  hdlcFrames: number;
  crcErrors: number;
  logRecords: number;
  badPackets: number;
}

export const GOLDEN_DECODER = 'FieldTap android/diag (Kotlin) + LteRrc v30 layout E + NrRrc v26 layout E (see lterrc_v30.diff, nrrrc_v26.diff)';
export const GOLDEN_MASKING = 'field values whose label matches IDENTITY_LABEL (and all their children) -> <masked>; in every other string, IPv4/IPv6, 10+ digit runs and 0x-hex of 8+ digits -> <masked>. pdu bytes are omitted (pduLength only).';

/** Kotlin's q(): a JSON string, escaping only what GoldenDump escapes (everything else is written as UTF-8). */
export function q(s: string | null): string {
  if (s === null) return 'null';
  let out = '"';
  for (const c of s) {
    if (c === '"') out += '\\"';
    else if (c === '\\') out += '\\\\';
    else if (c === '\n') out += '\\n';
    else if (c === '\r') out += '\\r';
    else if (c === '\t') out += '\\t';
    else if (c < ' ') out += '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0');
    else out += c;
  }
  return out + '"';
}

/** GoldenDump's num(): '%.3f' with Java's rounding. */
const num = (d: number) => fixed(d, 3);

function fieldJson(f: FlowField): string {
  const kids = f.children.length ? `,"children":[${f.children.map(fieldJson).join(',')}]` : '';
  return `{"label":${q(f.label)},"value":${q(f.value)}${kids}}`;
}

const cellJson = (c: Cell | null) => (c === null ? 'null' : `{"earfcn":${c.earfcn},"pci":${c.pci},"nr":${c.nr}}`);

const HEADER_NAMES: Record<number, string> = {
  1: 'integrity protected',
  2: 'integrity protected and ciphered',
  3: 'integrity protected, new security context',
  4: 'integrity protected and ciphered, new security context',
};

/** CallFlow.Protection.headerName. */
export const headerName = (headerType: number) => HEADER_NAMES[headerType] ?? `type ${headerType}`;

/** Kotlin prints a Long: the signed 64-bit value of the stamp's bits. */
const signed = (raw: bigint) => BigInt.asIntN(64, raw).toString();

/** callflow-golden.json for `flow`, as GoldenDump.kt writes it. `recordsPerCode` is diag/qmdl.ts recordsPerCode. */
export function goldenDump(flow: Flow, source: GoldenSource, recordsPerCode: Record<string, number>): string {
  let sb = '{\n';
  sb += `"source":{"file":${q(source.file)},"bytes":${source.bytes},"hdlcFrames":${source.hdlcFrames},"crcErrors":${source.crcErrors},"logRecords":${source.logRecords},"badPackets":${source.badPackets}},\n`;
  sb += `"decoder":${q(GOLDEN_DECODER)},\n`;
  sb += `"masking":${q(GOLDEN_MASKING)},\n`;
  sb += `"flow":{"records":${flow.records},"undecoded":${flow.undecoded},"crcErrors":${flow.crcErrors},"durationMs":${num(flow.durationMs)},"startUtcKnown":${flow.startUtcMs !== null},"failures":${flow.failures}},\n`;
  sb += '"events":[\n';
  sb += flow.events.map((e) => {
    const fields = e.fields.map((f) => fieldJson(maskField(f, false))).join(',');
    const p = e.protection;
    const prot = p ? `{"headerType":${p.headerType},"headerName":${q(headerName(p.headerType))},"sequence":${p.sequence}}` : 'null';
    return `{"index":${e.index},"record":${e.record},"logCode":"${hexCode(e.logCode)}",` +
      `"timestampRaw":${signed(e.timestampRaw)},"sinceStartMs":${num(e.sinceStartMs)},"layer":"${e.layer}","rat":${q(e.rat)},"uplink":${e.uplink},` +
      `"channel":${q(e.channel)},"key":${q(e.key)},"name":${q(e.name)},"summary":${q(scrubNullable(e.summary))},"cell":${cellJson(e.cell)},` +
      `"cause":${e.cause},"causeName":${q(e.causeName)},"protection":${prot},"ciphered":${e.ciphered},"isFailure":${e.isFailure},` +
      `"isHandoverCommand":${e.isHandoverCommand},"carrier":${q(e.carrier)},"pduLength":${e.pdu.length},"fields":[${fields}]}`;
  }).join(',\n');
  sb += '\n],\n"procedures":[\n';
  sb += flow.procedures.map((p) =>
    `{"name":${q(p.name)},"layer":"${p.layer}","detail":${q(scrubNullable(p.detail))},"first":${p.first},"last":${p.last},"outcome":"${p.outcome}","durationMs":${num(p.durationMs)},"refusal":${q(scrubNullable(p.refusal))}}`
  ).join(',\n');
  sb += '\n],\n"journey":[\n';
  sb += flow.journey.map((s) => `{"move":"${s.move}","from":${cellJson(s.from)},"to":${cellJson(s.to)},"event":${s.event},"sinceStartMs":${num(s.sinceStartMs)}}`).join(',\n');
  sb += '\n],\n"searched":[' + flow.searched.map(cellJson).join(',') + '],\n';
  sb += '"connections":[\n';
  sb += flow.connections.map((c) =>
    `{"first":${c.first},"last":${c.last},"establishmentCause":${q(c.establishmentCause)},"releaseCause":${q(c.releaseCause)},"outcome":"${c.outcome}","startMs":${num(c.startMs)},"endMs":${c.endMs === null ? 'null' : num(c.endMs)},"established":${c.established}}`
  ).join(',\n');
  sb += '\n],\n"cellDetails":[\n';
  sb += flow.cellDetails.map(({ cell, info: s }) =>
    `{"cell":${cellJson(cell)},"pci":${s.pci},"downlinkEarfcn":${s.downlinkEarfcn},"uplinkEarfcn":${s.uplinkEarfcn},"band":${s.band},"plmn":${q(s.plmn)},"tac":${s.tac},"cellIdentity":"${MASKED}","bandwidthMhz":${s.bandwidthMhz === null ? 'null' : javaDouble(s.bandwidthMhz)}}`
  ).join(',\n');
  sb += '\n],\n"recordsPerCode":{' + Object.entries(recordsPerCode).map(([code, n]) => `"${code}":${n}`).join(',') + '}\n}\n';
  return sb;
}

/** presentation-golden.json for `flow`, as PresDump.kt writes it: no field values at all. */
export function presentationDump(flow: Flow): string {
  let sb = '{\n';
  for (const filter of FILTERS) {
    sb += `"rows${filter}":[\n`;
    sb += flowRows(flow, filter).map((r) => {
      switch (r.kind) {
        case 'move':
          return `{"type":"move","key":${q(r.key)},"move":"${r.step.move}","to":${q(shortCell(r.step.to))},"band":${q(band(r.step.to))},"downlink":${q(downlinkMhz(r.step.to))}}`;
        case 'procedure':
          return `{"type":"procedure","key":${q(r.key)},"name":${q(r.procedure.name)},"outcome":"${r.procedure.outcome}","duration":${q(duration(r.procedure.durationMs))}}`;
        case 'message': {
          const g = gap(flow.events, r.event.index);
          return `{"type":"message","key":${q(r.key)},"name":${q(r.event.name)},"count":${messageCount(r)},"mixed":${messageMixed(r)},"cells":${q(cellsOf(r))},"cellCount":${cellCount(r)},"since":${q(sinceStart(r.event.sinceStartMs))},"gap":${g === null ? 'null' : q(duration(g))}}`;
        }
      }
    }).join(',\n');
    sb += '\n],\n';
  }
  const l = lanes(flow);
  sb += `"lanes":{"phone":${q(l.phone)},"ran":${q(l.ran)},"core":${q(l.core)}},\n`;
  sb += '"procedureGroups":[\n' + flowProcedureGroups(flow).map((g) =>
    `{"name":${q(g.name)},"layer":"${g.layer}","n":${g.items.length},"succeeded":${g.succeeded},"failed":${g.failed},"unanswered":${g.unanswered},"median":${g.medianMs === null ? 'null' : q(duration(g.medianMs))}}`
  ).join(',\n') + '\n]\n}\n';
  return sb;
}
