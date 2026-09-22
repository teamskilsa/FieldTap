// 0x1D0B - a 100 Hz modem sampler, version 7. No public name, and what it samples every 2 ms could not be
// identified, so nothing but its two clocks and its sequence number is read (docs/research/iphone-unknown-log-codes.md).
//
//   u32  +0   version, 7
//   u32  +4   timestamp, 1024 Hz: measured at 1,023.8 .. 1,023.9 counts per second of trace over three gap-free
//             stretches, with per-record increments of 10 (1,441x) or 11 (451x) - the 32.768 kHz sleep clock / 32
//   u32  +8   timestamp, 19.2 MHz, 24 bits (wraps every 0.874 s): median per-record rate 19,200,006 counts/s
//   u32 +84   record sequence number: 1,902 of 1,907 consecutive deltas are exactly +1
//   @90       five 56-byte entries, 2.000 ms apart, i.e. the 10 ms the sequence number steps over: not read
//
// What this buys: the 1024 Hz counter measures how much wall time went missing where the trace has holes. The
// record rate drops from 100/s to 14/s across the driving capture's detach, and the counter says exactly how much
// was never written (steps of +2,280, +1,154, +991 and +620 counts = 2.23 s, 1.13 s, 0.97 s and 0.61 s), which
// turns "three chunk files are missing" into seconds, in the right places.

import { type Decoded, has, malformed, u32, value, versionMiss } from './bytes.ts';

/** One 0x1D0B record: its two clocks and its sequence number. */
export interface ModemClockSample {
  /** The 1024 Hz sleep-clock counter. */
  ticks1024: number;
  /** The 19.2 MHz TCXO counter, 24 bits. */
  ticks19M2: number;
  sequence: number;
}

export const X1D0B_VERSION = 7;
/** The sleep clock's rate: 32.768 kHz / 32. */
export const CLOCK_1024_HZ = 1024;
const MIN_BODY_BYTES = 88;

/** The clocks of one 0x1D0B record; the three truncated records in the capture are malformed, not guessed at. */
export function decodeX1D0B(b: Uint8Array): Decoded<ModemClockSample> {
  if (!has(b, 0, 4)) return malformed;
  const version = u32(b, 0);
  if (version !== X1D0B_VERSION) return versionMiss('0x1D0B', `v${version}`);
  if (!has(b, 0, MIN_BODY_BYTES)) return malformed;
  return value({ ticks1024: u32(b, 4), ticks19M2: u32(b, 8) & 0xffffff, sequence: u32(b, 84) });
}
