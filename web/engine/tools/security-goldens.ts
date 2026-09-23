// Emit the golden SecurityReports so an iOS port can match them field for field.
//
//   deno run -A tools/security-goldens.ts            # write the synthetic goldens (committed, invented data)
//   deno run -A tools/security-goldens.ts --check     # fail if any committed golden is out of date (used by CI)
//
// The synthetic goldens (tests/security/golden/*.json) are invented — reserved PLMN, invented PCIs — so they live
// in web/engine. The real capture's report is capture-derived, so it is written to out/security/ (git-ignored),
// never committed, and only when web/app/public/dev/analysis.json is present on this machine.

import { analyzeSecurity } from '../src/security/report.ts';
import type { CaptureAnalysis } from '../src/types.ts';
import { FIXTURES } from '../tests/security_support.ts';
import { localPath } from './local_path.ts';

const GOLDEN_DIR = localPath(new URL('../tests/security/golden/', import.meta.url));
const OUT_DIR = localPath(new URL('../out/security/', import.meta.url));
const REAL = localPath(new URL('../../app/public/dev/analysis.json', import.meta.url));

const pretty = (v: unknown) => JSON.stringify(v, null, 2) + '\n';

function main(): void {
  const check = Deno.args.includes('--check');
  Deno.mkdirSync(GOLDEN_DIR, { recursive: true });
  let stale = 0;
  for (const [name, make] of Object.entries(FIXTURES)) {
    const report = analyzeSecurity(make());
    const path = `${GOLDEN_DIR}${name}.security.json`;
    const next = pretty(report);
    if (check) {
      const current = safeRead(path);
      if (current !== next) {
        console.error(`stale golden: ${name}.security.json`);
        stale++;
      }
    } else {
      Deno.writeTextFileSync(path, next);
      console.log(`wrote ${name}.security.json (${report.verdict})`);
    }
  }
  if (check) {
    if (stale) Deno.exit(1);
    console.log('all synthetic goldens up to date');
  }

  // The real capture's report: git-ignored, capture-derived, emitted for the iOS fixture machine only.
  if (!check) {
    try {
      Deno.statSync(REAL);
      const analysis = JSON.parse(Deno.readTextFileSync(REAL)) as CaptureAnalysis;
      Deno.mkdirSync(OUT_DIR, { recursive: true });
      Deno.writeTextFileSync(`${OUT_DIR}real-analysis.security.json`, pretty(analyzeSecurity(analysis)));
      console.log(`wrote out/security/real-analysis.security.json (${analyzeSecurity(analysis).verdict}) [git-ignored]`);
    } catch {
      console.log('real capture absent; skipped out/security/real-analysis.security.json');
    }
  }
}

function safeRead(path: string): string | null {
  try {
    return Deno.readTextFileSync(path);
  } catch {
    return null;
  }
}

main();
