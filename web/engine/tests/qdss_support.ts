// Synthetic QDSS traces for the deframer tests, built layer by layer the way the decoder reads them: DIAG packets,
// 16-byte units (start, bursts, word units with the reversed last word), and CoreSight formatter frames that
// interleave other trace IDs. Nothing here is capture-derived. Also the Python's .tsv layout, for parity checks.

import type { IndexRow } from '../src/qdss/deframer.ts';
import { DIAG_ATID } from '../src/qdss/formatter.ts';
import { concat, rng } from './support.ts';

// ------------------------------------------------------------------------------------------------ packets

const le16 = (v: number) => [v & 0xff, (v >> 8) & 0xff];
const le32 = (v: number) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >>> 24) & 0xff];
const le64 = (v: bigint) => [...le32(Number(v & 0xffffffffn)), ...le32(Number(v >> 32n))];

/** A 2026 modem timestamp (upper half in ts_ok's range), `n` ticks in. */
export const ts2026 = (n: number) => (0x01125000n << 32n) + BigInt(n);

/** 10 00 LL LL LL LL CC CC ts8 body. */
export function logPacket(code: number, ts: bigint, body: Uint8Array): Uint8Array {
  const inner = 12 + body.length;
  return new Uint8Array([0x10, 0x00, ...le16(inner), ...le16(inner), ...le16(code), ...le64(ts), ...body]);
}

/** 98 01 00 00 <u32 n> + packets; `count` overrides n (0 means 'until the end'). */
export function container(packets: Uint8Array[], count = packets.length): Uint8Array {
  return concat([new Uint8Array([0x98, 0x01, 0x00, 0x00, ...le32(count)]), ...packets]);
}

/** 9e 01 c2 00 + 16 bytes + LL LL CC CC ts8 body. */
export function securePacket(code: number, ts: bigint, body: Uint8Array): Uint8Array {
  return new Uint8Array([0x9e, 0x01, 0xc2, 0x00, ...new Array(16).fill(0xa5), ...le16(12 + body.length), ...le16(code), ...le64(ts), ...body]);
}

/** LL LL CC CC ts8 body, LL the whole packet. */
export function barePacket(code: number, ts: bigint, body: Uint8Array): Uint8Array {
  return new Uint8Array([...le16(12 + body.length), ...le16(code), ...le64(ts), ...body]);
}

// ------------------------------------------------------------------------------------------------ units

const TAIL = new Array(11).fill(1);
const unit = (bytes: number[]) => {
  const u = new Uint8Array(16);
  u.set(bytes.slice(0, 16));
  return u;
};

export const fillUnit = (lane = 0) => unit([lane << 5, 0, 0, 0, 0, ...TAIL]);
export const channelUnit = (lane: number, channel: number) => unit([(lane << 5) | 0x02, ...le16(channel), 0, 0, ...TAIL]);
export const contUnit = (lane: number, fill = 0) => unit([(lane << 5) | 0x03, ...new Array(15).fill(fill)]);

export interface FragmentSpec {
  lane: number;
  /** 1 whole, 2 QShrink F3, 3 first, 4 middle, 5 last, anything else unknown. */
  kind: number;
  payload: Uint8Array;
  /** Bits 6..4 of the class: payload bytes the start unit skips. */
  pad?: number;
  /** Continuation units to drop from the end (a truncated fragment) or, when negative, to add past it. */
  cut?: number;
}

/** The start unit and continuation units of one fragment, laid out as the modem writes them. */
export function fragmentUnits(spec: FragmentSpec): Uint8Array[] {
  const { lane, kind, payload } = spec;
  const pad = spec.pad ?? 0;
  const L = payload.length;
  const first = 8 - pad;
  const p = (i: number) => (i < L ? payload[i] : 0);
  const tag = (lane << 5) | 0x03;
  const start = unit([(lane << 5) | 0x13, (pad << 4) | kind, ...le16(L), 0x9d, 0x45, 0x00, 0x00]);
  for (let j = 0; j < pad; j++) start[8 + j] = 0xee;
  for (let j = 0; j < first; j++) start[8 + pad + j] = p(j);
  const units = [start];
  let at = first, rest = L - first;
  while (rest >= 240) {
    const displaced = contUnit(lane);
    for (let j = 0; j < 15; j++) {
      const u = new Uint8Array(16);
      u[0] = tag; // the tag overwrites byte 0 of each source line; unit 15 carries them
      for (let k = 1; k < 16; k++) u[k] = p(at + 16 * j + k);
      displaced[1 + j] = p(at + 16 * j);
      units.push(u);
    }
    units.push(displaced);
    at += 240;
    rest -= 240;
  }
  while (rest > 0) {
    const u = contUnit(lane, 0x5a);
    if (rest >= 12) {
      for (let k = 0; k < 12; k++) u[4 + k] = p(at + k);
    } else {
      // The last word unit: its ceil(R/4) valid words in reverse order.
      const words = Math.ceil(rest / 4);
      for (let m = 0; m < words; m++) for (let b = 0; b < 4; b++) u[4 + 4 * (words - 1 - m) + b] = p(at + 4 * m + b);
    }
    units.push(u);
    at += 12;
    rest -= 12;
  }
  const cut = spec.cut ?? 0;
  if (cut > 0) units.length = Math.max(1, units.length - cut);
  for (let k = 0; k < -cut; k++) units.push(contUnit(lane, 0x77));
  return units;
}

