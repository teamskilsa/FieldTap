// Port of ios/Contract/src-v1/CallFlow.kt (android/diag CallFlow.kt at contract v1: D1-D4).
//
// A capture read the way an engineer reads one: RRC and NAS on one timeline, grouped into the procedures they
// make up, with the cells the phone moved through.
//
// - One row per message. The modem logs most NAS messages twice after security starts, once as sent (with a MAC
//   and sequence number) and once in plain text. The plain copy is the row; the protected copy gives it its
//   security header, MAC and sequence number, matched on content rather than guessed at by time.
// - Procedures, each from the message that starts it to the one that answers it, with how long that took and
//   whether it worked. One the capture never saw answered says so instead of pretending to have succeeded.
// - The cell journey. Every RRC message carries the cell it was logged on, and what kind of change a new cell
//   was comes from what happened just before: a handover command, a redirecting release, a re-establishment
//   request on the new cell, or nothing at all while idle (a reselection).
//
// Parity: readFlow over a qmdl's records reproduces its golden (golden.ts serialises it the way GoldenDump.kt
// does); tests/signalling_golden_test.ts holds it to all four.

import { readQmdl } from '../diag/qmdl.ts';
import type { LogRecord } from '../diag/record.ts';
import { isPositive, modemMs, TimeBase, utcMs } from '../diag/timebase.ts';
import { bytesEqual } from './bytes.ts';
import { servingCell } from './cellinfo.ts';
import type { Cell, Flow, FlowConnection, FlowEvent, FlowField, FlowProcedure, FlowProtection, FlowStep, Layer, Outcome, ServingCellInfo } from './flow.ts';
import { logCodeOf, type LogCodeInfo } from './logcodes.ts';
import { decodeLteRrc, HANDOVER, isUplinkLte, readableLte } from './lterrc.ts';
import { decodeNas, decodeNasPdu, type NasMessage } from './nas.ts';
import { epsFields, fiveGsFields } from './nasfields.ts';
import { decodeNrRrc, isUplinkNr, readableNr } from './nrrrc.ts';
import { hex } from './javafmt.ts';

const SERVING_CELL_INFO = 0xb0c2;

/** Cell equality as the Kotlin data class has it. */
export const sameCell = (a: Cell | null | undefined, b: Cell | null | undefined): boolean =>
  a === b || (!!a && !!b && a.earfcn === b.earfcn && a.pci === b.pci && a.nr === b.nr);

export const cellKey = (c: Cell): string => `${c.nr ? 'nr' : 'lte'}/${c.earfcn}/${c.pci}`;

// MARK: - Reading

/** The call flow of a qmdl file (CallFlow.read): HDLC frames, log packets, then readFlow. */
export function readQmdlFlow(qmdl: Uint8Array): Flow {
  const read = readQmdl(qmdl);
  return readFlow(read.records, read.crcErrors);
}

/**
 * The call flow of a capture's records, in file order (CallFlow.of plus the D1 time base). `crcErrors` is carried
 * into Flow.crcErrors: the HDLC reader's count for a qmdl, 0 for records rebuilt from a QDSS trace. Only the
 * signalling records are kept, numbered as they came, so a long capture is not held twice.
 */
export function readFlow(records: readonly LogRecord[], crcErrors = 0): Flow {
  const timeBase = new TimeBase();
  const kept: [number, LogRecord][] = [];
  for (let i = 0; i < records.length; i++) {
    const record = records[i];
    // D1: measure from the first plausible (post-2005) timestamp; TimeBase makes CallFlow.Reading's pass.
    timeBase.add(record.timestampRaw);
    const category = logCodeOf(record.code)?.category;
    if (category === 'NAS' || category === 'RRC' || record.code === SERVING_CELL_INFO) kept.push([i + 1, record]);
  }
  return build(kept, records.length, crcErrors, timeBase);
}

// MARK: - Building

