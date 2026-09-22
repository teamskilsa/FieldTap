// archive/plist.ts, archive/profile.ts and archive/info.ts: synthetic cases, then the real profile stub and the
// first capture's baseband metadata (fixture-gated, read in place). No identifier is printed: only the stub's
// PayloadIdentifier, display name and dates are asserted.

import { chunkNumber, dumpFromTraceDir, parseInfoTxt, pressFromName, toUtcMs, traceWindow } from '../src/archive/info.ts';
import { isDict, parseBinaryPlist, parsePlist, parseXmlPlist, PlistDate } from '../src/archive/plist.ts';
import { ambtoolLoggingEnabled, guideState, profileProblems, profileState, readProfileStub } from '../src/archive/profile.ts';
import type { ProfileState } from '../src/types.ts';
import { fixture, gate } from '../tools/fixtures.ts';
import { assert, assertAlmost, assertEquals, assertThrows } from './assert.ts';
import { buildBinaryPlist } from './support.ts';

const enc = new TextEncoder();
const INSTALL = Date.UTC(2026, 8, 21, 19, 40, 6);
const REMOVAL = Date.UTC(2026, 8, 28, 19, 40, 2);
const PRESS = Date.UTC(2026, 8, 21, 19, 41, 47);

const xmlStub = (identifier: string, extra = '') => `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- a comment -->
	<key>InstallDate</key>
	<date>2026-09-21T19:40:06Z</date>
	<key>PayloadContent</key>
	<array>
		<dict><key>Enable-Logging</key><true/><key>Level</key><integer>3</integer></dict>
		<array/>
	</array>
	<key>PayloadDisplayName</key>
	<string>Baseband &amp; Telephony Logging</string>
	<key>PayloadIdentifier</key>
	<string>${identifier}</string>
	<key>Empty</key>
	<string/>
	<key>Ratio</key>
	<real>6.99995</real>
	<key>Cert</key>
	<data>
	AAEC
	/w==
	</data>
	<key>RemovalDate</key>
	<date>2026-09-28T19:40:02Z</date>
	${extra}
</dict>
</plist>
`;

Deno.test('XML plist: dict, array, string entities, empty elements, integer, real, true, data, date, comments', () => {
  const v = parseXmlPlist(xmlStub('com.apple.basebandlogging'));
  assert(isDict(v));
  assertEquals(v.PayloadDisplayName, 'Baseband & Telephony Logging');
  assertEquals(v.Empty, '');
  assertEquals(v.Ratio, 6.99995);
  assertEquals([...(v.Cert as Uint8Array)], [0, 1, 2, 0xff]);
  assert(v.InstallDate instanceof PlistDate && v.InstallDate.ms === INSTALL);
  const content = v.PayloadContent as unknown[];
  assertEquals(content.length, 2);
  assertEquals((content[0] as Record<string, unknown>)['Enable-Logging'], true);
  assertEquals((content[0] as Record<string, unknown>).Level, 3);
  assertEquals(content[1], []);
  assertThrows(() => parseXmlPlist('<plist><dict><key>a</key></dict></plist>'));
  assertThrows(() => parseXmlPlist('<plist><dict><string>no key</string></dict></plist>'));
});

Deno.test('binary plist: the same record reads the same as its XML form', () => {
  const bin = buildBinaryPlist({
    InstallDate: { date: INSTALL },
    PayloadDisplayName: 'Baseband and Telephony Logging',
    PayloadIdentifier: 'com.apple.basebandlogging',
    RemovalDate: { date: REMOVAL },
    PayloadVersion: 1,
    Big: 70_000,
    Ratio: 6.99995,
    Flags: [true, false],
    Cert: new Uint8Array([0, 1, 2]),
    Unicode: 'Réglages',
    Long: 'x'.repeat(40),
  });
  const v = parsePlist(bin);
  assert(isDict(v));
  assertEquals(v.PayloadIdentifier, 'com.apple.basebandlogging');
  assert(v.RemovalDate instanceof PlistDate && v.RemovalDate.ms === REMOVAL);
  assertEquals([v.PayloadVersion, v.Big, v.Ratio, v.Flags, v.Unicode, v.Long], [1, 70_000, 6.99995, [true, false], 'Réglages', 'x'.repeat(40)]);
  assertEquals([...(v.Cert as Uint8Array)], [0, 1, 2]);
  assertEquals(readProfileStub(bin), readProfileStub(enc.encode(xmlStub('com.apple.basebandlogging').replace('&amp; ', 'and '))));
  assertThrows(() => parseBinaryPlist(bin.subarray(0, 30)));
  const bad = bin.slice();
  bad[bad.length - 9] = 0xff; // offset table beyond the file
  assertThrows(() => parseBinaryPlist(bad));
});

