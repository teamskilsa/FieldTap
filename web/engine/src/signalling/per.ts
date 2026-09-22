// Port of PerBits from ios/Contract/src-v1/LteRrc.kt (the bottom of the file): an unaligned-PER bit reader,
// most significant bit first, shared by the LTE and NR RRC decoders.

import { OutOfBounds } from './bytes.ts';

export class PerBits {
  position: number;

  constructor(private readonly data: Uint8Array, startBit = 0) {
    this.position = startBit;
  }

  read(n: number): number {
    return this.readLong(n);
  }

  /** Up to 53 bits exactly (the decoders read at most 48). */
  readLong(n: number): number {
    let value = 0;
    for (let k = 0; k < n; k++) {
      const byte = this.position >>> 3;
      if (byte >= this.data.length) throw new OutOfBounds(`PDU ends at bit ${this.data.length * 8}`);
      const bit = (this.data[byte] >>> (7 - (this.position & 7))) & 1;
      value = value * 2 + bit;
      this.position++;
    }
    return value;
  }

  /**
   * An unaligned-PER length determinant: one bit for a length under 128, two for one under 16K. A fragmented
   * length (the 16K-and-over form) is not read.
   */
  readLength(): number {
    if (this.read(1) === 0) return this.read(7);
    if (this.read(1) === 0) return this.read(14);
    throw new OutOfBounds('fragmented length determinant');
  }

  /** An OCTET STRING with an unconstrained length. Unaligned PER, so the content starts at the current bit. */
  readOctetString(): Uint8Array {
    const length = this.readLength();
    if (this.position + length * 8 > this.data.length * 8) throw new OutOfBounds('octet string runs past the PDU');
    const out = new Uint8Array(length);
    for (let i = 0; i < length; i++) out[i] = this.read(8);
    return out;
  }

  /** Skips a SEQUENCE's extension additions: a normally-small count, a presence bitmap, and each as an open type. */
  skipExtensionAdditions(): void {
    if (this.read(1) !== 0) throw new OutOfBounds('large extension count');
    const count = this.read(6) + 1;
    let present = 0;
    for (let i = 0; i < count; i++) if (this.read(1) === 1) present++;
    for (let i = 0; i < present; i++) {
      if (this.read(1) !== 0) throw new OutOfBounds('long open type');
      this.position += this.read(7) * 8;
    }
  }
}
