// OWNER: integrator (seeded by the engine foundation). The whole pipeline, in the browser:
//   reading     stream the .tar.gz, keep only the Baseband trace, info.txt, ambtool log and profile stubs
//   extracting  archive facts: press time, trace window, profile, guide state, problems
//   deframing   QDSS chunks -> DIAG log records (qdss/)
//   decoding    records -> call flow and ladder (signalling/)
//   radio       records -> PHY series (phy/), then the journey (journey/)
// Nothing is uploaded and nothing is written anywhere: the trace lives in this worker's memory only.
//
// Memory: the archive reader keeps only the trace chunks (the tar is streamed), each chunk is released once it is
// fed to the deframer, and the records are dropped when the analysis is built. What outlives it is the call flow
// (a few hundred events, PDUs copied out of the record blocks) for revealIdentifiers.
//
// The analysis always resolves (a file that is not a sysdiagnose gives a CaptureAnalysis whose problems say so);
// it rejects only with an AbortError when cancelled.

import { chunkNumber } from './archive/info.ts';
import { archiveFacts, type ArchiveFacts, notASysdiagnose, readSysdiagnose, unreadableFacts } from './archive/sysdiagnose.ts';
import { problem } from './archive/profile.ts';
import { abortError, ArchiveError } from './archive/stream.ts';
import { TimeBase } from './diag/timebase.ts';
import { attributeCarriers, buildJourney, type CaptureFacts, stepAnnotations } from './journey/build.ts';
import { EMPTY_PHY_SUMMARY, extractPhy, type PhyCapture } from './phy/extract.ts';
import { type DeframeOutput, QdssDeframer } from './qdss/deframer.ts';
import { analyzeSecurity } from './security/report.ts';
import { readFlow } from './signalling/callflow.ts';
import { EMPTY_FLOW, type Flow } from './signalling/flow.ts';
import { scrub } from './signalling/mask.ts';
import { ladder } from './signalling/presentation.ts';
import { type UiSignalling, uiSignalling } from './signalling/ui.ts';
import { CONTRACT_VERSION, type CaptureAnalysis, type ImportProblem, type ImportProgress, type ImportStage, type TraceClock } from './types.ts';

export interface AnalyzeOptions {
  fileName: string;
  /** The file's size, for the reading stage's progress. */
  totalBytes?: number;
  /** When the guide state is judged; defaults to now. */
  nowMs?: number;
  /** Stop reading the archive once everything needed has been read (default true). */
  earlyStop?: boolean;
}

/** The analysis, masked, and a way to map its call flow again with identifiers revealed (null when there is none). */
export interface Analyzed {
  analysis: CaptureAnalysis;
  reveal: (() => UiSignalling) | null;
}

export async function analyzeArchive(
  stream: ReadableStream<Uint8Array>,
  onProgress: (p: ImportProgress) => void,
  signal: AbortSignal | undefined,
  options: AnalyzeOptions,
): Promise<CaptureAnalysis> {
  return (await analyzeCapture(stream, onProgress, signal, options)).analysis;
}

