// src/signalling/ against the contract fixtures (fixture-gated; read in place from $FT_FIXTURES, never copied).
//
// - Call flow: for iphone-recovered.qmdl, attach4 and both OnePlus captures, goldenDump(readFlow(...)) is the
//   fixture byte for byte (md5 as in CONTRACT.md's inventory) and equal under tools/golden.ts.
// - Presentation: the iPhone's presentation-golden.json byte for byte and structurally. The other three have no
//   presentation fixture; their md5s below are PresDump.kt's output from `ios/Contract/run-kotlin-golden.sh
//   ios/Contract/src-v1 ...` (2026-09-22; the same run reproduces both iPhone fixtures' md5s).
// - The UI mapping on the iPhone capture: masked by default it equals the golden's masking exactly and carries no
//   bytes, cell identity or identifier-shaped text; revealed it differs only where a masked form is given.
// Failures report paths, labels and counts only: never a decoded value.

import { readQmdl, recordsPerCode } from '../src/diag/qmdl.ts';
import { readFlow, readQmdlFlow } from '../src/signalling/callflow.ts';
import { goldenDump, presentationDump } from '../src/signalling/golden.ts';
import { shortCell } from '../src/signalling/presentation.ts';
import { uiSignalling } from '../src/signalling/ui.ts';
import type { Field } from '../src/types.ts';
import { fixture, gate } from '../tools/fixtures.ts';
import { jsonDiff, readJson } from '../tools/golden.ts';
import { parseJsonExact } from '../tools/json.ts';
import { md5 } from '../tools/md5.ts';
import { assert, assertEquals } from './assert.ts';

// deno-lint-ignore no-explicit-any
type Golden = any;

const enc = new TextEncoder();
const md5Of = (s: string) => md5(enc.encode(s));

const CASES = [
  {
    qmdl: 'iphone-recovered.qmdl',
    golden: 'contract/callflow-golden.json',
    file: 'iphone-recovered.qmdl',
    md5: '812920659751853fd251692c0d7b4e98',
    presentation: 'contract/presentation-golden.json',
    presentationMd5: '4562d3cf8b5c8dc12c7543c71c9d40b0',
  },
  {
    qmdl: 'qdss-attach4/expected/attach4.qmdl',
    golden: 'contract/callflow-attach4.json',
    file: 'attach4.qmdl',
    md5: '324b2571b5cea4bd37b91c4c9162bc41',
    presentation: null,
    presentationMd5: '9e07f8583c3f5d5edd23cbbce295bc56',
  },
  {
    qmdl: 'oneplus/oneplus-5g-registration.qmdl',
    golden: 'contract/oneplus-5g-registration.json',
    file: 'android/diag/src/test/resources/oneplus-5g-registration.qmdl',
    md5: 'abf8bed05c879913998ad318a4eadb83',
    presentation: null,
    presentationMd5: '63a75024d52297cb40f694cb0d237cb7',
  },
  {
    qmdl: 'oneplus/oneplus-callbox-service-request.qmdl',
    golden: 'contract/oneplus-callbox-service-request.json',
    file: 'android/diag/src/test/resources/oneplus-callbox-service-request.qmdl',
    md5: 'f7a9be3a01adf0701de6f198e0de9543',
    presentation: null,
    presentationMd5: 'ee6a6cde1f310d6f26e8f933d457c8fb',
  },
];

async function flowOf(qmdl: string) {
  const bytes = await Deno.readFile(fixture(qmdl));
  const read = readQmdl(bytes);
  return { bytes, read, flow: readFlow(read.records, read.crcErrors) };
}

