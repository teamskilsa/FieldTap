// Java's String.format and Double.toString for the numbers the Kotlin decoders print, so every string matches
// the goldens character for character. The algorithm of ios FTModel/JavaDecimal.swift, checked there against
// openjdk 21.
//
// %.Nf: Java rounds the shortest round-trip decimal of the double, half up (0.125 -> '0.13', 2.675 -> '2.68').
// Number.toFixed rounds the exact binary value instead (2.675 is 2.67499999... -> '2.67'), so it is never used.

/** String.format(Locale.ROOT, '%.<digits>f', value). */
export function fixed(value: number, digits: number): string {
  if (Number.isNaN(value)) return 'NaN';
  if (!Number.isFinite(value)) return value > 0 ? 'Infinity' : '-Infinity';
  // Java's Formatter takes the sign from Double.compare(value, 0.0), so -0.0 prints '-0.000'.
  const negative = value < 0 || Object.is(value, -0);
  const [d, point] = shortestDigits(Math.abs(value));
  // Keep point + digits digits, rounding half up on the first dropped one.
  const keep = point + digits;
  let kept: number[] = [];
  if (keep >= 0) {
    kept = d.slice(0, keep);
    while (kept.length < keep) kept.push(0);
    if ((keep < d.length ? d[keep] : 0) >= 5) increment(kept);
  }
  while (kept.length < digits + 1) kept.unshift(0);
  const whole = kept.slice(0, kept.length - digits).join('');
  const fraction = kept.slice(kept.length - digits).join('');
  return (negative ? '-' : '') + whole + (digits > 0 ? '.' + fraction : '');
}

/**
 * The shortest round-trip decimal digits of a non-negative finite double and where the point goes:
 * 123.45 gives ([1,2,3,4,5], 3), 0.00012 gives ([1,2], -3). ECMAScript's toExponential() with no argument
 * prints exactly the shortest digits.
 */
export function shortestDigits(v: number): [number[], number] {
  if (v === 0) return [[0], 1];
  const [mantissa, exponent] = v.toExponential().split('e');
  const digits = [...mantissa.replace('.', '')].map(Number);
  return [digits, Number(exponent) + 1];
}

function increment(digits: number[]): void {
  for (let i = digits.length - 1; i >= 0; i--) {
    if (digits[i] === 9) digits[i] = 0;
    else {
      digits[i]++;
      return;
    }
  }
  digits.unshift(1);
}

/** Kotlin's Double.toString: '10.0', '1.4', '1.0E7'. */
export function javaDouble(d: number): string {
  if (Number.isNaN(d)) return 'NaN';
  if (!Number.isFinite(d)) return d > 0 ? 'Infinity' : '-Infinity';
  if (d === 0) return Object.is(d, -0) ? '-0.0' : '0.0';
  const a = Math.abs(d);
  if (a >= 1e-3 && a < 1e7) {
    const s = String(d);
    return s.includes('.') ? s : s + '.0';
  }
  const [m, e] = d.toExponential().split('e');
  return `${m.includes('.') ? m : m + '.0'}E${Number(e)}`;
}

/** '%0<width>x' (or X): a non-negative integer in hex, zero-padded. Safe to 2^53. */
export function hex(value: number, width: number, upper = false): string {
  const s = value.toString(16).padStart(width, '0');
  return upper ? s.toUpperCase() : s;
}