export async function analyzeCapture(
  stream: ReadableStream<Uint8Array>,
  onProgress: (p: ImportProgress) => void,
  signal: AbortSignal | undefined,
  options: AnalyzeOptions,
): Promise<Analyzed> {
  const nowMs = options.nowMs ?? Date.now();
  const timings: CaptureAnalysis['timings'] = {};
  let stageStart = performance.now();
  const progress = (stage: ImportStage, fraction: number, detail: string) => onProgress({ stage, fraction, detail });
  const endStage = (stage: ImportStage) => {
    const now = performance.now();
    timings[stage] = Math.round(now - stageStart);
    stageStart = now;
    if (signal?.aborted) throw abortError();
  };

  // reading
  progress('reading', 0, 'Opening the archive');
  let read: Awaited<ReturnType<typeof readSysdiagnose>>;
  try {
    read = await readSysdiagnose(stream, {
      totalBytes: options.totalBytes,
      onProgress: (f, d) => progress('reading', f, d),
      signal,
      earlyStop: options.earlyStop,
    });
  } catch (e) {
    const facts = unreadableFacts(e, nowMs); // rethrows an AbortError
    endStage('reading');
    return { analysis: finished(emptyAnalysis(options.fileName, facts, timings), progress), reveal: null };
  }
  endStage('reading');

  // extracting
  const { parts } = read;
  if (notASysdiagnose(parts)) {
    // A readable tar of something else: say only that, not 'logging was off'.
    const other = unreadableFacts(new ArchiveError('notArchive', 'no logs/ tree'), nowMs);
    endStage('extracting');
    return { analysis: finished(emptyAnalysis(options.fileName, other, timings), progress), reveal: null };
  }
  const facts = archiveFacts(parts, options.fileName, nowMs);
  progress('extracting', 1, `${parts.chunks.length} trace files`);
  endStage('extracting');
  if (!facts.hasTrace) return { analysis: finished(emptyAnalysis(options.fileName, facts, timings), progress), reveal: null };

  const problems = facts.problems;
  // deframing
  // Async between chunks so a worker sees 'cancel' (and the page its progress) while this runs.
  let deframed: DeframeOutput | null = null;
  try {
    const deframer = new QdssDeframer();
    const n = parts.chunks.length;
    let previous: number | null = null;
    for (let i = 0; i < n; i++) {
      const chunk = parts.chunks[i]!;
      // Chunk names are the segment number ('0x000061BE.bin'). A hole in the run means the collector left files
      // out, so the stream jumps there and layer 2 must re-find its phase (the moving capture misses 3 of 133).
      const sequence = chunkNumber(chunk.name);
      if (previous !== null && sequence !== null && sequence !== previous + 1) deframer.gap();
      previous = sequence;
      deframer.feed(chunk.bytes);
      deframer.endChunk();
      chunk.bytes = new Uint8Array(0); // the trace is large: let each chunk go once it is fed
      if (i % 8 === 7 || i === n - 1) {
        progress('deframing', (i + 1) / n, `${i + 1} of ${n} trace files`);
        await breathe(signal);
      }
    }
    deframed = deframer.finish();
  } catch (e) {
    guardFailed(problems, 'deframing', e);
  }
  endStage('deframing');
  const records = deframed?.records ?? [];
  const secure = deframed?.secure ?? { records: 0, codes: 0 };

  // decoding
  progress('decoding', 0, `${records.length.toLocaleString('en-US')} records`);
  const timeBase = TimeBase.of(records);
  const flow = guard<Flow>(problems, 'decoding', EMPTY_FLOW, () => readFlow(records, 0));
  progress('decoding', 1, `${flow.events.length} messages`);
  endStage('decoding');
  await breathe(signal);

  // radio
  progress('radio', 0, 'Radio measurements');
  const phy = guard<PhyCapture>(problems, 'radio', extractPhy([], timeBase, secure), () => extractPhy(records, timeBase, secure));
  const codes = deframed?.stats.distinct_codes ?? new Set(records.map((r) => r.code)).size;
  const captureFacts: CaptureFacts = {
    traceDurationMs: flow.durationMs,
    traceWindow: facts.traceWindow,
    records: records.length,
    codes,
    encrypted: secure,
    profile: facts.profile,
  };
  if (facts.triggerTime) captureFacts.triggerTime = facts.triggerTime;
  const mcc = flow.cellDetails[0]?.info.plmn.split('-')[0];
  if (mcc) captureFacts.mcc = mcc;
  const journey = guard(problems, 'radio', buildJourney(EMPTY_FLOW, EMPTY_PHY_SUMMARY, captureFacts), () =>
    buildJourney(flow, phy.summary, captureFacts, phy.series));
  const annotations = guard(problems, 'radio', new Map<number, string>(), () => stepAnnotations(flow, journey));
  const series = guard(problems, 'radio', phy.series, () => attributeCarriers(phy.series, journey));
  measureTraceGaps(problems, phy.summary.traceClock);
  // Masked: no identifier, PDU byte or cell identity leaves the worker unless the user asks (reveal below).
  const ui = guard<UiSignalling>(problems, 'decoding', uiSignalling(EMPTY_FLOW), () => uiSignalling(flow, { annotations }));
  progress('radio', 1, `${phy.series.length} radio series`);
  endStage('radio');

  const analysis = emptyAnalysis(options.fileName, facts, timings);
  Object.assign(analysis, {
    records: records.length,
    codes,
    encryptedRecords: secure.records,
    encrypted: secure,
    crcErrors: flow.crcErrors,
    durationMs: timeBase.durationMs,
    ...ui,
    journey,
    phy: series,
    phySummary: phy.summary,
    phyChecks: phy.checks,
    versionMisses: phy.versionMisses,
    availability: phy.availability,
  } satisfies Partial<CaptureAnalysis>);
  if (deframed) analysis.deframe = deframed.stats;
  // Local fake-base-station check over the assembled call flow, cells and PHY. No network, no storage; a bug here
  // must not sink the analysis, so it is guarded like every other decoder and simply leaves `security` unset.
  const security = guard<CaptureAnalysis['security']>(problems, 'radio', undefined, () => analyzeSecurity(analysis));
  if (security) analysis.security = security;
  const startUtcMs = timeBase.startUtcMs;
  if (startUtcMs !== null) analysis.startUtc = new Date(startUtcMs).toISOString();
  analysis.problems = problems.sort((a, b) => Number(b.blocking) - Number(a.blocking));
  // The PDUs are views into the deframer's record blocks: copy them so the blocks (the whole trace) can go.
  for (const e of flow.events) e.pdu = e.pdu.slice();
  return { analysis: finished(analysis, progress), reveal: flow.events.length ? revealer(flow, annotations) : null };
}