interface Draft {
  record: number;
  logCode: number;
  timestampRaw: bigint;
  layer: Layer;
  rat: 'lte' | 'nr';
  uplink: boolean;
  key: string;
  name: string;
  cell: Cell | null;
  channel: string;
  fields: FlowField[];
  cause: number | null;
  causeName: string | null;
  protection: FlowProtection | null;
  ciphered: boolean;
  pdu: Uint8Array;
  /** For a security-protected copy: the message inside, to find its plain twin. */
  inner: Uint8Array | null;
  plain: boolean;
  carrier: string | null;
  dropped: boolean;
}

type DraftInit = Omit<Draft, 'inner' | 'plain' | 'carrier' | 'dropped'> & Partial<Pick<Draft, 'inner' | 'plain' | 'carrier'>>;

const draft = (d: DraftInit): Draft => ({ inner: null, plain: false, carrier: null, ...d, dropped: false });

function build(records: [number, LogRecord][], count: number, crcErrors: number, timeBase: TimeBase): Flow {
  const drafts: Draft[] = [];
  const cellDetails = new Map<string, { cell: Cell; info: ServingCellInfo }>();
  let undecoded = 0;
  for (const [number, record] of records) {
    if (record.code === SERVING_CELL_INFO) {
      const info = servingCell(record.body);
      if (info) {
        const cell: Cell = { earfcn: info.downlinkEarfcn, pci: info.pci, nr: false };
        // LinkedHashMap.put: a later record replaces the value but keeps the first-seen position.
        const known = cellDetails.get(cellKey(cell));
        if (known) known.info = info;
        else cellDetails.set(cellKey(cell), { cell, info });
      }
      continue;
    }
    const info = logCodeOf(record.code);
    if (!info) continue;
    let made: Draft[];
    if (record.code === 0xb0c0) made = nonNull(rrcDraft(number, record));
    else if (record.code === 0xb821) made = nrDrafts(number, record);
    else if (info.category === 'RRC') made = [];
    else made = nonNull(nasDraft(number, record, info));
    if (made.length === 0) undecoded++;
    else drafts.push(...made);
  }
  pairProtectedCopies(drafts);
  pairCarriedCopies(drafts);

  const kept = drafts.filter((d) => !d.dropped);
  const rrcCells: [number, Cell][] = [];
  kept.forEach((d, i) => {
    if (d.cell && SERVING_CHANNELS.has(d.channel)) rrcCells.push([i, d.cell]);
  });
  const firstRaw = timeBase.firstRaw;
  const startMs = firstRaw > 0n ? modemMs(firstRaw) : 0;
  const events: FlowEvent[] = kept.map((d, i) => {
    const fields = d.fields;
    return {
      index: i,
      record: d.record,
      logCode: d.logCode,
      timestampRaw: d.timestampRaw,
      sinceStartMs: isPositive(d.timestampRaw) && firstRaw > 0n ? modemMs(d.timestampRaw) - startMs : 0,
      layer: d.layer,
      rat: d.rat,
      uplink: d.uplink,
      key: d.key,
      name: d.name,
      summary: summaryOf(fields, d.cause, d.causeName),
      cell: d.cell ?? nearestCell(rrcCells, i, d.uplink),
      channel: d.channel,
      fields,
      cause: d.cause,
      causeName: d.causeName,
      protection: d.protection,
      ciphered: d.ciphered,
      pdu: d.pdu,
      carrier: d.carrier,
      isFailure: d.cause !== null || /reject|failure/i.test(d.key),
      isHandoverCommand: fields.some((f) => f.label === HANDOVER),
    };
  });
  const steps = journey(events).map((step) => ({ ...step, event: firstOnCell(events, step) }));
  const visited = new Set(steps.map((s) => cellKey(s.to)));
  const searched = new Map<string, Cell>();
  for (const e of events) {
    if (e.layer !== 'RRC' || !BROADCAST_CHANNELS.has(e.channel) || !e.cell) continue;
    const key = cellKey(e.cell);
    if (!visited.has(key) && !searched.has(key)) searched.set(key, e.cell);
  }
  return {
    events,
    procedures: procedures(events),
    journey: steps,
    searched: [...searched.values()],
    connections: connections(events),
    cellDetails: [...cellDetails.values()],
    records: count,
    undecoded,
    crcErrors,
    durationMs: timeBase.durationMs,
    startUtcMs: utcMs(firstRaw),
    failures: events.filter((e) => e.isFailure).length,
  };
}

