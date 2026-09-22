// NR records (versions are u16 minor, u16 major):
// - 0xB97F ML1 Searcher Measurement Database Update Ext, 3.0: SCAT's 3.0 field order (facts only), validated on the
//   iPhone 17 capture (the parse consumes each record exactly; cell RSRP within 0.2 dB of the measurement reports).
// - 0xB887 MAC PDSCH Status, 3.13: no public layout; every position was re-derived on this modem's captures.
// - 0xB888 MAC PDSCH Stats, 3.1: the MobileInsight 2.2 field order (Apache-2.0) with one extra u32 after the carrier
//   id. The counters are cumulative.

import { bits, type Decoded, has, malformed, u16, u32, u64, u8, value, versionMiss } from './bytes.ts';

const version = (b: Uint8Array) => ({ major: u16(b, 2), minor: u16(b, 0) });

export interface NrCellMeasurement {
  pci: number;
  rsrp: number | null;
  rsrq: number | null;
  beams: number;
}

export interface NrCarrierMeasurement {
  arfcn: number;
  /** 255 before the SCG is added (measured as a candidate), else the component carrier id. */
  ccId: number;
  servingPci: number;
  cells: NrCellMeasurement[];
}

const CARRIER_BYTES = 40, CELL_BYTES = 16, BEAM_BYTES = 84;

/** Q7: an 8-bit two's-complement integer part and a 7-bit fraction; 0 means not measured. */
export function q7(x: number): number | null {
  if (x === 0) return null;
  const integer = (x >>> 7) & 0xff, fraction = x & 0x7f;
  return -((integer ^ 0xff) + 1) + fraction * 0.0078125;
}

/**
 * 20-byte header (u8 carrier count @8); per carrier 40 bytes (u32 ARFCN @0, u8 CC id @4, u8 cell count @5, u16
 * serving PCI @6, u8 serving index @8), then 16-byte cells (u16 PCI @0, u8 beam count @4, Q7 RSRP @8, Q7 RSRQ
 * @12), each followed by its 84-byte beam records. The per-Rx serving fields are zero on this modem: not read.
 */
export function decodeB97F(b: Uint8Array): Decoded<NrCarrierMeasurement[]> {
  if (!has(b, 0, 4)) return malformed;
  const v = version(b);
  if (v.major !== 3 || v.minor !== 0) return versionMiss('0xB97F', `${v.major}.${v.minor}`);
  if (!has(b, 0, 20)) return malformed;
  let off = 20;
  const out: NrCarrierMeasurement[] = [];
  for (let l = 0; l < b[8]; l++) {
    if (!has(b, off, CARRIER_BYTES)) return malformed;
    const arfcn = u32(b, off), ccId = u8(b, off + 4), count = u8(b, off + 5), servingPci = u16(b, off + 6),
      servingIndex = u8(b, off + 8);
    off += CARRIER_BYTES;
    // A count of 0 or 0xFF means "see the serving index" on this firmware.
    const n = count !== 0 && count !== 0xff ? count : servingIndex > 0 && servingIndex < 0xff ? servingIndex : 0;
    const cells: NrCellMeasurement[] = [];
    for (let c = 0; c < n; c++) {
      if (!has(b, off, CELL_BYTES)) return malformed;
      const beams = u8(b, off + 4);
      cells.push({ pci: u16(b, off), rsrp: q7(u32(b, off + 8)), rsrq: q7(u32(b, off + 12)), beams });
      off += CELL_BYTES + BEAM_BYTES * beams;
      if (off > b.length) return malformed;
    }
    out.push({ arfcn, ccId, servingPci, cells });
  }
  return value(out);
}

/** One NR PDSCH slot: MCS, resource blocks, layers, TBS and CRC. */
export interface NrPdschSlot {
  frame: number;
  slot: number;
  pci: number;
  tbsBytes: number;
  /** Index into the MCS table RRC configured (TS 38.214 table 5.1.3.1-2, qam256, here); 28-31 are retransmissions. */
  mcs: number;
  nRb: number;
  harq: number;
  layers: number;
  crcOk: boolean;
}

const B887_RECORD_BYTES = 44;

/**
 * 8-byte header (u8 record count @7); 44-byte records: u32 @8 frame bits 5-14, slot bits 15-19; u16 @12 PCI 10b;
 * u32 @16 TBS bytes bits 5-22, MCS bits 26-30; u32 @20 nRB bits 0-7, HARQ bits 11-14, layers-1 bits 29-30; byte
 * @24 bit 0 CRC pass.
 *
 * The first capture (n5, 52 PRB, 15 kHz SCS, at most 2 layers) fixed the positions but never set the high bits.
 * The moving capture's n77 carrier (217 PRB, 30 kHz, up to 4 layers) did: with the narrower widths the reference
 * first used (slot 4, TBS 21, nRB 7, layers 1 bits) none of its 828 new transmissions matches TS 38.214, with these
 * all do, and the first capture decodes identically (497 of 497 slots). w4 bit 23 is a flag, not TBS.
 */
export function decodeB887(b: Uint8Array): Decoded<NrPdschSlot[]> {
  if (!has(b, 0, 4)) return malformed;
  const v = version(b);
  if (v.major !== 3 || v.minor !== 13) return versionMiss('0xB887', `${v.major}.${v.minor}`);
  if (!has(b, 0, 8)) return malformed;
  const out: NrPdschSlot[] = [];
  for (let k = 0; k < b[7]; k++) {
    const r = 8 + B887_RECORD_BYTES * k;
    if (!has(b, r, B887_RECORD_BYTES)) break;
    const w2 = u32(b, r + 8), w4 = u32(b, r + 16), w5 = u32(b, r + 20);
    out.push({
      frame: bits(w2, 5, 10),
      slot: bits(w2, 15, 5),
      pci: u16(b, r + 12) & 0x3ff,
      tbsBytes: bits(w4, 5, 18),
      mcs: bits(w4, 26, 5),
      nRb: bits(w5, 0, 8),
      harq: bits(w5, 11, 4),
      layers: bits(w5, 29, 2) + 1,
      crcOk: (b[r + 24] & 1) === 1,
    });
  }
  return value(out);
}

/** Cumulative NR DL MAC counters of one carrier. */
export interface NrPdschCounters {
  carrier: number;
  slots: number;
  decodes: number;
  crcPass: number;
  crcFail: number;
  retx: number;
  passBytes: number;
  failBytes: number;
  tbBytes: number;
}

const B888_MIN_BYTES = 92;

/** The first record @16: u32 carrier, u32, u32 slots, decodes, CRC pass, CRC fail, retx, ACK-as-NACK, HARQ fail;
 *  u64 pass bytes, fail bytes, TB bytes, padding bytes, retx bytes. */
export function decodeB888(b: Uint8Array): Decoded<NrPdschCounters> {
  if (!has(b, 0, 4)) return malformed;
  const v = version(b);
  if (v.major !== 3 || v.minor !== 1) return versionMiss('0xB888', `${v.major}.${v.minor}`);
  if (!has(b, 0, B888_MIN_BYTES)) return malformed;
  const u = (i: number) => u32(b, 16 + 4 * i);
  const q = (i: number) => u64(b, 52 + 8 * i);
  return value({
    carrier: u(0),
    slots: u(2),
    decodes: u(3),
    crcPass: u(4),
    crcFail: u(5),
    retx: u(6),
    passBytes: q(0),
    failBytes: q(1),
    tbBytes: q(2),
  });
}
