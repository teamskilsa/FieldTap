// Bundles the engine for the browser with esbuild (downloaded by npx; nothing else is installed):
//
//   dist/engine.js             src/index.ts  — analyzeFile, revealIdentifiers, the stage labels
//   dist/worker.js             src/worker.ts — the worker engine.js starts
//   dist/sample-analysis.json  the website's "Try the sample", invented end to end (tools/make-sample.ts)
//
// ES modules, minified, with sourcemaps. engine.js's `new URL('./worker.ts', import.meta.url)` is rewritten to
// './worker.js', so the two files sit side by side in the app's bundle.
//
//   deno run -A tools/build.ts [--outdir dist]

import { makeSample } from './make-sample.ts';

const outdir = (() => {
  const i = Deno.args.indexOf('--outdir');
  return i >= 0 ? Deno.args[i + 1]! : new URL('../dist', import.meta.url).pathname;
})();

async function esbuild(entry: string, out: string): Promise<void> {
  const cmd = new Deno.Command('npx', {
    args: [
      '--yes',
      'esbuild',
      new URL(`../src/${entry}`, import.meta.url).pathname,
      '--bundle',
      '--format=esm',
      '--platform=browser',
      '--target=es2022',
      '--minify',
      '--sourcemap',
      `--outfile=${outdir}/${out}`,
    ],
    stdout: 'inherit',
    stderr: 'inherit',
  });
  const { code } = await cmd.output();
  if (code !== 0) throw new Error(`esbuild failed on ${entry}`);
}

await Deno.mkdir(outdir, { recursive: true });
await esbuild('index.ts', 'engine.js');
await esbuild('worker.ts', 'worker.js');

// The worker URL: the bundle's own file name, not the source's.
const enginePath = `${outdir}/engine.js`;
const engine = await Deno.readTextFile(enginePath);
const rewritten = engine.replaceAll('./worker.ts', './worker.js');
if (rewritten === engine) throw new Error("engine.js has no './worker.ts' to rewrite");
await Deno.writeTextFile(enginePath, rewritten);

// The sample capture ships beside the bundle as a static asset (byte-stable, so it caches).
await Deno.writeTextFile(`${outdir}/sample-analysis.json`, JSON.stringify(makeSample(), null, 2) + '\n');

for (const name of ['engine.js', 'engine.js.map', 'worker.js', 'worker.js.map', 'sample-analysis.json']) {
  const { size } = await Deno.stat(`${outdir}/${name}`);
  console.log(`${name.padEnd(20)} ${(size / 1024).toFixed(1)} kB`);
}