Deno.test('profileState: the Baseband stub among others, judged at the press', () => {
  const baseband = enc.encode(xmlStub('com.apple.basebandlogging'));
  const other = enc.encode(xmlStub('com.example.other'));
  const s = profileState([other, baseband], PRESS);
  assertEquals(s.status, 'active');
  assertEquals(s.identifier, 'com.apple.basebandlogging');
  assertEquals(s.installDate, '2026-09-21T19:40:06.000Z');
  assertEquals(s.removalDate, '2026-09-28T19:40:02.000Z');
  assertAlmost(s.lifetimeDays!, 6.99995, 1e-5);
  assertEquals(s.observedAt, '2026-09-21T19:41:47.000Z');
  assertEquals(profileState([baseband], REMOVAL - 3_600_000).status, 'expiringSoon');
  assertEquals(profileState([baseband], REMOVAL).status, 'expired');
  assertEquals(profileState([other], PRESS), { status: 'missing', observedAt: '2026-09-21T19:41:47.000Z' });
  assertEquals(profileState([], null), { status: 'missing' });
  assertEquals(profileState([enc.encode('not a plist')], PRESS).status, 'unknown', 'an unreadable stub might be the one');
});

Deno.test('ambtool_output.log: not enabled / success / unknown', () => {
  assertEquals(ambtoolLoggingEnabled('Baseband logs are not enabled\n'), false);
  assertEquals(ambtoolLoggingEnabled('Baseband log collection: Success (ABM running)\nPath = /private/var/...'), true);
  assertEquals(ambtoolLoggingEnabled('something else'), undefined);
  assertEquals(ambtoolLoggingEnabled(undefined), undefined);
});

Deno.test('guideState: off / expired / expiringSoon / active / installedNoTrace / unknown', () => {
  const active: ProfileState = { status: 'active', removalDate: new Date(REMOVAL).toISOString() };
  const g = (profile: ProfileState, nowMs: number, hasTrace = true, loggingEnabled: boolean | undefined = true, unreadable = false) =>
    guideState({ profile, hasTrace, loggingEnabled, unreadable }, nowMs);
  assertEquals(g({ status: 'missing' }, PRESS).status, 'off');
  assertEquals(g(active, PRESS), { status: 'active', removalDate: '2026-09-28T19:40:02.000Z', daysLeft: 6, needsAttention: false, evaluatedAt: '2026-09-21T19:41:47.000Z' });
  assertEquals(g(active, REMOVAL - 12 * 3_600_000).status, 'expiringSoon');
  assertEquals(g(active, REMOVAL - 12 * 3_600_000).needsAttention, true);
  assertEquals(g(active, REMOVAL - 12 * 3_600_000).daysLeft, 0);
  assertEquals(g(active, REMOVAL + 1).status, 'expired');
  assertEquals(g({ ...active, status: 'expired' }, PRESS).status, 'expired');
  assertEquals(g(active, PRESS, false).status, 'installedNoTrace');
  assertEquals(g(active, PRESS, true, false).status, 'installedNoTrace');
  assertEquals(g({ status: 'unknown' }, PRESS).status, 'unknown');
  assertEquals(g(active, PRESS, true, true, true).status, 'unknown');
});

