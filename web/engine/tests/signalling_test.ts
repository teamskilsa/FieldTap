// src/signalling/ on constructed records: the synthetic tests of android/diag CallFlowTest.kt (and the Swift
// port) at contract v1, including the D1, D3 and D4 deltas, plus the header layouts of D2, Java's number
// formatting, the ladder, and identifier masking in the UI mapping. Nothing here is capture-derived.

import { hexCode, type LogRecord } from '../src/diag/record.ts';
import { readFlow, readQmdlFlow } from '../src/signalling/callflow.ts';
import type { Cell, Flow, FlowEvent, FlowField } from '../src/signalling/flow.ts';
import { fixed, javaDouble } from '../src/signalling/javafmt.ts';
import { decodeLteRrc } from '../src/signalling/lterrc.ts';
import { IDENTITY_LABEL, maskField, MASKED, scrub } from '../src/signalling/mask.ts';
import { epsFields } from '../src/signalling/nasfields.ts';
import { decodeNrRrc } from '../src/signalling/nrrrc.ts';
import { cellsOf, downlinkMhz, duration, flowRows, hexDump, lanes, ladder, shortCell, sinceStart, band } from '../src/signalling/presentation.ts';
import { uiSignalling } from '../src/signalling/ui.ts';
import { assert, assertAlmost, assertEquals } from './assert.ts';
import { cat, Capture, framed, hex, stamped } from './signalling_support.ts';

const cell = (earfcn: number, pci: number, nr = false): Cell => ({ earfcn, pci, nr });
const a = cell(1575, 3);
const b = cell(2850, 2);
const c = cell(1300, 4);
const scg = cell(174_770, 80, true);

const moves = (f: Flow) => f.journey.map((s) => s.move);
const outcomes = (f: Flow) => f.connections.map((x) => x.outcome);
const byName = (f: Flow, name: string) => f.procedures.find((p) => p.name === name);
/** Each RRC reconfiguration procedure's RAT and outcome (Kotlin's Flow.reconfigurations()). */
const reconfigurations = (f: Flow) => f.procedures.filter((p) => p.name === 'RRC reconfiguration').map((p) => `${f.events[p.first].rat} ${p.outcome}`);

// MARK: - Mobility

Deno.test('a handover is the cell change after a handover command', () => {
  const r = new Capture();
  const flow = readFlow([...r.connected(a), r.handoverTo2(a), r.reconfigurationComplete(b), r.release(b)]);
  assertEquals(moves(flow), ['FIRST_SEEN', 'HANDOVER']);
  assertEquals(flow.journey.map((s) => s.to), [a, b]);
  assertEquals(flow.journey[1].from, a);
  assertEquals(flow.events[3].summary, 'handover to PCI 2, EARFCN 2850');
  const handover = byName(flow, 'Handover');
  assertEquals(handover?.outcome, 'SUCCEEDED');
  assertAlmost(handover!.durationMs, 20, 0.01);
});

Deno.test('a re-establishment on another cell fails the handover', () => {
  const r = new Capture();
  const flow = readFlow([...r.connected(a), r.handoverTo2(a), r.reestablishment(c)]);
  assertEquals(flow.journey.at(-1)?.move, 'REESTABLISHMENT');
  assertEquals(flow.journey.at(-1)?.to, c);
  assertEquals(byName(flow, 'Handover')?.outcome, 'FAILED');
  assertEquals(byName(flow, 'RRC re-establishment')?.outcome, 'UNANSWERED');
  assertEquals(flow.events.at(-1)?.summary, 'handoverFailure');
});

Deno.test('a cell change while idle is a reselection', () => {
  const r = new Capture();
  const flow = readFlow([...r.connected(a), r.release(a), r.sib1(a), r.sib1(b), r.request(b)]);
  assertEquals(moves(flow), ['FIRST_SEEN', 'RESELECTION']);
  assertEquals(flow.journey.at(-1)?.to, b);
  assertEquals(outcomes(flow), ['RELEASED', 'NO_ANSWER']);
  assertEquals(flow.procedures.at(-1)?.outcome, 'UNANSWERED');
});

