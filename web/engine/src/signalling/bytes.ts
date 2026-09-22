// Byte access with the JVM's bounds: the Kotlin decoders read past the end of a short PDU on purpose and catch
// IndexOutOfBoundsException ("a message shorter than its own definition yields the fields read before it ran
// out"). A typed array returns undefined there instead, which would read as 0 and invent fields, so every read
// the Kotlin leaves unguarded goes through `u8`, which throws `OutOfBounds` as the JVM would.

/** The analogue of Java's IndexOutOfBoundsException: the only error the decoders catch. */
export class OutOfBounds extends RangeError {
  constructor(message = 'index out of bounds') {
    super(message);
  }
}

/** p[i] as an unsigned byte; throws OutOfBounds past either end. */
export function u8(p: Uint8Array, i: number): number {
  if (i < 0 || i >= p.length) throw new OutOfBounds(`byte ${i} of ${p.length}`);
  return p[i];
}

/** Little-endian u16 and u32 (as a non-negative number), bounds-checked. */
export const u16le = (p: Uint8Array, i: number) => u8(p, i) | (u8(p, i + 1) << 8);
export const u32le = (p: Uint8Array, i: number) => (u16le(p, i) + u16le(p, i + 2) * 0x10000);

/** ByteArray.contentEquals. */
export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** String(p, at, n, US_ASCII): throws OutOfBounds when the range is not inside p; bytes >= 0x80 become U+FFFD. */
export function ascii(p: Uint8Array, at: number, n: number): string {
  if (at < 0 || n < 0 || at + n > p.length) throw new OutOfBounds(`bytes ${at}+${n} of ${p.length}`);
  let s = '';
  for (let i = at; i < at + n; i++) s += p[i] < 0x80 ? String.fromCharCode(p[i]) : '�';
  return s;
}

/** Runs `read`, turning OutOfBounds into `fallback`: the Kotlin `try { ... } catch (e: IndexOutOfBoundsException)`. */
export function orElse<T>(read: () => T, fallback: T): T {
  try {
    return read();
  } catch (e) {
    if (e instanceof OutOfBounds) return fallback;
    throw e;
  }
}