const nonNull = <T>(v: T | null): T[] => (v === null ? [] : [v]);

function rrcDraft(number: number, record: LogRecord): Draft | null {
  const message = decodeLteRrc(record.body);
  if (!message || message.channel === null || message.asn1Name === null) return null;
  return draft({
    record: number,
    logCode: record.code,
    timestampRaw: record.timestampRaw,
    layer: 'RRC',
    rat: 'lte',
    uplink: isUplinkLte(message.channel),
    key: message.asn1Name,
    name: readableLte(message.asn1Name),
    cell: { earfcn: message.earfcn, pci: message.pci, nr: false },
    channel: message.channel,
    fields: message.fields,
    cause: null,
    causeName: null,
    protection: null,
    ciphered: false,
    pdu: message.payload,
  });
}

/**
 * An NR RRC message, and the 5G NAS message inside it when it carried one. The NAS row takes the RRC message's
 * direction and cell, and says which message carried it.
 */
function nrDrafts(number: number, record: LogRecord): Draft[] {
  const message = decodeNrRrc(record.body);
  if (!message || message.channel === null || message.asn1Name === null) return [];
  const cell: Cell = { earfcn: message.arfcn, pci: message.pci, nr: true };
  const uplink = isUplinkNr(message.channel);
  const rrc = draft({
    record: number,
    logCode: record.code,
    timestampRaw: record.timestampRaw,
    layer: 'RRC',
    rat: 'nr',
    uplink,
    key: message.asn1Name,
    name: readableNr(message.asn1Name),
    cell,
    channel: message.channel,
    fields: message.fields,
    cause: null,
    causeName: null,
    protection: null,
    ciphered: false,
    pdu: message.payload,
  });
  if (message.nas === null) return [rrc];
  return [rrc, ...nonNull(carriedNas(number, record, message.nas, uplink, cell, readableNr(message.asn1Name)))];
}

const be32 = (p: Uint8Array, at: number) => p[at] * 0x1000000 + (p[at + 1] << 16) + (p[at + 2] << 8) + p[at + 3];

/**
 * 5G NAS as it went over the air. After security starts it is protected: EPD, security header, MAC (4) and
 * sequence number, then the message: readable when only integrity-protected, ciphered otherwise, and with no
 * plain copy logged on this modem to fall back on.
 */
function carriedNas(number: number, record: LogRecord, pdu: Uint8Array, uplink: boolean, cell: Cell, carrier: string): Draft | null {
  const outer = decodeNasPdu(pdu, true);
  if (!outer) return null;
  let protection: FlowProtection | null = null;
  let message = outer;
  let body = pdu;
  if (outer.sublayer === '5gmm' && outer.securityHeader >= 1 && outer.securityHeader <= 4 && pdu.length > 7) {
    protection = { headerType: outer.securityHeader, mac: be32(pdu, 2), sequence: pdu[6] };
    const inner = pdu.slice(7);
    const decoded = decodeNasPdu(inner, true);
    if (decoded && decoded.securityHeader === 0 && decoded.name !== null) {
      message = decoded;
      body = inner;
    }
  }
  const readable = message.securityHeader === 0 && message.messageType !== null;
  return draft({
    record: number,
    logCode: record.code,
    timestampRaw: record.timestampRaw,
    layer: 'NAS',
    rat: 'nr',
    uplink,
    key: readable ? message.name ?? 'unnamed' : 'ciphered',
    name: readable
      ? message.name ?? `5GS message 0x${hex(message.messageType!, 2, true)}`
      : `Ciphered ${outer.sublayer.toUpperCase()} message`,
    cell,
    channel: message.sublayer.toUpperCase(),
    fields: readable ? fiveGsFields(message.sublayer, 0, message.messageType, body, uplink) : [],
    cause: message.cause,
    causeName: message.causeName,
    protection,
    ciphered: !readable,
    pdu,
    inner: body !== pdu ? body : null,
    carrier,
  });
}