Deno.test('system information read while searching is not where the phone was', () => {
  const x = cell(1450, 403), y = cell(5230, 417);
  const r = new Capture();
  const flow = readFlow([
    ...r.connected(a), r.release(a), r.sib1(x), r.sib1(y), r.sib1(b), r.sib1(x), r.request(b), r.request(b), ...r.connected(b),
  ]);
  assertEquals(moves(flow), ['FIRST_SEEN', 'RESELECTION']);
  assertEquals(flow.journey.map((s) => s.to), [a, b]);
  assertEquals(flow.searched, [x, y]);
  assertEquals(outcomes(flow), ['RELEASED', 'NO_ANSWER', 'NO_ANSWER', 'OPEN_AT_END']);
});

Deno.test('a new request with no release ends the connection as lost', () => {
  const r = new Capture();
  const flow = readFlow([...r.connected(a), r.reconfigurationComplete(a), r.request(a), r.setup(a), r.release(a)]);
  assertEquals(outcomes(flow), ['LOST', 'RELEASED']);
  assertEquals(flow.connections[0].last, 3);
  assertEquals(moves(flow), ['FIRST_SEEN']);
});

Deno.test('NAS sent after a reselection is on the new cell and starts the step', () => {
  // As logged: release on A, then the TAU request (NAS, uplink) before the RRC request on B, then the reject
  // (NAS, downlink) after the release on B.
  const r = new Capture();
  const flow = readFlow([
    ...r.connected(a), r.release(a),
    r.nas(0xb0ed, '0748010b'), r.request(b), r.setup(b), r.setupComplete(b), r.release(b), r.nas(0xb0ec, '074b09'),
  ]);
  const tau = flow.events.find((e) => e.key === 'Tracking area update request')!;
  assertEquals(tau.cell, b);
  assertEquals(flow.events.at(-1)?.cell, b);
  assertEquals(flow.journey.at(-1)?.event, tau.index);
  assertEquals(flow.journey.at(-1)?.move, 'RESELECTION');
  // The TAU request is cut short inside its GUTI: the fields read before it ran out, and no invented identity.
  assertEquals(tau.fields.map((f) => f.label), ['Update type', 'Active flag']);
});

Deno.test('a request on a new cell after a lost connection is a reselection', () => {
  const r = new Capture();
  assertEquals(moves(readFlow([...r.connected(a), r.reconfigurationComplete(a), r.request(c)])), ['FIRST_SEEN', 'RESELECTION']);
});

Deno.test('a cell change after a redirecting release is a redirect', () => {
  const r = new Capture();
  const flow = readFlow([...r.connected(a), r.releaseRedirect(a), r.request(c)]);
  assertEquals(moves(flow), ['FIRST_SEEN', 'REDIRECT']);
  assertEquals(flow.events[3].summary, 'other · redirect to EUTRA EARFCN 1300');
});

Deno.test('a connection already up when the capture started still counts', () => {
  const r = new Capture();
  const flow = readFlow([r.reconfigurationComplete(a), r.release(a)]);
  assertEquals(flow.connections.length, 1);
  assertEquals([flow.connections[0].outcome, flow.connections[0].first, flow.connections[0].establishmentCause], ['RELEASED', 0, null]);
});

// MARK: - Contract v1 deltas

