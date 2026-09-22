// Reads what FieldTap needs from a sysdiagnose and nothing else:
//   <root>/logs/Baseband/log-bb-*-qdss/0x*.bin      the modem's QDSS trace chunks
//   <root>/logs/Baseband/log-bb-*-qdss/info.txt     which files the modem wrote, and when
//   <root>/logs/Baseband/ambtool_output.log         'Baseband logs are not enabled' when logging was off
//   <root>/logs/MCState/Shared/profile-*.stub       profile records; the Baseband one says when it expires
// Everything else in the 400+ MB archive (messages, locations, other logs) is skipped unread.
//
// The archive stores the chunks newest first (0xF0 down to 0x6F), so they are all kept, then handed on sorted by
// name, the order the deframer needs. Reading stops early once the trace directory and MCState/Shared have both
// been passed: on the moving capture that is 27% of the uncompressed bytes, because ambtool_output.log comes
// last (99.6%) and is only needed when there is no trace.

import type { GuideState, ImportProblem, ProfileState, TraceWindow } from '../types.ts';
import { dumpFromTraceDir, parseInfoTxt, pressFromName, type TraceInfo, toUtcMs, traceWindow, type WallTime } from './info.ts';
import { ambtoolLoggingEnabled, guideState, problem, profileProblems, profileState } from './profile.ts';
import { ArchiveError, type ArchiveFormat, readArchive } from './stream.ts';
import type { TarHeader } from './tar.ts';

const TRACE_DIR = /^log-bb-[^/]*-qdss$/;
const CHUNK_NAME = /^0x[0-9A-Fa-f]+\.bin$/;
const PROFILE_STUB = /^profile-[0-9A-Fa-f]+\.stub$/;
const MAX_SMALL_FILE = 1 << 20;

export type PartKind = 'chunk' | 'info' | 'ambtool' | 'stub';

export interface PathInfo {
  kind: PartKind;
  /** The log-bb-*-qdss directory, for trace files. */
  traceDir?: string;
  leaf: string;
}

/** Which part of a sysdiagnose a path is, or null for everything FieldTap ignores. */
export function classifyPath(path: string): PathInfo | null {
  const parts = path.split('/').filter((p) => p !== '' && p !== '.');
  const n = parts.length;
  if (n < 3) return null;
  const leaf = parts[n - 1];
  if (leaf.startsWith('._')) return null;
  if (n >= 4 && parts[n - 4] === 'logs' && parts[n - 3] === 'Baseband' && TRACE_DIR.test(parts[n - 2])) {
    if (CHUNK_NAME.test(leaf)) return { kind: 'chunk', traceDir: parts[n - 2], leaf };
    if (leaf === 'info.txt') return { kind: 'info', traceDir: parts[n - 2], leaf };
    return null;
  }
  if (parts[n - 3] === 'logs' && parts[n - 2] === 'Baseband' && leaf === 'ambtool_output.log') return { kind: 'ambtool', leaf };
  if (n >= 4 && parts[n - 4] === 'logs' && parts[n - 3] === 'MCState' && parts[n - 2] === 'Shared' && PROFILE_STUB.test(leaf)) {
    return { kind: 'stub', leaf };
  }
  return null;
}

export interface TraceChunk {
  name: string;
  bytes: Uint8Array;
}

/** What was taken from the archive. Bytes are the trace itself and hold identifiers: keep them in memory only. */
export interface SysdiagnoseParts {
  /** The archive's top-level directory ('sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84'). */
  rootName?: string;
  /** The newest log-bb-*-qdss directory (the one this sysdiagnose dumped), and every one seen. */
  traceDir?: string;
  traceDirs: string[];
  /** The newest trace directory's chunks, sorted by name: deframer order. */
  chunks: TraceChunk[];
  infoTxt?: string;
  ambtool?: string;
  stubs: Uint8Array[];
  /** Any path under logs/: tells a sysdiagnose from some other tar. */
  sawLogs: boolean;
}

/**
 * Collects the parts from a sequence of paths, whether they come from a tar or from a dropped folder. `wants` is
 * asked for every path in order (it also tracks the directory boundaries early stopping relies on); `add` takes
 * the bytes of each wanted one.
 */
export class SysdiagnoseCollector {
  private readonly chunksByDir = new Map<string, TraceChunk[]>();
  private readonly infoByDir = new Map<string, string>();
  private readonly stubs: Uint8Array[] = [];
  private ambtool?: string;
  private rootName?: string;
  private sawLogs = false;
  /** The trace directory being read, then passed; and whether MCState/Shared has been passed. */
  private currentTraceDir?: string;
  private passedTraceDir?: string;
  private inShared = false;
  private passedShared = false;
  private readonly decoder = new TextDecoder();