function nasDraft(number: number, record: LogRecord, info: LogCodeInfo): Draft | null {
  const nr = info.isNr;
  const message = decodeNas(record.body, nr);
  if (!message) return null;
  const pdu = record.body.slice(message.offset);
  const logged = info.nasDirection ?? message.direction ?? 'ul';

  // A protected copy: header, MAC (4), sequence number (1), then the message. 5GS puts the EPD first.
  const headerAt = nr ? 1 : 0;
  const sec = message.securityHeader;
  if (info.nasProtected && sec >= 1 && sec <= 4 && pdu.length > headerAt + 6) {
    const macAt = headerAt + 1;
    const protection: FlowProtection = { headerType: sec, mac: be32(pdu, macAt), sequence: pdu[macAt + 4] };
    const inner = pdu.slice(macAt + 5);
    // Qualcomm logs the protected copy after deciphering, so the message inside is usually readable.
    const decoded = decodeNasPdu(inner, nr);
    if (decoded && decoded.name !== null && decoded.securityHeader === 0) {
      return { ...nasOf(number, record, info, decoded, inner, logged, nr), protection, inner, plain: false };
    }
    return draft({
      record: number,
      logCode: record.code,
      timestampRaw: record.timestampRaw,
      layer: 'NAS',
      rat: info.rat,
      uplink: logged === 'ul',
      key: 'ciphered',
      name: `Ciphered ${message.sublayer.toUpperCase()} message`,
      cell: null,
      channel: message.sublayer.toUpperCase(),
      fields: [],
      cause: null,
      causeName: null,
      protection,
      ciphered: true,
      pdu,
      inner,
    });
  }
  return nasOf(number, record, info, message, pdu, logged, nr);
}

function nasOf(number: number, record: LogRecord, info: LogCodeInfo, message: NasMessage, pdu: Uint8Array, logged: string, nr: boolean): Draft {
  const uplink = (message.direction ?? logged) === 'ul';
  const fields = nr
    ? fiveGsFields(message.sublayer, message.securityHeader, message.messageType, pdu, uplink)
    : epsFields(message.sublayer, message.securityHeader, message.messageType, pdu, uplink);
  const layer = message.sublayer.toUpperCase();
  const name = message.name ??
    (message.messageType === null ? `Ciphered ${layer} message` : `${layer} message 0x${hex(message.messageType, 2, true)}`);
  return draft({
    record: number,
    logCode: record.code,
    timestampRaw: record.timestampRaw,
    layer: 'NAS',
    rat: info.rat,
    uplink,
    key: message.name ?? 'unnamed',
    name,
    cell: null,
    channel: layer,
    fields,
    cause: message.cause,
    causeName: message.causeName,
    protection: null,
    ciphered: message.messageType === null && message.securityHeader !== 12,
    pdu,
    plain: !info.nasProtected,
  });
}

const WINDOW = 8;

function* around(drafts: Draft[], i: number): Generator<Draft> {
  for (let k = Math.max(0, i - WINDOW); k < Math.min(drafts.length, i + WINDOW + 1); k++) yield drafts[k];
}

/**
 * The modem logs a protected copy and a plain copy of the same message, in either order and a few records
 * apart. The plain copy stays and takes the protection; the protected copy goes. A protected copy with no plain
 * twin stays as its own row.
 */
function pairProtectedCopies(drafts: Draft[]): void {
  drafts.forEach((secured, i) => {
    const inner = secured.inner;
    if (inner === null || secured.plain) return;
    for (const plain of around(drafts, i)) {
      if (plain.plain && plain.protection === null && plain.uplink === secured.uplink && bytesEqual(plain.pdu, inner) && closeInTime(plain, secured)) {
        plain.protection = secured.protection;
        secured.dropped = true;
        return;
      }
    }
  });
}

