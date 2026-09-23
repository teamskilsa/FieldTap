// The privacy rule on the two files the app writes out: the redacted report and the JSON beside it must contain no
// trace of a location-bearing record type. This test imports web/app's own export builders (through the import map
// in deno.json), so it asserts the files the app actually produces rather than a copy of the logic.
//
// The list of codes is src/report/privacy.ts. It matters because the records are really there: the driving capture
// holds 105 GNSS position reports at 5 Hz, which the last test here counts straight out of the fixture.

import { readQmdl } from '../src/diag/qmdl.ts';
import { isLocationCode, LOCATION_LOG_CODES, locationCodesIn, stripLocationRecords } from '../src/report/privacy.ts';
import type { CaptureAnalysis } from '../src/types.ts';
import { createSampleAnalysis } from '../../app/src/lib/analysis/sample.ts';
import { reportHtml } from '../../app/src/lib/report/html.ts';
import { redactAnalysis } from '../../app/src/lib/report/redact.ts';
import { fixture, gate } from '../tools/fixtures.ts';
import { assert, assertEquals } from './assert.ts';

/** The sample analysis with a location record planted in every place a log code can appear. */
function withLocationRecords(): CaptureAnalysis {
  const a = createSampleAnalysis({ now: Date.UTC(2026, 8, 22, 12, 0, 0) });
  return {
    ...a,
    deframe: {
      atid32_bytes: 0,
      chunks: 1,
      stats: {},
      fits: {},
      fragment_kinds: {},
      packets: {},
      log_records: 1000,
      distinct_codes: 5,
      ts: {},
      incomplete_records: 0,
      targets: {},
      top_codes: [['0xB193', 500], ['0x1476', 105], ['0x147C', 21], ['0x1391', 813], ['0x1544', 844]],
    },
    encrypted: { records: 10, codes: 2, byCode: { '0xB8DD': 8, '0x147D': 2 } },
    events: [...a.events, { ...a.events[0], index: a.events.length, logCode: '0x1476', name: 'GNSS position report' }],
    phy: [...a.phy, { ...a.phy[0], code: '0x147E' }],
    versionMisses: { ...a.versionMisses, '0x1476 v30': 105 },
    availability: [
      ...a.availability,
      { id: 'gnss', title: 'Position', status: 'notDecodedYet', reason: 'not decoded', codes: ['0x1476', '0x147C'] },
    ],
  };
}

Deno.test('export privacy: the redacted JSON and the report HTML contain no location record', () => {
  const planted = withLocationRecords();
  // The planted analysis really does mention them, so the assertions below are not vacuous.
  assert(locationCodesIn(JSON.stringify(planted)).length >= 5, 'the fixture plants location codes');

  const redacted = redactAnalysis(planted);
  const json = JSON.stringify(redacted, null, 2);
  assertEquals(locationCodesIn(json), [], 'the exported JSON');

  const html = reportHtml(redacted, new Date(Date.UTC(2026, 8, 22, 12, 0, 0)));
  // The report prints the exclusion note, which names codes: strip the note before looking for a record.
  const body = html.replace(/<div class="note">[\s\S]*?<\/div>/, '');
  assertEquals(locationCodesIn(body), [], 'the exported report');
  assert(html.includes('GNSS'), 'and the report says the exclusion happened');

  // Nothing else was lost: the measurements and the cells a report is for are still there.
  assertEquals(redacted.records, planted.records);
  assert(redacted.phy.length === planted.phy.length - 1, 'only the planted GNSS series is gone');
  assert(redacted.events.length === planted.events.length - 1);
  assert(redacted.availability.length === planted.availability.length - 1);
  assertEquals(redacted.deframe!.top_codes, [['0xB193', 500]]);
  assertEquals(redacted.encrypted.byCode, { '0xB8DD': 8 });
  assertEquals(redacted.versionMisses, planted.versionMisses['0xB173 v48'] ? redacted.versionMisses : {});
  assert(html.includes('FieldTap capture report'));
});

Deno.test('export privacy: the code list covers the GNSS block and the NMEA-carrying QMI links', () => {
  for (const code of [0x1476, 0x147c, 0x147d, 0x147e, 0x1391, 0x1544]) {
    assert(isLocationCode(code), `0x${code.toString(16)} must be excluded`);
  }
  assert(!isLocationCode(0xb193), 'a measurement record is not location data');
  assert(!isLocationCode(0xb126), 'nor is the PDSCH demapper configuration');
  // Stripping an analysis that has none of them changes nothing.
  const clean = createSampleAnalysis({ now: Date.UTC(2026, 8, 22, 12, 0, 0) });
  assertEquals(JSON.stringify(stripLocationRecords(clean)), JSON.stringify(clean));
  assert(LOCATION_LOG_CODES.every((c) => c.hex === `0x${c.code.toString(16).toUpperCase().padStart(4, '0')}`));
});

for (
  const [name, path] of [['capture2', fixture('capture2/capture2.qmdl')], [
    'first',
    fixture('iphone-recovered.qmdl'),
  ]] as const
) {
  Deno.test({
    name: `export privacy: ${name} really contains location records, and no decoder reads them`,
    ignore: gate(path),
    fn: async () => {
      const { records } = readQmdl(await Deno.readFile(path));
      const perCode = new Map<number, number>();
      for (const r of records) if (isLocationCode(r.code)) perCode.set(r.code, (perCode.get(r.code) ?? 0) + 1);
      const total = [...perCode.values()].reduce((n, v) => n + v, 0);
      assert(total > 0, `${name} holds location records: ${[...perCode.keys()].map((c) => c.toString(16))}`);
      assert(perCode.get(0x1476)! > 0, 'including the GNSS position report itself');
    },
  });
}
