// A real sysdiagnose through src/archive and the deframer, timed. Used by qdss_archive_test.ts, and runnable for
// the performance notes (peak memory: run it under /usr/bin/time -l):
//
//   deno run -A tests/qdss_capture.ts first|moving|PATH [--stats-only]
//
// Prints counts, codes, record versions and md5s only: never a record body or anything read from one beyond
// its version field.

import { readSysdiagnose } from '../src/archive/sysdiagnose.ts';
import { writeQmdl } from '../src/diag/qmdl.ts';
import { hexCode, type LogRecord } from '../src/diag/record.ts';
import { type DeframeOutput, type DeframerOptions, QdssDeframer } from '../src/qdss/deframer.ts';
import { archive, REAL } from '../tools/fixtures.ts';
import { Md5 } from '../tools/md5.ts';

export interface CaptureRun {
  output: DeframeOutput;
  chunks: number;
  readMs: number;
  deframeMs: number;
  /** Largest RSS and heap seen at the sample points (after reading, after each 16 chunks, after finish). */
  sampledRssMb: number;
  sampledHeapMb: number;
}

const mb = (n: number) => Math.round(n / 1e5) / 10;

export async function deframeArchive(path: string, options: DeframerOptions = {}): Promise<CaptureRun> {
  let rss = 0, heap = 0;
  const sample = () => {
    const m = Deno.memoryUsage();
    rss = Math.max(rss, m.rss);
    heap = Math.max(heap, m.heapUsed);
  };
  const t0 = performance.now();
  const file = await Deno.open(path);
  const { parts } = await readSysdiagnose(file.readable, { totalBytes: (await Deno.stat(path)).size });
  const t1 = performance.now();
  sample();
  // As analyze.ts feeds it: whole chunks in name order, each let go once fed.
  const deframer = new QdssDeframer(options);
  parts.chunks.forEach((chunk, i) => {
    deframer.feed(chunk.bytes);
    deframer.endChunk();
    chunk.bytes = new Uint8Array(0);
    if (i % 16 === 15) sample();
  });
  const output = deframer.finish();
  const t2 = performance.now();
  sample();
  return { output, chunks: parts.chunks.length, readMs: t1 - t0, deframeMs: t2 - t1, sampledRssMb: mb(rss), sampledHeapMb: mb(heap) };
}

export function qmdlMd5(records: LogRecord[]): string {
  const h = new Md5();
  writeQmdl(records, (f) => h.update(f));
  return h.hex();
}

/** Packet versions per code, the way the PHY inventory reads them: NR-style codes (0xB800..0xB9FF) as u16
 *  major.minor from body[2:4] and body[0:2], the rest as the first body byte. */
export function versions(records: LogRecord[], code: number): Record<string, number> {
  const out: Record<string, number> = {};
  for (const r of records) {
    if (r.code !== code) continue;
    const b = r.body;
    let v: string;
    if (code >= 0xb800 && code <= 0xb9ff) {
      if (b.length < 4) continue;
      v = `${b[2] | (b[3] << 8)}.${b[0] | (b[1] << 8)}`;
    } else {
      if (b.length < 1) continue;
      v = String(b[0]);
    }
    out[v] = (out[v] ?? 0) + 1;
  }
  return out;
}

if (import.meta.main) {
  const which = Deno.args[0] ?? 'first';
  const path = which === 'first' ? archive(REAL.first) : which === 'moving' ? archive(REAL.moving) : which;
  const run = await deframeArchive(path);
  const { stats, secure } = run.output;
  const report: Record<string, unknown> = {
    chunks: run.chunks,
    readMs: Math.round(run.readMs),
    deframeMs: Math.round(run.deframeMs),
    sampledRssMb: run.sampledRssMb,
    sampledHeapMb: run.sampledHeapMb,
    records: stats.log_records,
    codes: stats.distinct_codes,
    secure: { records: secure.records, codes: secure.codes },
    qmdlMd5: qmdlMd5(run.output.records),
    versions: Object.fromEntries([0xb0c0, 0xb821].map((c) => [hexCode(c), versions(run.output.records, c)])),
    bytesPerAtid: run.output.bytesPerAtid,
  };
  if (!Deno.args.includes('--stats-only')) report.stats = stats;
  console.log(JSON.stringify(report, null, 1));
}
