// The browser bundle (tools/build.ts): dist/worker.js runs the whole analysis in a worker with no Deno API, and
// dist/engine.js points at it. Skipped when dist/ has not been built.

import { CONTRACT_VERSION, type CaptureAnalysis } from '../src/types.ts';
import type { WorkerReply, WorkerRequest } from '../src/worker.ts';
import { exists } from '../tools/fixtures.ts';
import { assert, assertEquals } from './assert.ts';
import { buildTar, gzip } from './support.ts';
import { localPath } from '../tools/local_path.ts';

const DIST = localPath(new URL('../dist', import.meta.url));
const ROOT = 'sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84';
const QDSS = `${ROOT}/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss`;

Deno.test({
  name: 'dist bundle: worker.js analyses in a worker, engine.js starts it, neither touches Deno or the network',
  ignore: !exists(`${DIST}/worker.js`),
  fn: async () => {
    const engine = await Deno.readTextFile(`${DIST}/engine.js`);
    assert(engine.includes('./worker.js'), 'engine.js starts ./worker.js');
    for (const source of [engine, await Deno.readTextFile(`${DIST}/worker.js`)]) {
      for (const banned of ['Deno.', 'fetch(', 'XMLHttpRequest', 'WebSocket', 'localStorage', 'indexedDB']) {
        assert(!source.includes(banned), `the bundle uses ${banned}`);
      }
    }

    const gz = await gzip(buildTar([
      { path: `${QDSS}/info.txt`, data: 'GUID: 1234\nDiagID: 2\nFile: 0x00000001.bin\nStarting From: 2026-09-21-15-42-06\nSize (Bytes): 64\n' },
      { path: `${QDSS}/0x00000001.bin`, data: new Uint8Array(64).fill(1) },
      { path: `${ROOT}/logs/Baseband/ambtool_output.log`, data: 'Baseband log collection: Success (ABM running)\n' },
    ]));
    const worker = new Worker(`file://${DIST}/worker.js`, { type: 'module' });
    const replies: WorkerReply[] = [];
    const analysis = await new Promise<CaptureAnalysis>((resolve, reject) => {
      worker.onmessage = (e: MessageEvent<WorkerReply>) => {
        replies.push(e.data);
        if (e.data.type === 'done') resolve(e.data.analysis);
        else if (e.data.type === 'error') reject(new Error(e.data.message));
      };
      worker.postMessage({ type: 'analyze', file: gz.slice().buffer, fileName: `${ROOT}.tar.gz` } satisfies WorkerRequest);
    });
    worker.terminate();
    assertEquals(analysis.contract, CONTRACT_VERSION);
    assertEquals([analysis.traceWindow?.filesKept, analysis.problems.filter((p) => p.blocking).length], [1, 0]);
    assert(replies.filter((r) => r.type === 'progress').length > 3, 'progress before the result');
    assertEquals(replies.at(-1)?.type, 'done');
  },
});
