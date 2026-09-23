// 0xB16C LTE ML1 DCI Information Report, v50 (this modem): the scheduler's own decisions at 1 ms resolution.
// Layout derived and checked on the two iPhone 17 captures (docs/research/iphone-named-log-codes.md).
//
//   header, 4 bytes: u8 version 50; element count = bits 6-11 of the u16 at +1, saturating at 20
//   then `count` elements, each a u32 followed by its records:
//     u32  +0   SFN bits 0-9, subframe bits 10-13, uplink grants bits 14-15, downlink assignments bits 17-19
//     then (uplink grants) x 16 bytes, then (downlink assignments) x 8 bytes
//   uplink grant, 16 bytes:
//     bits 43-49  start RB      bits 50-56  number of RBs      bits 32-34 (byte +4 bits 0-2)  modulation
//
// The flag-driven chain consumes 495 of 495 bodies exactly, and the two record kinds were identified by *when*
// they land, which is the cleanest proof available: the 8-byte records fall on a subframe where 0xB173 logged a
// PDSCH in 99.4% / 99.6% (downlink assignments), and the 16-byte records fall exactly four subframes before an
// 0xB139 PUSCH report in 97.7% / 99.6% - FDD's textbook n+4 uplink-grant timing, where every other shift from 0
// to 8 scores at the base rate. The grant's own fields then agree with 0xB139's for the same subframe in 99.96%
// and 99.98% of 2,751 and 4,744 one-to-one matches.
//
// The 8-byte downlink assignment's CONTENTS are deliberately not decoded: the bytes are nearly constant and the
// best field anywhere in them matches 0xB173's MCS in 31%/16%, N_RB at chance level, TBS in 1%/5% and HARQ in
// 14%, in both bit orders. Only the per-subframe count is read from them.

import { type Decoded, has, malformed, u32, u8, value, versionMiss } from './bytes.ts';

/** One uplink grant the PDCCH carried. */
export interface UplinkGrant {
  startRb: number;
  nRb: number;
  /** Modulation as the grant codes it (0 = QPSK, 1 = 16QAM, 2 = 64QAM on this modem's PUSCH). */
  modulation: number;
}

/** One subframe of PDCCH decoding: the grants and how many downlink assignments came with them. */
export interface DciSubframe {
  sfn: number;
  subframe: number;
  /** SFN x 10 + subframe. */
  tti: number;
  uplinkGrants: UplinkGrant[];
  /** Downlink assignments in this subframe: counted, contents not decoded. */
  downlinkAssignments: number;
}

/** One 0xB16C record. `exact` is false when the element chain did not consume the body. */
export interface DciRecord {
  declared: number;
  subframes: DciSubframe[];
  exact: boolean;
}

export const B16C_VERSION = 50;
const GRANT_BYTES = 16;
const ASSIGNMENT_BYTES = 8;

/** The subframes of one 0xB16C record. Any other version is a counted miss, never guessed at. */
export function decodeB16C(b: Uint8Array): Decoded<DciRecord> {
  if (!has(b, 0, 1)) return malformed;
  if (b[0] !== B16C_VERSION) return versionMiss('0xB16C', `v${b[0]}`);
  if (!has(b, 0, 4)) return malformed;
  const declared = ((b[1] >> 6) | (b[2] << 2)) & 0x3f;
  const subframes: DciSubframe[] = [];
  let pos = 4;
  while (subframes.length < declared && has(b, pos, 4)) {
    const w = u32(b, pos);
    const grants = (w >>> 14) & 3, assignments = (w >>> 17) & 7;
    let p = pos + 4;
    const uplinkGrants: UplinkGrant[] = [];
    for (let i = 0; i < grants; i++) {
      const g = p + GRANT_BYTES * i;
      if (!has(b, g, GRANT_BYTES)) return value({ declared, subframes, exact: false });
      uplinkGrants.push({
        startRb: (u32(b, g + 5) >>> 3) & 0x7f,
        nRb: (u32(b, g + 6) >>> 2) & 0x7f,
        modulation: u8(b, g + 4) & 7,
      });
    }
    p += GRANT_BYTES * grants + ASSIGNMENT_BYTES * assignments;
    if (p > b.length) return value({ declared, subframes, exact: false });
    const sfn = w & 0x3ff, subframe = (w >>> 10) & 15;
    subframes.push({ sfn, subframe, tti: sfn * 10 + subframe, uplinkGrants, downlinkAssignments: assignments });
    pos = p;
  }
  return value({ declared, subframes, exact: pos === b.length && subframes.length === declared });
}
