// The absolute TTI axis: the one piece of plumbing every cross-record check in the LTE decoders needs.
//
// An LTE record names its moment by SFN x 10 + subframe, which cycles every 10.24 s, and the capture is twice
// that long, so the same TTI comes round two or three times: without unwrapping it, every alignment between two
// log codes comes out flat (the research's own finding, docs/research/iphone-named-log-codes.md "The cross-cutting
// result"). Unwrapping needs one number, the constant offset between a record's DIAG timestamp and the subframe it
// reports - the modem's logging latency, 1,463-1,547 ms on the driving capture and 1,677-1,754 ms on the
// stationary one, the same window for every code.
//
// The offset is measured, never assumed: each stamped record contributes (t - TTI) mod 10.24 s, and the circular
// mean of those angles is the latency. The concentration R of the same sample says how good the fit is (1.00000
// on both captures), and it is reported in the self-checks, so a firmware change that moves the latency shows up
// instead of quietly mis-keying every comparison.

/** One radio frame cycle: 1,024 frames of 10 ms. */
export const SFN_CYCLE_MS = 10_240;

/** Absolute TTI: the subframe counter unwrapped past the 10.24 s cycle, in ms since the time base. */
export class TtiAxis {
  private sin = 0;
  private cos = 0;
  private n = 0;
  private latency = 0;
  private concentration = 0;
  private sealed = false;

  /** One stamped record that also reports its own subframe. */
  observe(tMs: number, tti: number): void {
    const angle = (2 * Math.PI * (((tMs - tti) % SFN_CYCLE_MS) + SFN_CYCLE_MS)) / SFN_CYCLE_MS;
    this.sin += Math.sin(angle);
    this.cos += Math.cos(angle);
    this.n++;
  }

  /** Fix the latency from what was observed. Called once, before the first lookup. */
  seal(): void {
    if (this.sealed) return;
    this.sealed = true;
    if (this.n === 0) return;
    const mean = Math.atan2(this.sin / this.n, this.cos / this.n);
    this.latency = ((mean / (2 * Math.PI)) * SFN_CYCLE_MS + SFN_CYCLE_MS) % SFN_CYCLE_MS;
    this.concentration = Math.hypot(this.sin, this.cos) / this.n;
  }

  get records(): number {
    return this.n;
  }

  /** The measured logging latency in ms (how far a record's timestamp trails the subframe it reports). */
  get latencyMs(): number {
    return this.latency;
  }

  /** Circular concentration of the latency sample, 0..1: 1 means every record agrees exactly. */
  get r(): number {
    return this.concentration;
  }

  get usable(): boolean {
    return this.n > 0;
  }

  /** The absolute TTI of a record stamped `tMs` that reports subframe `tti`. */
  absolute(tMs: number, tti: number): number {
    return tti + SFN_CYCLE_MS * Math.round((tMs - this.latency - tti) / SFN_CYCLE_MS);
  }

  /** The time a record reporting `tti` was logged at, given a rough idea of when it arrived (`aboutMs`). */
  timeOf(tti: number, aboutMs: number): number {
    return this.absolute(aboutMs, tti) + this.latency;
  }
}