Deno.test('profileProblems: logging off, no trace, expired, installed after the trace, gaps', () => {
  const kinds = (p: Parameters<typeof profileProblems>[0]) => profileProblems(p).map((x) => `${x.kind}${x.blocking ? '!' : ''}`);
  const base = { hasTrace: true, loggingEnabled: true, traceBeganMs: PRESS - 2000, filesMissing: 0, noInfoTxt: false };
  const active: ProfileState = { status: 'active', installDate: new Date(INSTALL).toISOString(), removalDate: new Date(REMOVAL).toISOString() };
  assertEquals(kinds({ ...base, profile: active }), []);
  assertEquals(kinds({ ...base, profile: { status: 'missing' }, hasTrace: false, loggingEnabled: false }), ['loggingNotEnabled!', 'noBasebandTrace!']);
  assertEquals(kinds({ ...base, profile: active, hasTrace: false }), ['profileInstalledNoTrace!']);
  assertEquals(kinds({ ...base, profile: { ...active, status: 'expired' }, hasTrace: false }), ['profileExpired!']);
  assertEquals(kinds({ ...base, profile: { ...active, status: 'expiringSoon' } }), ['profileExpiresSoon']);
  assertEquals(kinds({ ...base, profile: { status: 'missing' } }), ['profileMissing']);
  assertEquals(kinds({ ...base, profile: active, traceBeganMs: INSTALL - 60_000 }), ['profileInstalledAfterTrace']);
  assertEquals(kinds({ ...base, profile: active, filesMissing: 3 }), ['traceGaps']);
  assertEquals(profileProblems({ ...base, profile: active, filesMissing: 3 })[0].detail, '3');
  assertEquals(kinds({ ...base, profile: active, noInfoTxt: true }), ['unsupportedTrace']);
});

Deno.test('names: the press from an archive or directory name, the dump from a trace directory', () => {
  const press = pressFromName('sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84.tar.gz')!;
  assertEquals(press.offsetMin, -240);
  assertEquals(toUtcMs(press, null), PRESS);
  assertEquals(pressFromName('renamed.tar.gz'), null);
  assertEquals(toUtcMs(pressFromName('sysdiagnose_2026.01.02_03-04-05+0530_x')!, null), Date.UTC(2026, 0, 1, 21, 34, 5));
  const dump = dumpFromTraceDir('log-bb-2026-09-21-15-42-33-844-qdss')!;
  assertEquals(dump.offsetMin, null);
  assertEquals(toUtcMs(dump, press.offsetMin), Date.UTC(2026, 8, 21, 19, 42, 33, 844));
  assertEquals(chunkNumber('0x0000006F.bin'), 0x6f);
  assertEquals(chunkNumber('._0x0000006F.bin'), null);
});

const INFO = `GUID: 00000000-0000-0000-0000-000000000000
DiagID: 2
Ext: .bin
QSR: test-hash
File: 0x00000001.bin
Starting From: 2026-09-21-15-41-45
Size (Bytes): 1000
File: 0x00000002.bin
Starting From: 2026-09-21-15-41-50
Size (Bytes): 1000
File: 0x00000003.bin
Starting From: 2026-09-21-15-42-06
Size (Bytes): 1000
File: 0x00000004.bin
Starting From: 2026-09-21-15-42-20
Size (Bytes): 1000
File: 0x00000005.bin
Starting From: 2026-09-21-15-42-33
Size (Bytes): 500
Dropped (Bytes): 0
Max memory file count: 8
Applied memory file count: 8
Dump Reason: [abmtool] "bb log collection - for sysdiagnose"
`;

Deno.test('info.txt: files, times and counters are read; GUID, DiagID and QSR are not kept', () => {
  const info = parseInfoTxt(INFO);
  assertEquals(info.files.map((f) => [f.name, f.number, f.size]), [
    ['0x00000001.bin', 1, 1000], ['0x00000002.bin', 2, 1000], ['0x00000003.bin', 3, 1000], ['0x00000004.bin', 4, 1000], ['0x00000005.bin', 5, 500],
  ]);
  assertEquals(info.files[2].startWallMs, Date.UTC(2026, 8, 21, 15, 42, 6));
  assertEquals([info.maxMemoryFiles, info.droppedBytes], [8, 0]);
  assert(!JSON.stringify(info).includes('GUID') && !JSON.stringify(info).includes('00000000-0000'), 'no GUID kept');
  assert(!JSON.stringify(info).includes('test-hash'), 'no QSR kept');
});