Deno.test('D1: records before network time do not set the baseline', () => {
  // An iPhone trace opens with records stamped before the modem had network time, counted from 1980.
  const early: LogRecord = { code: 0xb193, timestampRaw: BigInt(Math.floor((1_000 * 4) / 5)) << 16n, body: new Uint8Array(4), more: 0 };
  const t0 = 1_474_054_925_000; // 2026-09-21 19:42:05 UTC, in GPS milliseconds
  const r = new Capture();
  const flow = readFlow([early, ...r.connected(a).map((rec, i) => stamped(t0 + 20 * i, rec))]);
  assertEquals(flow.records, 4);
  assertEquals(flow.startUtcMs, 1_790_019_725_000);
  assertAlmost(flow.durationMs, 40, 0.001);
  assertEquals(flow.events.map((e) => e.sinceStartMs), [0, 20, 40]);
  assertEquals(flow.events.map((e) => e.record), [2, 3, 4], 'record numbers count every record');
});

Deno.test('D1: without any plausible stamp the flow counts from the first non-zero one and has no wall clock', () => {
  const r = new Capture();
  const flow = readFlow([{ ...r.request(a), timestampRaw: 0n }, stamped(1_000, r.setup(a)), stamped(1_050, r.setupComplete(a))]);
  assertEquals(flow.startUtcMs, null);
  assertAlmost(flow.durationMs, 50, 0.001);
  assertEquals(flow.events.map((e) => e.sinceStartMs), [0, 0, 50], 'an unstamped record sits at 0');
});

Deno.test('D2: LTE RRC packet version 30 reads header layout E with PDU map D', () => {
  const m = decodeLteRrc(Capture.rrcV30(cell(66_786, 80), 11, cat(new Uint8Array([0x08]), new Uint8Array(1))))!;
  assertEquals([m.packetVersion, m.pci, m.earfcn, m.channel, m.asn1Name], [30, 80, 66_786, 'UL-DCCH', 'measurementReport']);
});

Deno.test('D2: NR RRC packet version 26 reads layout E, with PDU 11/12 = RRCReconfiguration(Complete)', () => {
  const m11 = decodeNrRrc(Capture.nrRrc(scg, 11, hex('0800')))!;
  const m12 = decodeNrRrc(Capture.nrRrc(scg, 12, hex('0000')))!;
  assertEquals([m11.packetVersion, m11.pci, m11.arfcn, m11.bearerId, m11.channel, m11.asn1Name], [26, 80, 174_770, 1, 'RRCReconfiguration', 'rrcReconfiguration']);
  assertEquals([m12.channel, m12.asn1Name], ['RRCReconfigurationComplete', 'rrcReconfigurationComplete']);
});

Deno.test('D3: an NR reconfiguration inside an LTE one is answered on its own RAT', () => {
  const r = new Capture();
  const flow = readFlow([...r.connected(a), r.reconfiguration(a), r.nrReconfiguration(scg), r.nrReconfigurationComplete(scg), r.reconfigurationComplete(a)]);
  assertEquals(reconfigurations(flow), ['lte SUCCEEDED', 'nr SUCCEEDED']);
  const lte = byName(flow, 'RRC reconfiguration')!;
  assertEquals([lte.first, lte.last], [3, 6]);
});

Deno.test('D3: a second start on the same RAT still means the first went unanswered', () => {
  const r = new Capture();
  const flow = readFlow([
    ...r.connected(a), r.reconfiguration(a), r.nrReconfiguration(scg), r.reconfiguration(a), r.nrReconfigurationComplete(scg), r.reconfigurationComplete(a),
  ]);
  assertEquals(reconfigurations(flow), ['lte UNANSWERED', 'nr SUCCEEDED', 'lte SUCCEEDED']);
});

