// 0x184C "LTE RF FED Tx AGC", version 0x11 on this modem (FED = front-end driver; the public name is in the QXDM
// release notes). 2,393 records in the driving capture and 4,465 in the stationary one; the framing and the fields
// below were derived on both (docs/research/iphone-unknown-log-codes.md).
//
//   record = N blocks; block = 16-byte block header + k x 120-byte sub-records, k = 1..3
//   body[1] = N (2..5), and len(body) == 16*N + 120*M fits every observed length (392..680)
//   block header: b[0] = 0x11, five zero bytes at +2, u16 @7 = a subframe counter packed as (frame << 8 |
//                 subframe << 4): the low field is never above 9 in 10,667 and 20,319 blocks, so it does count
//                 subframes, but it is the front end's own counter and NOT the cell's SFN - fitted against the
//                 records' own timestamps it scores circular R = 0.11, and its subframes line up with the PUSCH
//                 reports of 0xB139 no better than chance. So it is read, checked for that 0..9 range, and
//                 deliberately not used to place a sample in time; the record's DIAG timestamp does that.
//   sub-record, 120 bytes:
//     u8   +0   chain tag (0x10, 0x11, 0x20, 0x21, 0x22 ...): which transmit chain this is
//     u8   +1   AGC / PA gain state (0x10, 0x24, 0x30, 0x34 ...), r = -0.80 against the PUSCH Tx power
//     i16  +4   transmit power in 0.1 dBm, -70.0 dBm when the chain is off      (mirrored at +8)
//     i16  +6   a second transmit-power measure in 0.1 dBm
//     u16 +10, +12, +114  linear gain words (r = +0.57 / +0.72 / +0.82 against the PUSCH Tx power)
//     u16 +66, +68, +70   the chain's own power limit in 0.1 dBm (17.7 .. 25.0 dBm, r = -0.73 .. -0.75)
//
// A walk that finds block headers by that signature consumes the body exactly on 2,391 of 2,393 records (99.92%)
// and 4,464 of 4,465 (99.98%); a record whose walk does not close is reported with no sub-records rather than read
// on a guess. The powers are the front end's own, measured at its own instants, and a best fit against the PUSCH
// power FieldTap derives from 0xB139 leaves a 3.8 dB residual - which is the point: it is a different, more
// physical quantity than the PUSCH target, and it is what says whether the phone was transmit-limited.

import { type Decoded, has, i16, malformed, u16, u8, value, versionMiss } from './bytes.ts';

/** One transmit chain in one subframe. */
export interface TxChainSample {
  /** Index of the block inside the record. */
  block: number;
  /** The block's subframe counter, as the header packs it (frame << 8 | subframe << 4, read as frame x 10 + sub).
   *  A front-end counter, not the cell's SFN: it does not place the sample in time. */
  subframeCounter: number;
  /** The record's own chain tag, e.g. 0x10 or 0x21. */
  chain: number;
  /** AGC / PA gain state: what drives handset heat during an upload (a lower state means more power). */
  gainState: number;
  /** Front-end transmit power in dBm; -70.0 is the "chain off" sentinel. */
  powerDbm: number;
  /** The record's second transmit-power measure, in dBm. */
  power2Dbm: number;
  /** The chain's own power limits in dBm (three fields; the smallest is the binding one). */
  limitsDbm: number[];
  /** False when the power reads the -70.0 dBm sentinel: this chain was not transmitting. */
  live: boolean;
}

/** One 0x184C record. `exact` is false when the block walk did not consume the body; then there are no samples. */
export interface FedTxAgcRecord {
  blocks: number;
  /** Each block's subframe counter, in order (frame x 10 + subframe of the front end's own counter). */
  blockCounters: number[];
  /** Blocks whose counter's subframe field was inside 0..9: the structural check on the field. */
  subframesInRange: number;
  samples: TxChainSample[];
  exact: boolean;
}

export const X184C_VERSION = 0x11;
const BLOCK_HEADER_BYTES = 16;
const SUB_BYTES = 120;
/** The value the power field takes when the chain is off. */
export const CHAIN_OFF_DBM = -70;

const isBlockHeader = (b: Uint8Array, p: number): boolean =>
  has(b, p, BLOCK_HEADER_BYTES) && b[p] === X184C_VERSION && b[p + 2] === 0 && b[p + 3] === 0 && b[p + 4] === 0 &&
  b[p + 5] === 0 && b[p + 6] === 0;

/** The transmit chains of one 0x184C record. Any other version is a counted miss, never guessed at. */
export function decodeX184C(b: Uint8Array): Decoded<FedTxAgcRecord> {
  if (!has(b, 0, 2)) return malformed;
  if (b[0] !== X184C_VERSION) return versionMiss('0x184C', `v${b[0]}`);
  const samples: TxChainSample[] = [];
  const blockCounters: number[] = [];
  let pos = 0, blocks = 0, subframesInRange = 0;
  while (pos + BLOCK_HEADER_BYTES <= b.length) {
    if (!isBlockHeader(b, pos)) return value({ blocks, blockCounters, subframesInRange, samples: [], exact: false });
    const w = u16(b, pos + 7);
    const frame = (w >> 8) & 0x3ff, subframe = (w >> 4) & 15;
    if (subframe <= 9) subframesInRange++;
    const subframeCounter = frame * 10 + subframe;
    blockCounters.push(subframeCounter);
    const index = blocks++;
    pos += BLOCK_HEADER_BYTES;
    while (pos + SUB_BYTES <= b.length && !isBlockHeader(b, pos)) {
      const power = i16(b, pos + 4) / 10;
      samples.push({
        block: index,
        subframeCounter,
        chain: u8(b, pos),
        gainState: u8(b, pos + 1),
        powerDbm: power,
        power2Dbm: i16(b, pos + 6) / 10,
        limitsDbm: [u16(b, pos + 66) / 10, u16(b, pos + 68) / 10, u16(b, pos + 70) / 10],
        live: power > CHAIN_OFF_DBM,
      });
      pos += SUB_BYTES;
    }
  }
  if (pos !== b.length) return value({ blocks, blockCounters, subframesInRange, samples: [], exact: false });
  return value({ blocks, blockCounters, subframesInRange, samples, exact: true });
}

/** The binding power limit of a chain: the smallest of the three limit fields. */
export const bindingLimitDbm = (s: TxChainSample): number => Math.min(...s.limitsDbm);