/** Units from several fragments merged round-robin, as channels interleave in the stream. */
export function interleave(groups: Uint8Array[][]): Uint8Array[] {
  const out: Uint8Array[] = [];
  const at = groups.map(() => 0);
  for (let left = true; left;) {
    left = false;
    groups.forEach((g, i) => {
      if (at[i] < g.length) {
        out.push(g[at[i]++]);
        left = true;
      }
    });
  }
  return out;
}

// ------------------------------------------------------------------------------------------------ layer 1

/** The trace ID the encoder switches to when it runs out of data (never 0x7f, whose ID byte is 0xff). */
export const PAD_ATID = 0x7d;

export interface Run {
  id: number;
  bytes: Uint8Array;
}

/**
 * CoreSight formatter frames carrying `runs` in order. An ID change goes at an even byte; when the byte after it
 * still belongs to the old ID the aux bit says so, which is how a run can end at any byte. Space after the last
 * run is PAD_ATID data.
 */
export function formatFrames(runs: Run[], startId = -1): Uint8Array {
  const ids: number[] = [], bytes: number[] = [];
  for (const r of runs) for (const b of r.bytes) {
    ids.push(r.id);
    bytes.push(b);
  }
  const n = ids.length;
  const frames: Uint8Array[] = [];
  let k = 0, cur = startId;
  while (k < n) {
    const f = new Uint8Array(16);
    let aux = 0;
    for (let i = 0; i < 8; i++) {
      const last = i === 7;
      if (k >= n) {
        if (cur !== PAD_ATID) {
          f[2 * i] = (PAD_ATID << 1) | 1;
          cur = PAD_ATID;
        }
        continue;
      }
      if (ids[k] !== cur) {
        cur = ids[k];
        f[2 * i] = (cur << 1) | 1;
        if (!last) f[2 * i + 1] = bytes[k++];
        continue;
      }
      if (last) {
        f[14] = bytes[k] & 0xfe;
        aux |= (bytes[k++] & 1) << 7;
        continue;
      }
      const next = k + 1 < n ? ids[k + 1] : PAD_ATID;
      if (next !== cur) {
        // ID change first, aux bit set: the byte after it is the old ID's last.
        f[2 * i] = (next << 1) | 1;
        aux |= 1 << i;
        f[2 * i + 1] = bytes[k++];
        cur = next;
        continue;
      }
      f[2 * i] = bytes[k] & 0xfe;
      aux |= (bytes[k++] & 1) << i;
      f[2 * i + 1] = bytes[k++];
    }
    f[15] = aux;
    frames.push(f);
  }
  return concat(frames);
}

