// Drives a TarReader from a ReadableStream: sniffs gzip or plain tar (Safari can gunzip a download on its own),
// inflates with the platform's DecompressionStream, counts the compressed bytes for progress, and stops reading
// as soon as the caller has what it needs.

import { TarError, type TarCounts, TarReader, type TarReaderOptions } from './tar.ts';

export type ArchiveFormat = 'gzip' | 'tar';

export class ArchiveError extends Error {
  constructor(readonly kind: 'notArchive' | 'truncated' | 'corrupt', message: string) {
    super(message);
  }
}

export interface ArchiveReadOptions extends TarReaderOptions {
  /** Asked after every piece of input; true stops reading and cancels the source. */
  shouldStop?: () => boolean;
  /** Compressed (source) bytes read so far. */
  onBytes?: (read: number) => void;
  signal?: AbortSignal;
}

export interface ArchiveReadResult {
  format: ArchiveFormat;
  compressedBytes: number;
  uncompressedBytes: number;
  /** shouldStop ended the read before the end of the archive. */
  stoppedEarly: boolean;
  counts: TarCounts;
}

const GZIP_MAGIC = [0x1f, 0x8b];
const USTAR_AT = 257;

export function abortError(): Error {
  return new DOMException('The analysis was cancelled', 'AbortError');
}

export async function readArchive(source: ReadableStream<Uint8Array>, options: ArchiveReadOptions): Promise<ArchiveReadResult> {
  const { signal } = options;
  if (signal?.aborted) throw abortError();
  const reader = source.getReader();

  // Enough bytes to tell gzip from tar (the ustar magic sits at 257).
  const parts: Uint8Array[] = [];
  let have = 0, sourceDone = false;
  while (have < USTAR_AT + 6) {
    const { done, value } = await reader.read();
    if (done) {
      sourceDone = true;
      break;
    }
    parts.push(value);
    have += value.length;
  }
  const head = concat(parts, have);
  const format = sniff(head);
  if (!format) {
    await reader.cancel();
    throw new ArchiveError('notArchive', 'neither a gzip nor a tar file');
  }

  let compressed = head.length;
  options.onBytes?.(compressed);
  const counted = new ReadableStream<Uint8Array>({
    start(controller) {
      if (head.length) controller.enqueue(head);
      if (sourceDone) controller.close();
    },
    async pull(controller) {
      const { done, value } = await reader.read();
      if (done) {
        sourceDone = true;
        controller.close();
        return;
      }
      compressed += value.length;
      options.onBytes?.(compressed);
      controller.enqueue(value);
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
  const tarBytes = format === 'gzip'
    ? counted.pipeThrough(new DecompressionStream('gzip') as unknown as ReadableWritablePair<Uint8Array, Uint8Array>)
    : counted;

  const tar = new TarReader(options);
  const input = tarBytes.getReader();
  let stoppedEarly = false;
  try {
    for (;;) {
      if (signal?.aborted) {
        await input.cancel().catch(() => {});
        throw abortError();
      }
      let next: ReadableStreamReadResult<Uint8Array>;
      try {
        next = await input.read();
      } catch (e) {
        // The inflater failed. After the tar's end block that is trailing data and harmless; otherwise the file
        // either stopped early (a copy cut short) or is damaged.
        if (tar.ended) break;
        throw new ArchiveError(sourceDone ? 'truncated' : 'corrupt', `gzip: ${(e as Error).message}`);
      }
      if (next.done) break;
      tar.feed(next.value);
      if (tar.ended) {
        await input.cancel().catch(() => {});
        break;
      }
      if (options.shouldStop?.()) {
        stoppedEarly = true;
        await input.cancel().catch(() => {});
        break;
      }
    }
    if (!stoppedEarly) tar.finish();
  } catch (e) {
    if (e instanceof TarError) {
      throw new ArchiveError(e.kind === 'notTar' ? 'notArchive' : e.kind, e.message);
    }
    throw e;
  }
  return { format, compressedBytes: compressed, uncompressedBytes: tar.counts.bytes, stoppedEarly, counts: tar.counts };
}

function sniff(head: Uint8Array): ArchiveFormat | null {
  if (head.length >= 2 && head[0] === GZIP_MAGIC[0] && head[1] === GZIP_MAGIC[1]) return 'gzip';
  const ustar = [0x75, 0x73, 0x74, 0x61, 0x72]; // 'ustar', POSIX or GNU
  if (head.length >= USTAR_AT + 5 && ustar.every((c, i) => head[USTAR_AT + i] === c)) return 'tar';
  return null;
}

function concat(parts: Uint8Array[], total: number): Uint8Array {
  if (parts.length === 1) return parts[0];
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}
