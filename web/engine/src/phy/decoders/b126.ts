// 0xB126 LTE LL1 PDSCH Demapper Configuration, v163 (this modem). Public name from the Qualcomm log-code tables;
// no published layout was found, so the whole layout was derived on the two iPhone 17 captures and each field had
// to pass a check (docs/research/iphone-named-log-codes.md).
//
// The body is always exactly 968 bytes: an 8-byte header (u8 version 163, then 7 bytes that never change) and 20
// fixed 48-byte sub-records, one per logged subframe, OLDEST FIRST. Only the last sub-record is "now": its (SFN,
// subframe) matches the record's own DIAG timestamp with circular R = 1.00000 and a standard deviation of 0.12 ms,
// the tightest timing in either capture, which is what fixed the sub-record size, the count and the order.
//
// Sub-record, 48 bytes:
//   u16  +0        SFN bits 4-13, subframe bits 0-3
//   u8   +2 bits 1-3   transmit antenna ports of the cell (2 or 4 seen)
//           bits 4-5   receive antennas - 1 (0 -> 1, 1 -> 2, 3 -> 4)
//   u8   +4 bits 0-1   rank - 1 (spatial layers of this PDSCH)
//   7 B  +8        PDSCH resource-block allocation bitmap, bit k = PRB k (50 bits on a 50-PRB cell)
//   7 B +24        the same bitmap again (identical in 3,599 of 3,600 sub-records)
//   +5, +7, +40, +41   not identified, not read; +15..23, +31..39, +42..47 are zero on this modem
//
// Validated: popcount(bitmap) is an N_RB 0xB173 reports for the same subframe in 99.5% / 99.7%; rank equals
// 0xB173's layer count in 97.3% / 97.0%, and 99.9% / 100.0% counting the transmit-diversity subframes where
// 0xB173 says "4 layers, 1 transport block" and rank 1 is the correct reading; transmit antenna ports equal the
// 0xB0C1 MIB's antenna count for every cell whose MIB was captured, and follow the serving cell rather than the
// scheduling, which is why the field is an antenna-port count and not the transmission mode. Receive antennas
// agree with the Rx antennas 0xB193 measured in 88% / 93% only, so that field is medium confidence.

import { bits, type Decoded, has, malformed, u16, u8, value, versionMiss } from './bytes.ts';

/** One logged subframe of PDSCH demapper configuration. */
export interface PdschDemapperSubframe {
  sfn: number;
  subframe: number;
  /** Transmit antenna ports of the serving cell (1, 2 or 4): the measured answer to "how many antennas". */
  txAntennas: number;
  /** Receive antennas the phone had in use (medium confidence: 88% / 93% against 0xB193). */
  rxAntennas: number;
  /** Spatial layers of this PDSCH (1-4). */
  rank: number;
  /** The PRB allocation bitmap, low word first: bit k of word w is PRB 32w + k. */
  prbMask: number[];
  /** popcount(prbMask): the PRB count, derived from the bitmap rather than read from a second field. */
  nPrb: number;
}

export const B126_VERSION = 163;
const BODY_BYTES = 968;
const HEADER_BYTES = 8;
const SUB_BYTES = 48;
export const B126_SUBFRAMES = 20;
/** 0 -> 1 Rx, 1 -> 2 Rx, 2 -> 3 Rx, 3 -> 4 Rx. */
const RX_ANTENNAS = [1, 2, 3, 4];

const popcount = (w: number): number => {
  let n = 0;
  for (let x = w >>> 0; x !== 0; x >>>= 1) n += x & 1;
  return n;
};

/** The 20 logged subframes, oldest first. Any other version is a counted miss; any other length is malformed. */
export function decodeB126(b: Uint8Array): Decoded<PdschDemapperSubframe[]> {
  if (!has(b, 0, 1)) return malformed;
  if (b[0] !== B126_VERSION) return versionMiss('0xB126', `v${b[0]}`);
  // The body is fixed at 968 bytes on this modem, so a different length is not a layout to guess at.
  if (b.length !== BODY_BYTES) return malformed;
  const out: PdschDemapperSubframe[] = [];
  for (let k = 0; k < B126_SUBFRAMES; k++) {
    const o = HEADER_BYTES + SUB_BYTES * k;
    const w = u16(b, o), antennas = u8(b, o + 2);
    // 7 bytes of bitmap as two 32-bit words: PRB 0-31 and PRB 32-55.
    const lo = (b[o + 8] | (b[o + 9] << 8) | (b[o + 10] << 16) | (b[o + 11] << 24)) >>> 0;
    const hi = (b[o + 12] | (b[o + 13] << 8) | (b[o + 14] << 16)) >>> 0;
    out.push({
      sfn: bits(w, 4, 10),
      subframe: w & 15,
      txAntennas: bits(antennas, 1, 3),
      rxAntennas: RX_ANTENNAS[bits(antennas, 4, 2)],
      rank: bits(u8(b, o + 4), 0, 2) + 1,
      prbMask: [lo, hi],
      nPrb: popcount(lo) + popcount(hi),
    });
  }
  return value(out);
}

/** The subframe number a sub-record's (SFN, subframe) names: SFN x 10 + subframe, the record's own TTI. */
export const b126Tti = (s: PdschDemapperSubframe): number => s.sfn * 10 + s.subframe;
