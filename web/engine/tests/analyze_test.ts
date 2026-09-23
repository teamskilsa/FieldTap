// analyze.ts, worker.ts and index.ts end to end. The decoders are still stubs, so these tests assert the archive
// facts and the CaptureAnalysis shape only: they keep passing as the qdss, signalling and phy-journey agents land.

import { analyzeArchive, measureTraceGaps } from '../src/analyze.ts';
import { analyzeFile, forgetCapture, revealIdentifiers } from '../src/index.ts';
import { type CaptureAnalysis, CONTRACT_VERSION, type ImportProblem, type ImportProgress } from '../src/types.ts';
import type { WorkerReply, WorkerRequest } from '../src/worker.ts';
import { captureSource, gateCapture, REAL } from '../tools/fixtures.ts';
import { assert, assertEquals, assertRejects } from './assert.ts';
import { buildTar, gzip, openCapture, streamOf, type TarSpec } from './support.ts';

const ROOT = 'sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84';
const QDSS = `${ROOT}/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss`;
const PRESS = Date.UTC(2026, 8, 21, 19, 41, 47);

const STUB = `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>InstallDate</key><date>2026-09-21T19:40:06Z</date>
<key>PayloadDisplayName</key><string>Baseband and Telephony Logging</string>
<key>PayloadIdentifier</key><string>com.apple.basebandlogging</string>
<key>RemovalDate</key><date>2026-09-28T19:40:02Z</date>
</dict></plist>`;

const INFO = ['0x00000001.bin', '0x00000002.bin', '0x00000003.bin']
  .map((f, i) =>
    `File: ${f}\nStarting From: 2026-09-21-15-42-${String(6 + 10 * i).padStart(2, '0')}\nSize (Bytes): 64\n`
  ).join('');

/** A synthetic sysdiagnose laid out like the real ones: trace first (chunks newest first), then MCState, then
 *  unrelated files, ambtool_output.log last. */
function syntheticSysdiagnose(extra: TarSpec[] = []): TarSpec[] {
  return [
    { path: `${QDSS}/info.txt`, data: `GUID: 1234\nDiagID: 2\n${INFO}Max memory file count: 8\n` },
    { path: `${QDSS}/0x00000003.bin`, data: new Uint8Array(64).fill(3) },
    { path: `${QDSS}/._0x00000003.bin`, data: 'appledouble' },
    { path: `${QDSS}/0x00000002.bin`, data: new Uint8Array(64).fill(2) },
    { path: `${QDSS}/0x00000001.bin`, data: new Uint8Array(64).fill(1) },
    { path: `${ROOT}/logs/Other/unrelated.log`, data: 'x'.repeat(5000) },
    { path: `${ROOT}/logs/MCState/Shared/profile-aa01.stub`, data: STUB },
    { path: `${ROOT}/logs/MCState/Shared/UserSettings.plist`, data: '<plist/>' },
    ...Array.from(
      { length: 30 },
      (_, i) => ({ path: `${ROOT}/logs/Other/f${i}.log`, data: new Uint8Array(20_000).fill(i) }),
    ),
    { path: `${ROOT}/logs/Baseband/ambtool_output.log`, data: 'Baseband log collection: Success (ABM running)\n' },
    ...extra,
  ];
}

/** Every value is plain, JSON-representable data: what postMessage and the UI expect. */
function assertPlainData(v: unknown, path = 'analysis'): void {
  if (v === null || typeof v === 'string' || typeof v === 'boolean') return;
  if (typeof v === 'number') return assert(Number.isFinite(v), `${path} is ${v}`);
  if (Array.isArray(v)) return v.forEach((x, i) => assertPlainData(x, `${path}[${i}]`));
  assert(
    typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype,
    `${path} is not a plain object (${typeof v})`,
  );
  for (const [k, x] of Object.entries(v as object)) {
    assert(x !== undefined, `${path}.${k} is undefined: leave it out instead`);
    assertPlainData(x, `${path}.${k}`);
  }
}