for (const c of CASES) {
  const paths = [fixture(c.qmdl), fixture(c.golden), ...(c.presentation ? [fixture(c.presentation)] : [])];
  Deno.test({
    name: `${c.qmdl}: the call flow is ${c.golden} byte for byte; the presentation is PresDump's (md5 ${c.presentationMd5.slice(0, 8)})`,
    ignore: gate(...paths),
    fn: async () => {
      const { bytes, read, flow } = await flowOf(c.qmdl);
      const source = { file: c.file, bytes: bytes.length, hdlcFrames: read.frames, crcErrors: read.crcErrors, logRecords: read.records.length, badPackets: read.badPackets };
      const text = goldenDump(flow, source, recordsPerCode(read.records));
      const goldenText = await Deno.readTextFile(fixture(c.golden));
      assertEquals(md5Of(goldenText), c.md5, 'the fixture itself');
      assertEquals(jsonDiff(parseJsonExact(text), parseJsonExact(goldenText)), [], 'structurally equal');
      assertEquals(md5Of(text), c.md5, 'byte for byte');

      const pres = presentationDump(flow);
      if (c.presentation) {
        const presText = await Deno.readTextFile(fixture(c.presentation));
        assertEquals(jsonDiff(parseJsonExact(pres), parseJsonExact(presText)), [], 'presentation structurally equal');
      }
      assertEquals(md5Of(pres), c.presentationMd5, 'presentation byte for byte');

      // readQmdlFlow (CallFlow.read) is the same reading.
      assertEquals(md5Of(goldenDump(readQmdlFlow(bytes), source, recordsPerCode(read.records))), c.md5);
    },
  });
}

const IPHONE = [fixture('iphone-recovered.qmdl'), fixture('contract/callflow-golden.json'), fixture('contract/presentation-golden.json')];

Deno.test({
  name: 'iphone-recovered.qmdl: the contract counts, D3 (20/20 reconfigurations) and D4 (event 73 is "NR cell pending")',
  ignore: gate(...IPHONE),
  fn: async () => {
    const { flow } = await flowOf('iphone-recovered.qmdl');
    const count = (pred: (e: (typeof flow.events)[number]) => boolean) => flow.events.filter(pred).length;
    assertEquals([flow.events.length, count((e) => e.layer === 'RRC' && e.rat === 'lte'), count((e) => e.layer === 'RRC' && e.rat === 'nr'), count((e) => e.layer === 'NAS')], [128, 100, 4, 24]);
    assertEquals([flow.procedures.length, flow.procedures.filter((p) => p.outcome === 'SUCCEEDED').length], [34, 34]);
    assertEquals(flow.journey.map((s) => s.move), ['FIRST_SEEN', 'RESELECTION', 'HANDOVER', 'HANDOVER']);
    assertEquals(flow.connections.map((x) => x.outcome), ['RELEASED', 'OPEN_AT_END']);
    assertEquals([flow.cellDetails.length, flow.undecoded, flow.crcErrors, flow.failures], [3, 5, 0, 0]);
    const reconfigurations = flow.procedures.filter((p) => p.name === 'RRC reconfiguration');
    assertEquals([reconfigurations.length, reconfigurations.filter((p) => p.outcome === 'SUCCEEDED').length], [20, 20]);
    assertEquals(shortCell(flow.events[73].cell!), 'NR cell pending');
  },
});

/** Every string value in `v`, with its path. */
function strings(v: unknown, path: string, out: [string, string][]): [string, string][] {
  if (typeof v === 'string') out.push([path, v]);
  else if (Array.isArray(v)) v.forEach((x, i) => strings(x, `${path}[${i}]`, out));
  else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) strings(x, path ? `${path}.${k}` : k, out);
  return out;
}

const LEAKS: [RegExp, string][] = [
  [/\b\d{1,3}(\.\d{1,3}){3}\b/, 'IPv4'],
  [/\b([0-9a-f]{1,4}:){2,7}[0-9a-f:]{1,4}\b|::[0-9a-f]{1,4}/i, 'IPv6'],
  [/\+?\d[\d ]{8,}\d/, 'digit run'],
  [/0x[0-9a-f]{8,}/i, 'long hex'],
];

const plainFields = (fields: Field[]): unknown[] => fields.map((f) => ({ label: f.label, value: f.value, ...(f.children.length ? { children: plainFields(f.children) } : {}) }));

