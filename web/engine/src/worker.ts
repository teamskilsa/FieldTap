// OWNER: integrator (seeded by the engine foundation). The Web Worker entry: runs analyzeArchive off the main
// thread and posts progress and the result back. The file is read here, from the Blob the page passed; nothing
// leaves the worker except the CaptureAnalysis.
//
// The messages are the Lovable mock worker's ('progress', 'done', 'error'; requests 'analyze' and 'cancel'), so
// either side can be swapped alone. 'error' also carries the error's name.

import { analyzeArchive } from './analyze.ts';
import type { CaptureAnalysis, ImportProgress } from './types.ts';

export type WorkerRequest =
  /** `file` is the File itself in browsers (streamed from disk, never copied whole); an ArrayBuffer where a
   *  runtime cannot clone a Blob into a worker (Deno). */
  | { type: 'analyze'; file: Blob | ArrayBuffer; fileName: string; nowMs?: number }
  | { type: 'cancel' };

export type WorkerReply =
  | { type: 'progress'; progress: ImportProgress }
  | { type: 'done'; analysis: CaptureAnalysis }
  | { type: 'error'; name: string; message: string };

/** The part of DedicatedWorkerGlobalScope used here, so this file type-checks under the DOM and Deno libs. */
interface WorkerScope {
  onmessage: ((event: MessageEvent<WorkerRequest>) => void) | null;
  postMessage(message: WorkerReply): void;
}

const scope = globalThis as unknown as WorkerScope;
let running: AbortController | null = null;

scope.onmessage = (event) => {
  const request = event.data;
  if (request.type === 'cancel') {
    running?.abort();
    return;
  }
  running?.abort();
  const controller = new AbortController();
  running = controller;
  const { file, fileName, nowMs } = request;
  const blob = file instanceof ArrayBuffer ? new Blob([file]) : file;
  analyzeArchive(blob.stream(), (progress) => scope.postMessage({ type: 'progress', progress }), controller.signal, {
    fileName,
    totalBytes: blob.size,
    nowMs,
  }).then(
    (analysis) => scope.postMessage({ type: 'done', analysis }),
    (e: unknown) => {
      const err = e instanceof Error ? e : new Error(String(e));
      scope.postMessage({ type: 'error', name: err.name, message: err.message });
    },
  ).finally(() => {
    if (running === controller) running = null;
  });
};
