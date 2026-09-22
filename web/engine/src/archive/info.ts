// The trace's timing facts: when the buttons were pressed (the archive's name), which trace files the modem
// wrote (logs/Baseband/log-bb-*-qdss/info.txt) and when it dumped them (the directory's name), so the import can
// say which part of the ring was kept: 'covers 0:19-0:46 after you pressed the buttons; 111 of 241 files
// overwritten'.
//
// Only names, times, sizes and counts are read. info.txt's GUID, DiagID and QSR lines and trace.info's hardware
// model and boot args identify the handset: they are never parsed into anything that is kept.

import type { TraceWindow } from '../types.ts';

/** A local wall-clock time read from a name or info.txt, and the UTC offset it was taken with. */
export interface WallTime {
  /** The wall-clock reading as if it were UTC (Date.UTC of its fields), in ms. */
  wallMs: number;
  /** Minutes east of UTC (-240 for -0400); null when the text carries no offset. */
  offsetMin: number | null;
}

/** iOS names the archive after the moment the buttons were pressed, in local time with its UTC offset. */
const ARCHIVE_NAME = /sysdiagnose_(\d{4})\.(\d{2})\.(\d{2})_(\d{2})-(\d{2})-(\d{2})([+-])(\d{2})(\d{2})/;
/** log-bb-2026-09-21-15-42-33-844-qdss: the dump, local time with milliseconds. */
const TRACE_DIR_TIME = /log-bb-(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})(?:-(\d{3}))?/;
const STARTING_FROM = /^(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})$/;

const wall = (y: string, mo: string, d: string, h: string, mi: string, s: string, ms = '0') =>
  Date.UTC(+y, +mo - 1, +d, +h, +mi, +s, +ms);

/** The press, from a sysdiagnose archive or top-level directory name; null for any other name. */
export function pressFromName(name: string): WallTime | null {
  const m = ARCHIVE_NAME.exec(name);
  if (!m) return null;
  const [, y, mo, d, h, mi, s, sign, oh, om] = m;
  return { wallMs: wall(y, mo, d, h, mi, s), offsetMin: (sign === '-' ? -1 : 1) * (+oh * 60 + +om) };
}

/** When the modem dumped the trace, from its directory's name (no offset: the phone's local time). */
export function dumpFromTraceDir(dir: string): WallTime | null {
  const m = TRACE_DIR_TIME.exec(dir);
  if (!m) return null;
  const [, y, mo, d, h, mi, s, ms] = m;
  return { wallMs: wall(y, mo, d, h, mi, s, ms ?? '0'), offsetMin: null };
}

/** UTC ms of a wall time, using `offsetMin` (the press's offset) when the time has none of its own. */
export function toUtcMs(t: WallTime, offsetMin: number | null): number | null {
  const off = t.offsetMin ?? offsetMin;
  return off === null ? null : t.wallMs - off * 60_000;
}

export interface TraceFile {
  /** '0x0000006F.bin'. */
  name: string;
  /** The file's number (0x6F), for ordering and gap counting. */
  number: number;
  /** 'Starting From', whole seconds, local time. */
  startWallMs: number;
  size: number;
}

export interface TraceInfo {
  /** Every file the modem wrote, in info.txt's order. */
  files: TraceFile[];
  maxMemoryFiles?: number;
  droppedBytes?: number;
  dumpReason?: string;
}

/** Parses info.txt's File / Starting From / Size blocks and the trailing counters; nothing else is kept. */
export function parseInfoTxt(text: string): TraceInfo {
  const info: TraceInfo = { files: [] };
  let file: Partial<TraceFile> | null = null;
  const flush = () => {
    if (file?.name !== undefined && file.startWallMs !== undefined) {
      info.files.push({ name: file.name, number: file.number!, startWallMs: file.startWallMs, size: file.size ?? 0 });
    }
    file = null;
  };
  for (const raw of text.split(/\r?\n/)) {
    const colon = raw.indexOf(':');
    if (colon < 0) continue;
    const key = raw.slice(0, colon).trim(), value = raw.slice(colon + 1).trim();
    switch (key) {
      case 'File': {
        flush();
        const number = chunkNumber(value);
        file = number === null ? null : { name: value, number };
        break;
      }
      case 'Starting From': {
        const m = STARTING_FROM.exec(value);
        if (file && m) file.startWallMs = wall(m[1], m[2], m[3], m[4], m[5], m[6]);
        break;
      }
      case 'Size (Bytes)':
        if (file) file.size = Number(value) || 0;
        break;
      case 'Max memory file count':
        info.maxMemoryFiles = Number(value);
        break;
      case 'Dropped (Bytes)':
        info.droppedBytes = Number(value);
        break;
      case 'Dump Reason':
        info.dumpReason = value;
        break;
    }
  }
  flush();
  return info;
}

/** 0x6F for '0x0000006F.bin'; null for anything that is not a trace chunk name. */
export function chunkNumber(name: string): number | null {
  const m = /^0x([0-9A-Fa-f]+)\.bin$/.exec(name);
  return m ? parseInt(m[1], 16) : null;
}

/**
 * The kept window. `kept` are the chunk names the archive holds; `press` the archive name's time; `dump` the
 * trace directory's. Wall times are compared directly (all are the phone's local time), and turned into UTC with
 * the press's offset. Null when info.txt lists none of the kept files.
 */
export function traceWindow(info: TraceInfo, kept: string[], press: WallTime | null, dump: WallTime | null): TraceWindow | null {
  const keptNumbers = new Set(kept.map(chunkNumber).filter((n): n is number => n !== null));
  const listed = info.files.filter((f) => keptNumbers.has(f.number)).sort((a, b) => a.number - b.number);
  if (listed.length === 0) return null;
  const first = listed[0], last = listed[listed.length - 1];
  const endWallMs = dump && dump.wallMs >= last.startWallMs ? dump.wallMs : last.startWallMs;
  const offset = press?.offsetMin ?? null;
  // UTC ('Z') when the press gave an offset; otherwise the local wall time with no offset, rather than a guess.
  const iso = (wallMs: number) => {
    const utc = toUtcMs({ wallMs, offsetMin: null }, offset);
    return utc === null ? new Date(wallMs).toISOString().slice(0, -1) : new Date(utc).toISOString();
  };
  // Every listed file is kept, overwritten (older than the window: the ring reused its space) or missing (newer,
  // but the collection dropped it: the moving capture lost 3 inside its window), so the three add up.
  const notKept = info.files.filter((f) => !keptNumbers.has(f.number));
  const overwritten = notKept.filter((f) => f.number < first.number).length;
  return {
    startUtc: iso(first.startWallMs),
    endUtc: iso(endWallMs),
    afterPressStartS: press ? (first.startWallMs - press.wallMs) / 1000 : null,
    afterPressEndS: press ? (endWallMs - press.wallMs) / 1000 : null,
    filesKept: keptNumbers.size,
    filesOnPhone: info.files.length,
    filesOverwritten: overwritten,
    filesMissing: notKept.length - overwritten,
  };
}
