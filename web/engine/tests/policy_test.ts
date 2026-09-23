// src/ runs in the visitor's browser and must never reach the network or the host: the type check with
// deno.browser.json (no Deno namespace) enforces the API side; this scans for the rest. Also: no fixture paths or
// capture-derived data inside web/engine.

import { assert, assertEquals } from './assert.ts';
import { localPath } from '../tools/local_path.ts';

const ROOT = localPath(new URL('..', import.meta.url));

function files(dir: string, ext: RegExp): string[] {
  const out: string[] = [];
  for (const e of Deno.readDirSync(dir)) {
    const p = `${dir}/${e.name}`;
    if (e.isDirectory) out.push(...files(p, ext));
    else if (ext.test(e.name)) out.push(p);
  }
  return out;
}

const FORBIDDEN_IN_SRC: [RegExp, string][] = [
  [/\bDeno\./, 'Deno API'],
  [/from\s+['"]node:|require\(/, 'Node API'],
  [/\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon|RTCPeerConnection|importScripts/, 'networking'],
  [/from\s+['"]https?:|import\(\s*['"]https?:|from\s+['"](jsr|npm):/, 'remote import'],
  [/localStorage|sessionStorage|indexedDB|document\.cookie|caches\./, 'persistent storage'],
  [/\beval\s*\(|new Function\s*\(/, 'dynamic code'],
];

Deno.test('src/: no host, network, storage or dynamic-code APIs', () => {
  const offenders: string[] = [];
  for (const f of files(`${ROOT}src`, /\.ts$/)) {
    const text = Deno.readTextFileSync(f).split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
    for (const [re, what] of FORBIDDEN_IN_SRC) if (re.test(text)) offenders.push(`${f.slice(ROOT.length)}: ${what}`);
  }
  assertEquals(offenders, []);
});

Deno.test('web/engine holds no capture-derived files, and src/ names no absolute local path', () => {
  const data = files(ROOT.replace(/\/$/, ''), /\.(qmdl|bin|stub|tar|gz|pcapng|tsv)$/);
  assertEquals(data, []);
  for (const f of files(`${ROOT}src`, /\.ts$/)) {
    const text = Deno.readTextFileSync(f);
    assert(!/\/Users\/|\/private\/(tmp|var)|~\/Downloads|Downloads\/sysdiagnose/.test(text), `${f} names an absolute local path`);
  }
});

// The UI copies src/types.ts verbatim into its src/lib/analysis/types.ts, where the Lovable tsconfig adds
// noUncheckedIndexedAccess, exactOptionalPropertyTypes and noPropertyAccessFromIndexSignature (deno.lovable.json
// mirrors them). So the contract must stand alone and check under those flags.
Deno.test('src/types.ts stands alone and type-checks under the Lovable project\'s compiler options', async () => {
  const text = Deno.readTextFileSync(`${ROOT}src/types.ts`);
  assert(!/^\s*(import|export\s+[^;]*\bfrom\b)/m.test(text), 'types.ts imports nothing');
  const out = await new Deno.Command(Deno.execPath(), {
    args: ['check', '--quiet', '--config', `${ROOT}deno.lovable.json`, `${ROOT}src/types.ts`],
    stdout: 'piped',
    stderr: 'piped',
  }).output();
  assert(out.success, new TextDecoder().decode(out.stderr));
});