Deno.test('D4: an NR header logged before the SCG cell is assigned is "NR cell pending", never a PCI', () => {
  assertEquals(shortCell(cell(0xffff_ffff, 0xffff, true)), 'NR cell pending');
  assertEquals(shortCell(cell(174_770, 0xffff, true)), 'NR cell pending');
  assertEquals(shortCell(cell(0xffff_ffff, 80, true)), 'NR cell pending');
  assertEquals(shortCell(cell(174_770, 80, true)), 'NR PCI 80');
  // An LTE cell is never "pending", whatever its numbers.
  assertEquals(shortCell(cell(0xffff_ffff, 0xffff)), 'EARFCN 4294967295 PCI 65535');
  // And through a flow: the pending NR reconfiguration's ladder row names no PCI.
  const r = new Capture();
  const flow = readFlow([...r.connected(a), r.reconfiguration(a), r.nrReconfiguration(cell(0xffff_ffff, 0xffff, true)), r.nrReconfigurationComplete(scg)]);
  const row = ladder(flow).rows.ALL.find((x) => x.type === 'message' && x.event === 4);
  assertEquals(row?.type === 'message' ? row.cells : null, 'NR cell pending');
  assertEquals(downlinkMhz(cell(0xffff_ffff, 0xffff, true)), null);
});

// MARK: - NAS

Deno.test('a reject fails its procedure and carries the cause', () => {
  // Attach request (a constructed IMSI), then Attach reject #15.
  const r = new Capture();
  const flow = readFlow([r.nas(0xb0ed, '07417208 09101000 00000000'), r.nas(0xb0ec, '07440f')]);
  assertEquals(flow.procedures.length, 1);
  const attach = flow.procedures[0];
  assertEquals([attach.name, attach.outcome, attach.refusal], ['Attach', 'FAILED', '#15 No suitable cells in tracking area']);
  const reject = flow.events.at(-1)!;
  assertEquals([reject.isFailure, reject.cause, reject.summary], [true, 15, '#15 No suitable cells in tracking area']);
  assertEquals(flow.failures, 1);
});

Deno.test('a protected copy with no plain twin stays as its own row', () => {
  const r = new Capture();
  const flow = readFlow([r.nas(0xb0eb, '27010203 04051122 3344')]);
  assertEquals(flow.events.length, 1);
  const row = flow.events[0];
  assertEquals([row.ciphered, row.name, row.protection], [true, 'Ciphered EMM message', { headerType: 2, mac: 0x0102_0304, sequence: 5 }]);
});

Deno.test('a protected copy that reads is named from inside, and a plain twin takes its protection', () => {
  const r = new Capture();
  const alone = readFlow([r.nas(0xb0ea, '27aabbccdd070746')]);
  assertEquals([alone.events.length, alone.events[0].name, alone.events[0].ciphered, alone.events[0].protection?.sequence], [1, 'Detach accept', false, 7]);
  const r2 = new Capture();
  const paired = readFlow([r2.nas(0xb0ea, '27aabbccdd070746'), r2.nas(0xb0ec, '0746')]);
  assertEquals(paired.events.length, 1, 'one row per message');
  assertEquals([paired.events[0].logCode, paired.events[0].protection?.mac], [0xb0ec, 0xaabbccdd]);
});

Deno.test('framed: the LTE attach reject from the reference handset is a failure with its cause', () => {
  const flow = readQmdlFlow(framed(0xb0ec, hex('01090500 074407')));
  assertEquals(flow.events.length, 1);
  const e = flow.events[0];
  assertEquals([e.name, e.channel, e.uplink, e.cause, e.causeName, e.summary], ['Attach reject', 'EMM', false, 7, 'EPS services not allowed', '#7 EPS services not allowed']);
});

Deno.test('framed: the 5G registration reject is read with its cause', () => {
  const flow = readQmdlFlow(framed(0xb80a, hex('010000000f04007e00441b16012c')));
  assertEquals(flow.events.length, 1);
  assertEquals([flow.events[0].name, flow.events[0].rat, flow.events[0].cause, flow.events[0].causeName], ['Registration reject', 'nr', 27, 'N1 mode not allowed']);
  assertEquals(flow.events[0].fields, [{ label: 'T3502', value: '12 min', children: [] }]);
});

Deno.test('framed: a record with no NAS in it is counted, not shown', () => {
  // What the SM8450 logs under 0xB80C on a callbox: a state struct (PLMN 001-01, then padding), not a PDU.
  const flow = readQmdlFlow(framed(0xb80c, hex('01000000 01020000 f110ffff ffffffff ffffffff ffff0100 0000')));
  assertEquals([flow.events.length, flow.undecoded], [0, 1]);
});

