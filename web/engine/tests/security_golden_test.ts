// The synthetic goldens are the contract an iOS port matches. This asserts analyzeSecurity() still produces each
// committed golden byte for byte; regenerate with `deno run -A tools/security-goldens.ts` when a rule changes.

import { assertEquals } from './assert.ts';
import { localPath } from '../tools/local_path.ts';
import { analyzeSecurity } from '../src/security/report.ts';
import { FIXTURES } from './security_support.ts';

const GOLDEN_DIR = localPath(new URL('./security/golden/', import.meta.url));

for (const [name, make] of Object.entries(FIXTURES)) {
  Deno.test(`golden parity: ${name}`, () => {
    const golden = JSON.parse(Deno.readTextFileSync(`${GOLDEN_DIR}${name}.security.json`));
    assertEquals(analyzeSecurity(make()), golden);
  });
}
