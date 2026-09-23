// Where the capture-derived fixtures and the real archives live. They are never copied into web/engine: tests
// read them in place.
//
//   FT_FIXTURES           default ios/Fixtures/local next to this checkout
//   FT_ARCHIVES           directory holding the real sysdiagnose archives (default ~/Downloads)
//   FT_REQUIRE_FIXTURES=1 a missing fixture fails its test instead of skipping it (use on the fixture machine)

import { localPath } from './local_path.ts';
export const FIXTURES = Deno.env.get('FT_FIXTURES') ??
  localPath(new URL('../../../ios/Fixtures/local', import.meta.url));

export const ARCHIVES = Deno.env.get('FT_ARCHIVES') ?? `${Deno.env.get('HOME') ?? ''}/Downloads`;

export const REQUIRE_FIXTURES = Deno.env.get('FT_REQUIRE_FIXTURES') === '1';

/** The real captures (read in place; never copied or uploaded). */
export const REAL = {
  /** First capture, profile on. */
  first: 'sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84.tar.gz',
  /** Moving capture, profile on. */
  moving: 'sysdiagnose_2026.09.22_08-57-25-0400_iPhone-OS_iPhone_23F84.tar.gz',
  /** Profile off: no such capture is on this Mac. The 14-39-54 archive never was, and the extracted 14-35-58
   *  folder that stood in for it has been deleted from ~/Downloads, so the tests build a synthetic one instead
   *  (tests/support.ts `loggingOffFiles`). Kept here only so a machine that has one can be pointed at it. */
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

/**
 * A real capture in whichever form this machine still has. The `.tar.gz` downloads are ~400 MB each and get
 * cleaned up when the disk runs short (both were removed while this engine was being written), but an extracted
 * folder beside them serves just as well for everything except the archive-format assertions: `folder` is tarred
 * on the fly, without gzip and without ever holding the trace in memory (`tests/support.ts tarStreamOfFiles`).
 */
export interface CaptureSource {
  kind: 'archive' | 'folder';
  path: string;
}

/** `name` is a `REAL` entry (a `.tar.gz` name); the folder is the same name without the suffix. */
export function captureSource(name: string): CaptureSource | null {
  const tar = archive(name);
  if (exists(tar)) return { kind: 'archive', path: tar };
  const folder = archive(name.replace(/\.tar\.gz$/, ''));
  if (exists(`${folder}/logs/Baseband`)) return { kind: 'folder', path: folder };
  return null;
}

/** `ignore` for a test that needs a real capture's contents in either form. */
export function gateCapture(...names: string[]): boolean {
  return !REQUIRE_FIXTURES && !names.every((n) => captureSource(n) !== null);
}
