// Port of android/diag Hdlc.kt / fieldtap/diag/hdlc.py: the framing Qualcomm's diag protocol uses on the wire
// and in a .qmdl file. Byte-for-byte compatible with both, because a rebuilt qmdl must hash the same as the
// Python deframer's.
//
// A frame is escape(payload || crc16_le(payload)) || 0x7E, with no leading flag. 0x7D and 0x7E inside are sent
// as 0x7D, byte ^ 0x20. The CRC is CRC-16/X-25 (reflected 0x1021, init 0xFFFF, xorout 0xFFFF), so a frame
// including its own CRC checks to GOOD_CRC.

export const FLAG = 0x7e;
export const ESCAPE = 0x7d;
const ESCAPE_MASK = 0x20;

/** What crc16 returns over a buffer that already ends in its own correct CRC. */
export const GOOD_CRC = 0x0f47;

const TABLE = (() => {
  const t = new Uint16Array(256);
  for (let byte = 0; byte < 256; byte++) {
    let crc = byte;
    for (let k = 0; k < 8; k++) crc = crc & 1 ? (crc >>> 1) ^ 0x8408 : crc >>> 1;
    t[byte] = crc;
  }
  return t;
})();

/** CRC-16/X-25 over data[from, to). crc16('123456789') == 0x906E pins the whole table. */
export function crc16(data: Uint8Array, from = 0, to = data.length): number {
  let crc = 0xffff;
  for (let i = from; i < to; i++) crc = (crc >>> 8) ^ TABLE[(crc ^ data[i]) & 0xff];
  return ~crc & 0xffff;
}

/** `payload` as a complete frame: payload, CRC, trailing flag, with escaping applied. */
export function hdlcEncode(payload: Uint8Array): Uint8Array {
  const crc = crc16(payload);
  let escapes = 0;
  for (let i = 0; i < payload.length; i++) if (payload[i] === FLAG || payload[i] === ESCAPE) escapes++;
  const crcBytes = [crc & 0xff, crc >>> 8];
  for (const b of crcBytes) if (b === FLAG || b === ESCAPE) escapes++;
  const out = new Uint8Array(payload.length + 2 + escapes + 1);
  let n = 0;
  const put = (b: number) => {
    if (b === FLAG || b === ESCAPE) {
      out[n++] = ESCAPE;
      out[n++] = b ^ ESCAPE_MASK;
    } else {
      out[n++] = b;
    }
  };
  for (let i = 0; i < payload.length; i++) put(payload[i]);
  put(crcBytes[0]);
  put(crcBytes[1]);
  out[n++] = FLAG;
  return out;
}

/** data[from, to) with escapes resolved. A trailing lone escape is dropped, as in Hdlc.kt. */
export function unescape(data: Uint8Array, from = 0, to = data.length): Uint8Array {
  const out = new Uint8Array(to - from);
  let n = 0;
  for (let i = from; i < to; i++) {
    const b = data[i];
    if (b === ESCAPE) {
      if (i + 1 >= to) break;
      out[n++] = data[++i] ^ ESCAPE_MASK;
    } else {
      out[n++] = b;
    }
  }
  return out.subarray(0, n);
}

/**
 * Splits a byte stream into frame payloads, keeping whatever is incomplete until more arrives.
 *
 * `feed` may be called with any split of the stream and yields the same frames either way. Frames whose CRC
 * fails are counted in `crcErrors` and dropped rather than thrown: one corrupt frame must not end a capture.
 */
export class Unframer {
  private buffer = new Uint8Array(4096);
  private length = 0;
  /** Frames dropped because their CRC did not check (or were shorter than a CRC). */
  crcErrors = 0;
  /** Frames that checked. */
  frames = 0;

  /** Bytes held for a frame that has not ended yet. */
  get pending(): number {
    return this.length;
  }

  /** Calls `onFrame` with each complete payload in `data`, in order. The payload is a fresh copy. */
  feed(data: Uint8Array, onFrame: (payload: Uint8Array) => void): void {
    let start = 0;
    for (let i = 0; i < data.length; i++) {
      if (data[i] !== FLAG) continue;
      if (this.length > 0) {
        this.append(data, start, i);
        this.emit(this.buffer, 0, this.length, onFrame);
        this.length = 0;
      } else if (i > start) {
        this.emit(data, start, i, onFrame);
      }
      start = i + 1;
    }
    if (start < data.length) this.append(data, start, data.length);
  }

  private append(data: Uint8Array, from: number, to: number): void {
    const need = this.length + (to - from);
    if (need > this.buffer.length) {
      const grown = new Uint8Array(Math.max(need, this.buffer.length * 2));
      grown.set(this.buffer.subarray(0, this.length));
      this.buffer = grown;
    }
    this.buffer.set(data.subarray(from, to), this.length);
    this.length = need;
  }

  private emit(src: Uint8Array, from: number, to: number, onFrame: (payload: Uint8Array) => void): void {
    const raw = unescape(src, from, to);
    if (raw.length < 3 || crc16(raw) !== GOOD_CRC) {
      this.crcErrors++;
      return;
    }
    this.frames++;
    onFrame(raw.subarray(0, raw.length - 2));
  }
}