const REQUIRED: (keyof CaptureAnalysis)[] = [
  'contract',
  'fileName',
  'traceWindow',
  'profile',
  'guide',
  'problems',
  'records',
  'codes',
  'encryptedRecords',
  'encrypted',
  'crcErrors',
  'durationMs',
  'events',
  'procedures',
  'steps',
  'connections',
  'cellDetails',
  'ladder',
  'journey',
  'phy',
  'phySummary',
  'phyChecks',
  'versionMisses',
  'availability',
  'timings',
];

function assertShape(a: CaptureAnalysis): void {
  for (const k of REQUIRED) assert(k in a, `missing ${k}`);
  assertEquals(a.contract, CONTRACT_VERSION);
  assertEquals(Object.keys(a.ladder.rows).sort(), ['ALL', 'NAS', 'RRC']);
  assertPlainData(a);
  assertEquals(JSON.parse(JSON.stringify(a)), a, 'survives JSON');
}

async function run(bytes: Uint8Array, fileName: string, sizes = [8192], earlyStop = true) {
  const progress: ImportProgress[] = [];
  const a = await analyzeArchive(streamOf(bytes, sizes), (p) => progress.push(p), undefined, {
    fileName,
    totalBytes: bytes.length,
    nowMs: PRESS,
    earlyStop,
  });
  return { a, progress, stages: [...new Set(progress.map((p) => p.stage))] };
}

Deno.test('analyzeArchive: a synthetic sysdiagnose gives the archive facts, a complete shape, and staged progress', async () => {
  const gz = await gzip(buildTar(syntheticSysdiagnose()));
  const { a, progress, stages } = await run(gz, `${ROOT}.tar.gz`);
  assertShape(a);
  assertEquals(a.fileName, `${ROOT}.tar.gz`);
  assertEquals(a.triggerTime, '2026-09-21T19:41:47.000Z');
  assertEquals(a.traceWindow, {
    startUtc: '2026-09-21T19:42:06.000Z',
    endUtc: '2026-09-21T19:42:33.844Z',
    afterPressStartS: 19,
    afterPressEndS: 46.844,
    filesKept: 3,
    filesOnPhone: 3,
    filesOverwritten: 0,
    filesMissing: 0,
  });
  assertEquals([a.profile.status, a.profile.removalDate, a.guide.status], [
    'active',
    '2026-09-28T19:40:02.000Z',
    'active',
  ]);
  assertEquals(a.problems, []);
  assertEquals(stages, ['reading', 'extracting', 'deframing', 'decoding', 'radio', 'done']);
  assert(progress.every((p) => p.fraction >= 0 && p.fraction <= 1), 'fractions within 0..1');
  assertEquals(progress.at(-1), { stage: 'done', fraction: 1, detail: 'Done' });
  for (const s of ['reading', 'extracting', 'deframing', 'decoding', 'radio'] as const) {
    assert(typeof a.timings[s] === 'number', `timing ${s}`);
  }
});