  wants(path: string, size: number): boolean {
    const top = path.split('/').find((p) => p !== '' && p !== '.');
    if (this.rootName === undefined && top && pressFromName(top)) this.rootName = top;
    if (path.includes('/logs/') || path.startsWith('logs/')) this.sawLogs = true;
    const info = classifyPath(path);
    // Directory boundaries: an entry outside a directory after entries inside it means it is complete. The
    // archive writes each directory's files together (checked on both real archives).
    const traceDir = info?.traceDir ?? traceDirOf(path);
    if (this.currentTraceDir !== undefined && traceDir !== this.currentTraceDir) {
      this.passedTraceDir = this.currentTraceDir;
      this.currentTraceDir = undefined;
    }
    if (traceDir !== undefined) this.currentTraceDir = traceDir;
    const shared = /(^|\/)logs\/MCState\/Shared\//.test(path);
    if (this.inShared && !shared) this.passedShared = true;
    this.inShared = shared;
    if (!info) return false;
    return info.kind === 'chunk' || size <= MAX_SMALL_FILE;
  }

  add(path: string, bytes: Uint8Array): void {
    const info = classifyPath(path);
    if (!info) return;
    switch (info.kind) {
      case 'chunk': {
        const list = this.chunksByDir.get(info.traceDir!) ?? [];
        list.push({ name: info.leaf, bytes });
        this.chunksByDir.set(info.traceDir!, list);
        break;
      }
      case 'info':
        this.infoByDir.set(info.traceDir!, this.decoder.decode(bytes));
        break;
      case 'ambtool':
        this.ambtool = this.decoder.decode(bytes);
        break;
      case 'stub':
        this.stubs.push(bytes);
        break;
    }
  }

  /**
   * True when reading further cannot change the result: the trace directory has been passed with its info.txt
   * and chunks, MCState/Shared has been passed, and the trace was dumped after the press (so it is this
   * sysdiagnose's, not an older one a later directory could replace).
   */
  complete(): boolean {
    const dir = this.passedTraceDir;
    if (!dir || !this.passedShared || !this.infoByDir.has(dir) || !this.chunksByDir.get(dir)?.length) return false;
    const press = this.rootName ? pressFromName(this.rootName) : null;
    const dump = dumpFromTraceDir(dir);
    return press !== null && dump !== null && dump.wallMs >= press.wallMs - 60_000;
  }

  parts(): SysdiagnoseParts {
    const dirs = [...new Set([...this.chunksByDir.keys(), ...this.infoByDir.keys()])].sort();
    const newest = dirs.length ? dirs[dirs.length - 1] : undefined;
    const chunks = (newest ? this.chunksByDir.get(newest) ?? [] : []).slice().sort((a, b) => byChunkName(a.name, b.name));
    return {
      rootName: this.rootName,
      traceDir: newest,
      traceDirs: dirs,
      chunks,
      infoTxt: newest ? this.infoByDir.get(newest) : undefined,
      ambtool: this.ambtool,
      stubs: this.stubs,
      sawLogs: this.sawLogs,
    };
  }
}

const leafOf = (path: string) => path.slice(path.lastIndexOf('/') + 1);

function traceDirOf(path: string): string | undefined {
  const m = /(?:^|\/)logs\/Baseband\/(log-bb-[^/]*-qdss)\//.exec(path);
  return m?.[1];
}

/** Chunk names sort by their number (names are zero-padded, but numbers never mislead). */
function byChunkName(a: string, b: string): number {
  return parseInt(a.slice(2), 16) - parseInt(b.slice(2), 16) || (a < b ? -1 : a > b ? 1 : 0);
}

export interface ReadStats {
  format: ArchiveFormat;
  compressedBytes: number;
  uncompressedBytes: number;
  stoppedEarly: boolean;
  entries: number;
  appleDoubleSkipped: number;
  selected: number;
  selectedBytes: number;
}

export interface ReadSysdiagnoseOptions {
  /** The file's size, for progress. */
  totalBytes?: number;
  onProgress?: (fraction: number, detail: string) => void;
  signal?: AbortSignal;
  /** Default true. */
  earlyStop?: boolean;
}