const EMPTY = new Uint8Array(0);

/**
 * 5G NAS pulled out of an RRC message is usually also logged plain (0xB80A/0xB80B) a record or two away. The
 * plain copy stays (after security starts it is the only readable one) and takes from the carried copy what only
 * it knows: which RRC message carried it, on which cell, and its protection. A carried copy with no plain twin
 * stays as its own row.
 */
function pairCarriedCopies(drafts: Draft[]): void {
  drafts.forEach((carried, i) => {
    if (carried.carrier === null || carried.plain || carried.dropped) return;
    for (const plain of around(drafts, i)) {
      if (
        plain !== carried && plain.plain && plain.carrier === null && plain.uplink === carried.uplink &&
        (bytesEqual(plain.pdu, carried.pdu) || bytesEqual(plain.pdu, carried.inner ?? EMPTY)) && closeInTime(plain, carried)
      ) {
        plain.carrier = carried.carrier;
        plain.cell = carried.cell;
        if (plain.protection === null) plain.protection = carried.protection;
        carried.dropped = true;
        return;
      }
    }
  });
}

const closeInTime = (a: Draft, b: Draft): boolean =>
  !isPositive(a.timestampRaw) || !isPositive(b.timestampRaw) || Math.abs(modemMs(a.timestampRaw) - modemMs(b.timestampRaw)) <= 2_000;

/**
 * The cell a NAS message went over. The modem logs an uplink NAS message just before the RRC message that
 * carries it, and a downlink one just after, so uplink looks forward and downlink back. Looking back for an
 * uplink message put the tracking area update that followed a reselection on the cell the phone had left.
 */
function nearestCell(cells: [number, Cell][], index: number, uplink: boolean): Cell | null {
  // cells is in index order: binary-search the first entry at or after `index`.
  let lo = 0, hi = cells.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (cells[mid][0] < index) lo = mid + 1;
    else hi = mid;
  }
  const before = lo > 0 ? cells[lo - 1][1] : null;
  const atOrAfter = lo < cells.length && cells[lo][0] === index ? lo + 1 : lo;
  const after = atOrAfter < cells.length ? cells[atOrAfter][1] : null;
  return uplink ? after ?? before : before ?? after;
}

// MARK: - The line under the name

const PLAIN_SUMMARY = new Set([
  'Establishment cause', 'Release cause', 'Attach type', 'Detach type', 'Update type',
  'Identity requested', 'APN', 'PDN address', 'Wait time', 'Cause', 'Ciphering', 'Integrity',
  'Carries', 'Registration type', 'Registration result', 'Service type', 'Deregistration',
  'PDU session type',
]);

function summaryOf(fields: FlowField[], cause: number | null, causeName: string | null): string | null {
  if (cause !== null) return causeName !== null ? `#${cause} ${causeName}` : `#${cause}`;
  const parts: string[] = [];
  for (const f of fields) {
    let part: string | null = null;
    if (PLAIN_SUMMARY.has(f.label)) part = f.value;
    else if (f.label === 'T3502' || f.label === 'T3346') part = `${f.label} ${f.value}`;
    else if (f.label === 'Redirected to') part = `redirect to ${f.value}`;
    else if (f.label === HANDOVER) part = f.value === 'command' ? 'handover command' : `handover ${f.value}`;
    else if (f.label === 'Serving RSRP') part = `RSRP ${f.value}`;
    else if (f.label === 'Neighbours') part = `${f.value.split(' ')[0]} neighbours`;
    else if (f.label === 'QCI') part = `QCI ${f.value}`;
    else if (f.label === 'Switch off') part = f.value === 'yes' ? 'switch off' : null;
    if (part !== null) parts.push(part);
  }
  return parts.length ? parts.join(' · ') : null;
}

// MARK: - Procedures