Deno.test('traceWindow: relative to the press, with overwritten and missing files', () => {
  const info = parseInfoTxt(INFO);
  const press = pressFromName('sysdiagnose_2026.09.21_15-41-47-0400_x')!;
  const dump = dumpFromTraceDir('log-bb-2026-09-21-15-42-33-844-qdss');
  assertEquals(traceWindow(info, ['0x00000003.bin', '0x00000005.bin'], press, dump), {
    startUtc: '2026-09-21T19:42:06.000Z',
    endUtc: '2026-09-21T19:42:33.844Z',
    afterPressStartS: 19,
    afterPressEndS: 46.844,
    filesKept: 2,
    filesOnPhone: 5,
    filesOverwritten: 2,
    filesMissing: 1,
  });
  const noPress = traceWindow(info, ['0x00000003.bin'], null, null)!;
  assertEquals([noPress.afterPressStartS, noPress.startUtc], [null, '2026-09-21T15:42:06.000'], 'local time, no offset guessed');
  assertEquals(traceWindow(info, ['0x000000AA.bin'], press, dump), null);
});

const STUB_DIR = fixture('profile');
const META = fixture('baseband-meta');

Deno.test({
  name: 'real profile stub (fixture): com.apple.basebandlogging, 7.0 days, active at the first press; its binary form reads the same',
  ignore: gate(STUB_DIR),
  fn: async () => {
    const stubs = [...Deno.readDirSync(STUB_DIR)].filter((e) => e.name.endsWith('.stub'));
    assertEquals(stubs.length, 1);
    const path = `${STUB_DIR}/${stubs[0].name}`;
    const bytes = await Deno.readFile(path);
    const s = profileState([bytes], PRESS);
    assertEquals([s.status, s.identifier, s.displayName, s.installDate, s.removalDate], [
      'active', 'com.apple.basebandlogging', 'Baseband and Telephony Logging', '2026-09-21T19:40:06.000Z', '2026-09-28T19:40:02.000Z',
    ]);
    assertAlmost(s.lifetimeDays!, 6.99995, 1e-5);
    // macOS plutil writes the binary form to stdout: nothing touches the disk.
    const out = await new Deno.Command('plutil', { args: ['-convert', 'binary1', '-o', '-', path], stdout: 'piped', stderr: 'null' }).output();
    assert(out.success, 'plutil converted the stub');
    assertEquals(new TextDecoder().decode(out.stdout.subarray(0, 8)), 'bplist00');
    assertEquals(profileState([out.stdout], PRESS), s);
  },
});

Deno.test({
  name: 'baseband-meta (fixture): first capture keeps 0x6F..0xF0 of 241 files, +19 to +46.844 s after the press',
  ignore: gate(META),
  fn: async () => {
    const info = parseInfoTxt(await Deno.readTextFile(`${META}/info.txt`));
    const archiveName = (await Deno.readTextFile(`${META}/archive-name.txt`)).trim();
    const traceDir = (await Deno.readTextFile(`${META}/trace-dir-name.txt`)).trim();
    assertEquals(info.files.length, 241);
    assertEquals([info.files[0].number, info.files[240].number], [0x00, 0xf0]);
    const kept = Array.from({ length: 0xf0 - 0x6f + 1 }, (_, i) => `0x${(0x6f + i).toString(16).toUpperCase().padStart(8, '0')}.bin`);
    const w = traceWindow(info, kept, pressFromName(archiveName), dumpFromTraceDir(traceDir))!;
    assertEquals(w, {
      startUtc: '2026-09-21T19:42:06.000Z',
      endUtc: '2026-09-21T19:42:33.844Z',
      afterPressStartS: 19,
      afterPressEndS: 46.844,
      filesKept: 130,
      filesOnPhone: 241,
      filesOverwritten: 111,
      filesMissing: 0,
    });
    assertEquals(ambtoolLoggingEnabled(await Deno.readTextFile(`${META}/ambtool_output.log`)), true);
  },
});
