// The three real captures, read in place (never copied): archive-gated on $FT_ARCHIVES / $FT_FIXTURES.
// - first capture (profile on): 130 of 241 trace files, +19 to +46.844 s after the press; the chunks the reader
//   keeps are byte-identical to the deframer fixtures' inputs (md5 per chunk);
// - moving capture (profile on): 130 of 1,024 files, -4 to +18.506 s, 3 files missing inside the window;
// - profile off: only its extracted folder exists; it is read through the collector and through an in-memory
//   tar.gz of the same paths.
// Only counts, times and profile dates are asserted or printed.

import { archiveFacts, readSysdiagnose, SysdiagnoseCollector } from '../src/archive/sysdiagnose.ts';
import { archive, exists, fixture, gate, REAL } from '../tools/fixtures.ts';
import { readJson } from '../tools/golden.ts';
import { md5 } from '../tools/md5.ts';
import { assert, assertEquals } from './assert.ts';
import { buildTar, gzip, streamOf } from './support.ts';

const FIRST = archive(REAL.first);
const MOVING = archive(REAL.moving);
const OFF = archive(REAL.offFolder);
const PRESS_FIRST = Date.UTC(2026, 8, 21, 19, 41, 47);
const PRESS_MOVING = Date.UTC(2026, 8, 22, 12, 57, 25);
const PROFILE = {
  status: 'active',
  identifier: 'com.apple.basebandlogging',
  displayName: 'Baseband and Telephony Logging',
  installDate: '2026-09-21T19:40:06.000Z',
  removalDate: '2026-09-28T19:40:02.000Z',
};

async function read(path: string, earlyStop = true) {
  const file = await Deno.open(path);
  return readSysdiagnose(file.readable, { earlyStop, totalBytes: (await Deno.stat(path)).size });
}

// deno-lint-ignore no-explicit-any
const pick = (o: any, keys: string[]) => Object.fromEntries(keys.map((k) => [k, o[k]]));

Deno.test({
  name: 'first capture: early stop, 130 chunks 0x6F..0xF0 byte-identical to the fixtures, +19..+46.844 s, profile active',
  ignore: gate(FIRST, fixture('qdss-first3/manifest.json'), fixture('qdss-attach4/manifest.json')),
  fn: async () => {
    const { parts, stats } = await read(FIRST);
    assert(stats.stoppedEarly, 'stopped once the trace and MCState/Shared were read');
    assert(stats.uncompressedBytes < 0.35 * 929_382_400, `read ${stats.uncompressedBytes} of 929,382,400 tar bytes`);
    assertEquals(stats.format, 'gzip');
    assertEquals(parts.traceDir, 'log-bb-2026-09-21-15-42-33-844-qdss');
    assertEquals(parts.traceDirs.length, 1);
    assertEquals(parts.chunks.length, 130);
    assertEquals([parts.chunks[0].name, parts.chunks[129].name], ['0x0000006F.bin', '0x000000F0.bin']);
    assert(parts.chunks.every((c, i) => parseInt(c.name.slice(2), 16) === 0x6f + i), 'sorted by number, no gaps');
    assert(stats.appleDoubleSkipped >= 130, `${stats.appleDoubleSkipped} AppleDouble entries skipped`);
    assertEquals(parts.stubs.length, 2, 'the Baseband stub and one unrelated profile');

    // The kept chunks are exactly the deframer fixtures' inputs.
    for (const set of ['qdss-first3', 'qdss-attach4']) {
      // deno-lint-ignore no-explicit-any
      const manifest: any = await readJson(fixture(`${set}/manifest.json`));
      for (const [name, want] of Object.entries(manifest.inputs) as [string, { md5: string; bytes: number }][]) {
        if (!name.endsWith('.bin')) continue;
        const chunk = parts.chunks.find((c) => c.name === name);
        assert(chunk, `${name} kept`);
        assertEquals([chunk.bytes.length, md5(chunk.bytes)], [want.bytes, want.md5], `${set} ${name}`);
      }
    }

    const facts = archiveFacts(parts, REAL.first, PRESS_FIRST);
    assertEquals(facts.triggerTime, '2026-09-21T19:41:47.000Z');
    assertEquals(facts.traceWindow, {
      startUtc: '2026-09-21T19:42:06.000Z',
      endUtc: '2026-09-21T19:42:33.844Z',
      afterPressStartS: 19,
      afterPressEndS: 46.844,
      filesKept: 130,
      filesOnPhone: 241,
      filesOverwritten: 111,
      filesMissing: 0,
    });
    assertEquals(pick(facts.profile, Object.keys(PROFILE)), PROFILE);
    assertEquals(facts.profile.observedAt, '2026-09-21T19:41:47.000Z');
    assertEquals(facts.problems, []);
    assertEquals(pick(facts.guide, ['status', 'daysLeft', 'needsAttention']), { status: 'active', daysLeft: 6, needsAttention: false });
    // The same capture judged later: the guide moves on, the capture's own profile status does not.
    assertEquals(archiveFacts(parts, REAL.first, Date.UTC(2026, 8, 28, 12)).guide.status, 'expiringSoon');
    const later = archiveFacts(parts, REAL.first, Date.UTC(2026, 8, 29));
    assertEquals([later.guide.status, later.profile.status], ['expired', 'active']);
  },
});

