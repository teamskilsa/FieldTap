// The ATID-0x32 stream between layer 1 and layer 2: layer 1 appends at `end`, layer 2 takes 16-byte units from
// `start`. Only what layer 2 has not consumed is held, so a 125 MB stream passes through a buffer of about one
// chunk.

export class ByteQueue {
  bytes = new Uint8Array(1 << 16);
  start = 0;
  end = 0;
  /** Stream offset of bytes[0]. */
  base = 0;

  /** Makes room for `n` more bytes at `end`, dropping consumed bytes first. `bytes` may be replaced. */
  reserve(n: number): void {
    if (this.end + n <= this.bytes.length) return;
    const live = this.end - this.start;
    if (live + n <= this.bytes.length) {
      this.bytes.copyWithin(0, this.start, this.end);
    } else {
      const grown = new Uint8Array(Math.max(live + n, this.bytes.length * 2));
      grown.set(this.bytes.subarray(this.start, this.end));
      this.bytes = grown;
    }
    this.base += this.start;
    this.end = live;
    this.start = 0;
  }
}
