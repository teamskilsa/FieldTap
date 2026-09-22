// tools/: the golden comparator follows json_equal.py rule for rule, big integers stay exact, MD5 matches RFC 1321.

import { DEFAULT_TOLERANCE, jsonDiff, readJson } from '../tools/golden.ts';
import { parseJsonExact } from '../tools/json.ts';
import { md5, Md5 } from '../tools/md5.ts';
import { fixture, gate } from '../tools/fixtures.ts';
import { assert, assertEquals, assertThrows } from './assert.ts';

Deno.test('parseJsonExact keeps 17-digit integers exact and everything else as JSON.parse does', () => {
  const text = '{"ts":77282930941493954,"n":-12,"f":26959.395,"e":1e3,"s":"a\\"b\\u00e9","l":[true,false,null],"o":{}}';
  const v = parseJsonExact(text) as Record<string, unknown>;
  assertEquals(v.ts, 77282930941493954n);
  assert(BigInt(JSON.parse(text).ts) !== 77282930941493954n, 'JSON.parse would have rounded it');
  assertEquals([v.n, v.f, v.e, v.s, v.l, v.o], [-12, 26959.395, 1000, 'a"bé', [true, false, null], {}]);
  assertThrows(() => parseJsonExact('{"a":1,}'));
  assertThrows(() => parseJsonExact('[1] x'));
});

Deno.test('jsonDiff: json_equal.py rules (tolerance, bool vs number, key sets, lengths, ignore at every position)', () => {
  assertEquals(DEFAULT_TOLERANCE, 0.0015);
  assertEquals(jsonDiff({ a: 1.0004, b: 2 }, { a: 1.0010, b: 2 }), []);
  assertEquals(jsonDiff({ a: 1.0 }, { a: 1.002 }), ['a']);
  assertEquals(jsonDiff({ a: true }, { a: 1 }), ['a'], 'a boolean never equals a number');
  assertEquals(jsonDiff({ a: null }, { a: 0 }), ['a']);
  assertEquals(jsonDiff({ a: 'x' }, { a: 'x ' }), ['a']);
  assertEquals(jsonDiff({ b: 1, a: 1 }, { a: 1, c: 1 }), ['b', 'c'], 'sorted keys, missing on either side');
  assertEquals(jsonDiff({ l: [1, 2, 3] }, { l: [1, 5] }), ['l.length', 'l[1]']);
  const golden = { source: { file: 'x.qmdl', bytes: 3 }, events: [{ cell: { pci: 1 }, i: 0 }, { cell: null, i: 1 }] };
  const ours = { source: { file: 'y.qmdl', bytes: 3 }, events: [{ cell: { pci: 2 }, i: 0 }, { cell: { pci: 3 }, i: 1 }] };
  assertEquals(jsonDiff(ours, golden), ['events[0].cell.pci', 'events[1].cell'], 'source.file is ignored by default');
  assertEquals(jsonDiff(ours, golden, { ignore: ['source.file', 'events.cell'] }), []);
  assertEquals(jsonDiff(ours, golden, { ignore: [] }), ['events[0].cell.pci', 'events[1].cell', 'source.file']);
  // Big integers: exact against each other and against integers, whatever the tolerance.
  assertEquals(jsonDiff({ t: 77282930941493954n }, { t: 77282930941493955n }), ['t']);
  assertEquals(jsonDiff({ t: 77282930941493954n }, { t: 77282930941493954n }), []);
  assertEquals(jsonDiff({ t: 5n }, { t: 5 }), []);
  assertEquals(jsonDiff({ t: 5n }, { t: 5.001 }), []);
  assertEquals(jsonDiff({ t: 5n }, { t: 6 }), ['t']);
});

Deno.test('md5: RFC 1321 test vectors, incremental in any split', () => {
  const enc = new TextEncoder();
  const vectors: [string, string][] = [
    ['', 'd41d8cd98f00b204e9800998ecf8427e'],
    ['a', '0cc175b9c0f1b6a831c399e269772661'],
    ['abc', '900150983cd24fb0d6963f7d28e17f72'],
    ['message digest', 'f96b697d7cb7938d525a2f31aaf161d0'],
    ['abcdefghijklmnopqrstuvwxyz', 'c3fcd3d76192e4007dfb496cca67e13b'],
    ['12345678901234567890123456789012345678901234567890123456789012345678901234567890', '57edf4a22be3c955ac49da2e2107b67a'],
  ];
  for (const [s, h] of vectors) assertEquals(md5(enc.encode(s)), h, JSON.stringify(s));
  const long = new Uint8Array(100_003).map((_, i) => (i * 7) % 251);
  const whole = md5(long);
  const h = new Md5();
  for (let at = 0; at < long.length; at += 97) h.update(long.subarray(at, at + 97));
  assertEquals(h.hex(), whole);
});

Deno.test({
  name: 'jsonDiff: every contract golden equals itself exactly, and a one-unit timestamp change is caught',
  ignore: gate(fixture('contract/callflow-golden.json')),
  fn: async () => {
    for (const f of ['callflow-golden', 'presentation-golden', 'callflow-attach4', 'oneplus-5g-registration', 'oneplus-callbox-service-request', 'phy-golden-v1', 'phy-summary-v1', 'journey-expected']) {
      const a = await readJson(fixture(`contract/${f}.json`));
      const b = await readJson(fixture(`contract/${f}.json`));
      assertEquals(jsonDiff(a, b), [], f);
    }
    // deno-lint-ignore no-explicit-any
    const g: any = await readJson(fixture('contract/callflow-golden.json'));
    // deno-lint-ignore no-explicit-any
    const h: any = await readJson(fixture('contract/callflow-golden.json'));
    h.events[7].timestampRaw += 1n;
    h.events[3].sinceStartMs += 0.001;
    assertEquals(jsonDiff(h, g), ['events[7].timestampRaw']);
  },
});
