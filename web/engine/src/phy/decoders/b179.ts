// 0xB179 LTE ML1 Connected Mode Intra-Frequency Measurement Results, v56 (this modem). The public name comes from
// SCAT's log-code table; the layout was derived on the two iPhone 17 captures
// (docs/research/iphone-named-log-codes.md). FieldTap's Python registry called the record "version dependent and
// bit packed"; on v56 it is not bit packed at all.
//
//   u8   +0   version 56
//   3 B  +1   reserved
//   u32  +4   0, 9, 18 or 27 on this modem: not identified (it is not the neighbour count)
//   u32  +8   EARFCN of this measurement
//   u16 +12   serving PCI
//   u16 +14   TTI = SFN * 10 + subframe
//   u16 +16   serving RSRP, x * 0.0625 - 180 dBm     u16 +18  the same value again
//   u16 +20   serving RSRQ, x * 0.0625 - 30 dB       u16 +22  the same value again
//   u32 +24   neighbour count n
//   then n x 12 bytes: u16 PCI @0, u16 RSRP @2 (again @4), u16 RSRQ @6 (again @8), u16 zero @10
//
// The paired fields are the instantaneous and the filtered value and are equal in every record of both captures,
// so only one is returned.
//
// These records carry NO DIAG timestamp: all 385 and all 373 arrive stamped zero. The TTI at +14 is the time
// source instead (extract.ts turns it into absolute time with the capture's own measured frame-to-log latency):
// against the interpolated time it scores circular R = 1.00000 / 0.99999 with a mean offset of 1,438 / 1,669 ms,
// the same constant every other log code in the same capture shows, and a spread of 3.8 / 5.2 ms.
//
// Validated: len == 28 + 12 x count in 380 of 385 (98.7%) and 369 of 373 (98.9%); the serving (EARFCN, PCI) is a
// cell 0xB193 reports as serving, and the serving RSRP agrees with 0xB193's to mean +0.12 dB, sd 0.78 dB, 93%
// inside 1 dB on the stationary capture (mean -0.06 dB, sd 2.33 dB while driving, where the phone moves between
// the two measurements) - which is what fixes the scales as 0xB193's own, with no published constant taken on
// trust. Only 29 of 492 and 43 of 265 neighbour PCIs appear anywhere else in the capture: the rest are measured
// by nothing but this record.

import { type Decoded, has, malformed, u16, u32, value, versionMiss } from './bytes.ts';

/** One measured neighbour cell on this frequency. */
export interface IntraFreqNeighbour {
  pci: number;
  rsrp: number;
  rsrq: number;
}

/** One measured LTE frequency: the serving cell's own measurement and the neighbours found on it. */
export interface IntraFreqMeasurement {
  earfcn: number;
  pci: number;
  sfn: number;
  subframe: number;
  /** SFN x 10 + subframe, as the record carries it: this record's only clock. */
  tti: number;
  rsrp: number;
  rsrq: number;
  neighbours: IntraFreqNeighbour[];
}

export const B179_VERSION = 56;
const HEADER_BYTES = 28;
const NEIGHBOUR_BYTES = 12;
/** TTI runs over the 1,024-frame SFN cycle: 10.24 s in ms. */
export const SFN_CYCLE_MS = 10_240;

const rsrpDbm = (x: number) => x * 0.0625 - 180;
const rsrqDb = (x: number) => x * 0.0625 - 30;

/** One frequency's measurement, or malformed when the length the neighbour count implies is not the body's. */
export function decodeB179(b: Uint8Array): Decoded<IntraFreqMeasurement> {
  if (!has(b, 0, 1)) return malformed;
  if (b[0] !== B179_VERSION) return versionMiss('0xB179', `v${b[0]}`);
  if (!has(b, 0, HEADER_BYTES)) return malformed;
  const n = u32(b, 24);
  // The length identity is the framing: a body the count does not explain is not read.
  if (b.length !== HEADER_BYTES + NEIGHBOUR_BYTES * n) return malformed;
  const neighbours: IntraFreqNeighbour[] = [];
  for (let j = 0; j < n; j++) {
    const o = HEADER_BYTES + NEIGHBOUR_BYTES * j;
    neighbours.push({ pci: u16(b, o), rsrp: rsrpDbm(u16(b, o + 2)), rsrq: rsrqDb(u16(b, o + 6)) });
  }
  const tti = u16(b, 14);
  return value({
    earfcn: u32(b, 8),
    pci: u16(b, 12),
    sfn: Math.floor(tti / 10),
    subframe: tti % 10,
    tti,
    rsrp: rsrpDbm(u16(b, 16)),
    rsrq: rsrqDb(u16(b, 20)),
    neighbours,
  });
}