interface Rule {
  name: string;
  starts: ReadonlySet<string>;
  succeeds: ReadonlySet<string>;
  fails: ReadonlySet<string>;
}

const set = (...keys: string[]): ReadonlySet<string> => new Set(keys);
const rule = (name: string, starts: ReadonlySet<string>, succeeds: ReadonlySet<string>, fails: ReadonlySet<string> = set()): Rule => ({ name, starts, succeeds, fails });

// The same moments of a connection under their LTE and NR names.
const REQUESTS = set('rrcConnectionRequest', 'rrcSetupRequest', 'rrcResumeRequest', 'rrcResumeRequest1');
const SETUPS = set('rrcConnectionSetup', 'rrcSetup', 'rrcResume');
const RELEASES = set('rrcConnectionRelease', 'rrcRelease');
const REJECTS = set('rrcConnectionReject', 'rrcReject');
const REESTABLISHMENT_REQUESTS = set('rrcConnectionReestablishmentRequest', 'rrcReestablishmentRequest');
const REESTABLISHMENTS = set('rrcConnectionReestablishment', 'rrcReestablishment');

const RECONFIGURATION = 'RRC reconfiguration';

const RULES: readonly Rule[] = [
  rule('RRC connection setup', set('rrcConnectionRequest', 'rrcSetupRequest'), set('rrcConnectionSetupComplete', 'rrcSetupComplete'), set('rrcConnectionReject', 'rrcReject')),
  rule('RRC re-establishment', REESTABLISHMENT_REQUESTS, set('rrcConnectionReestablishmentComplete', 'rrcReestablishmentComplete'), set('rrcConnectionReestablishmentReject')),
  rule('RRC resume', set('rrcResumeRequest', 'rrcResumeRequest1'), set('rrcResumeComplete'), set('rrcReject')),
  rule('AS security', set('securityModeCommand'), set('securityModeComplete'), set('securityModeFailure')),
  rule('UE capability', set('ueCapabilityEnquiry'), set('ueCapabilityInformation')),
  rule(RECONFIGURATION, set('rrcConnectionReconfiguration', 'rrcReconfiguration'), set('rrcConnectionReconfigurationComplete', 'rrcReconfigurationComplete'), REESTABLISHMENT_REQUESTS),
  rule('Attach', set('Attach request'), set('Attach accept'), set('Attach reject')),
  // An EPS service request is answered by the RAN starting security, not by a NAS accept.
  rule('Service request', set('Service request', 'Extended service request'), set('Service accept', 'securityModeCommand'), set('Service reject')),
  rule('Tracking area update', set('Tracking area update request'), set('Tracking area update accept'), set('Tracking area update reject')),
  rule('Detach', set('Detach request'), set('Detach accept')),
  rule('Authentication', set('Authentication request'), set('Authentication response'), set('Authentication failure', 'Authentication reject')),
  rule('NAS security', set('Security mode command'), set('Security mode complete'), set('Security mode reject')),
  rule('Identity', set('Identity request'), set('Identity response')),
  rule('PDN connectivity', set('PDN connectivity request'), set('Activate default EPS bearer context accept'), set('PDN connectivity reject', 'Activate default EPS bearer context reject')),
  rule('Dedicated bearer', set('Activate dedicated EPS bearer context request'), set('Activate dedicated EPS bearer context accept'), set('Activate dedicated EPS bearer context reject')),
  rule('Bearer modification', set('Modify EPS bearer context request'), set('Modify EPS bearer context accept'), set('Modify EPS bearer context reject')),
  rule('Bearer deactivation', set('Deactivate EPS bearer context request'), set('Deactivate EPS bearer context accept')),
  rule('PDN disconnect', set('PDN disconnect request'), set('Deactivate EPS bearer context accept'), set('PDN disconnect reject')),
  rule('ESM information', set('ESM information request'), set('ESM information response')),
  rule('Registration', set('Registration request'), set('Registration accept'), set('Registration reject')),
  rule('Deregistration', set('Deregistration request (UE originating)', 'Deregistration request (UE terminated)'), set('Deregistration accept (UE originating)', 'Deregistration accept (UE terminated)')),
  rule('PDU session establishment', set('PDU session establishment request'), set('PDU session establishment accept'), set('PDU session establishment reject')),
  rule('PDU session release', set('PDU session release request'), set('PDU session release command')),
];

