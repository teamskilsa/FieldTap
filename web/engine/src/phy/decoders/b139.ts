// 0xB139 LTE LL1 PUSCH Tx Report, v162 (0xA2). Header and record words follow the MobileInsight v145 order; the
// modulation and power bytes and the power scale were re-derived on the iPhone 17 capture (power calibrated
// against 442 TTI-matched power headroom reports).

import { bits, type Decoded, has, malformed, u16, u32, u8, value, versionMiss } from './bytes.ts';

/** One PUSCH transmission: resource blocks, TBS, code rate, modulation and required Tx power. */
export interface PuschTransmission {
  /** Serving-cell id from the header (9 bits). */
  pci: number;
  tti: number;
  carrier: number;
  retxIndex: number;
  startRb: number;
  nRb: number;
  tbsBytes: number;
  /** Code rate x1024 over 1024. */
  codeRate: number;
  /** 1 QPSK, 2 16QAM, 3 64QAM, 4 256QAM. */
  modulation: number;
  /** Required PUSCH power in 0.25 dB units, before Pcmax capping. */
  powerRaw: number;
}

const QM: Record<number, number> = { 1: 2, 2: 4, 3: 6, 4: 8 };

/** Modulation order Qm, or null for a code outside 1-4. */
export const puschQm = (tx: PuschTransmission): number | null => QM[tx.modulation] ?? null;

/** dBm = raw / 4 - 1.5: 0.25 dB steps (slope 4.0 per dB against 10log10(nRB)); the -1.5 dB offset comes from the
 *  PHRs and assumes Pcmax,c = 23 dBm, so the absolute value is good to about 1.5 dB. */
export const requiredPowerDbm = (tx: PuschTransmission): number => tx.powerRaw / 4 - 1.5;

export const B139_VERSION = 162;
const RECORD_BYTES = 100;

/**
 * 8-byte header: version, u16 serving cell 9b | record count 5b, u8, u16 dispatch SFN, 2 reserved. Records: u32
 * @0 = TTI (low 16) | flags (carrier 2b, ACK, CQI, RI, hopping 2b, retx index 5b, RV 2b); u32 @4 = RA type 1b,
 * start RB 7b, ..., nRB 7b @15; u16 TBS bytes @8; u16 code rate @10; byte @36 bits 2-4 modulation; byte @46
 * required power.
 */
export function decodeB139(b: Uint8Array): Decoded<PuschTransmission[]> {
  if (!has(b, 0, 3)) return malformed;
  if (b[0] !== B139_VERSION) return versionMiss('0xB139', `v${b[0]}`);
  const w = u16(b, 1), pci = w & 511, n = (w >> 9) & 31;
  const out: PuschTransmission[] = [];
  for (let k = 0; k < n; k++) {
    const r = 8 + RECORD_BYTES * k;
    if (!has(b, r, RECORD_BYTES)) break;
    const w0 = u32(b, r), w1 = u32(b, r + 4);
    const flags = w0 >>> 16;
    out.push({
      pci,
      tti: w0 & 0xffff,
      carrier: flags & 3,
      retxIndex: (flags >> 7) & 31,
      startRb: bits(w1, 1, 7),
      nRb: bits(w1, 15, 7),
      tbsBytes: u16(b, r + 8),
      codeRate: u16(b, r + 10) / 1024,
      modulation: (u8(b, r + 36) >> 2) & 7,
      powerRaw: u8(b, r + 46),
    });
  }
  return value(out);
}
