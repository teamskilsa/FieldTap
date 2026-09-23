// The real AT&T capture MUST come back clean: a legitimate network must never be flagged. This reads the analysis
// the engine already produced for the moving capture (web/app/public/dev/analysis.json, git-ignored and
// capture-derived, read in place and never copied into web/engine). It skips when that file is absent, so it runs
// on the fixture machine and stays green everywhere else.

import { assert, assertEquals } from './assert.ts';
import { localPath } from '../tools/local_path.ts';
import { analyzeSecurity } from '../src/security/report.ts';
import type { CaptureAnalysis } from '../src/types.ts';

const REAL = localPath(new URL('../../app/public/dev/analysis.json', import.meta.url));

function present(): boolean {
  try {
    Deno.statSync(REAL);
    return true;
  } catch {
    return false;
  }
}

Deno.test({
  name: 'real capture (moving, AT&T): security verdict is trusted, no false positives',
  ignore: !present(),
  fn: () => {
    const analysis = JSON.parse(Deno.readTextFileSync(REAL)) as CaptureAnalysis;
    const report = analyzeSecurity(analysis);
    const fired = [...report.cells.flatMap((c) => c.findings), ...report.findings];
    assertEquals(
      report.verdict,
      'trusted',
      `expected a clean capture, got ${report.verdict} with [${fired.map((f) => `${f.check}: ${f.evidence.join('; ')}`).join(' | ')}]`,
    );
    assertEquals(fired.length, 0, 'no findings on a legitimate network');
    assert(report.headline.length > 0);
  },
});