/** Streams a sysdiagnose .tar.gz (or .tar) and collects its parts. Throws ArchiveError or an AbortError. */
export async function readSysdiagnose(
  stream: ReadableStream<Uint8Array>,
  options: ReadSysdiagnoseOptions = {},
): Promise<{ parts: SysdiagnoseParts; stats: ReadStats }> {
  const collector = new SysdiagnoseCollector();
  const { totalBytes, onProgress } = options;
  let lastReport = 0;
  const result = await readArchive(stream, {
    select: (h: TarHeader) => collector.wants(h.path, h.size),
    onEntry: (e) => collector.add(e.path, e.bytes),
    // Boundaries are tracked in wants(). `select` is asked only for regular, non-AppleDouble files, so the
    // entries it never sees (directories, links, '._' leaves) pass through wants() here; it keeps none of them.
    onHeader: (h) => {
      if ((h.type !== '0' && h.type !== '7') || leafOf(h.path).startsWith('._')) collector.wants(h.path, 0);
    },
    shouldStop: options.earlyStop === false ? undefined : () => collector.complete(),
    onBytes: (read) => {
      if (!onProgress || !totalBytes) return;
      if (read - lastReport < 1 << 20 && read < totalBytes) return;
      lastReport = read;
      onProgress(Math.min(1, read / totalBytes), `${(read / 1e6).toFixed(0)} of ${(totalBytes / 1e6).toFixed(0)} MB`);
    },
    signal: options.signal,
  });
  return {
    parts: collector.parts(),
    stats: {
      format: result.format,
      compressedBytes: result.compressedBytes,
      uncompressedBytes: result.uncompressedBytes,
      stoppedEarly: result.stoppedEarly,
      entries: result.counts.entries,
      appleDoubleSkipped: result.counts.appleDoubleSkipped,
      selected: result.counts.selected,
      selectedBytes: result.counts.selectedBytes,
    },
  };
}

/** What the archive says about the capture before any decoding: the facts behind the import sheet and guide. */
export interface ArchiveFacts {
  /** ISO UTC of the button press. */
  triggerTime?: string;
  traceWindow: TraceWindow | null;
  profile: ProfileState;
  guide: GuideState;
  problems: ImportProblem[];
  loggingEnabled?: boolean;
  hasTrace: boolean;
  traceInfo?: TraceInfo;
}

/**
 * The facts, from the parts and the file's name. The press comes from the file name, or from the archive's
 * top-level directory when the file was renamed. `nowMs` is when the guide is judged (the analysis time).
 */
export function archiveFacts(parts: SysdiagnoseParts, fileName: string, nowMs: number): ArchiveFacts {
  const press: WallTime | null = pressFromName(fileName) ?? (parts.rootName ? pressFromName(parts.rootName) : null);
  const pressUtcMs = press ? toUtcMs(press, null) : null;
  const hasTrace = parts.chunks.length > 0;
  const loggingEnabled = ambtoolLoggingEnabled(parts.ambtool);
  const profile = profileState(parts.stubs, pressUtcMs);
  const traceInfo = parts.infoTxt === undefined ? undefined : parseInfoTxt(parts.infoTxt);
  const window = traceInfo && hasTrace
    ? traceWindow(traceInfo, parts.chunks.map((c) => c.name), press, parts.traceDir ? dumpFromTraceDir(parts.traceDir) : null)
    : null;
  const firstListed = traceInfo?.files.length ? Math.min(...traceInfo.files.map((f) => f.startWallMs)) : null;
  const traceBeganMs = firstListed === null || !press ? null : toUtcMs({ wallMs: firstListed, offsetMin: null }, press.offsetMin);
  const problems = profileProblems({
    profile,
    hasTrace,
    loggingEnabled,
    traceBeganMs,
    filesMissing: window?.filesMissing ?? 0,
    noInfoTxt: hasTrace && parts.infoTxt === undefined,
  });
  const guide = guideState({ profile, hasTrace, loggingEnabled, unreadable: false }, nowMs);
  const facts: ArchiveFacts = { traceWindow: window, profile, guide, problems, hasTrace };
  if (pressUtcMs !== null) facts.triggerTime = new Date(pressUtcMs).toISOString();
  if (loggingEnabled !== undefined) facts.loggingEnabled = loggingEnabled;
  if (traceInfo) facts.traceInfo = traceInfo;
  return facts;
}

/** The facts for a file that could not be read as a sysdiagnose at all. */
export function unreadableFacts(error: unknown, nowMs: number): ArchiveFacts {
  if (error instanceof DOMException && error.name === 'AbortError') throw error;
  const truncated = error instanceof ArchiveError && error.kind === 'truncated';
  const p = truncated
    ? problem('truncatedArchive', 'The file ends part way through: copy the sysdiagnose again and retry.', true)
    : problem('notASysdiagnose', 'This is not an iPhone sysdiagnose (.tar.gz).', true);
  if (!(error instanceof ArchiveError)) p.detail = String((error as Error)?.message ?? error);
  const profile: ProfileState = { status: 'unknown' };
  return {
    traceWindow: null,
    profile,
    guide: guideState({ profile, hasTrace: false, loggingEnabled: undefined, unreadable: true }, nowMs),
    problems: [p],
    hasTrace: false,
  };
}

/** A tar that is readable but holds no sysdiagnose logs/ tree. */
export function notASysdiagnose(parts: SysdiagnoseParts): boolean {
  return !parts.sawLogs;
}

