// The app's only door to the analysis engine (web/engine). Everything the UI knows about a capture comes through
// here, and the contract types come from the engine's own src/types.ts — the app keeps no copy of them.
//
// The worker is built from the engine's worker module. The `new Worker(new URL(...))` form lives in this file (not
// in the engine) so Vite puts the worker in the app's bundle graph and the dev server serves it as a module.

import { analyzeFile as run, forgetCapture, revealIdentifiers } from '@engine/index';

export type * from '@engine/types';
export { CONTRACT_VERSION } from '@engine/types';
export { STAGE_LABELS, STAGE_ORDER } from '@engine/index';
export type { RevealedSignalling } from '@engine/worker';
export { forgetCapture, revealIdentifiers };

import type { CaptureAnalysis, ImportProgress } from '@engine/types';

function makeWorker(): Worker {
  // A static relative path, not the '@engine' alias: Vite only rewrites `new URL` when it can see the literal.
  return new Worker(new URL('../../../engine/src/worker.ts', import.meta.url), { type: 'module' });
}

/**
 * Analyse a sysdiagnose archive in a Web Worker. The File handle is passed to the worker and read there; nothing
 * is uploaded, and the promise rejects with an AbortError when `signal` aborts.
 */
export function analyzeFile(
  file: File,
  onProgress: (p: ImportProgress) => void,
  signal?: AbortSignal,
): Promise<CaptureAnalysis> {
  return run(file, onProgress, signal, makeWorker);
}
