// Write a fully-synthetic FLAGGED CaptureAnalysis to web/app/public/dev/flagged.json (git-ignored) so the app can
// render a "suspicious" Security screen for a screenshot. Everything is invented (reserved PLMN, invented PCIs) —
// no capture-derived data — and the `security` field is precomputed by the same engine function the app uses.
//
//   deno run -A tools/flagged-fixture.ts

import { analyzeSecurity } from '../src/security/report.ts';
import { flaggedShowcase } from '../tests/security_support.ts';
import { localPath } from './local_path.ts';

const OUT = localPath(new URL('../../app/public/dev/flagged.json', import.meta.url));

const analysis = flaggedShowcase();
analysis.security = analyzeSecurity(analysis);

Deno.mkdirSync(OUT.replace(/\/[^/]+$/, ''), { recursive: true });
Deno.writeTextFileSync(OUT, JSON.stringify(analysis, null, 2) + '\n');
console.log(`wrote ${OUT} (${analysis.security.verdict})`);
