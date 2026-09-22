// LTE MAC records (SCAT field orders, facts only, re-derived for this modem's versions):
// - 0xB064 MAC UL Transport Block, packet v1 with subpacket 0x08 v7: per sample the cell id, then the SCAT v1
//   order, then the MAC PDU's header bytes, whose subheaders and control elements are parsed per TS 36.321 6.1.2.
// - 0xB062 MAC RACH Attempt, packet v1 with subpacket 0x06 v50, validated by the UL EARFCNs of the target cells
//   and the preamble target power (= SIB2's).

import { type Decoded, has, i16, malformed, u16, u32, u8, value, versionMiss } from './bytes.ts';

export interface ControlElement {
  /** UL LCID (TS 36.321 table 6.2.1-2): 26 PHR, 27 C-RNTI, 28 truncated, 29 short, 30 long BSR. */
  lcid: number;
  payload: Uint8Array;
}

/** One uplink MAC transport block: its grant and the MAC control elements it carried (the PHR among them). */
export interface MacUlSample {
  carrier: number;
  harq: number;
  rntiType: number;
  sfn: number;
  subframe: number;
  grantBytes: number;
  paddingBytes: number;
  headerLength: number;
  controlElements: ControlElement[];
  /** The subheaders and CEs consumed exactly `headerLength` bytes: the layout check. */
  headerConsistent: boolean;
}

export const B064_VERSION = 1;
const B064_SUBPACKET = 0x08;
const B064_SUBPACKET_VERSION = 7;
const SAMPLE_HEADER_BYTES = 13;

/**
 * 4-byte packet header; subpackets of (id, version, u16 size including this header); subpacket 0x08: u8 sample
 * count, then per sample u8 cell, u8 HARQ, u8 RNTI type, u16 SFN<<4|SF, u16 grant, u8 RLC PDUs, u16 padding, u8
 * BSR event, u8 BSR trigger, u8 header length, and the header bytes.
 */
export function decodeB064(b: Uint8Array): Decoded<MacUlSample[]> {
  if (!has(b, 0, 2)) return malformed;
  if (b[0] !== B064_VERSION) return versionMiss('0xB064', `v${b[0]}`);
  const out: MacUlSample[] = [];
  let pos = 4;
  for (let s = 0; s < b[1]; s++) {
    if (!has(b, pos, 4)) return malformed;
    const id = u8(b, pos), ver = u8(b, pos + 1), size = u16(b, pos + 2);
    if (size < 4) return malformed;
    const body = pos + 4, end = Math.min(pos + size, b.length);
    pos += size;
    if (id !== B064_SUBPACKET) continue;
    if (ver !== B064_SUBPACKET_VERSION) return versionMiss('0xB064', `v1/0x08 v${ver}`);
    if (body >= end) continue;
    let p = body + 1;
    for (let k = 0; k < b[body]; k++) {
      if (p + SAMPLE_HEADER_BYTES > end) break;
      const sfnWord = u16(b, p + 3), headerLength = u8(b, p + 12);
      const header = b.subarray(p + SAMPLE_HEADER_BYTES, Math.min(p + SAMPLE_HEADER_BYTES + headerLength, end));
      const { ces, used } = controlElements(header);
      out.push({
        carrier: u8(b, p),
        harq: u8(b, p + 1),
        rntiType: u8(b, p + 2),
        sfn: sfnWord >> 4,
        subframe: sfnWord & 15,
        grantBytes: u16(b, p + 5),
        paddingBytes: u16(b, p + 8),
        headerLength,
        controlElements: ces,
        headerConsistent: used === headerLength,
      });
      p += SAMPLE_HEADER_BYTES + headerLength;
    }
  }
  return value(out);
}

/** Fixed-size UL MAC CEs by LCID: PHR, C-RNTI, truncated, short and long BSR. */
const FIXED_CE_BYTES: Record<number, number> = { 26: 1, 27: 2, 28: 1, 29: 1, 30: 3 };

