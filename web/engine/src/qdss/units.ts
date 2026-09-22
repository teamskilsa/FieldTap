// Layer 2 of qdss_deframe.py: the ATID-0x32 stream is a sequence of 16-byte units at a fixed phase.
// u[0] = lane << 5 | type (lane = a 3-bit context):
//   0x00  fill unit (00 00 00 00 00 01*11), every 65th unit        skipped
//   0x02  channel unit: u16 channel id at u[1:3], tail 01*11        binds the lane to that channel
//   0x13  start of a fragment: u[1] = class (kind = low nibble, pad = bits 6..4), u16 length at u[2:4], a u32 at
//         u[4:8] (9d 45 .. for QShrink F3), then 8 - pad payload bytes at u[8+pad:16]
//   0x03  continuation of the fragment open on the lane's channel
// After the start unit, with R = the payload bytes still missing:
//   while R >= 240: a burst of 16 continuation units. Units 0..14 carry bytes 1..15 of a 16-byte source line whose
//         byte 0 the unit tag overwrote; unit 15 carries those 15 displaced bytes at u[1:16].
//   then word units, 12 bytes at u[4:16]; in the LAST one, when fewer than 12 bytes remain, its ceil(R/4) valid
//         32-bit words arrive in reverse order.
//   and the payload is cut to the length field.

export const UNIT = 16;
export const FILL = 0x00;
export const CHANNEL = 0x02;
export const START = 0x13;
export const CONTINUATION = 0x03;

const BURST = 240;
const WORDS = 12;
/** find_phase's sample: 20,000 candidate units for each phase. */
export const PHASE_SAMPLE = UNIT * 20_000;
/**
 * Bytes that settle the phase. find_phase scans [p, min(len - 16, p + sample)) for p < 16; once len - 16 >=
 * 15 + sample the bound no longer depends on the length (and no scanned unit reaches past byte 320,014), so the
 * first 320,031 bytes give the answer the whole stream gives.
 */
export const PHASE_WINDOW = PHASE_SAMPLE + UNIT + 15;

/** u[5:16] == 01*11: the tail of fill and channel units. */
function fillTail(s: Uint8Array, i: number): boolean {
  for (let j = 5; j < UNIT; j++) if (s[i + j] !== 1) return false;
  return true;
}

/** The unit phase: the offset with the most unit-shaped units in the sample; the first maximum wins. */
export function findPhase(s: Uint8Array, length = s.length): number {
  let best = 0, bestGood = -1;
  for (let p = 0; p < UNIT; p++) {
    let good = 0;
    const end = Math.min(length - UNIT, p + PHASE_SAMPLE);
    for (let i = p; i < end; i += UNIT) {
      const t = s[i] & 0x1f;
      if (t === CONTINUATION || t === START || ((t === FILL || t === CHANNEL) && fillTail(s, i))) good++;
    }
    if (good > bestGood) {
      best = p;
      bestGood = good;
    }
  }
  return best;
}

/** Continuation units a fragment of `length` payload bytes needs (expected_units). */
export function expectedUnits(length: number, pad: number): number {
  const rest = length - (8 - pad);
  if (rest <= 0) return 0;
  const bursts = Math.floor(rest / BURST);
  return 16 * bursts + Math.floor((rest - BURST * bursts + 11) / WORDS);
}

/**
 * A fragment being received. The Python collects the units and assembles them when the fragment closes; the
 * assembly only ever looks at units in arrival order and at R, so it is done here as each unit arrives, with the
 * same result and without keeping the units.
 */
export class Fragment {
  readonly cls: number;
  readonly length: number;
  readonly pad: number;
  /** Continuation units received (len(conts)), and those the payload used (k). */
  units = 0;
  used = 0;
  /** R: payload bytes still missing; <= 0 once complete. */
  private missing: number;
  /** len(out): bytes assembled, before the cut to `length`. */
  private filled: number;
  /** Units of the current burst received. */
  private burst = 0;
  /** Null when the payload is not needed (QShrink F3 and unknown kinds): it is only counted. */
  private readonly data: Uint8Array | null;

  /** The start unit at s[i:i+16]. */
  constructor(readonly offset: number, readonly key: number, s: Uint8Array, i: number, keepData: boolean) {
    this.cls = s[i + 1];
    this.pad = (this.cls >> 4) & 7;
    this.length = s[i + 2] | (s[i + 3] << 8);
    const first = 8 - this.pad;
    this.filled = first;
    this.missing = this.length - first;
    // Bursts stop at `length`; the reversed last words may run 3 bytes past it; the start alone may exceed it.
    this.data = keepData ? new Uint8Array(Math.max(this.length + 3, first)) : null;
    this.data?.set(s.subarray(i + 8 + this.pad, i + UNIT));
  }

  get kind(): number {
    return this.cls & 0xf;
  }

  get complete(): boolean {
    return this.missing <= 0;
  }

  /** The continuation unit at s[i:i+16]. */
  add(s: Uint8Array, i: number): void {
    this.units++;
    const r = this.missing;
    const d = this.data;
    if (r >= BURST) {
      const j = this.burst;
      if (j < 15) {
        if (d) for (let k = 1, at = this.filled + 16 * j; k < UNIT; k++) d[at + k] = s[i + k];
        this.burst = j + 1;
      } else {
        if (d) for (let k = 0; k < 15; k++) d[this.filled + 16 * k] = s[i + 1 + k];
        this.filled += BURST;
        this.missing = r - BURST;
        this.used += 16;
        this.burst = 0;
      }
    } else if (r > 0) {
      if (r < WORDS) {
        const words = (r + 3) >> 2;
        if (d) {
          for (let m = 0; m < words; m++) {
            const from = i + 4 * (words - m), at = this.filled + 4 * m;
            d[at] = s[from];
            d[at + 1] = s[from + 1];
            d[at + 2] = s[from + 2];
            d[at + 3] = s[from + 3];
          }
        }
        this.filled += 4 * words;
      } else {
        if (d) for (let k = 4, at = this.filled - 4; k < UNIT; k++) d[at + k] = s[i + k];
        this.filled += WORDS;
      }
      this.missing = r - WORDS;
      this.used++;
    }
    // r <= 0: a unit past the end, only counted.
  }

  /** The payload: whole bursts and words assembled, cut to the length field. A burst cut short is dropped. */
  payload(): Uint8Array {
    return this.data ? this.data.subarray(0, Math.min(this.filled, this.length)) : new Uint8Array(0);
  }
}
