// Port of ios/Contract/src-v1/CellInfo.kt: 0xB0C2 LTE RRC Serving Cell Info, who the cell the phone is camped on
// actually is. The RRC OTA header names a cell by PCI and EARFCN; the PLMN, tracking area and cell identity are
// in this record instead. A record whose fields are out of range is rejected rather than shown: a layout that
// does not fit this modem would otherwise produce a confident-looking PLMN that is noise.

import type { ServingCellInfo } from './flow.ts';

/** Older records index a table of bandwidths; newer ones count resource blocks. Both are unambiguous. */
const BANDWIDTH_INDEX = new Map([[0, 1.4], [1, 3.0], [2, 5.0], [3, 10.0], [4, 15.0], [5, 20.0]]);
const BANDWIDTH_PRBS = new Map([[6, 1.4], [15, 3.0], [25, 5.0], [50, 10.0], [75, 15.0], [100, 20.0]]);

const bandwidth = (raw: number): number | null => BANDWIDTH_PRBS.get(raw) ?? BANDWIDTH_INDEX.get(raw) ?? null;

export function servingCell(body: Uint8Array): ServingCellInfo | null {
  if (body.length === 0) return null;
  // Version 2 keeps the EARFCNs in 16 bits; every modern modem uses the 32-bit layout.
  const wide = body[0] !== 2;
  const size = wide ? 27 : 23;
  if (body.length < 1 + size) return null;
  const view = new DataView(body.buffer, body.byteOffset, body.byteLength);
  let at = 1;
  const u8 = () => body[at++];
  const u16 = () => {
    const v = view.getUint16(at, true);
    at += 2;
    return v;
  };
  const u32 = () => {
    const v = view.getUint32(at, true);
    at += 4;
    return v;
  };
  const pci = u16();
  const downlink = wide ? u32() : u16();
  const uplink = wide ? u32() : u16();
  const downlinkBandwidth = u8();
  at += 1; // uplink bandwidth, always the same as the downlink on FDD
  const cellIdentity = u32();
  const tac = u16();
  const band = u32();
  const mcc = u16();
  const mncDigits = u8();
  const mnc = view.getUint16(at, true);
  if (pci > 1007 || band < 1 || band > 256 || mcc > 999) return null;
  return {
    pci,
    downlinkEarfcn: downlink,
    uplinkEarfcn: uplink,
    band,
    plmn: `${mcc}`.padStart(3, '0') + '-' + `${mnc}`.padStart(mncDigits === 3 ? 3 : 2, '0'),
    tac,
    cellIdentity,
    bandwidthMhz: bandwidth(downlinkBandwidth),
  };
}
