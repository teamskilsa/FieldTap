// 0xB193 LTE ML1 Serving Cell Meas Response, packet v1 with subpacket 0x19 v66 (this modem). The field order is
// the v40 (MobileInsight) / v48 (SCAT) one with each cell record shifted by 8 bytes (a u32 Rx map plus 4 bytes
// before the PCI word) and grown to 144 bytes, re-derived and validated on the iPhone 17 capture (facts only).

import { bits, type Decoded, has, malformed, u16, u32, u8, value, versionMiss } from './bytes.ts';

/** Per-cell RSRP/RSRQ/RSSI, per Rx antenna and combined, for a serving cell (PCell or SCell) or a neighbour. */
export interface CellMeasurement {
  earfcn: number;
  pci: number;
  /** Bit 15 of the PCI word: a serving cell, not a neighbour. */
  serving: boolean;
  /** Bits 9-11 of the PCI word: 0 = PCell, 1-3 = SCell index (serving cells only). */
  carrier: number;
  /** Which of Rx0-Rx3 were measured (bit k = Rx k). */
  rxMap: number;
  rsrpRx: number[];
  rsrqRx: number[];
  rssiRx: number[];
  rsrp: number;
  rsrpFiltered: number;
  rsrq: number;
  rsrqFiltered: number;
  rssi: number;
}

export const measured = (c: CellMeasurement, rx: number): boolean => ((c.rxMap >>> rx) & 1) === 1;

export const rxCount = (c: CellMeasurement): number => [0, 1, 2, 3].filter((k) => measured(c, k)).length;

export const B193_VERSION = 1;
export const B193_SUBPACKET = 0x19;
export const B193_SUBPACKET_VERSION = 66;
const CELL_BYTES = 144;

const rsrp = (x: number) => x * 0.0625 - 180;
const rsrq = (x: number) => x * 0.0625 - 30;
const rssi = (x: number) => x * 0.0625 - 110;

/**
 * 4-byte packet header (version, subpacket count); subpackets of (id, version, u16 size including this header);
 * body: u32 EARFCN, u16 cell count, u16 valid-Rx flags, then 144-byte cell records. Other subpacket ids are
 * skipped; subpacket 0x19 in any version but 66 makes the whole record a version miss.
 */
export function decodeB193(b: Uint8Array): Decoded<CellMeasurement[]> {
  if (!has(b, 0, 4)) return malformed;
  if (b[0] !== B193_VERSION) return versionMiss('0xB193', `v${b[0]}`);
  const out: CellMeasurement[] = [];
  let pos = 4;
  for (let s = 0; s < b[1]; s++) {
    if (!has(b, pos, 4)) return malformed;
    const id = u8(b, pos), ver = u8(b, pos + 1), size = u16(b, pos + 2);
    if (size < 4 || !has(b, pos, size)) return malformed;
    const body = pos + 4, end = pos + size;
    pos = end;
    if (id !== B193_SUBPACKET) continue;
    if (ver !== B193_SUBPACKET_VERSION) return versionMiss('0xB193', `v1/0x19 v${ver}`);
    if (end - body < 8) return malformed;
    const earfcn = u32(b, body), cells = u16(b, body + 4);
    for (let k = 0; k < cells; k++) {
      const c = body + 8 + CELL_BYTES * k;
      if (c + CELL_BYTES > end) break;
      out.push(cell(b, c, earfcn));
    }
  }
  return value(out);
}

/** One 144-byte cell record at `c`: u32 Rx map @0, u16 PCI word @8, measurement words u32 @24...@68. */
function cell(b: Uint8Array, c: number, earfcn: number): CellMeasurement {
  const pciWord = u16(b, c + 8);
  const w = (i: number) => u32(b, c + 24 + 4 * i);
  const w0 = w(0), w1 = w(1), w2 = w(2), w4 = w(4), w5 = w(5), w6 = w(6), w7 = w(7), w8 = w(8), w9 = w(9), w10 = w(10),
    w11 = w(11);
  return {
    earfcn,
    pci: pciWord & 511,
    serving: ((pciWord >> 15) & 1) === 1,
    carrier: (pciWord >> 9) & 7,
    rxMap: u32(b, c),
    rsrpRx: [rsrp(bits(w0, 10, 12)), rsrp(bits(w1, 12, 12)), rsrp(bits(w2, 12, 12)), rsrp(bits(w4, 0, 12))],
    rsrqRx: [rsrq(bits(w6, 0, 10)), rsrq(bits(w6, 20, 10)), rsrq(bits(w7, 10, 10)), rsrq(bits(w7, 20, 10))],
    rssiRx: [rssi(bits(w9, 0, 11)), rssi(bits(w9, 11, 11)), rssi(bits(w10, 0, 11)), rssi(bits(w10, 11, 11))],
    // The combined RSRP is stored 40 dB (640 units) below the per-Rx scale.
    rsrp: rsrp(bits(w4, 12, 12) + 640),
    rsrpFiltered: rsrp(bits(w5, 12, 12)),
    rsrq: rsrq(bits(w8, 0, 10)),
    rsrqFiltered: rsrq(bits(w8, 20, 10)),
    rssi: rssi(bits(w11, 0, 11)),
  };
}
