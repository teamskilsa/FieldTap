// Shared by the PHY tests: the real capture loaded once (fixture-gated, read in place from $FT_FIXTURES), the
// reference extractor's own TBS table as a test oracle, and the contract's KPI comparison (CONTRACT.md, PHY
// parity: sample counts exact; min, max and mean within 0.01 (or 1e-4 relative); first and last 3 samples within
// 1.0 ms and 0.01).

import { readQmdl } from '../src/diag/qmdl.ts';
import type { LogRecord } from '../src/diag/record.ts';
import { TimeBase } from '../src/diag/timebase.ts';
import { type PhyRun, runPhy } from '../src/phy/extract.ts';
import { LteTbsLookup } from '../src/phy/lteTbs.ts';
import type { EncryptedCensus, PhySample } from '../src/types.ts';
import { fixture } from '../tools/fixtures.ts';
import { readJson } from '../tools/golden.ts';

export const QMDL = fixture('iphone-recovered.qmdl');
export const PHY_GOLDEN = fixture('contract/phy-golden-v1.json');
export const PHY_SUMMARY = fixture('contract/phy-summary-v1.json');
/** The reference extractor's own copy of the TS 36.213 tables (a local oracle; it never enters web/engine). */
export const TBS_REFERENCE = fixture('reference-phy/lte-tbs-reference.json');
/** qdss_deframe.py's secure-packet census for the whole trace (phy-summary.json 'encrypted'). */
export const CENSUS: EncryptedCensus = { records: 23_764, codes: 61 };

export interface Loaded {
  records: LogRecord[];
  timeBase: TimeBase;
  /** The extraction against the reference's TBS table, as the reference extractor ran. */
  run: PhyRun;
}

let cached: Promise<Loaded> | null = null;

export function loadCapture(): Promise<Loaded> {
  cached ??= (async () => {
    const { records } = readQmdl(await Deno.readFile(QMDL));
    const timeBase = TimeBase.of(records);
    const run = runPhy(records, timeBase, CENSUS, await referenceTable());
    return { records, timeBase, run };
  })();
  return cached;
}

export async function referenceTable(): Promise<LteTbsLookup> {
  // deno-lint-ignore no-explicit-any
  const j: any = await readJson(TBS_REFERENCE);
  return new LteTbsLookup(j.tbs as number[][]);
}

// deno-lint-ignore no-explicit-any
export type Golden = any;

const near = (a: number, b: number, relative = false) => Math.abs(a - b) <= 0.01 || (relative && Math.abs(a - b) <= 1e-4 * Math.abs(b));

/** Every difference between one KPI's values and its phy-golden entry ({count, min, max, mean}). */
export function statsDiff(values: number[], want: Golden, name: string): string[] {
  const out: string[] = [];
  const n = want.count ?? 0;
  if (values.length !== n) out.push(`${name} count ${values.length} != ${n}`);
  if (!n || !values.length) return out;
  let lo = Infinity, hi = -Infinity, sum = 0;
  for (const v of values) {
    lo = Math.min(lo, v);
    hi = Math.max(hi, v);
    sum += v;
  }
  const mean = sum / values.length;
  if (!near(lo, want.min)) out.push(`${name} min ${lo} != ${want.min}`);
  if (!near(hi, want.max)) out.push(`${name} max ${hi} != ${want.max}`);
  if (!near(mean, want.mean, true)) out.push(`${name} mean ${mean} != ${want.mean}`);
  return out;
}

/** The first or last samples against the golden's {tMs, value}. */
export function endsDiff(got: PhySample[], want: Golden[], name: string): string[] {
  const out: string[] = [];
  if (got.length !== want.length) out.push(`${name} length ${got.length} != ${want.length}`);
  got.forEach((s, i) => {
    const w = want[i];
    if (!w) return;
    if (!(Math.abs(s.tMs - w.tMs) <= 1.0)) out.push(`${name}[${i}] tMs ${s.tMs} != ${w.tMs}`);
    if (Array.isArray(w.value)) {
      const mine = s.perIndex ?? [];
      if (mine.length !== w.value.length) out.push(`${name}[${i}] per-index length`);
      mine.forEach((a, k) => {
        const b = w.value[k];
        if (!((a === null && b === null) || (a !== null && b !== null && Math.abs(a - b) <= 0.01))) out.push(`${name}[${i}][${k}] ${a} != ${b}`);
      });
    } else {
      const a = s.value, b = w.value;
      if (!((a === null && b === null) || (a !== null && b !== null && Math.abs(a - b) <= 0.01))) out.push(`${name}[${i}] value ${a} != ${b}`);
    }
  });
  return out;
}
