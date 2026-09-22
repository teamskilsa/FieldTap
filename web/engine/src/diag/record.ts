// Port of android/diag Protocol.kt: the diag log packets FieldTap reads, and the qmdl2 container a handset
// wraps them in. Every multi-byte field is little-endian.

/** Asynchronous log packet, modem to host. */
export const DIAG_LOG_F = 0x10;
/** A qmdl2 container holding one or more DIAG_LOG_F packets. */
export const DIAG_MULTI_LOG_F = 0x98;
/** cmd, more, outer length, inner length, log code, timestamp. */
export const LOG_HEADER_LEN = 16;
/** The entry header inside a log packet: length, code, timestamp. */
export const LOG_ENTRY_HEADER_LEN = 12;
/** cmd, version, pad, packet count. */
export const MULTI_LOG_HEADER_LEN = 8;

/**
 * One log packet: its code, the modem's timestamp and the body the decoders read.
 *
 * `timestampRaw` is a bigint: the raw 64-bit value exactly, as Kotlin's Long and Python's int hold it. The goldens
 * print it as a 17-digit integer, beyond a double's 2^53, so a number would round it; and sorting, the D1
 * plausibility test and re-encoding all need the exact bits. Only TimeBase.modemMs turns it into a double.
 */
export interface LogRecord {
  /** The 16-bit log code, e.g. 0xB0C0 for LTE RRC OTA. */
  code: number;
  timestampRaw: bigint;
  body: Uint8Array;
  /** Non-zero when the modem split one logical record across packets. */
  more: number;
}

export class NotALogPacket extends Error {
  constructor() {
    super('not a log packet');
  }
}

const u16 = (d: Uint8Array, at: number) => d[at] | (d[at + 1] << 8);
const u32 = (d: Uint8Array, at: number) => (d[at] | (d[at + 1] << 8) | (d[at + 2] << 16) | (d[at + 3] << 24)) >>> 0;

/** The top nibble of a log code: which subsystem emitted it. */
export const equipId = (code: number) => (code >> 12) & 0xf;

export function hexCode(code: number): string {
  return '0x' + code.toString(16).toUpperCase().padStart(4, '0');
}

/**
 * The record in one DIAG_LOG_F packet. The inner length is trusted only when it agrees with the bytes that
 * arrived; a packet cut short keeps whatever it has rather than throwing, as the Python reader does.
 * `body` is a view into `payload`.
 */
export function parseLogPacket(payload: Uint8Array): LogRecord {
  if (payload.length < LOG_HEADER_LEN || payload[0] !== DIAG_LOG_F) throw new NotALogPacket();
  const innerLen = u16(payload, 4);
  const bodyLen = innerLen - LOG_ENTRY_HEADER_LEN;
  const available = payload.length - LOG_HEADER_LEN;
  const end = bodyLen >= 0 && bodyLen <= available ? LOG_HEADER_LEN + bodyLen : payload.length;
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  return {
    code: u16(payload, 6),
    timestampRaw: view.getBigUint64(8, true),
    body: payload.subarray(LOG_HEADER_LEN, end),
    more: payload[1],
  };
}

/**
 * Every DIAG_LOG_F packet inside a qmdl2 container, or none when `frame` is not one. The count is trusted only
 * as far as the bytes allow, and each packet is measured by its own length field.
 */
export function qmdl2LogPackets(frame: Uint8Array): Uint8Array[] {
  if (frame.length < MULTI_LOG_HEADER_LEN || frame[0] !== DIAG_MULTI_LOG_F) return [];
  const count = u32(frame, 4);
  const out: Uint8Array[] = [];
  let offset = MULTI_LOG_HEADER_LEN;
  while (offset + LOG_HEADER_LEN <= frame.length && (count === 0 || out.length < count)) {
    if (frame[offset] !== DIAG_LOG_F) break;
    const innerLen = u16(frame, offset + 4);
    if (innerLen < LOG_ENTRY_HEADER_LEN) break;
    // The 16-byte header plus the body; innerLen counts the 12-byte entry header and the body.
    const end = Math.min(offset + innerLen + 4, frame.length);
    out.push(frame.subarray(offset, end));
    offset = end;
  }
  return out;
}

/** The log packets in one unframed diag frame, bare or in a qmdl2 container. Anything else yields nothing. */
export function logPacketsOf(frame: Uint8Array): Uint8Array[] {
  if (frame.length === 0) return [];
  if (frame[0] === DIAG_LOG_F) return [frame];
  if (frame[0] === DIAG_MULTI_LOG_F) return qmdl2LogPackets(frame);
  return [];
}

/**
 * `record` as a DIAG_LOG_F packet, laid out as qdss_deframe.py writes it (struct '<BBHHHQ': 0x10, more, outer
 * length, inner length, code, timestamp, then the body; both lengths are 12 + body).
 */
export function encodeLogPacket(record: LogRecord): Uint8Array {
  const inner = LOG_ENTRY_HEADER_LEN + record.body.length;
  const out = new Uint8Array(4 + inner);
  const view = new DataView(out.buffer);
  out[0] = DIAG_LOG_F;
  out[1] = record.more;
  view.setUint16(2, inner, true);
  view.setUint16(4, inner, true);
  view.setUint16(6, record.code, true);
  view.setBigUint64(8, record.timestampRaw, true);
  out.set(record.body, LOG_HEADER_LEN);
  return out;
}