/**
 * The trace-gap warning, in seconds instead of file counts.
 *
 * The archive stage can only count the chunk files the collector left out. The modem's own 1024 Hz sleep clock
 * (0x1D0B, a 100 Hz record) says how much wall time actually went missing and where, so the warning reads "5.3 s of
 * trace was never written, the largest 2.2 s at 0:10.2" instead of "3 files are missing". When the files are all
 * there but the clock still shows holes, the warning stands on the clock's evidence alone.
 */
export function measureTraceGaps(problems: ImportProblem[], clock: TraceClock | undefined): void {
  if (!clock || clock.missingMs < 1000) return;
  const seconds = (ms: number) => `${(ms / 1000).toFixed(1)} s`;
  const at = (tMs: number) => {
    const total = Math.max(0, tMs) / 1000;
    return `${Math.floor(total / 60)}:${(total % 60).toFixed(1).padStart(4, '0')}`;
  };
  const largest = [...clock.gaps].sort((a, b) => b.missingMs - a.missingMs)[0];
  const holes = `${clock.gaps.length} ${clock.gaps.length === 1 ? 'hole' : 'holes'}`;
  const measured = `the modem's own 1024 Hz clock says ${seconds(clock.missingMs)} of trace was never written, in ${holes}` +
    (largest ? `, the largest ${seconds(largest.missingMs)} at ${at(largest.tMs)}` : '');
  const existing = problems.find((p) => p.kind === 'traceGaps');
  if (existing) {
    const n = existing.detail ?? '';
    const files = n ? `${n} trace ${n === '1' ? 'file is' : 'files are'} missing inside the kept window` : 'Trace files are missing';
    existing.message = `${files}: ${measured}. Messages around the holes may be incomplete.`;
    existing.detail = `${n || '?'} files, ${Math.round(clock.missingMs)} ms`;
    return;
  }
  problems.push({
    ...problem('traceGaps', `Part of the trace was not written: ${measured}. Messages around the holes may be incomplete.`, false),
    detail: `0 files, ${Math.round(clock.missingMs)} ms`,
  });
}

/** Built outside analyzeCapture on purpose: a closure there would share its scope and keep the records alive. */
function revealer(flow: Flow, annotations: ReadonlyMap<number, string>): () => UiSignalling {
  return () => uiSignalling(flow, { annotations, reveal: true });
}

/** Yield to the event loop (queued messages run), then honour cancellation. */
async function breathe(signal: AbortSignal | undefined): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
  if (signal?.aborted) throw abortError();
}

/** A stage's result, or `fallback` plus an 'unsupportedTrace' problem when its decoder throws: one broken decoder
 *  must not hide what the others found. Cancellation is never swallowed. */
function guard<T>(problems: ImportProblem[], stage: ImportStage, fallback: T, run: () => T): T {
  try {
    return run();
  } catch (e) {
    guardFailed(problems, stage, e);
    return fallback;
  }
}

function guardFailed(problems: ImportProblem[], stage: ImportStage, e: unknown): void {
  if (e instanceof DOMException && e.name === 'AbortError') throw e;
  // Decoder messages quote no capture bytes, but scrub anyway: the detail is shown and may be copied.
  const message = scrub(String((e as Error)?.message ?? e));
  problems.push({ ...problem('unsupportedTrace', `Part of this trace could not be decoded (${stage}).`, false), detail: `${stage}: ${message}` });
}

function finished(a: CaptureAnalysis, progress: (s: ImportStage, f: number, d: string) => void): CaptureAnalysis {
  progress('done', 1, a.problems.some((p) => p.blocking) ? 'No modem trace to show' : 'Done');
  return a;
}

/** A complete CaptureAnalysis with the archive's facts and nothing decoded. */
export function emptyAnalysis(fileName: string, facts: ArchiveFacts, timings: CaptureAnalysis['timings']): CaptureAnalysis {
  const a: CaptureAnalysis = {
    contract: CONTRACT_VERSION,
    fileName,
    traceWindow: facts.traceWindow,
    profile: facts.profile,
    guide: facts.guide,
    problems: facts.problems,
    records: 0,
    codes: 0,
    encryptedRecords: 0,
    encrypted: { records: 0, codes: 0 },
    crcErrors: 0,
    durationMs: 0,
    events: [],
    procedures: [],
    steps: [],
    connections: [],
    cellDetails: [],
    ladder: ladder(EMPTY_FLOW),
    journey: { durationMs: 0, states: [], registration: [], cells: [], markers: [], findings: [], tiles: [] },
    phy: [],
    phySummary: EMPTY_PHY_SUMMARY,
    phyChecks: [],
    versionMisses: {},
    availability: [],
    timings,
  };
  if (facts.triggerTime) a.triggerTime = facts.triggerTime;
  return a;
}
