// `tsc --noEmit`, reporting only this package's files.
//
// The engine next door is a Deno project with its own, slightly looser compiler options, and it is checked by
// `deno check` in web/engine. Importing it pulls its sources into this program, so tsc would also judge them
// against the app's stricter flags (noUncheckedIndexedAccess, exactOptionalPropertyTypes) and report problems
// that are not ours to fix. This filter keeps the app honest without reaching into the engine.
import { spawn } from 'node:child_process';

const OTHER_PACKAGE = /^\.\.[/\\]/;

const tsc = spawn('node', ['node_modules/typescript/bin/tsc', '--noEmit', '--pretty', 'false'], {
  cwd: new URL('..', import.meta.url).pathname,
});

let out = '';
tsc.stdout.on('data', (d) => (out += d));
tsc.stderr.on('data', (d) => (out += d));

tsc.on('close', () => {
  const lines = out.split('\n').filter((l) => l.trim().length > 0);
  const mine = [];
  let skipping = false;
  for (const line of lines) {
    const starts = /^\S.*\(\d+,\d+\): (error|warning) TS\d+:/.test(line);
    if (starts) skipping = OTHER_PACKAGE.test(line);
    // Continuation lines (indented) belong to the message above them.
    if (!skipping) mine.push(line);
  }
  const errors = mine.filter((l) => l.includes('): error TS')).length;
  const skipped = lines.filter((l) => l.includes('): error TS')).length - errors;
  if (mine.length) console.log(mine.join('\n'));
  console.log(`\n${errors} error(s) in web/app${skipped ? `, ${skipped} in web/engine (checked there, not here)` : ''}.`);
  process.exit(errors ? 1 : 0);
});
