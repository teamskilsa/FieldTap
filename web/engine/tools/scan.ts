// Scans a sysdiagnose archive and prints its structure as counts only: no file names outside the trace directory
// (a sysdiagnose's other paths can name people, apps and places). Used to check the early-stop rule's premise
// (each directory's entries are contiguous) and where reading stops.
//
//   deno run -A tools/scan.ts ARCHIVE.tar.gz [--full]

import { classifyPath, SysdiagnoseCollector } from '../src/archive/sysdiagnose.ts';
import { readArchive } from '../src/archive/stream.ts';

type Group = 'qdss' | 'shared' | 'baseband' | 'other';

function groupOf(path: string): Group {
  if (/(^|\/)logs\/Baseband\/log-bb-[^/]*-qdss(\/|$)/.test(path)) return 'qdss';
  if (/(^|\/)logs\/MCState\/Shared(\/|$)/.test(path)) return 'shared';
  if (/(^|\/)logs\/Baseband(\/|$)/.test(path)) return 'baseband';
  return 'other';
}

export async function scan(path: string, full: boolean) {
  const file = await Deno.open(path);
  const size = (await Deno.stat(path)).size;
  const collector = new SysdiagnoseCollector();
  const runs: Record<Group, number> = { qdss: 0, shared: 0, baseband: 0, other: 0 };
  const lastOffset: Partial<Record<Group, number>> = {};
  const appleDouble: Record<Group, number> = { qdss: 0, shared: 0, baseband: 0, other: 0 };
  let previous: Group | null = null;
  let offset = 0, entries = 0, completeAt: { entry: number; offset: number } | null = null;
  const t0 = performance.now();
  const result = await readArchive(file.readable, {
    skipAppleDouble: false, // counted here, skipped by hand below
    onHeader: (h) => {
      entries++;
      const g = groupOf(h.path);
      if (g !== previous) runs[g]++;
      previous = g;
      const dot = h.path.split('/').pop()!.startsWith('._');
      if (dot) appleDouble[g]++;
      offset += 512 + Math.ceil(h.size / 512) * 512;
      lastOffset[g] = offset;
      // As readSysdiagnose: entries `select` skips still pass through wants() for the directory boundaries.
      if ((h.type !== '0' && h.type !== '7') || dot) collector.wants(h.path, 0);
    },
    select: (h) => !h.path.split('/').pop()!.startsWith('._') && collector.wants(h.path, h.size),
    onEntry: (e) => collector.add(e.path, e.bytes),
    shouldStop: () => {
      if (!completeAt && collector.complete()) completeAt = { entry: entries, offset };
      return !full && completeAt !== null;
    },
  });
  const parts = collector.parts();
  return {
    compressedBytes: size,
    compressedRead: result.compressedBytes,
    uncompressedRead: result.uncompressedBytes,
    stoppedEarly: result.stoppedEarly,
    seconds: +((performance.now() - t0) / 1000).toFixed(1),
    entries,
    appleDouble,
    runsPerGroup: runs,
    groupEndsAtUncompressed: lastOffset,
    completeAt,
    traceDir: parts.traceDir,
    traceDirs: parts.traceDirs.length,
    chunks: parts.chunks.length,
    firstChunk: parts.chunks[0]?.name,
    lastChunk: parts.chunks.at(-1)?.name,
    chunkBytes: parts.chunks.reduce((n, c) => n + c.bytes.length, 0),
    infoTxt: parts.infoTxt !== undefined,
    ambtool: parts.ambtool !== undefined,
    stubs: parts.stubs.length,
    kinds: [...new Set(parts.chunks.map((c) => classifyPath(`x/logs/Baseband/${parts.traceDir}/${c.name}`)?.kind))],
  };
}

if (import.meta.main) {
  const [path, flag] = Deno.args;
  console.log(JSON.stringify(await scan(path, flag === '--full'), null, 1));
}
