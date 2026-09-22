// Where the capture-derived fixtures and the real archives live. They are never copied into web/engine: tests
// read them in place.
//
//   FT_FIXTURES           default ios/Fixtures/local next to this checkout
//   FT_ARCHIVES           directory holding the real sysdiagnose archives (default ~/Downloads)
//   FT_REQUIRE_FIXTURES=1 a missing fixture fails its test instead of skipping it (use on the fixture machine)

export const FIXTURES = Deno.env.get('FT_FIXTURES') ??
  new URL('../../../ios/Fixtures/local', import.meta.url).pathname;

export const ARCHIVES = Deno.env.get('FT_ARCHIVES') ?? `${Deno.env.get('HOME') ?? ''}/Downloads`;

export const REQUIRE_FIXTURES = Deno.env.get('FT_REQUIRE_FIXTURES') === '1';

/** The real captures (read in place; never copied or uploaded). */
export const REAL = {
  /** First capture, profile on. */
  first: 'sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84.tar.gz',
  /** Moving capture, profile on. */
  moving: 'sysdiagnose_2026.09.22_08-57-25-0400_iPhone-OS_iPhone_23F84.tar.gz',
  /** Profile off: only its extracted folder exists (the task's 14-39-54 archive is not on this Mac). */
  offFolder: 'sysdiagnose_2026.09.21_14-35-58-0400_iPhone-OS_iPhone_23F84',
} as const;

export const fixture = (rel: string) => `${FIXTURES}/${rel}`;
export const archive = (name: string) => `${ARCHIVES}/${name}`;

export function exists(path: string): boolean {
  try {
    Deno.statSync(path);
    return true;
  } catch {
    return false;
  }
}

/** `ignore` for a fixture-gated Deno.test: run when every path exists, or when fixtures are required. */
export function gate(...paths: string[]): boolean {
  return !REQUIRE_FIXTURES && !paths.every(exists);
}