Deno.test('analyzeArchive: unusable files resolve with a blocking problem, never a rejection', async () => {
  const notArchive = await run(new TextEncoder().encode('%PDF-1.7 '.repeat(100)), 'report.pdf');
  assertShape(notArchive.a);
  assertEquals(notArchive.a.problems.map((p) => [p.kind, p.blocking]), [['notASysdiagnose', true]]);
  assertEquals([notArchive.a.guide.status, notArchive.a.profile.status], ['unknown', 'unknown']);
  assertEquals(notArchive.stages, ['reading', 'done']);

  const gz = await gzip(buildTar(syntheticSysdiagnose()));
  // Cut short after the parts FieldTap needs: early stop never reaches the damage, and the analysis is whole.
  const half = gz.subarray(0, Math.floor(gz.length / 2));
  assertEquals((await run(half, `${ROOT}.tar.gz`, [100])).a.problems, []);
  // Read to the end, the same file is reported as truncated.
  const cut = await run(half, `${ROOT}.tar.gz`, [100], false);
  assertEquals(cut.a.problems.map((p) => [p.kind, p.blocking]), [['truncatedArchive', true]]);

  const otherTar = await gzip(buildTar([{ path: 'photos/IMG_0001.txt', data: 'not a sysdiagnose' }]));
  const other = await run(otherTar, 'photos.tar.gz');
  assertEquals(other.a.problems.map((p) => [p.kind, p.blocking]), [['notASysdiagnose', true]]);
  assertEquals(other.a.guide.status, 'unknown');

  const off = await gzip(
    buildTar([{ path: `${ROOT}/logs/Baseband/ambtool_output.log`, data: 'Baseband logs are not enabled\n' }]),
  );
  const offRun = await run(off, 'renamed.tar.gz');
  assertEquals(offRun.a.problems.map((p) => p.kind), ['loggingNotEnabled', 'noBasebandTrace']);
  assertEquals(
    [offRun.a.guide.status, offRun.a.triggerTime],
    ['off', '2026-09-21T19:41:47.000Z'],
    'press from the root directory',
  );
});

Deno.test('analyzeArchive: cancelling rejects with an AbortError', async () => {
  const gz = await gzip(buildTar(syntheticSysdiagnose()));
  const controller = new AbortController();
  await assertRejects(
    () =>
      analyzeArchive(streamOf(gz, [256]), () => controller.abort(), controller.signal, {
        fileName: 'x.tar.gz',
        totalBytes: gz.length,
      }),
    (e) => e instanceof DOMException && e.name === 'AbortError',
  );
});

Deno.test('worker.ts + index.ts: analyzeFile runs the analysis in a Web Worker and resolves with plain data', async () => {
  const gz = await gzip(buildTar(syntheticSysdiagnose()));
  const file = new File([new Uint8Array(gz)], `${ROOT}.tar.gz`, { type: 'application/gzip' });
  // Browsers clone the File into the worker; Deno cannot clone a Blob, so this test's worker is handed the same
  // bytes as an ArrayBuffer (the other form WorkerRequest accepts).
  const makeWorker = () => {
    const w = new Worker(new URL('../src/worker.ts', import.meta.url).href, { type: 'module' });
    const post = w.postMessage.bind(w);
    w.postMessage = (m: WorkerRequest) => post(m.type === 'analyze' ? { ...m, file: gz.slice().buffer } : m);
    return w;
  };
  const progress: ImportProgress[] = [];
  const a = await analyzeFile(file, (p) => progress.push(p), undefined, makeWorker);
  assertShape(a);
  assertEquals([a.profile.status, a.traceWindow?.filesKept], ['active', 3]);
  assertEquals(progress.at(-1)?.stage, 'done');

  // Cancel before it finishes: rejects with an AbortError and terminates the worker.
  const controller = new AbortController();
  const pending = analyzeFile(file, () => controller.abort(), controller.signal, makeWorker);
  await assertRejects(() => pending, (e) => e instanceof DOMException && e.name === 'AbortError');

  // The raw protocol (the Lovable mock worker's): progress messages, then one 'done'.
  const w = makeWorker();
  const replies: WorkerReply['type'][] = [];
  await new Promise<void>((resolve) => {
    w.onmessage = (e: MessageEvent<WorkerReply>) => {
      replies.push(e.data.type);
      if (e.data.type !== 'progress') resolve();
    };
    w.postMessage({ type: 'analyze', file: gz.slice().buffer, fileName: file.name } satisfies WorkerRequest);
  });
  // 'reveal' answers from the same worker; this archive's synthetic chunks hold no call flow, so there is none.
  const revealed = await new Promise<WorkerReply>((resolve) => {
    w.onmessage = (e: MessageEvent<WorkerReply>) => resolve(e.data);
    w.postMessage({ type: 'reveal' } satisfies WorkerRequest);
  });
  assertEquals(revealed, { type: 'revealed', signalling: null });
  w.postMessage({ type: 'forget' } satisfies WorkerRequest);
  w.terminate();
  assertEquals(replies.at(-1), 'done');
  assert(replies.slice(0, -1).every((r) => r === 'progress'));

  // The analysing worker is kept for revealIdentifiers, and forgetCapture ends it (Deno fails the test on a
  // worker left running).
  await analyzeFile(file, () => {}, undefined, makeWorker);
  assertEquals(await revealIdentifiers(), null);
  forgetCapture();
  assertEquals(await revealIdentifiers(), null, 'nothing kept after forgetCapture');
});

