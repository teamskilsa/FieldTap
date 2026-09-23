// 0xB12A LTE LL1 PCFICH Decoding Results, v161 (this modem). Derived and checked on the two iPhone 17 captures
// (docs/research/iphone-named-log-codes.md).
//
//   header, 16 bytes: u8 version 161; u16 +4 bits 0-9 = SFN (circular R = 0.99854 / 0.99985); +6..15 always zero
//   then 20 fixed 8-byte elements, one per subframe, so a record covers two radio frames:
//     u16  +0   rolling element index 0..19
//     u8   +2   decoded flag: 1 = the PCFICH was decoded, 0 = nothing logged for this subframe
//     u8   +3   4 x CFI: only 0x04, 0x08, 0x0C and 0x00 occur across all 32,140 and 26,680 elements, i.e. CFI in
//               {1, 2, 3} - exactly the legal set for a 50-PRB cell, never the 4 that only 1.4 MHz cells use -
//               and 0 in precisely the elements whose decode flag is 0, with no exceptions in either capture
//     u16  +4   bits 8-11 = subframe
//
// Which of the two radio frames the header SFN names could not be settled (10 ms is below the timestamp's
// discriminating power), and the CFI could not be corroborated against this phone's own DCI count from 0xB16C
// (r about 0.00) - which is expected, since the control region is sized for the whole cell rather than for one
// phone. So the CFI is corroborated structurally, and the value is the cell's control-channel load: the first
// network-load indicator in FieldTap that does not depend on the phone's own traffic (CFI 3 on 30% of subframes
// while driving against 6% while stationary).

import { type Decoded, has, malformed, u16, u8, value, versionMiss } from './bytes.ts';

/** One subframe's PCFICH result. */
export interface PcfichSubframe {
  /** Rolling element index 0..19 inside the record. */
  index: number;
  subframe: number;
  /** The PCFICH was decoded in this subframe. */
  decoded: boolean;
  /** Control-format indicator 1-3: PDCCH symbols in this subframe. Null when nothing was decoded. */
  cfi: number | null;
  /** The field holds 4 x CFI with CFI in {1, 2, 3}, and zero exactly when the decode flag is zero. This is the
   *  structural identity the runtime check counts: it held for all 58,820 elements of the two captures. */
  consistent: boolean;
}

/** One 0xB12A record: the SFN its header names and its 20 subframes. */
export interface PcfichRecord {
  sfn: number;
  subframes: PcfichSubframe[];
}

export const B12A_VERSION = 161;
const BODY_BYTES = 176;
const HEADER_BYTES = 16;
const ELEMENT_BYTES = 8;
export const B12A_SUBFRAMES = 20;

/** The 20 subframes of one 0xB12A record. Any other version is a counted miss; the body is a fixed 176 bytes. */
export function decodeB12A(b: Uint8Array): Decoded<PcfichRecord> {
  if (!has(b, 0, 1)) return malformed;
  if (b[0] !== B12A_VERSION) return versionMiss('0xB12A', `v${b[0]}`);
  if (b.length !== BODY_BYTES) return malformed;
  const subframes: PcfichSubframe[] = [];
  for (let k = 0; k < B12A_SUBFRAMES; k++) {
    const o = HEADER_BYTES + ELEMENT_BYTES * k;
    const raw = u8(b, o + 3), decoded = u8(b, o + 2) === 1;
    // The field is 4 x CFI; anything that is not 4, 8 or 12 is not a CFI and is not reported as one.
    const legal = raw === 4 || raw === 8 || raw === 12;
    subframes.push({
      index: u16(b, o),
      subframe: (u16(b, o + 4) >> 8) & 15,
      decoded,
      cfi: legal ? raw >> 2 : null,
      consistent: raw === 0 ? !decoded : legal && decoded,
    });
  }
  return value({ sfn: u16(b, 4) & 0x3ff, subframes });
}
