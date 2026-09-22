// Layer 1 of qdss_deframe.py: the ARM CoreSight trace formatter. The TMC/ETR writes memory-aligned 16-byte frames
// with no FSYNC; frames are aligned to offset 0 of every chunk, and the formatter state (the current trace ID)
// carries across chunks.
//
// For an even byte x = f[2i], i < 7: when x & 1 it changes the ID to x >> 1, and aux bit i (aux = f[15]) set means
// the byte after it, f[2i+1], still belongs to the OLD ID; otherwise x is data whose LSB is aux bit i, followed by
// the data byte f[2i+1]. f[14] is an ID or data the same way, by aux bit 7, with no byte after it.

import type { ByteQueue } from './queue.ts';

/** The trace ID of the modem's DIAG traffic. */
export const DIAG_ATID = 0x32;
/** Before the first ID change (Python's None). */
export const NO_ATID = -1;
const FRAME = 16;

export class Deformatter {
  private readonly frame = new Uint8Array(FRAME);
  /** Bytes of a frame split across feed() calls. */
  private held = 0;
  private cur = NO_ATID;
  /** Bytes per ID, at index id + 1, and the IDs in first-seen order (the Counter's key order). */
  private readonly perId = new Float64Array(129);
  private readonly seen: number[] = [];
  /** The wanted ID's bytes so far: the length of the Python's atid32.bin. */
  written = 0;

  constructor(private readonly want = DIAG_ATID) {}

  /** The next bytes of the current chunk, in any split. The wanted ID's bytes are appended to `out`. */
  feed(bytes: Uint8Array, out: ByteQueue): void {
    let at = 0;
    if (this.held > 0) {
      at = Math.min(FRAME - this.held, bytes.length);
      this.frame.set(bytes.subarray(0, at), this.held);
      this.held += at;
      if (this.held < FRAME) return;
      this.frames(this.frame, 0, FRAME, out);
      this.held = 0;
    }
    const whole = bytes.length - ((bytes.length - at) % FRAME);
    this.frames(bytes, at, whole, out);
    if (whole < bytes.length) {
      this.frame.set(bytes.subarray(whole), 0);
      this.held = bytes.length - whole;
    }
  }

  /** The chunk ended: a tail shorter than a frame is not a frame, and the next chunk starts a new one. */
  endChunk(): void {
    this.held = 0;
  }

  /** bytes_per_atid as atid32.bin.json has it: {'none': 10, '0x32': 2885648}. */
  bytesPerAtid(): Record<string, number> {
    const out: Record<string, number> = {};
    for (const id of this.seen) {
      out[id === NO_ATID ? 'none' : '0x' + id.toString(16).padStart(2, '0')] = this.perId[id + 1];
    }
    return out;
  }

  private count(id: number, n: number): void {
    if (this.perId[id + 1] === 0) this.seen.push(id);
    this.perId[id + 1] += n;
  }

  private frames(b: Uint8Array, from: number, to: number, q: ByteQueue): void {
    if (to <= from) return;
    q.reserve(((to - from) / FRAME) * 15);
    const out = q.bytes;
    const want = this.want;
    let w = q.end;
    let cur = this.cur;
    for (let k = from; k < to; k += FRAME) {
      const f0 = b[k];
      // ff ff ff 7f: a frame the formatter wrote no trace into.
      if (f0 === 0xff && b[k + 1] === 0xff && b[k + 2] === 0xff && b[k + 3] === 0x7f) continue;
      const aux = b[k + 15];
      if (((f0 | b[k + 2] | b[k + 4] | b[k + 6] | b[k + 8] | b[k + 10] | b[k + 12] | b[k + 14]) & 1) === 0) {
        // No ID change in the frame: 15 data bytes, the even ones completed by their aux bit.
        this.count(cur, 15);
        if (cur === want) {
          for (let j = 0; j < 15; j++) out[w + j] = b[k + j];
          if (aux) for (let i = 0; i < 8; i++) if ((aux >> i) & 1) out[w + 2 * i] |= 1;
          w += 15;
        }
        continue;
      }
      for (let i = 0; i < 8; i++) {
        const x = b[k + 2 * i];
        const bit = (aux >> i) & 1;
        if (x & 1) {
          const nid = x >> 1;
          if (i === 7) {
            cur = nid;
          } else if (bit) {
            this.count(cur, 1);
            if (cur === want) out[w++] = b[k + 2 * i + 1];
            cur = nid;
          } else {
            cur = nid;
            this.count(cur, 1);
            if (cur === want) out[w++] = b[k + 2 * i + 1];
          }
        } else {
          this.count(cur, i === 7 ? 1 : 2);
          if (cur === want) {
            out[w++] = x | bit;
            if (i < 7) out[w++] = b[k + 2 * i + 1];
          }
        }
      }
    }
    this.cur = cur;
    this.written += w - q.end;
    q.end = w;
  }
}
