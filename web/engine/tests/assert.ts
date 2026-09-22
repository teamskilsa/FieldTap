// Minimal assertions, so the tests need nothing downloaded.

import { jsonDiff } from '../tools/golden.ts';

export class AssertionError extends Error {}

export function assert(cond: unknown, message = 'assertion failed'): asserts cond {
  if (!cond) throw new AssertionError(message);
}

const show = (v: unknown) => {
  try {
    return JSON.stringify(v, (_k, x) => (typeof x === 'bigint' ? `${x}n` : x instanceof Uint8Array ? `<${x.length} bytes>` : x));
  } catch {
    return String(v);
  }
};

/** Deep equality with the golden rules at tolerance 0 (no path ignored), or strict equality for primitives. */
export function assertEquals(actual: unknown, expected: unknown, message?: string): void {
  if (Object.is(actual, expected)) return;
  const diffs = jsonDiff(actual, expected, { tolerance: 0, ignore: [] });
  if (diffs.length) {
    const where = diffs.slice(0, 8).join(', ');
    throw new AssertionError(`${message ?? 'not equal'}: differs at [${where || '<root>'}]\n  actual:   ${show(actual)?.slice(0, 600)}\n  expected: ${show(expected)?.slice(0, 600)}`);
  }
}

export function assertAlmost(actual: number, expected: number, tolerance: number, message?: string): void {
  if (!(Math.abs(actual - expected) <= tolerance)) {
    throw new AssertionError(`${message ?? 'not within tolerance'}: ${actual} vs ${expected} (±${tolerance})`);
  }
}

export async function assertRejects(fn: () => Promise<unknown>, check?: (e: unknown) => boolean, message?: string): Promise<unknown> {
  try {
    await fn();
  } catch (e) {
    if (check && !check(e)) throw new AssertionError(`${message ?? 'rejected with the wrong error'}: ${e}`);
    return e;
  }
  throw new AssertionError(message ?? 'expected a rejection');
}

export function assertThrows(fn: () => unknown, check?: (e: unknown) => boolean, message?: string): unknown {
  try {
    fn();
  } catch (e) {
    if (check && !check(e)) throw new AssertionError(`${message ?? 'threw the wrong error'}: ${e}`);
    return e;
  }
  throw new AssertionError(message ?? 'expected a throw');
}
