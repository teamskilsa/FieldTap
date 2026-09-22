// 0xB173 LTE PDSCH Stat Indication, v50 (this modem). 4-byte header (version, record count, 2 reserved), then
// fixed 40-byte records: a 12-byte part, two 12-byte transport-block slots in the MobileInsight v40 slot order,
// and a 4-byte tail. The meaning of bytes 2-4 was re-derived on the iPhone 17 capture and validated by the TS
// 36.213 TBS matches and the SCell carriers.

import { type Decoded, has, malformed, u16, u8, value, versionMiss } from './bytes.ts';

export interface TransportBlock {
  harq: number;
  rv: number;
  ndi: number;
  crcOk: boolean;
  /** 0 = C-RNTI (user data); the others are SI/P/RA-RNTI broadcasts. */
  rntiType: number;
  tbIndex: number;
  tbsBytes: number;
  mcs: number;
  nRb: number;
  /** Modulation order Qm (2, 4, 6, 8); 0 when the slot is unused. */
  qm: number;
}

/** One PDSCH scheduling decision: layers, transport blocks and the carrier they were on. */
export interface PdschRecord {
  sfn: number;
  subframe: number;
  /** Spatial layers; 4 with one transport block is transmit diversity, not 4-layer MIMO. */
  layers: number;
  transportBlocks: number;
  /** Serving-cell index: 0 = PCell, 1-3 = SCell. */
  carrier: number;
  blocks: TransportBlock[];
}

export const B173_VERSION = 50;
const RECORD_BYTES = 40;

/**
 * u16 SFN<<4|SF @0, u8 layers @2, u8 TB count @3, u8 carrier&7 @4; TB slots @12 and @24: u8 HARQ 4b | RV 2b |
 * NDI 1b | CRC 1b, u16 RNTI type 4b | TB index bit 4, u16 TBS bytes @+4, u8 MCS @+6, u8 nRB @+7, u8 Qm @+8.
 */
export function decodeB173(b: Uint8Array): Decoded<PdschRecord[]> {
  if (!has(b, 0, 2)) return malformed;
  if (b[0] !== B173_VERSION) return versionMiss('0xB173', `v${b[0]}`);
  const out: PdschRecord[] = [];
  for (let k = 0; k < b[1]; k++) {
    const r = 4 + RECORD_BYTES * k;
    if (!has(b, r, RECORD_BYTES)) break;
    const w = u16(b, r), ntb = u8(b, r + 3);
    const blocks: TransportBlock[] = [];
    for (let j = 0; j < Math.min(ntb, 2); j++) {
      const t = r + 12 + 12 * j;
      const hb = u8(b, t), rw = u16(b, t + 1);
      blocks.push({
        harq: hb & 15,
        rv: (hb >> 4) & 3,
        ndi: (hb >> 6) & 1,
        crcOk: ((hb >> 7) & 1) === 1,
        rntiType: rw & 15,
        tbIndex: (rw >> 4) & 1,
        tbsBytes: u16(b, t + 4),
        mcs: u8(b, t + 6),
        nRb: u8(b, t + 7),
        qm: u8(b, t + 8),
      });
    }
    out.push({ sfn: (w >> 4) & 4095, subframe: w & 15, layers: u8(b, r + 2), transportBlocks: ntb, carrier: u8(b, r + 4) & 7, blocks });
  }
  return value(out);
}
