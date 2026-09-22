// Layer 3 of qdss_deframe.py: the DIAG packets inside a gathered message.
//   98 01 00 00 <u32 n> + n packets                 a container, usually of one 10 00 log packet
//   10 00 LL LL LL LL CC CC ts8 body                 plain DIAG_LOG_F
//   9e 01 c2 00 + 16 bytes + LL LL CC CC ts8 body    'secure' log: the header is clear, the body encrypted
//   79 / 99 / 60 / 9d                                extended message, QSR4 F3, event, command: counted only
//   LL LL CC CC ts8 body                             a bare log entry, its length the packet's

export type PacketForm = 'plain' | 'multi98';

export interface Packet {
  /** 'log', 'bare', 'secure', 'log_bad', 'extmsg_0x79', 'other_0x26', ...: the Python's packet counter keys. */
  kind: string;
  /** For log, bare and secure packets: the log code, where the 8-byte timestamp is, and where the body starts. */
  code: number;
  tsAt: number;
  bodyAt: number;
}

const u16 = (d: Uint8Array, at: number) => d[at] | (d[at + 1] << 8);
const u32 = (d: Uint8Array, at: number) => (d[at] | (d[at + 1] << 8) | (d[at + 2] << 16) | (d[at + 3] << 24)) >>> 0;

const COUNTED: Record<number, string> = { 0x79: 'extmsg_0x79', 0x99: 'qsr4_0x99', 0x60: 'event_0x60', 0x9d: 'cmd_0x9d' };

/** Each packet of `msg` (split_packets). A container's count is trusted only while log packets fit. */
export function splitPackets(msg: Uint8Array, each: (form: PacketForm, packet: Uint8Array) => void): void {
  if (msg.length >= 8 && msg[0] === 0x98 && msg[1] === 0x01 && msg[2] === 0x00 && msg[3] === 0x00) {
    const n = u32(msg, 4);
    let off = 8, seen = 0;
    while (off < msg.length && (seen < n || n === 0)) {
      if (msg[off] === 0x10 && off + 16 <= msg.length) {
        const len = u16(msg, off + 2);
        each('multi98', msg.subarray(off, off + 4 + len));
        off += 4 + len;
      } else {
        each('multi98', msg.subarray(off));
        break;
      }
      seen++;
    }
    return;
  }
  each('plain', msg);
}

const packet = (kind: string, code = 0, tsAt = 0, bodyAt = 0): Packet => ({ kind, code, tsAt, bodyAt });

/** What a packet is (classify). Only the length fields are checked: a log whose lengths disagree is 'log_bad'. */
export function classify(p: Uint8Array): Packet {
  if (p.length === 0) return packet('empty');
  const c = p[0];
  if (c === 0x10) {
    if (p.length >= 16) {
      const outer = u16(p, 2), inner = u16(p, 4);
      if (outer === inner && inner === p.length - 4) return packet('log', u16(p, 6), 8, 16);
    }
    return packet('log_bad');
  }
  if (c === 0x9e && p[1] === 0x01 && p[2] === 0xc2 && p[3] === 0x00 && p.length >= 32) {
    if (u16(p, 20) === p.length - 20) return packet('secure', u16(p, 22), 24, 32);
    return packet('secure_bad');
  }
  const counted = COUNTED[c];
  if (counted) return packet(counted);
  if (p.length >= 12) {
    const code = u16(p, 2);
    if (u16(p, 0) === p.length && code !== 0) return packet('bare', code, 4, 12);
  }
  return packet('other_0x' + c.toString(16).padStart(2, '0'));
}

/** The 64-bit timestamp at `at`, as its two 32-bit halves. */
export const tsHi = (p: Uint8Array, at: number) => u32(p, at + 4);
export const tsLo = (p: Uint8Array, at: number) => u32(p, at);