Deno.test({
  name: 'first capture read to the end: the same parts, plus ambtool "Success"',
  ignore: gate(FIRST),
  fn: async () => {
    const { parts, stats } = await read(FIRST, false);
    assert(!stats.stoppedEarly);
    assertEquals(stats.compressedBytes, 408_450_455);
    assertEquals(stats.uncompressedBytes, 929_382_400);
    assertEquals(parts.chunks.length, 130);
    assertEquals(stats.appleDoubleSkipped, 1741);
    const facts = archiveFacts(parts, REAL.first, PRESS_FIRST);
    assertEquals(facts.loggingEnabled, true);
    assertEquals(facts.problems, []);
  },
});

Deno.test({
  name: 'moving capture: 130 of 1,024 files, -4..+18.506 s after the press, 3 missing inside the window',
  ignore: gate(MOVING),
  fn: async () => {
    const { parts, stats } = await read(MOVING);
    assert(stats.stoppedEarly);
    assertEquals(parts.traceDir, 'log-bb-2026-09-22-08-57-43-506-qdss');
    assertEquals(parts.chunks.length, 130);
    assertEquals([parts.chunks[0].name, parts.chunks[129].name], ['0x000061BE.bin', '0x00006242.bin']);
    const numbers = new Set(parts.chunks.map((c) => parseInt(c.name.slice(2), 16)));
    const missing = [];
    for (let n = 0x61be; n <= 0x6242; n++) if (!numbers.has(n)) missing.push(n.toString(16).toUpperCase());
    assertEquals(missing, ['61D6', '620B', '621F']);
    const facts = archiveFacts(parts, REAL.moving, PRESS_MOVING);
    assertEquals(facts.triggerTime, '2026-09-22T12:57:25.000Z');
    assertEquals(facts.traceWindow, {
      startUtc: '2026-09-22T12:57:21.000Z',
      endUtc: '2026-09-22T12:57:43.506Z',
      afterPressStartS: -4,
      afterPressEndS: 18.506,
      filesKept: 130,
      filesOnPhone: 1024,
      filesOverwritten: 891,
      filesMissing: 3,
    });
    assertEquals(pick(facts.profile, Object.keys(PROFILE)), PROFILE, 'the same profile, a day later');
    assertEquals(facts.problems.map((p) => [p.kind, p.blocking, p.detail]), [['traceGaps', false, '3']]);
    assertEquals(facts.guide.status, 'active');
  },
});

/** The files the profile-off folder holds under the paths the reader wants. */
function offFolderFiles(): { path: string; bytes: Uint8Array }[] {
  const out: { path: string; bytes: Uint8Array }[] = [];
  for (const dir of ['logs/Baseband', 'logs/MCState/Shared']) {
    for (const e of Deno.readDirSync(`${OFF}/${dir}`)) {
      if (!e.isFile) continue;
      if (dir === 'logs/MCState/Shared' && !/^profile-.*\.stub$/.test(e.name)) continue;
      out.push({ path: `${REAL.offFolder}/${dir}/${e.name}`, bytes: Deno.readFileSync(`${OFF}/${dir}/${e.name}`) });
    }
  }
  return out;
}

Deno.test({
  name: 'profile-off capture (extracted folder): logging off, no trace, no Baseband stub, guide "off"',
  ignore: gate(OFF),
  fn: async () => {
    assert(!exists(archive('sysdiagnose_2026.09.21_14-39-54-0400_iPhone-OS_iPhone_23F84.tar.gz')), 'the named archive is absent; the folder stands in');
    const files = offFolderFiles();
    const expectFacts = (facts: ReturnType<typeof archiveFacts>) => {
      assertEquals(facts.triggerTime, '2026-09-21T18:35:58.000Z');
      assertEquals(facts.traceWindow, null);
      assertEquals(facts.hasTrace, false);
      assertEquals(facts.loggingEnabled, false);
      assertEquals(facts.profile.status, 'missing');
      assertEquals(facts.problems.map((p) => [p.kind, p.blocking]), [['loggingNotEnabled', true], ['noBasebandTrace', true]]);
      assertEquals(pick(facts.guide, ['status', 'needsAttention']), { status: 'off', needsAttention: true });
    };
    // As a dropped folder: paths straight into the collector.
    const collector = new SysdiagnoseCollector();
    for (const f of files) if (collector.wants(f.path, f.bytes.length)) collector.add(f.path, f.bytes);
    const parts = collector.parts();
    assertEquals([parts.chunks.length, parts.stubs.length, parts.ambtool !== undefined], [0, 1, true]);
    expectFacts(archiveFacts(parts, `${REAL.offFolder}.tar.gz`, PRESS_FIRST));
    // As an archive: the same paths in an in-memory tar.gz (never written to disk).
    const gz = await gzip(buildTar(files.map((f) => ({ path: f.path, data: f.bytes }))));
    const read = await readSysdiagnose(streamOf(gz, [4096]));
    assertEquals(read.stats.stoppedEarly, false, 'no trace: read to the end for ambtool_output.log');
    expectFacts(archiveFacts(read.parts, 'renamed.tar.gz', PRESS_FIRST));
  },
});
