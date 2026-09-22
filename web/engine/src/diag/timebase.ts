// Port of the time rules in android/diag CallFlow.kt at contract v1 (rule D1, ios/Contract/CONTRACT.md) and of
// FTModel/TimeBase.swift.
//
// iPhone captures begin with records stamped before the modem had network time (they count from the GPS epoch of
// 1980). D1 measures from the first plausible, post-2005, timestamp when there is one and otherwise, as before,
// from the first non-zero one, so 'since start' means the same thing in every app.

import type { LogRecord } from './record.ts';

/** 1980-01-06, the GPS epoch, in Unix ms. */
export const GPS_EPOCH_UTC_MS = 315_964_800_000;
/** 2005-01-01: a modem without network time counts from 1980, and that is not a date to show. */
export const PLAUSIBLE_UTC_MS = 1_104_537_600_000;

const TOP_BIT = 1n << 63n;

/** Kotlin reads the stamp as a signed Long and skips values <= 0; the same bits are skipped here. */
export const isPositive = (raw: bigint) => raw > 0n && raw < TOP_BIT;

/**
 * Milliseconds since the GPS epoch, read the way fieldtap/diag/protocol.py and the Wireshark export read it: the
 * upper 48 bits count 1.25 ms units, the lower 16 bits a 1/32 of that at 1.2288 MHz. Both halves are exact in a
 * double, so this is the same double Kotlin computes.
 */
export function modemMs(raw: bigint): number {
  return Number(raw >> 16n) * 1.25 + Number(raw & 0xffffn) / 39_321.6;
}

/** Unix ms of a raw stamp (truncated, as Kotlin's toLong), or null when it is zero or before 2005. */
export function utcMs(raw: bigint): number | null {
  if (!isPositive(raw)) return null;
  const utc = GPS_EPOCH_UTC_MS + Math.trunc(modemMs(raw));
  return utc >= PLAUSIBLE_UTC_MS ? utc : null;
}

/** Where a capture's clock starts and ends. Build it with `TimeBase.of(records)` or incrementally with `add`. */
export class TimeBase {
  private firstAny = 0n;
  private lastAny = 0n;
  private firstPlausible = 0n;
  private lastPlausible = 0n;

  static of(records: Iterable<LogRecord>): TimeBase {
    const t = new TimeBase();
    for (const r of records) t.add(r.timestampRaw);
    return t;
  }

  /** The same pass CallFlow.Reading.add makes, in file order. */
  add(raw: bigint): void {
    if (!isPositive(raw)) return;
    if (this.firstAny === 0n) this.firstAny = raw;
    this.lastAny = raw;
    if (utcMs(raw) !== null) {
      if (this.firstPlausible === 0n) this.firstPlausible = raw;
      this.lastPlausible = raw;
    }
  }

  get firstRaw(): bigint {
    return this.firstPlausible !== 0n ? this.firstPlausible : this.firstAny;
  }

  get lastRaw(): bigint {
    return this.firstPlausible !== 0n ? this.lastPlausible : this.lastAny;
  }

  /** Milliseconds since the start of the capture, or null for an unstamped (zero) record. */
  sinceStartMs(raw: bigint): number | null {
    const first = this.firstRaw;
    if (!isPositive(raw) || first === 0n) return null;
    return modemMs(raw) - modemMs(first);
  }

  /** From the first counted record to the last; 0 for a capture with no stamped record. */
  get durationMs(): number {
    const first = this.firstRaw, last = this.lastRaw;
    return first > 0n && last > 0n ? modemMs(last) - modemMs(first) : 0;
  }

  /** Unix ms of tMs 0, truncated as CallFlow.Flow.startUtcMs; null when the modem had no network time. */
  get startUtcMs(): number | null {
    return utcMs(this.firstRaw);
  }

  /** Unix seconds of tMs 0, untruncated: phy-golden.json's timeBase.unixStart (1,790,019,725.984205 s). */
  get unixStartS(): number | null {
    return this.startUtcMs === null ? null : (GPS_EPOCH_UTC_MS + modemMs(this.firstRaw)) / 1000;
  }
}
