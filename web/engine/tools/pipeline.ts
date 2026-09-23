// The whole engine on one archive, as the worker runs it: prints stage timings, counts and peak memory only (no
// identifier, cell or time from the capture). Run under `/usr/bin/time -l` for the process's peak RSS.
//
//   deno run -A tools/pipeline.ts ARCHIVE.tar.gz [--full]     (--full: read the whole archive, no early stop)

import { analyzeCapture } from '../src/analyze.ts';

const [path, ...flags] = Deno.args;
if (!path) {
  console.error('usage: deno run -A tools/pipeline.ts ARCHIVE.tar.gz [--full]');
  Deno.exit(2);
}
const name = path.split('/').pop()!;
let peakRss = 0;
const sample = () => (peakRss = Math.max(peakRss, Deno.memoryUsage().rss));
const timer = setInterval(sample, 20);
const t0 = performance.now();
const file = await Deno.open(path);
const { analysis: a, reveal } = await analyzeCapture(file.readable, sample, undefined, {
  fileName: name,
  totalBytes: (await Deno.stat(path)).size,
  earlyStop: !flags.includes('--full'),
});
const totalMs = Math.round(performance.now() - t0);
sample();
clearInterval(timer);
console.log(JSON.stringify({
  totalMs,
  timings: a.timings,
  peakRssMB: Math.round(peakRss / 1e6),
  records: a.records,
  codes: a.codes,
  events: a.events.length,
  procedures: a.procedures.length,
  steps: a.steps.map((s) => s.move),
  markers: a.journey.markers.length,
  findings: a.journey.findings.length,
  tiles: a.journey.tiles.length,
  phySeries: a.phy.length,
  phySamples: a.phy.reduce((n, s) => n + s.samples.length, 0),
  attributed: a.phy.reduce((n, s) => n + s.samples.filter((x) => x.cell).length, 0),
  versionMisses: a.versionMisses,
  problems: a.problems.map((p) => `${p.kind}${p.blocking ? '!' : ''}`),
  guide: a.guide.status,
  revealable: reveal !== null,
  resultMB: +(JSON.stringify(a).length / 1e6).toFixed(2),
}));
