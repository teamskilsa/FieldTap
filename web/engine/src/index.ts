// OWNER: integrator. The engine's only entry point for the UI: the drop-in replacement for the Lovable project's
// src/engine/index.ts. analyzeFile runs the analysis in a Web Worker and resolves with a CaptureAnalysis (whose
// problems explain an unusable file); it rejects with an AbortError when `signal` aborts.
//
// Identifiers arrive masked. The worker of the last capture stays alive holding only its call flow, so
// revealIdentifiers() can return the decoded values once the user confirms; forgetCapture() ends it.

import type { CaptureAnalysis, ImportProgress, ImportStage } from './types.ts';
import type { RevealedSignalling, WorkerReply, WorkerRequest } from './worker.ts';

export type * from './types.ts';
export type { RevealedSignalling } from './worker.ts';
export { CONTRACT_VERSION } from './types.ts';

/** The stages the import sheet lists, in order (as the Lovable UI's src/engine/index.ts exports them). */
export const STAGE_ORDER: ImportStage[] = ['reading', 'extracting', 'deframing', 'decoding', 'radio'];

export const STAGE_LABELS: Record<ImportStage, string> = {
  reading: 'Reading archive',
  extracting: 'Extracting modem trace',
  deframing: 'Rebuilding the modem log',
  decoding: 'Decoding signalling',
  radio: 'Decoding radio',
  done: 'Done',
};

/** The worker to run in. Bundlers (Vite) resolve this URL form into a separate worker chunk; the dist build
 *  rewrites it to './worker.js'. */
export function defaultWorker(): Worker {
  return new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' });
}

/** The worker that analysed the last capture, kept for revealIdentifiers. */
let kept: Worker | null = null;

export function analyzeFile(
  file: File,
  onProgress: (p: ImportProgress) => void,
  signal?: AbortSignal,
  makeWorker: () => Worker = defaultWorker,
): Promise<CaptureAnalysis> {
  forgetCapture();
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new DOMException('The analysis was cancelled', 'AbortError'));
    const worker = makeWorker();
    const detach = () => signal?.removeEventListener('abort', onAbort);
    const fail = (e: Error) => {
      detach();
      worker.terminate();
      reject(e);
    };
    const onAbort = () => {
      worker.postMessage({ type: 'cancel' } satisfies WorkerRequest);
      fail(new DOMException('The analysis was cancelled', 'AbortError'));
    };
    signal?.addEventListener('abort', onAbort);
    worker.onmessage = (event: MessageEvent<WorkerReply>) => {
      const m = event.data;
      if (m.type === 'progress') onProgress(m.progress);
      else if (m.type === 'done') {
        detach();
        worker.onmessage = () => {}; // the kept worker answers only revealIdentifiers from here on
        kept = worker;
        resolve(m.analysis);
      } else if (m.type === 'error') {
        fail(m.name === 'AbortError' ? new DOMException(m.message, 'AbortError') : new Error(m.message));
      }
    };
    worker.onerror = (event) => fail(new Error(event.message || 'the analysis worker failed'));
    worker.postMessage({ type: 'analyze', file, fileName: file.name } satisfies WorkerRequest);
  });
}

/**
 * The last capture's events, procedures, steps, connections, cell details and ladder with identifiers as decoded
 * (plus PDU bytes and cell identities). Spread it over the masked analysis. Null when nothing is kept (no capture
 * analysed, the capture had no call flow, or forgetCapture ran). Ask only after the user confirmed.
 */
export function revealIdentifiers(): Promise<RevealedSignalling | null> {
  const worker = kept;
  if (!worker) return Promise.resolve(null);
  return new Promise((resolve, reject) => {
    worker.onmessage = (event: MessageEvent<WorkerReply>) => {
      const m = event.data;
      if (m.type === 'revealed') resolve(m.signalling);
      else if (m.type === 'error') reject(new Error(m.message));
    };
    worker.postMessage({ type: 'reveal' } satisfies WorkerRequest);
  });
}

/** End the kept worker, and with it everything decoded from the last capture. */
export function forgetCapture(): void {
  kept?.terminate();
  kept = null;
}