Deno.test('framed: a corrupt frame is counted and the rest still read; an empty capture is an empty flow', () => {
  const good = framed(0xb0ec, hex('01090500 074407'));
  const bad = good.slice();
  bad[1] = (bad[1] + 1) & 0xff;
  const flow = readQmdlFlow(cat(bad, good));
  assertEquals([flow.events.length, flow.crcErrors], [1, 1]);
  const empty = readQmdlFlow(new Uint8Array(0));
  assertEquals([empty.records, empty.events.length, empty.startUtcMs, empty.durationMs], [0, 0, null, 0]);
});

Deno.test('NAS fields: a message shorter than its definition keeps what was read before it ran out', () => {
  // Authentication request cut inside RAND: the key set only, never a RAND of zeros.
  assertEquals(epsFields('emm', 0, 0x52, hex('0752 00 0102030405'), false).map((f) => f.label), ['NAS key set']);
  // Uplink detach with switch-off, identity missing entirely.
  assertEquals(epsFields('emm', 0, 0x45, hex('0745 09'), true).map((f) => `${f.label}=${f.value}`), ['Detach type=EPS detach', 'Switch off=yes', 'NAS key set=0']);
});

// MARK: - Java's formatting (CONTRACT.md: the shortest round-trip decimal, rounded half up)

Deno.test("fixed() is Java's String.format('%.Nf'), not Number.toFixed", () => {
  assertEquals(fixed(0.125, 2), '0.13');
  assertEquals(fixed(2.675, 2), '2.68');
  assertEquals(fixed(1.005, 2), '1.01');
  assertEquals((2.675).toFixed(2), '2.67', 'the reason fixed() exists');
  assertEquals(fixed(-99_494.492, 3), '-99494.492');
  assertEquals(fixed(-0, 3), '-0.000');
  assertEquals(fixed(0.0005, 3), '0.001');
  assertEquals(fixed(0.00004, 3), '0.000');
  assertEquals(fixed(9.995, 2), '10.00');
  assertEquals(fixed(560.5, 0), '561');
  assertEquals(fixed(26_959.395, 3), '26959.395');
  assertEquals(fixed(1e21, 1), '1000000000000000000000.0');
  assertEquals([javaDouble(10), javaDouble(1.4), javaDouble(1e7)], ['10.0', '1.4', '1.0E7']);
});

Deno.test('ladder formats: since start, durations, cells, MHz and hex, as the Kotlin test pins them', () => {
  assertEquals([sinceStart(63.771), sinceStart(118_338.425), sinceStart(3_723_004.0), sinceStart(-5)], ['0:00.064', '1:58.338', '1:02:03.004', '0:00.000']);
  assertEquals([duration(0.4), duration(67.52), duration(312.0), duration(1_240.0), duration(123_400.0), duration(-1)], ['0.4 ms', '67.5 ms', '312 ms', '1.24 s', '2 min 3 s', '0.0 ms']);
  assertEquals([duration(12_345), duration(7_300_000)], ['12.3 s', '2 h 1 min']);
  assertEquals([shortCell(a), shortCell(b), downlinkMhz(a), shortCell(cell(99_999, 1))], ['B3 PCI 3', 'B7 PCI 2', '1842.5 MHz', 'EARFCN 99999 PCI 1']);
  const nr = cell(647_328, 417, true);
  assertEquals([band(nr), shortCell(nr), downlinkMhz(nr)], [null, 'NR PCI 417', '3709.9 MHz']);
  assertEquals(hexDump(new TextEncoder().encode('ims')), '0000  69 6d 73                 ims');
});

