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

// --------------------------------------------------------------------------------------- 0xB063 MAC DL transport
//
// 0xB063 LTE MAC DL Transport Block, packet v50 (0x32). The name is in MobileInsight's log-code table; SCAT
// publishes a v49/v50 layout, and it does not fit this modem (it gives transport-block sizes in the millions):
// both its header and its per-transport-block header sit 8 bytes earlier than what v50 emits here, and its 3-byte
// SDU descriptor has a different bit order. The layout below was re-derived and checked on the two iPhone 17
// captures (docs/research/iphone-named-log-codes.md).
//
//   header, 8 bytes: u8 version 0x32, 3 reserved, u32 transport-block count
//   per transport block, 16 bytes:
//     u32  +0  transport block size in BYTES     u32 +4  padding bytes
//     u32  +8  SFN bits 0-9, subframe bits 10-13
//     u8  +12  HARQ id bits 4-7, carrier bits 0-3
//     u8  +13  SDU count                        u16 +14  MAC header length in bytes
//   then per SDU a 12-byte descriptor whose first 3 bytes are a little-endian 24-bit word:
//     bit 0 = 1 for a MAC control element, bits 1-6 LCID (TS 36.321 6.2.1-1/-2), bits 7-22 length in bytes
//   and, for a data SDU, a PDCP tail of 8 x descriptor byte 9 bytes.
//
// Validated: every transport block the walk finds is a 0xB173 PDSCH transport block on (SFN, subframe, carrier,
// HARQ, size) in 968 of 978 (99.0%) and 2,518 of 2,521 (99.9%) - four independent fields have to be right at once
// for that. The descriptor bit order is confirmed by 3GPP's own fixed control-element sizes (LCID 28 reads length
// 6, the UE Contention Resolution Identity; LCID 27 reads 1, Activation/Deactivation); no other bit split gives
// both. The PDCP tail rule was measured, not guessed, over 2,176 single-SDU tails, and with the scan-forward
// fallback the walk still reaches only about 80% of the declared transport blocks - which is why the app must
// present this as accounting with an explicit coverage figure and keep 0xB173 as the throughput source.
//
// It does NOT give continuous timing advance: 0xB063 logs a control element's LCID and length, never its body, so
// the timing-advance command's 6-bit value is not in the record (and the network sent 2 in 22 s of driving).

/** One MAC SDU or control element inside a downlink transport block. */
export interface MacDlSdu {
  /** True for a MAC control element, false for a data SDU. */
  control: boolean;
  /** TS 36.321 table 6.2.1-1 (DL) LCID: 1-2 signalling, 3-10 user data, 26-31 control elements. */
  lcid: number;
  lengthBytes: number;
}

/** One downlink transport block as the MAC saw it. */
export interface MacDlTransportBlock {
  sizeBytes: number;
  paddingBytes: number;
  sfn: number;
  subframe: number;
  carrier: number;
  harq: number;
  /** Logged MAC header length; the size identity is off by one byte in half the records, so it is low confidence. */
  headerLength: number;
  sdus: MacDlSdu[];
}

/** One 0xB063 record: what it declared, what the walk recovered, and whether the walk ended on the last byte. */
export interface MacDlRecord {
  /** Transport blocks the record's own header declares. */
  declared: number;
  blocks: MacDlTransportBlock[];
  /** The walk consumed the body exactly and found every declared block. */
  exact: boolean;
  /** Times the walk lost the chain and had to scan forward for the next self-consistent header. */
  resynced: number;
}

export const B063_VERSION = 0x32;
const TB_HEADER_BYTES = 16;
const SDU_DESCRIPTOR_BYTES = 12;
/** TS 36.321 table 6.2.1-1: the downlink MAC control elements. */
export const DL_CONTROL_ELEMENTS: Readonly<Record<number, string>> = {
  26: 'Long DRX command',
  27: 'Activation/deactivation',
  28: 'Contention resolution identity',
  29: 'Timing advance command',
  30: 'DRX command',
  31: 'Padding',
};
/** The LCID of the timing-advance command, whose value 0xB063 does not carry. */
export const TIMING_ADVANCE_LCID = 29;
/** The largest LTE transport block, 75,376 bits (TS 36.213): a header claiming more is not a header. */
const MAX_TB_BYTES = 9422;

