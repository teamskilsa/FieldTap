// 0xB0C1 LTE RRC MIB v2 and 0xB0C2 LTE RRC Serving Cell Info v3 (the MobileInsight/SCAT field orders, facts
// only). The cell identity, TAC and PLMN in 0xB0C2 are deliberately not read: with the PLMN they locate the
// phone, and nothing on the Radio page needs them.

import { type Decoded, has, malformed, u16, u32, u8, value, versionMiss } from './bytes.ts';

/** The MIB as the modem logged it: which cell, and the eNB's Tx antenna count and DL bandwidth it announces. */
export interface Mib {
  pci: number;
  earfcn: number;
  sfn: number;
  txAntennas: number;
  dlBandwidthPrb: number;
}

export const B0C1_VERSION = 2;

/** u16 PCI @1, u32 EARFCN @3, u16 SFN @7, u8 Tx antennas @9, u8 DL bandwidth (PRB) @10. */
export function decodeB0C1(b: Uint8Array): Decoded<Mib> {
  if (!has(b, 0, 1)) return malformed;
  if (b[0] !== B0C1_VERSION) return versionMiss('0xB0C1', `v${b[0]}`);
  if (!has(b, 0, 11)) return malformed;
  return value({ pci: u16(b, 1), earfcn: u32(b, 3), sfn: u16(b, 7), txAntennas: u8(b, 9), dlBandwidthPrb: u8(b, 10) });
}

/** The serving cell's channels and band. */
export interface ServingCell {
  pci: number;
  dlEarfcn: number;
  ulEarfcn: number;
  dlBandwidthPrb: number;
  ulBandwidthPrb: number;
  band: number;
}

export const B0C2_VERSION = 3;

/** u16 PCI @1, u32 DL/UL EARFCN @3/@7, u8 DL/UL bandwidth @11/@12, u32 band @19. */
export function decodeB0C2(b: Uint8Array): Decoded<ServingCell> {
  if (!has(b, 0, 1)) return malformed;
  if (b[0] !== B0C2_VERSION) return versionMiss('0xB0C2', `v${b[0]}`);
  if (!has(b, 0, 29)) return malformed;
  return value({
    pci: u16(b, 1),
    dlEarfcn: u32(b, 3),
    ulEarfcn: u32(b, 7),
    dlBandwidthPrb: u8(b, 11),
    ulBandwidthPrb: u8(b, 12),
    band: u32(b, 19),
  });
}
