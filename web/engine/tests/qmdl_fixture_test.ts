// diag/ against the contract fixtures (fixture-gated; read in place from $FT_FIXTURES):
// - iphone-recovered.qmdl reads as the golden's source block says (92,133 frames, 0 CRC errors) with the same
//   records per code, and re-encodes byte for byte (md5 e53a167b...), fed whole or in random pieces;
// - the D1 time base gives the golden's duration and start, and every golden event's sinceStartMs from its
//   17-digit timestampRaw;
// - the Python deframer's first3/attach4 logs and the OnePlus captures read and re-encode the same way.

import { readQmdl, QmdlReader, recordsPerCode, writeQmdl } from '../src/diag/qmdl.ts';
import type { LogRecord } from '../src/diag/record.ts';
import { TimeBase } from '../src/diag/timebase.ts';
import { fixture, gate } from '../tools/fixtures.ts';
import { readJson } from '../tools/golden.ts';
import { md5, Md5 } from '../tools/md5.ts';
import { assert, assertAlmost, assertEquals } from './assert.ts';
import { randomPieces } from './support.ts';

const QMDL = fixture('iphone-recovered.qmdl');
const GOLDEN = fixture('contract/callflow-golden.json');
const PHY_GOLDEN = fixture('contract/phy-golden-v1.json');

// deno-lint-ignore no-explicit-any
type Golden = any;

function reencodeMd5(records: LogRecord[]): string {
  const h = new Md5();
  writeQmdl(records, (f) => h.update(f));
  return h.hex();
}

Deno.test({
  name: 'iphone-recovered.qmdl: golden source counts, records per code, and a byte-exact re-encode',
  ignore: gate(QMDL, GOLDEN),
  fn: async () => {
    const bytes = await Deno.readFile(QMDL);
    assertEquals(md5(bytes), 'e53a167b29b25560938d1f089e719d33', 'the fixture itself');
    const golden: Golden = await readJson(GOLDEN);
    const read = readQmdl(bytes);
    assertEquals(
      { bytes: bytes.length, hdlcFrames: read.frames, crcErrors: read.crcErrors, logRecords: read.records.length, badPackets: read.badPackets },
      { bytes: golden.source.bytes, hdlcFrames: golden.source.hdlcFrames, crcErrors: golden.source.crcErrors, logRecords: golden.source.logRecords, badPackets: golden.source.badPackets },
    );
    assertEquals(read.frames, 92_133);
    assertEquals(read.crcErrors, 0);
    const perCode = recordsPerCode(read.records);
    assertEquals(perCode, golden.recordsPerCode);
    assertEquals(Object.keys(perCode).length, 224);
    assertEquals(reencodeMd5(read.records), 'e53a167b29b25560938d1f089e719d33');

    // The same file fed in random pieces reads identically.
    const reader = new QmdlReader();
    for (const piece of randomPieces(bytes, 7, 70_000)) reader.feed(piece);
    const split = reader.finish();
    assertEquals([split.frames, split.crcErrors, split.records.length], [92_133, 0, 92_133]);
    assertEquals(reencodeMd5(split.records), 'e53a167b29b25560938d1f089e719d33');
  },
});

Deno.test({
  name: 'D1 time base on iphone-recovered.qmdl: duration, start, and all 128 golden events since start',
  ignore: gate(QMDL, GOLDEN, PHY_GOLDEN),
  fn: async () => {
    const golden: Golden = await readJson(GOLDEN);
    const phy: Golden = await readJson(PHY_GOLDEN);
    const { records } = readQmdl(await Deno.readFile(QMDL));
    const tb = TimeBase.of(records);
    assertAlmost(tb.durationMs, golden.flow.durationMs, 0.0015, 'flow.durationMs');
    assertEquals(tb.startUtcMs, 1_790_019_725_984, '2026-09-21 19:42:05.984 UTC');
    assertEquals(golden.flow.startUtcKnown, true);
    assertAlmost(tb.unixStartS!, phy.timeBase.unixStart, 1e-6, 'phy-golden timeBase.unixStart');
    // The QDSS stats count 33 implausible and 5,139 zero stamps: D1 must skip them.
    let zero = 0, implausible = 0;
    for (const r of records) {
      if (r.timestampRaw === 0n) zero++;
      else if (TimeBase.of([r]).startUtcMs === null) implausible++;
    }
    assertEquals([zero, implausible], [5_139, 33]);
    assertEquals(golden.events.length, 128);
    for (const e of golden.events) {
      assert(typeof e.timestampRaw === 'bigint', 'the 17-digit stamp is parsed exactly');
      assertAlmost(tb.sinceStartMs(e.timestampRaw)!, e.sinceStartMs, 0.0015, `event ${e.index} sinceStartMs`);
      // The golden's record number points at this very record.
      assertEquals(records[e.record - 1].timestampRaw, e.timestampRaw, `event ${e.index} record ${e.record}`);
      assertEquals(records[e.record - 1].code, parseInt(e.logCode, 16), `event ${e.index} logCode`);
    }
  },
});

const REBUILT = [
  { qmdl: 'qdss-first3/expected/first3.qmdl', md5: '8bee416586647da91511a952c527c272', golden: null },
  { qmdl: 'qdss-attach4/expected/attach4.qmdl', md5: '245d59fc9af24e3acb5535966de6946d', golden: 'contract/callflow-attach4.json' },
  { qmdl: 'oneplus/oneplus-5g-registration.qmdl', md5: '58a2a3a667099e4bfe34b2fe75a1f87c', golden: 'contract/oneplus-5g-registration.json' },
  { qmdl: 'oneplus/oneplus-callbox-service-request.qmdl', md5: '29aeca6f065ce0cc5ee68ca4ea89aed7', golden: 'contract/oneplus-callbox-service-request.json' },
];

for (const c of REBUILT) {
  const paths = c.golden ? [fixture(c.qmdl), fixture(c.golden)] : [fixture(c.qmdl)];
  Deno.test({
    name: `${c.qmdl}: reads, re-encodes to md5 ${c.md5.slice(0, 8)}${c.golden ? ', and matches its golden' : ''}`,
    ignore: gate(...paths),
    fn: async () => {
      const bytes = await Deno.readFile(fixture(c.qmdl));
      assertEquals(md5(bytes), c.md5, 'the fixture itself');
      const read = readQmdl(bytes);
      assertEquals(read.crcErrors, 0);
      assertEquals(reencodeMd5(read.records), c.md5);
      if (!c.golden) return;
      const golden: Golden = await readJson(fixture(c.golden));
      assertEquals([read.frames, read.records.length, read.badPackets], [golden.source.hdlcFrames, golden.source.logRecords, golden.source.badPackets]);
      assertEquals(recordsPerCode(read.records), golden.recordsPerCode);
      // Including the OnePlus 5G registration's negative duration, which is what repo main produces.
      assertAlmost(TimeBase.of(read.records).durationMs, golden.flow.durationMs, 0.0015, 'flow.durationMs');
    },
  });
}