const FIRST = REAL.first;

Deno.test({
  name: 'analyzeArchive on the first real capture: the archive facts, early stop, a complete plain-data shape',
  ignore: gateCapture(FIRST),
  fn: async () => {
    const { stream, totalBytes } = openCapture(captureSource(FIRST)!);
    const progress: ImportProgress[] = [];
    const a = await analyzeArchive(stream, (p) => progress.push(p), undefined, {
      fileName: REAL.first,
      totalBytes,
      nowMs: PRESS,
    });
    assertShape(a);
    assertEquals(a.triggerTime, '2026-09-21T19:41:47.000Z');
    assertEquals([
      a.traceWindow?.afterPressStartS,
      a.traceWindow?.afterPressEndS,
      a.traceWindow?.filesKept,
      a.traceWindow?.filesOnPhone,
    ], [19, 46.844, 130, 241]);
    assertEquals([a.profile.status, a.guide.status, a.guide.daysLeft], ['active', 'active', 6]);
    assertEquals(a.problems.filter((p) => p.kind !== 'unsupportedTrace'), []);
    assert(a.events.every((e) => e.pduHex === undefined), 'masked by default: no PDU bytes');
    const reading = progress.filter((p) => p.stage === 'reading');
    assert(
      reading.at(-1)!.fraction < 0.5,
      `early stop: reading ended at ${(reading.at(-1)!.fraction * 100).toFixed(0)}% of the file`,
    );
  },
});

Deno.test("measureTraceGaps: the trace-gap warning reads in seconds, from the modem's own 1024 Hz clock", () => {
  const clock = {
    records: 1914,
    gaps: [{ tMs: 6327, missingMs: 221 }, { tMs: 10_222, missingMs: 2227 }, { tMs: 12_364, missingMs: 1127 }],
    missingMs: 3575,
    sequenceSteps: 1902,
    sequenceStepsExpected: 1913,
  };
  // The archive stage counted files; the clock replaces the count with seconds and says where the largest hole is.
  const fromFiles: ImportProblem[] = [{
    kind: 'traceGaps',
    message: '3 trace files are missing inside the kept window; messages around them may be incomplete.',
    blocking: false,
    detail: '3',
  }];
  measureTraceGaps(fromFiles, clock);
  assertEquals(fromFiles.length, 1);
  assertEquals(
    fromFiles[0].message,
    "3 trace files are missing inside the kept window: the modem's own 1024 Hz clock says 3.6 s of trace was never written, in 3 holes, the largest 2.2 s at 0:10.2. Messages around the holes may be incomplete.",
  );
  assertEquals(fromFiles[0].detail, '3 files, 3575 ms');

  // No files missing, but the clock still measures holes: the warning stands on the clock alone.
  const clockOnly: ImportProblem[] = [];
  measureTraceGaps(clockOnly, clock);
  assertEquals(clockOnly.map((p) => [p.kind, p.blocking, p.detail]), [['traceGaps', false, '0 files, 3575 ms']]);
  assert(clockOnly[0].message.startsWith('Part of the trace was not written: the modem'), clockOnly[0].message);

  // Under a second of missing trace is not worth a warning, and no clock means no claim.
  const quiet: ImportProblem[] = [];
  measureTraceGaps(quiet, { ...clock, gaps: [], missingMs: 120 });
  measureTraceGaps(quiet, undefined);
  assertEquals(quiet, []);
});
