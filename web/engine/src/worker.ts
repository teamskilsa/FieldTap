// OWNER: integrator. The Web Worker entry: runs the analysis off the main thread and posts progress and the
// result back. The file is read here, from the Blob the page passed (streamed, never copied whole); nothing
// leaves the worker except the CaptureAnalysis, masked.
//
// Messages are the Lovable mock worker's ('analyze' and 'cancel' in; 'progress', 'done', 'error' out), so either
// side can be swapped alone, plus 'reveal' / 'revealed' and 'forget'. The worker keeps the last capture's call
// flow (not the trace) so the identifiers can be revealed without reading the file again. 'error' carries the
// error's name, so an AbortError stays one.

import { analyzeCapture, type Analyzed } from './analyze.ts';
import type { UiSignalling } from './signalling/ui.ts';
import type { CaptureAnalysis, ImportProgress } from './types.ts';

/** The call-flow part of a CaptureAnalysis with identifiers as decoded: replaces the same keys of the masked one. */
export type RevealedSignalling = UiSignalling;

export type WorkerRequest =
  /** `file` is the File itself in browsers; an ArrayBuffer (transferable) where a runtime cannot clone a Blob
   *  into a worker (Deno). */
  | { type: 'analyze'; file: Blob | ArrayBuffer; fileName: string; nowMs?: number }
  | { type: 'cancel' }
  /** The last analysis's call flow with identifiers revealed; asked only after the user confirmed. */
  | { type: 'reveal' }
  /** Drop what is kept of the last capture. */
  | { type: 'forget' };

export type WorkerReply =
  | { type: 'progress'; progress: ImportProgress }
  | { type: 'done'; analysis: CaptureAnalysis }
  | { type: 'revealed'; signalling: RevealedSignalling | null }
  | { type: 'error'; name: string; message: string };

/** The part of DedicatedWorkerGlobalScope used here, so this file type-checks under the DOM and Deno libs. */
interface WorkerScope {
  onmessage: ((event: MessageEvent<WorkerRequest>) => void) | null;
  postMessage(message: WorkerReply): void;
}

const scope = globalThis as unknown as WorkerScope;
let running: AbortController | null = null;
let reveal: Analyzed['reveal'] = null;

scope.onmessage = (event) => {
  const request = event.data;
  switch (request.type) {
    case 'cancel':
      running?.abort();
      return;
    case 'forget':
      reveal = null;
      return;
    case 'reveal':
      try {
        scope.postMessage({ type: 'revealed', signalling: reveal ? reveal() : null });
      } catch (e) {
        postError(e);
      }
      return;
    case 'analyze':
      analyze(request);
  }
};

function analyze(request: Extract<WorkerRequest, { type: 'analyze' }>): void {
  running?.abort();
  reveal = null;
  const controller = new AbortController();
  running = controller;
  const { file, fileName, nowMs } = request;
  const blob = file instanceof ArrayBuffer ? new Blob([file]) : file;
  const options = nowMs === undefined ? { fileName, totalBytes: blob.size } : { fileName, totalBytes: blob.size, nowMs };
  analyzeCapture(blob.stream(), (progress) => scope.postMessage({ type: 'progress', progress }), controller.signal, options)
    .then((result) => {
      if (controller.signal.aborted) return;
      reveal = result.reveal;
      scope.postMessage({ type: 'done', analysis: result.analysis });
    }, (e) => {
      // A run superseded by a newer 'analyze' ends silently; a cancelled one reports its AbortError.
      if (running === controller) postError(e);
    })
    .finally(() => {
      if (running === controller) running = null;
    });
}

function postError(e: unknown): void {
  const err = e instanceof Error ? e : new Error(String(e));
  scope.postMessage({ type: 'error', name: err.name, message: err.message });
}