interface Open {
  rule: Rule;
  name: string;
  start: FlowEvent;
}

/** Stable, as Kotlin's sortedBy (and Array.prototype.sort since ES2019). */
const byFirst = <T extends { first: number }>(items: T[]): T[] => [...items].sort((a, b) => a.first - b.first);

function procedures(events: FlowEvent[]): FlowProcedure[] {
  const done: FlowProcedure[] = [];
  let open: Open[] = [];
  const close = (o: Open, end: FlowEvent, outcome: Outcome) => {
    open = open.filter((x) => x !== o);
    done.push({
      name: o.name,
      layer: o.start.layer,
      detail: o.start.summary,
      first: o.start.index,
      last: end.index,
      outcome,
      durationMs: end.sinceStartMs - o.start.sinceStartMs,
      refusal: outcome === 'FAILED' ? end.summary ?? end.name : null,
    });
  };
  for (const event of events) {
    for (const o of [...open]) {
      // Contract v1 (D3): a procedure is answered only on the RAT it started on. On EN-DC the NR
      // RRCReconfiguration rides inside the LTE one; without this it closed the LTE one as unanswered.
      if (o.start.rat !== event.rat) continue;
      if (o.rule.succeeds.has(event.key)) close(o, event, 'SUCCEEDED');
      else if (o.rule.fails.has(event.key)) close(o, event, 'FAILED');
    }
    const r = RULES.find((x) => x.starts.has(event.key));
    if (!r) continue;
    // A second start before the first was answered: the first never was.
    for (const o of open.filter((x) => x.rule === r && x.start.rat === event.rat)) close(o, o.start, 'UNANSWERED');
    const started: Open = { rule: r, name: r.name === RECONFIGURATION && event.isHandoverCommand ? 'Handover' : r.name, start: event };
    open.push(started);
    // A phone switching off does not wait to be told it may.
    if (r.name === 'Detach' && event.uplink && event.fields.some((f) => f.label === 'Switch off' && f.value === 'yes')) {
      close(started, event, 'SUCCEEDED');
    }
  }
  for (const o of [...open]) close(o, o.start, 'UNANSWERED');
  return byFirst(done);
}

// MARK: - Cells and connections

const CONNECTED_CHANNELS = set('UL-DCCH', 'DL-DCCH');

/**
 * Channels a phone only uses on the cell it is camped on or connected to. System information is not one: a phone
 * searching for service reads SIB1 from every cell it can hear, and counting those as cells it was on turned one
 * lost-coverage minute into forty "cell changes".
 */
const SERVING_CHANNELS = set('UL-CCCH', 'DL-CCCH', 'UL-DCCH', 'DL-DCCH', 'PCCH');

const BROADCAST_CHANNELS = set('BCCH-BCH', 'BCCH-DL-SCH', 'MCCH');

/** A step starts at the RRC message that showed the new cell; the NAS messages just before it were on that cell too. */
function firstOnCell(events: FlowEvent[], step: FlowStep): number {
  let first = step.event;
  while (first > 0 && events[first - 1].layer === 'NAS' && sameCell(events[first - 1].cell, step.to)) first--;
  return first;
}

