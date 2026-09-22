// Little-endian reads over a DIAG log body. Every decoder checks the length it needs before reading, so a short
// or garbled record is counted as malformed instead of being read past its end.

export const u8 = (b: Uint8Array, o: number): number => b[o];

export const u16 = (b: Uint8Array, o: number): number => b[o] | (b[o + 1] << 8);

export const i16 = (b: Uint8Array, o: number): number => (u16(b, o) << 16) >> 16;

export const u32 = (b: Uint8Array, o: number): number =>
  (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;

/** A u64 counter as a number: exact below 2^53, which cumulative MAC byte counters never reach. */
export const u64 = (b: Uint8Array, o: number): number => u32(b, o) + u32(b, o + 4) * 4_294_967_296;

/** True when `count` bytes starting at `o` are inside the body. */
export const has = (b: Uint8Array, o: number, count: number): boolean => o >= 0 && count >= 0 && o + count <= b.length;

/** `width` (< 32) bits of the u32 `w` starting at bit `shift`. */
export const bits = (w: number, shift: number, width: number): number => (w >>> shift) & (2 ** width - 1);

/**
 * What a decoder made of one record: its values, a record version it has not been validated for (counted in
 * PhyCapture.versionMisses under `key`, never guessed at), or a body too short for its own layout.
 */
export type Decoded<V> =
  | { kind: 'value'; value: V }
  | { kind: 'versionMiss'; key: string; version: string }
  | { kind: 'malformed' };

export const value = <V>(v: V): Decoded<V> => ({ kind: 'value', value: v });

export const malformed: { kind: 'malformed' } = { kind: 'malformed' };

/** A version miss keyed '0xB173 v48' (the Radio page's "not decodable (version 48)"). */
export const versionMiss = (code: string, version: string): { kind: 'versionMiss'; key: string; version: string } => ({
  kind: 'versionMiss',
  key: `${code} ${version}`,
  version,
});
