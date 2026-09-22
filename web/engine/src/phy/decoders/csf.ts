// LTE channel state feedback, v164 of both records:
// - 0xB14E LL1 PUSCH CSF (aperiodic): the MobileInsight v142 bit order for the first two words, validated on the
//   iPhone 17 capture (Tx mode = RRC tm4; 9 subbands of 6 PRB for 50 PRB; RI against 0xB173).
// - 0xB14D LL1 PUCCH CSF (periodic): the first word in the v142 order; after byte 5 v164 differs from v142 and the
//   CQI/PMI/RI positions were re-derived (they agree with 0xB14E at the same moments), hence medium confidence.

import { bits, type Decoded, has, malformed, u16, u32, u8, value, versionMiss } from './bytes.ts';

export const CSF_VERSION = 164;

/** One aperiodic CSI report: wideband CQI per codeword, rank and PMI, and the transmission mode. */
export interface PuschCsf {
  sfn: number;
  subframe: number;
  carrier: number;
  ri: number;
  cqiCw0: number;
  cqiCw1: number;
  widebandPmi: number;
  txMode: number;
}

/** u32 @1: SF 4b, SFN 10b @4, carrier 4b @14, SCell 5b @18, mode 3b @24, RI-1 2b @28; u32 @5: WB CQI CW0 4b @7,
 *  CW1 4b @11, WB PMI 4b @24; byte 9 low nibble = transmission mode. */
export function decodeB14E(b: Uint8Array): Decoded<PuschCsf> {
  if (!has(b, 0, 1)) return malformed;
  if (b[0] !== CSF_VERSION) return versionMiss('0xB14E', `v${b[0]}`);
  if (!has(b, 0, 10)) return malformed;
  const a = u32(b, 1), c = u32(b, 5);
  return value({
    sfn: bits(a, 4, 10),
    subframe: bits(a, 0, 4),
    carrier: bits(a, 14, 4),
    ri: bits(a, 28, 2) + 1,
    cqiCw0: bits(c, 7, 4),
    cqiCw1: bits(c, 11, 4),
    widebandPmi: bits(c, 24, 4),
    txMode: u8(b, 9) & 15,
  });
}

/** One periodic CSI report. Report type 3 carries RI; types 2 and 4 carry wideband CQI and PMI. */
export interface PucchCsf {
  sfn: number;
  subframe: number;
  carrier: number;
  reportType: number;
  ri?: number;
  cqiCw0?: number;
  cqiCw1?: number;
  widebandPmi?: number;
  txMode: number;
}

/** u32 @1: SF, SFN, carrier 4b @14, SCell, mode 2b @24, report type 4b @26; u16 @6: CQI CW0 bits 4-7, CW1 bits
 *  8-11, WB PMI bits 12-15; u16 @8 low nibble = Tx mode; u16 @10 bits 8-9 = RI-1. */
export function decodeB14D(b: Uint8Array): Decoded<PucchCsf> {
  if (!has(b, 0, 1)) return malformed;
  if (b[0] !== CSF_VERSION) return versionMiss('0xB14D', `v${b[0]}`);
  if (!has(b, 0, 14)) return malformed;
  const a = u32(b, 1), q = u16(b, 6), r = u16(b, 10);
  const reportType = bits(a, 26, 4);
  const report: PucchCsf = { sfn: bits(a, 4, 10), subframe: bits(a, 0, 4), carrier: bits(a, 14, 4), reportType, txMode: u16(b, 8) & 15 };
  if (reportType === 3) {
    report.ri = ((r >> 8) & 3) + 1;
  } else if (reportType === 2 || reportType === 4) {
    report.cqiCw0 = (q >> 4) & 15;
    report.cqiCw1 = (q >> 8) & 15;
    report.widebandPmi = (q >> 12) & 15;
  }
  return value(report);
}