Deno.test('ladder rows: broadcast runs fold, banners and moves sit before their message, lanes follow the RATs', () => {
  const r = new Capture();
  const flow = readFlow([r.sib1(a), r.sib1(b), r.sib1(c), r.sib1(b), ...r.connected(b)]);
  const rows = flowRows(flow, 'ALL');
  assertEquals(rows.map((x) => x.key), ['event-0', 'procedure-0', 'event-4', 'event-5', 'event-6']);
  const folded = rows[0];
  assert(folded.kind === 'message');
  assertEquals([folded.repeats.length, cellsOf(folded)], [3, 'B3 PCI 3, B7 PCI 2 +1']);
  assertEquals(lanes(flow), { phone: 'UE', ran: 'eNB', core: 'MME' });
  const ui = ladder(flow);
  assertEquals(ui.rows.ALL[0], { type: 'message', key: 'event-0', event: 0, repeats: [1, 2, 3], name: 'SIB1', count: 4, mixed: true, cells: 'B3 PCI 3, B7 PCI 2 +1', cellCount: 3, since: '0:00.000' });
  assertEquals(ui.rows.NAS, []);
  assertEquals(ui.procedureGroups, [{ name: 'RRC connection setup', layer: 'RRC', n: 1, succeeded: 1, failed: 0, unanswered: 0, median: '40.0 ms', procedures: [0] }]);
  const both = readFlow([r.request(a), r.nrReconfiguration(scg)]);
  assertEquals(lanes(both), { phone: 'UE', ran: 'RAN', core: 'Core' });
});

// MARK: - Masking

Deno.test('golden masking: identity labels, their children, and scrubbed free text in the rule order', () => {
  for (const label of ['Identity', 'UE identity', 'Old GUTI', 'M-TMSI', 'PDN address', 'DNS server', 'P-CSCF', '5G-S-TMSI', 'I-RNTI', 'Cell identity', 'IPv4']) {
    assert(IDENTITY_LABEL.test(label), `${label} is an identity label`);
  }
  for (const label of ['Identity requested', 'Establishment cause', 'C-RNTI', 'PLMN', 'Tracking area', 'RAND', 'Ciphering']) {
    assert(!IDENTITY_LABEL.test(label), `${label} is not`);
  }
  const f: FlowField = {
    label: 'Identity',
    value: 'GUTI',
    children: [{ label: 'PLMN', value: '001-01', children: [] }, { label: 'M-TMSI', value: '0x12345678', children: [] }],
  };
  assertEquals(maskField(f), { label: 'Identity', value: 'GUTI', children: [{ label: 'PLMN', value: MASKED, children: [] }, { label: 'M-TMSI', value: MASKED, children: [] }] });
  assertEquals(scrub('ping 10.0.0.1 or 2001:db8::1, IMSI 001010123456789, TMSI 0xdeadbeef, PCI 80'), `ping ${MASKED} or ${MASKED}, IMSI ${MASKED}, TMSI ${MASKED}, PCI 80`);
  assertEquals(scrub('::1a2b'), MASKED);
  assertEquals(scrub('0x1234 and 123456789'), '0x1234 and 123456789', 'short hex and 9-digit runs stay');
});

/** Constructed events carrying every kind of identifier the masking rules cover. */
function unmaskedFlow(): Flow {
  const r = new Capture();
  const base = readFlow([r.nas(0xb0ed, '07417208 09101000 00000000'), ...r.connected(a)]);
  const e0 = base.events[0];
  const extra: FlowEvent = {
    ...e0,
    index: base.events.length,
    key: 'Activate default EPS bearer context request',
    summary: 'ims · 10.1.2.3',
    fields: [
      { label: 'APN', value: 'ims', children: [] },
      { label: 'PDN address', value: '10.1.2.3', children: [{ label: 'PDN type', value: 'IPv4v6', children: [] }, { label: 'IPv6 interface ID', value: '::2001:db8:0:1', children: [] }] },
      { label: 'P-CSCF', value: '2001:db8::5', children: [] },
      { label: 'Note', value: 'MSISDN +1 555 010 0000 and 0x0123456789', children: [] },
    ],
  };
  return {
    ...base,
    events: [...base.events, extra],
    procedures: [...base.procedures, { name: 'PDN connectivity', layer: 'NAS', detail: 'ims · 10.1.2.3', first: extra.index, last: extra.index, outcome: 'FAILED', durationMs: 0, refusal: 'rejected for 10.1.2.3' }],
    cellDetails: [{ cell: a, info: { pci: 3, downlinkEarfcn: 1575, uplinkEarfcn: 19_575, band: 3, plmn: '001-01', tac: 1, cellIdentity: 0x1a2b3c01, bandwidthMhz: 10 } }],
  };
}