function journey(events: FlowEvent[]): FlowStep[] {
  const steps: FlowStep[] = [];
  let current: Cell | null = null;
  let connected = false;
  let handoverPending = false;
  let redirectPending = false;
  for (const event of events) {
    if (event.layer !== 'RRC' || !SERVING_CHANNELS.has(event.channel)) continue;
    const cell = event.cell;
    if (!cell) continue;
    if (current === null) {
      steps.push({ move: 'FIRST_SEEN', from: null, to: cell, event: event.index, sinceStartMs: event.sinceStartMs });
    } else if (!sameCell(cell, current)) {
      const move = REESTABLISHMENT_REQUESTS.has(event.key)
        ? 'REESTABLISHMENT'
        : handoverPending
        ? 'HANDOVER'
        : redirectPending
        ? 'REDIRECT'
        // A phone asks for a connection, and listens for paging, only when it has none, whatever the log last
        // showed. Connections end without a logged release more often than not.
        : !connected || REQUESTS.has(event.key) || event.channel === 'PCCH'
        ? 'RESELECTION'
        : 'CELL_CHANGE';
      steps.push({ move, from: current, to: cell, event: event.index, sinceStartMs: event.sinceStartMs });
      handoverPending = false;
      redirectPending = false;
      // A request on a new cell after an unanswered one on the old: the phone was idle all along.
      if (move === 'RESELECTION' || move === 'REDIRECT') connected = false;
    }
    current = cell;
    if (RELEASES.has(event.key)) {
      connected = false;
      handoverPending = false;
      redirectPending = event.fields.some((f) => f.label === 'Redirected to');
    } else if (REJECTS.has(event.key) || event.channel === 'PCCH') {
      connected = false;
    } else if (event.isHandoverCommand) {
      handoverPending = true;
    } else if (SETUPS.has(event.key) || REESTABLISHMENTS.has(event.key) || CONNECTED_CHANNELS.has(event.channel)) {
      // A request alone is not a connection: plenty go unanswered.
      connected = true;
    }
  }
  return steps;
}

function connections(events: FlowEvent[]): FlowConnection[] {
  const out: FlowConnection[] = [];
  let request: FlowEvent | null = null;
  let requestCause: string | null = null;
  let open: FlowEvent | null = null;
  let openCause: string | null = null;
  let lastOfOpen: FlowEvent | null = null;

  const connection = (first: FlowEvent, last: FlowEvent | null, establishmentCause: string | null, releaseCause: string | null, outcome: FlowConnection['outcome']): FlowConnection => ({
    first: first.index,
    last: last?.index ?? null,
    establishmentCause,
    releaseCause,
    outcome,
    startMs: first.sinceStartMs,
    endMs: last?.sinceStartMs ?? null,
    established: outcome === 'RELEASED' || outcome === 'OPEN_AT_END' || outcome === 'LOST',
  });
  const valueOf = (e: FlowEvent, label: string) => e.fields.find((f) => f.label === label)?.value ?? null;
  const unanswered = () => {
    if (request) out.push(connection(request, request, requestCause, null, 'NO_ANSWER'));
    request = null;
  };
  const lost = () => {
    if (!open) return;
    out.push(connection(open, lastOfOpen ?? open, openCause, null, 'LOST'));
    open = null;
  };

  for (const event of events) {
    if (event.layer !== 'RRC') continue;
    if (REQUESTS.has(event.key)) {
      unanswered();
      lost();
      request = event;
      requestCause = valueOf(event, 'Establishment cause');
    } else if (SETUPS.has(event.key)) {
      lost();
      open = request ?? event;
      openCause = request !== null ? requestCause : null;
      lastOfOpen = event;
      request = null;
    } else if (REJECTS.has(event.key)) {
      if (request) {
        out.push(connection(request, event, requestCause, null, 'REJECTED'));
        request = null;
      }
    } else if (RELEASES.has(event.key)) {
      out.push(connection(open ?? event, event, open !== null ? openCause : null, valueOf(event, 'Release cause'), 'RELEASED'));
      open = null;
    } else if (CONNECTED_CHANNELS.has(event.channel)) {
      // Connected-mode traffic with no setup seen: the connection began before the capture did.
      if (open === null) {
        open = event;
        openCause = null;
      }
      lastOfOpen = event;
    }
  }
  unanswered();
  if (open) out.push(connection(open, null, openCause, null, 'OPEN_AT_END'));
  return byFirst(out);
}