Deno.test({
  name: 'iphone-recovered.qmdl, UI mapping masked by default: the golden masking exactly, no bytes, no cell identity, no identifier-shaped text',
  ignore: gate(...IPHONE),
  fn: async () => {
    const { flow } = await flowOf('iphone-recovered.qmdl');
    const golden: Golden = await readJson(fixture('contract/callflow-golden.json'));
    const pres: Golden = await readJson(fixture('contract/presentation-golden.json'));
    const ui = uiSignalling(flow);

    assertEquals(ui.events.length, golden.events.length);
    ui.events.forEach((e, i) => {
      const g = golden.events[i];
      assertEquals(jsonDiff(plainFields(e.fields), g.fields, { tolerance: 0, ignore: [] }), [], `event ${i} fields`);
      assertEquals(e.summary ?? null, g.summary, `event ${i} summary`);
      assertEquals([e.key, e.name, e.channel, e.pduLength, e.logCode], [g.key, g.name, g.channel, g.pduLength, g.logCode], `event ${i}`);
      assert(e.pduHex === undefined, `event ${i} carries no bytes`);
    });
    ui.procedures.forEach((p, i) => {
      assertEquals([p.detail ?? null, p.refusal ?? null], [golden.procedures[i].detail, golden.procedures[i].refusal], `procedure ${i}`);
    });
    assert(ui.cellDetails.every((d) => d.cellIdentity === undefined), 'no cell identity');
    const leaks = strings(ui, '', []).flatMap(([path, s]) => LEAKS.filter(([re]) => re.test(s)).map(([, what]) => `${path}: ${what}`));
    assertEquals(leaks, [], 'no identifier-shaped text in any string');
    const flagged = ui.events.flatMap((e) => e.fields).filter(function any(f: Field): boolean {
      return f.masked !== undefined || f.children.some(any);
    });
    assert(flagged.length >= 5, `the golden's masked fields are flagged (${flagged.length})`);

    // The ladder is the presentation golden, field for field.
    for (const filter of ['ALL', 'RRC', 'NAS'] as const) {
      const rows = ui.ladder.rows[filter].map((r) => {
        switch (r.type) {
          case 'move': return { type: r.type, key: r.key, move: r.move, to: r.to, band: r.band ?? null, downlink: r.downlink ?? null };
          case 'procedure': return { type: r.type, key: r.key, name: r.name, outcome: r.outcome, duration: r.duration };
          case 'message': return { type: r.type, key: r.key, name: r.name, count: r.count, mixed: r.mixed, cells: r.cells, cellCount: r.cellCount, since: r.since, gap: r.gap ?? null };
        }
      });
      assertEquals(jsonDiff(rows, pres[`rows${filter}`], { tolerance: 0, ignore: [] }), [], `ladder ${filter}`);
    }
    assertEquals(ui.ladder.lanes, pres.lanes);
    assertEquals(ui.ladder.procedureGroups.map(({ procedures: _, median, ...g }) => ({ ...g, median: median ?? null })), pres.procedureGroups);
  },
});

Deno.test({
  name: 'iphone-recovered.qmdl, UI mapping with reveal: decoded values only where a masked form is given, and the bytes',
  ignore: gate(...IPHONE),
  fn: async () => {
    const { flow } = await flowOf('iphone-recovered.qmdl');
    const masked = uiSignalling(flow);
    const revealed = uiSignalling(flow, { reveal: true });
    let changed = 0;
    const walk = (m: Field[], r: Field[], where: string) =>
      m.forEach((f, k) => {
        assertEquals(f.value, r[k].masked ?? r[k].value, `${where} ${f.label}`);
        if (r[k].masked !== undefined && r[k].value !== r[k].masked) changed++;
        walk(f.children, r[k].children, where);
      });
    masked.events.forEach((e, i) => walk(e.fields, revealed.events[i].fields, `event ${i}`));
    assert(changed >= 5, `revealed values differ from their masked forms (${changed})`);
    // The masked test's scan is not vacuous: over the revealed fields it finds identifier-shaped text.
    const found = strings(revealed.events.map((e) => e.fields), '', []).filter(([, s]) => LEAKS.some(([re]) => re.test(s))).length;
    assert(found > 0, 'the leak scan finds the revealed identifiers');
    assert(revealed.events.every((e, i) => (e.pduHex?.length ?? 0) === 2 * flow.events[i].pdu.length), 'every PDU as hex');
    assert(revealed.cellDetails.every((d) => typeof d.cellIdentity === 'number'), 'cell identity when revealed');
    // Plain data for the worker boundary.
    assertEquals(structuredClone(masked), masked);
  },
});
