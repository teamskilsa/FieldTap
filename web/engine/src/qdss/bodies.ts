// Record bodies, copied into shared 1 MiB blocks as they are found. A body left as a view would keep its whole
// message and fragment buffers alive (74 MB behind the first capture's 38 MB of bodies); copied, those die young.

const BLOCK = 1 << 20;

export class BodyStore {
  private block = new Uint8Array(0);
  private used = 0;

  /** A copy of `bytes` that shares a block with its neighbours. */
  put(bytes: Uint8Array): Uint8Array {
    const n = bytes.length;
    if (n > BLOCK >> 2) return bytes.slice();
    if (this.used + n > this.block.length) {
      this.block = new Uint8Array(BLOCK);
      this.used = 0;
    }
    const out = this.block.subarray(this.used, this.used + n);
    out.set(bytes);
    this.used += n;
    return out;
  }
}