const LEAKS: [RegExp, string][] = [
  [/\b\d{1,3}(\.\d{1,3}){3}\b/, 'IPv4'],
  [/\b([0-9a-f]{1,4}:){2,7}[0-9a-f:]{1,4}\b|::[0-9a-f]{1,4}/i, 'IPv6'],
  [/\+?\d[\d ]{8,}\d/, 'digit run'],
  [/0x[0-9a-f]{8,}/i, 'long hex'],
  [/001010123456789|0123456789/, 'the constructed IMSI'],
];

Deno.test('UI mapping, masked by default: no identifier, no bytes and no cell identity cross into the UI types', () => {
  const flow = unmaskedFlow();
  const ui = uiSignalling(flow);
  const text = JSON.stringify(ui);
  for (const [re, what] of LEAKS) assert(!re.test(text), `masked UI output holds no ${what}`);
  assert(!text.includes('pduHex') && !text.includes('cellIdentity'), 'no bytes, no cell identity');
  const imsi = ui.events[0].fields.find((f) => f.label === 'Identity')!;
  assertEquals([imsi.value, imsi.masked], [MASKED, MASKED], 'the value is masked and flagged');
  const extra = ui.events.at(-1)!;
  assertEquals([extra.summary, extra.summaryMasked], [`ims · ${MASKED}`, `ims · ${MASKED}`]);
  assertEquals(extra.fields[0], { label: 'APN', value: 'ims', children: [] }, 'nothing to mask: no flag');
  assertEquals(extra.fields[1].children.map((f) => f.value), [MASKED, MASKED], 'everything under an identity label');
  assertEquals(ui.procedures.at(-1)!.refusal, `rejected for ${MASKED}`);
  assertEquals(ui.cellDetails[0].tac, 1, 'TAC stays (golden rule); the UI hides it while masked');
});

Deno.test('UI mapping with reveal: the decoded values, the masked forms beside them, and the bytes', () => {
  const flow = unmaskedFlow();
  const ui = uiSignalling(flow, { reveal: true });
  const imsi = ui.events[0].fields.find((f) => f.label === 'Identity')!;
  assert(imsi.value.startsWith('IMSI ') && imsi.masked === MASKED, 'revealed value with its masked form');
  assertEquals(ui.events[0].pduHex, [...flow.events[0].pdu].map((x) => x.toString(16).padStart(2, '0')).join(''));
  assertEquals(ui.cellDetails[0].cellIdentity, 0x1a2b3c01);
  assertEquals(ui.events.at(-1)!.summary, 'ims · 10.1.2.3');
  assertEquals(ui.procedures.at(-1)!.refusalMasked, `rejected for ${MASKED}`);
  // Masked and revealed differ only where a masked form is given.
  const masked = uiSignalling(flow);
  masked.events.forEach((e, i) => {
    const walk = (m: typeof e.fields, v: typeof e.fields) =>
      m.forEach((f, k) => {
        assertEquals(f.value, v[k].masked ?? v[k].value, `event ${i} ${f.label}`);
        walk(f.children, v[k].children);
      });
    walk(e.fields, ui.events[i].fields);
  });
  assertEquals(ui.events.map((e) => e.logCode), flow.events.map((e) => hexCode(e.logCode)));
});