/** Walks the subheaders (R/F2/E/LCID, then F/L for SDUs and the variable CEs) until E = 0, then the CEs in
 *  subheader order. Returns the CEs and the bytes consumed. */
export function controlElements(h: Uint8Array): { ces: ControlElement[]; used: number } {
  const subheaders: { lcid: number; length: number | null }[] = [];
  let i = 0;
  while (i < h.length) {
    const x = h[i], extends_ = ((x >> 5) & 1) === 1, lcid = x & 31;
    i++;
    let length: number | null = null;
    if ((lcid <= 10 || lcid === 24 || lcid === 25) && extends_) {
      if (i >= h.length) break;
      if (h[i] >> 7 === 1) {
        if (i + 1 >= h.length) break;
        length = ((h[i] & 0x7f) << 8) | h[i + 1];
        i += 2;
      } else {
        length = h[i] & 0x7f;
        i += 1;
      }
    }
    subheaders.push({ lcid, length });
    if (!extends_) break;
  }
  const ces: ControlElement[] = [];
  for (const s of subheaders) {
    const n = FIXED_CE_BYTES[s.lcid] ?? (s.lcid === 24 || s.lcid === 25 ? s.length : null);
    if (n === null) continue;
    ces.push({ lcid: s.lcid, payload: h.slice(Math.min(i, h.length), Math.min(i + n, h.length)) });
    i += n;
  }
  return { ces, used: i };
}

/** The power headroom of a PHR CE (LCID 26): PH index - 23, the lower edge of its 1 dB bin (TS 36.133 9.1.8.4). */
export function powerHeadroomDb(s: MacUlSample): number | null {
  const ce = s.controlElements.find((c) => c.lcid === 26 && c.payload.length > 0);
  return ce ? (ce.payload[0] & 63) - 23 : null;
}

/** One random-access attempt: the preamble, its target power and the timing advance of the response. */
export interface RachAttempt {
  cell: number;
  attempts: number;
  result: number;
  contention: number;
  preamble: number;
  preambleTargetDbm: number;
  /** The RAR's timing advance, when the message bitmask says Msg2 was received. */
  taRar: number | null;
  ulEarfcn: number;
}

export const B062_VERSION = 1;
const B062_SUBPACKET = 0x06;
const B062_SUBPACKET_VERSION = 50;
const B062_MIN_BODY = 41;

/**
 * 4-byte packet header; subpackets of (id, version, u16 size excluding this header). Subpacket 0x06: u8 id, cell,
 * attempts, result, contention, message bitmask @0-5; Msg1 @6: u8 preamble, u8 mask, s16 target power; Msg2 @13:
 * u16 backoff, u8 result, u16 TC-RNTI, u16 TA @18; u32 UL EARFCN @37.
 */
export function decodeB062(b: Uint8Array): Decoded<RachAttempt[]> {
  if (!has(b, 0, 2)) return malformed;
  if (b[0] !== B062_VERSION) return versionMiss('0xB062', `v${b[0]}`);
  const out: RachAttempt[] = [];
  let pos = 4;
  for (let s = 0; s < b[1]; s++) {
    if (!has(b, pos, 4)) return malformed;
    const id = u8(b, pos), ver = u8(b, pos + 1), size = u16(b, pos + 2);
    const body = pos + 4;
    pos = body + size;
    if (id !== B062_SUBPACKET) continue;
    if (ver !== B062_SUBPACKET_VERSION) return versionMiss('0xB062', `v1/0x06 v${ver}`);
    if (size < B062_MIN_BODY || !has(b, body, B062_MIN_BODY)) return malformed;
    const mask = u8(b, body + 5);
    out.push({
      cell: u8(b, body + 1),
      attempts: u8(b, body + 2),
      result: u8(b, body + 3),
      contention: u8(b, body + 4),
      preamble: u8(b, body + 6),
      preambleTargetDbm: i16(b, body + 8),
      taRar: mask & 2 ? u16(b, body + 18) : null,
      ulEarfcn: u32(b, body + 37),
    });
  }
  return value(out);
}
