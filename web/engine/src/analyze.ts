// OWNER: integrator (seeded by the engine foundation). The whole pipeline, in the browser:
//   reading     stream the .tar.gz, keep only the Baseband trace, info.txt, ambtool log and profile stubs
//   extracting  archive facts: press time, trace window, profile, guide state, problems
//   deframing   QDSS chunks -> DIAG log records (qdss/)
//   decoding    records -> call flow and ladder (signalling/)
//   radio       records -> PHY series (phy/), then the journey (journey/)
// Nothing is uploaded and nothing is written anywhere: the trace lives in this worker's memory only.
//
// The analysis always resolves (a file that is not a sysdiagnose gives a CaptureAnalysis whose problems say so);
// it rejects only with an AbortError when cancelled.

import { archiveFacts, type ArchiveFacts, notASysdiagnose, readSysdiagnose, unreadableFacts } from './archive/sysdiagnose.ts';
import { problem } from './archive/profile.ts';
import { abortError, ArchiveError } from './archive/stream.ts';
import { TimeBase } from './diag/timebase.ts';
import { buildJourney, type CaptureFacts, stepAnnotations } from './journey/build.ts';
import { uiCellDetails, uiConnections, uiEvent, uiProcedure, uiSteps } from './mapping.ts';
import { EMPTY_PHY_SUMMARY, extractPhy, type PhyCapture } from './phy/extract.ts';
import { type DeframeOutput, QdssDeframer } from './qdss/deframer.ts';
import { readFlow } from './signalling/callflow.ts';
import { EMPTY_FLOW, type Flow } from './signalling/flow.ts';
import { ladder } from './signalling/presentation.ts';
import { CONTRACT_VERSION, type CaptureAnalysis, type ImportProblem, type ImportProgress, type ImportStage } from './types.ts';

export interface AnalyzeOptions {
  fileName: string;
  /** The file's size, for the reading stage's progress. */
  totalBytes?: number;
  /** When the guide state is judged; defaults to now. */
  nowMs?: number;
  /** Stop reading the archive once everything needed has been read (default true). */
  earlyStop?: boolean;
}

export async function analyzeArchive(
  stream: ReadableStream<Uint8Array>,
  onProgress: (p: ImportProgress) => void,
  signal: AbortSignal | undefined,
  options: AnalyzeOptions,
): Promise<CaptureAnalysis> {
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
    return finished(emptyAnalysis(options.fileName, facts, timings), progress);
  }
  endStage('reading');

  // extracting
  const { parts } = read;
  if (notASysdiagnose(parts)) {
    // A readable tar of something else: say only that, not 'logging was off'.
    const other = unreadableFacts(new ArchiveError('notArchive', 'no logs/ tree'), nowMs);
    endStage('extracting');
    return finished(emptyAnalysis(options.fileName, other, timings), progress);
  }
  const facts = archiveFacts(parts, options.fileName, nowMs);
  progress('extracting', 1, `${parts.chunks.length} trace files`);
  endStage('extracting');
  if (!facts.hasTrace) return finished(emptyAnalysis(options.fileName, facts, timings), progress);

  const problems = facts.problems;
  // deframing
  const deframed = guard<DeframeOutput | null>(problems, 'deframing', null, () => {
    const deframer = new QdssDeframer();
    const n = parts.chunks.length;
    parts.chunks.forEach((chunk, i) => {
      deframer.feed(chunk.bytes);
      deframer.endChunk();
      chunk.bytes = new Uint8Array(0); // the trace is large: let each chunk go once it is fed
      if (i % 8 === 7 || i === n - 1) progress('deframing', (i + 1) / n, `${i + 1} of ${n} trace files`);
    });
    return deframer.finish();
  });
  endStage('deframing');
  const records = deframed?.records ?? [];
  const secure = deframed?.secure ?? { records: 0, codes: 0 };

  // decoding
  progress('decoding', 0, `${records.length.toLocaleString('en-US')} records`);
  const timeBase = TimeBase.of(records);
  const flow = guard<Flow>(problems, 'decoding', EMPTY_FLOW, () => readFlow(records, 0));
  const lad = guard(problems, 'decoding', ladder(EMPTY_FLOW), () => ladder(flow));
  progress('decoding', 1, `${flow.events.length} messages`);
  endStage('decoding');

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
    buildJourney(flow, phy.summary, captureFacts));
  const annotations = guard(problems, 'radio', new Map<number, string>(), () => stepAnnotations(flow, journey));
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
    events: flow.events.map(uiEvent),
    procedures: flow.procedures.map(uiProcedure),
    steps: uiSteps(flow, annotations),
    connections: uiConnections(flow),
    cellDetails: uiCellDetails(flow),
    ladder: lad,
    journey,
    phy: phy.series,
    phySummary: phy.summary,
    phyChecks: phy.checks,
    versionMisses: phy.versionMisses,
    availability: phy.availability,
  } satisfies Partial<CaptureAnalysis>);
  if (deframed) analysis.deframe = deframed.stats;
  const startUtcMs = timeBase.startUtcMs;
  if (startUtcMs !== null) analysis.startUtc = new Date(startUtcMs).toISOString();
  analysis.problems = problems.sort((a, b) => Number(b.blocking) - Number(a.blocking));
  return finished(analysis, progress);
}

/** A stage's result, or `fallback` plus an 'unsupportedTrace' problem when its decoder throws: one broken decoder
 *  must not hide what the others found. Cancellation is never swallowed. */
function guard<T>(problems: ImportProblem[], stage: ImportStage, fallback: T, run: () => T): T {
  try {
    return run();
  } catch (e) {
    if (e instanceof DOMException && e.name === 'AbortError') throw e;
    problems.push({ ...problem('unsupportedTrace', `Part of this trace could not be decoded (${stage}).`, false), detail: `${stage}: ${(e as Error)?.message ?? e}` });
    return fallback;
  }
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