/** A candidate transport-block header, or null when it fails the self-consistency test the walk resynchronises on. */
function transportBlockHeader(b: Uint8Array, o: number): MacDlTransportBlock | null {
  if (!has(b, o, TB_HEADER_BYTES)) return null;
  const size = u32(b, o), padding = u32(b, o + 4), w = u32(b, o + 8);
  const carrierHarq = u8(b, o + 12), nSdu = u8(b, o + 13), headerLength = u16(b, o + 14);
  if (nSdu < 1 || nSdu > 8) return null;
  if (headerLength > 4 * nSdu + 4) return null;
  if (size === 0 || size > MAX_TB_BYTES || padding > size) return null;
  return {
    sizeBytes: size,
    paddingBytes: padding,
    sfn: w & 0x3ff,
    subframe: (w >>> 10) & 15,
    carrier: carrierHarq & 15,
    harq: (carrierHarq >> 4) & 15,
    headerLength,
    sdus: [],
  };
}

/** The transport blocks of one 0xB063 record. Any other version is a counted miss. */
export function decodeB063(b: Uint8Array): Decoded<MacDlRecord> {
  if (!has(b, 0, 1)) return malformed;
  if (b[0] !== B063_VERSION) return versionMiss('0xB063', `v${b[0]}`);
  if (!has(b, 0, 8)) return malformed;
  const declared = u32(b, 4);
  const blocks: MacDlTransportBlock[] = [];
  let pos = 8, resynced = 0;
  while (blocks.length < declared) {
    const tb = transportBlockHeader(b, pos);
    if (tb === null) {
      // The PDCP tail rule missed: look for the next self-consistent header that is also near in time.
      let next = -1;
      const last = blocks[blocks.length - 1];
      for (let q = pos; q + TB_HEADER_BYTES <= b.length; q += 4) {
        const candidate = transportBlockHeader(b, q);
        if (candidate && (!last || ((candidate.sfn - last.sfn + 1024) % 1024) <= 2)) {
          next = q;
          break;
        }
      }
      if (next < 0) break;
      resynced++;
      pos = next;
      continue;
    }
    const start = pos + TB_HEADER_BYTES, nSdu = u8(b, pos + 13);
    let tail = 0;
    for (let i = 0; i < nSdu; i++) {
      const p = start + SDU_DESCRIPTOR_BYTES * i;
      if (!has(b, p, 3)) break;
      const w = b[p] | (b[p + 1] << 8) | (b[p + 2] << 16);
      tb.sdus.push({ control: (w & 1) === 1, lcid: (w >>> 1) & 0x3f, lengthBytes: (w >>> 7) & 0xffff });
      // A data SDU is followed by a PDCP tail of 8 x descriptor byte 9 bytes (measured, not guessed).
      if (has(b, p, SDU_DESCRIPTOR_BYTES)) tail += 8 * b[p + 9];
    }
    blocks.push(tb);
    pos = start + SDU_DESCRIPTOR_BYTES * nSdu + tail;
  }
  return value({ declared, blocks, exact: pos === b.length && blocks.length === declared, resynced });
}

/** True when the transport block carried a timing-advance command (TS 36.321 6.1.3.5); its value is not logged. */
export const hasTimingAdvanceCommand = (tb: MacDlTransportBlock): boolean =>
  tb.sdus.some((s) => s.control && s.lcid === TIMING_ADVANCE_LCID);

/**
 * Whether an LCID is signalling (a DCCH), user data (a DTCH), a control element or the broadcast channel, per TS
 * 36.321 table 6.2.1-1. Downlink LCIDs 11-26 are reserved and anything above 31 is outside the subheader's own
 * 5-bit field, so those are reported as 'other' rather than counted as user data: they are the walk's own
 * uncertainty showing (a handful of SDUs per capture), and they must not inflate the data share.
 */
export function dlChannelKind(sdu: MacDlSdu): 'signalling' | 'data' | 'control' | 'broadcast' | 'other' {
  if (sdu.control) return 'control';
  if (sdu.lcid === 0) return 'broadcast';
  if (sdu.lcid <= 2) return 'signalling';
  return sdu.lcid <= 10 ? 'data' : 'other';
}