/** A frame the formatter wrote no trace into. */
export const SKIP_FRAME = new Uint8Array([0xff, 0xff, 0xff, 0x7f, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);

/** `stream` as the DIAG ID, cut into runs with other IDs' bytes between them. */
export function withOtherIds(stream: Uint8Array, seed: number, others = [0x10, 0x00]): Run[] {
  const r = rng(seed);
  const runs: Run[] = [];
  for (let at = 0; at < stream.length;) {
    const n = 1 + Math.floor(r() * 3000);
    runs.push({ id: DIAG_ATID, bytes: stream.subarray(at, at + n) });
    at += n;
    if (r() < 0.3) runs.push({ id: others[Math.floor(r() * others.length)], bytes: Uint8Array.from({ length: 1 + Math.floor(r() * 40) }, () => Math.floor(r() * 256)) });
  }
  return runs;
}

/** Frames cut into chunks of whole frames, each optionally followed by a tail shorter than a frame. */
export function chunksOf(frames: Uint8Array, seed: number, tails = false): Uint8Array[] {
  const r = rng(seed);
  const out: Uint8Array[] = [];
  for (let at = 0; at < frames.length;) {
    const n = 16 * (1 + Math.floor(r() * 4000));
    const whole = frames.subarray(at, at + n);
    at += n;
    const tail = tails ? Math.floor(r() * 16) : 0;
    out.push(tail ? concat([whole, Uint8Array.from({ length: tail }, () => Math.floor(r() * 256))]) : whole);
  }
  return out;
}

// ------------------------------------------------------------------------------------------------ random traces

/**
 * A random ATID-0x32 stream exercising every rule: fill and channel units, lanes rebinding, interleaved
 * fragments of every kind (whole, QShrink, first/middle/last runs, runs left unterminated, orphans, unknown
 * kinds), bursts and every last-word remainder, truncated fragments and extra units, orphan and bad-type units,
 * containers, secure, bare, counted and malformed packets, and timestamps in and out of the 2026 range.
 */
export function randomStream(seed: number, fragments: number, phase: number): Uint8Array {
  const r = rng(seed);
  const pick = <T>(xs: T[]) => xs[Math.floor(r() * xs.length)];
  const bytes = (n: number) => Uint8Array.from({ length: n }, () => Math.floor(r() * 256));
  const channels = [0x0152, 0x0194, 0x00dc, 0x013f];
  const codes = [0xb0c0, 0xb821, 0x1375, 0xb8c9, 0x1874, 0xb0e2];
  let tick = 0;
  const ts = () => {
    const x = r();
    tick += 1 + Math.floor(r() * 50_000);
    return x < 0.8 ? ts2026(tick) : x < 0.93 ? 0n : BigInt(Math.floor(r() * 2 ** 31)) << 16n;
  };
  const message = (): Uint8Array => {
    const x = r();
    const body = () => bytes(Math.floor(r() * (r() < 0.2 ? 900 : 90)));
    if (x < 0.45) return container(Array.from({ length: 1 + Math.floor(r() * 2) }, () => logPacket(pick(codes), ts(), body())));
    if (x < 0.55) return logPacket(pick(codes), ts(), body());
    if (x < 0.65) return securePacket(0xb8dd, ts(), body());
    if (x < 0.72) return barePacket(pick(codes), ts(), body());
    if (x < 0.8) return concat([new Uint8Array([pick([0x79, 0x99, 0x60, 0x9d])]), bytes(Math.floor(r() * 60))]);
    if (x < 0.85) return container([logPacket(0x1375, ts(), body()), new Uint8Array([0x79, 1, 2, 3])], 0);
    if (x < 0.9) return logPacket(0x1375, ts(), body()).subarray(0, 20); // lengths disagree: log_bad
    return bytes(Math.floor(r() * 40));
  };
  const out: Uint8Array[] = [bytes(phase)];
  for (let lane = 0; lane < 8; lane++) if (r() < 0.7) out.push(channelUnit(lane, pick(channels)));
  let open: Uint8Array[][] = [];
  const flush = () => {
    out.push(...interleave(open));
    open = [];
  };
  for (let f = 0; f < fragments; f++) {
    const lane = Math.floor(r() * 8);
    if (open.length >= 1 + Math.floor(r() * 3)) flush();
    if (r() < 0.05) out.push(channelUnit(lane, pick(channels)));
    if (r() < 0.03) out.push(fillUnit(lane));
    if (r() < 0.01) out.push(contUnit(lane, 0x33)); // maybe an orphan
    if (r() < 0.005) out.push(unit([0x07, ...bytes(15)])); // bad type
    const cut = r() < 0.03 ? 1 + Math.floor(r() * 3) : r() < 0.03 ? -1 - Math.floor(r() * 2) : 0;
    const pad = r() < 0.2 ? Math.floor(r() * 8) : 0;
    const x = r();
    // One lane carries one fragment at a time here, so interleaving never reorders a lane's own units.
    const units: Uint8Array[] = [];
    if (x < 0.35) units.push(...fragmentUnits({ lane, kind: 1, payload: message(), pad, cut }));
    else if (x < 0.6) units.push(...fragmentUnits({ lane, kind: 2, payload: bytes(Math.floor(r() * 120)), pad }));
    else if (x < 0.9) {
      const msg = message();
      const cuts = [0, Math.floor(r() * msg.length), msg.length].sort((a, b) => a - b);
      const parts = r() < 0.5 ? [msg.subarray(0, cuts[1]), msg.subarray(cuts[1])] : [msg.subarray(0, cuts[1]), msg.subarray(cuts[1], (cuts[1] + msg.length) >> 1), msg.subarray((cuts[1] + msg.length) >> 1)];
      const kinds = parts.length === 2 ? [3, 5] : [3, 4, 5];
      const drop = r() < 0.06 ? kinds.length - 1 : r() < 0.03 ? 0 : -1; // an unterminated run, or an orphan
      parts.forEach((p, i) => {
        if (i !== drop) units.push(...fragmentUnits({ lane, kind: kinds[i], payload: p, pad: i === 0 ? pad : 0, cut: i === parts.length - 1 ? cut : 0 }));
      });
    } else units.push(...fragmentUnits({ lane, kind: pick([0, 6, 9, 15]), payload: bytes(Math.floor(r() * 50)) }));
    if (open.some((g) => g.length && (g[0][0] >> 5) === lane)) flush();
    open.push(units);
  }
  flush();
  return concat(out);
}

// ------------------------------------------------------------------------------------------------ parity

/** The Python's .tsv: '%d\t%s\t%s\t0x%04X\t%d\t%d\t%d\n' per record, after its header line. */
export function tsvOf(rows: IndexRow[]): string {
  let out = 'offset\tkey\tform\tcode\tts\tbody_len\tcomplete\n';
  for (const r of rows) {
    const code = r.code.toString(16).toUpperCase().padStart(4, '0');
    out += `${r.offset}\t${r.channel ?? 'None'}\t${r.form}\t0x${code}\t${r.timestampRaw}\t${r.bodyLength}\t${r.complete ? 1 : 0}\n`;
  }
  return out;
}
