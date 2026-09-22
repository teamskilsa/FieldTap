// A streaming port of ios/Fixtures/local/reference/qdss_deframe.py, its verified default rules only (demux by
// channel, reversed last words, gather by kind, secure logs counted not kept), plus the resync below:
//   layer 1  formatter.ts  CoreSight frames -> the ATID-0x32 stream
//   layer 2  units.ts      16-byte units -> fragments per channel
//   gather   here          fragments by kind: 1 whole, 2 QShrink F3 (counted), 3 first, 4 middle, 5 last
//   layer 3  packets.ts    messages -> DIAG packets -> log records
//
// Usage: for each trace chunk in name order, feed() its bytes in any split, then endChunk(); finish() once. The
// output does not depend on the split. Nothing is kept of the chunks themselves: layer 1 holds at most a partial
// frame, layer 2 the first 320,031 bytes until the phase is settled and then less than a unit between feeds, so
// memory is the open fragments plus the records (the first capture: 1.1 M fragments, 92,133 records).
//
// Parity: records written with diag/qmdl.ts writeQmdl hash (tools/md5.ts) to the Python's .qmdl md5
// (qdss-first3 8bee4165..., qdss-attach4 245d59fc..., the whole first capture e53a167b...), and the stats
// serialise (JSON, indent 1) byte for byte as the Python's stats.json, except that JS always puts the key '2026'
// first in `ts` (an integer-like key), where Python keeps first-seen order; on the real traces it is first anyway.
//
// Resync (the one rule beyond the reference's defaults). The reference settles one unit phase and keeps it for the
// whole stream. That holds for a trace whose chunks are all present, but not for one the sysdiagnose collector took
// files out of: the moving capture (08-57-25) is missing 3 of its 133 segments, and its phase slips 8 times — 3 at
// the holes and 5 mid-chunk. With one phase it yields 18,667 of its 85,361 records. So layer 2 also:
//   - re-finds the phase when it loses sync, i.e. RESYNC_RUN consecutive units fail the tag check, scanning
//     RESYNC_WINDOW bytes from the first unit of the bad run (the reference's own per-4 KB scan, done online);
//   - re-finds the phase at a chunk-sequence gap too, on the caller's `gap()`.
// At either break the fragments in flight are closed for what they already hold (their leading bytes were read
// before the break) rather than thrown away, and the lanes are unbound.
// It cannot fire on a whole trace: the first capture has no bad unit at all in 5.4 M (qdss-full-stats.json has no
// u_badtype key), so its md5 and its byte-identical stats are untouched. The resync keys appear in `stats` only
// when a resync happened, which keeps that parity literal rather than by tolerance.
//
// Not ported: the Python's rejected alternatives (--demux lane, --no-reverse, --gather bit0, --per-chunk,
// --keep-secure) and its atid32.bin cache.

import { hexCode, type LogRecord } from '../diag/record.ts';
import type { DeframeStats, EncryptedCensus } from '../types.ts';
import { BodyStore } from './bodies.ts';
import { Counter } from './counter.ts';
import { Deformatter } from './formatter.ts';
import { classify, type PacketForm, splitPackets, tsHi, tsLo } from './packets.ts';
import { ByteQueue } from './queue.ts';
import { CHANNEL, CONTINUATION, expectedUnits, FILL, findPhase, Fragment, PHASE_WINDOW, START, UNIT } from './units.ts';

export interface DeframeOutput {
  /** Plain log records (DIAG_LOG_F and bare), in the reference's output order: sorted by effective timestamp,
   *  records without a plausible stamp inheriting the last one seen on their channel. */
  records: LogRecord[];
  /** Secure (0x9E) records: only their headers are readable, so they are counted, per code. */
  secure: EncryptedCensus;
  stats: DeframeStats;
  /** Bytes per trace ID over the whole trace, as the Python's atid32.bin.json has them ({'none': 10, '0x32': ...}). */
  bytesPerAtid: Record<string, number>;
  /** With `index`: one row per record, in output order (the Python's .tsv). */
  index?: IndexRow[];
}

/** A record's row in the Python's .tsv index. */
export interface IndexRow {
  /** Stream offset of the start unit of the record's (first) fragment. */
  offset: number;
  /** The channel, or null when its lane was never bound. */
  channel: number | null;
  /** 'multi98/log', 'plain/bare/unterm', ... */
  form: string;
  code: number;
  timestampRaw: bigint;
  bodyLength: number;
  complete: boolean;
}

export interface DeframerOptions {
  /** Keep the .tsv index rows. */
  index?: boolean;
  /** Sees the ATID-0x32 stream as it is deformatted (the Python's atid32.bin), in order. */
  onStream?: (bytes: Uint8Array) => void;
}

export const EMPTY_STATS: DeframeStats = {
  atid32_bytes: 0,
  chunks: 0,
  stats: {},
  fits: {},
  fragment_kinds: {},
  packets: {},
  log_records: 0,
  distinct_codes: 0,
  ts: {},
  incomplete_records: 0,
  targets: {},
  top_codes: [],
};

/** The codes stats.json reports even when absent. */
const TARGETS = [0xb0c0, 0xb0c1, 0xb0c2, 0xb0e2, 0xb0e3, 0xb0ec, 0xb0ed, 0xb0e4, 0xb0e5, 0xb821, 0xb825, 0xb826, 0xb80a, 0xb80b, 0xb80c];
/** A lane that no channel unit has bound: Python's key None. Channel ids are u16, so it cannot collide. */
const UNBOUND = -1;

/** Consecutive units failing the tag check that mean the phase has slipped, not that one unit is damaged. A
 *  correctly phased stream has essentially none (the first capture: 0 in 5,411,059), so 8 is already decisive. */
const RESYNC_RUN = 8;
/** Bytes scanned to re-find the phase, as the reference's slip hunt scanned per 4 KB. 256 candidate units per
 *  phase is plenty, and waiting for so few bytes keeps the resync split-invariant. */
const RESYNC_WINDOW = 4096;

/** ts_ok: the upper half of a 2026 modem timestamp. */
const plausible = (hi: number) => hi >= 0x01120000 && hi <= 0x0113ffff;

type Tag = '' | 'unterm';

interface Found {
  offset: number;
  key: number;
  form: PacketForm;
  kind: string;
  tag: Tag;
  code: number;
  hi: number;
  lo: number;
  body: Uint8Array;
  complete: boolean;
}

interface Gathering {
  offset: number;
  parts: Uint8Array[];
  complete: boolean;
}

function concat(parts: Uint8Array[]): Uint8Array {
  if (parts.length === 1) return parts[0];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

export class QdssDeframer {
  private readonly layer1 = new Deformatter();
  private readonly queue = new ByteQueue();
  private phase: number | null = null;
  private chunks = 0;
  private fedSinceEnd = false;
  private done = false;
  /** Stream offset the phase is being re-found from, while a resync waits for its window. */
  private resync: number | null = null;
  /** Units failing the tag check in a row, for the resync trigger. */
  private badRun = 0;

  /** Lane -> bound channel. */
  private readonly lanes = new Int32Array(8).fill(UNBOUND);
  /** Channel -> its open fragment, in opening order (a dict's order: a reopened key moves to the end). */
  private readonly open = new Map<number, Fragment>();
  /** Channel -> the first[+middle] fragments waiting for their last. */
  private readonly gathering = new Map<number, Gathering>();

  private readonly stats = new Counter<string>();
  private readonly fits = new Counter<string>();
  private readonly kinds = new Counter<number>();
  private readonly packets = new Counter<string>();
  private readonly secure = new Counter<number>();
  private readonly found: Found[] = [];
  private readonly bodies = new BodyStore();

  constructor(private readonly options: DeframerOptions = {}) {}

  /** More bytes of the current chunk. */
  feed(bytes: Uint8Array): void {
    if (this.done) throw new Error('QdssDeframer: feed after finish');
    this.fedSinceEnd = true;
    const q = this.queue;
    const before = this.layer1.written;
    this.layer1.feed(bytes, q);
    // The new bytes are the queue's last ones (reserve may have moved the queue, so not from a saved index).
    const added = this.layer1.written - before;
    if (this.options.onStream && added > 0) this.options.onStream(q.bytes.subarray(q.end - added, q.end));
    if (this.phase === null && q.base + q.end >= PHASE_WINDOW) this.settlePhase();
    if (this.phase !== null) this.units();
  }

  /** The current chunk is complete. */
  endChunk(): void {
    if (this.done) throw new Error('QdssDeframer: endChunk after finish');
    this.layer1.endChunk();
    this.chunks++;
    this.fedSinceEnd = false;
  }

  /**
   * Trace files are missing before the next chunk, so the stream jumps: whatever layer 2 was assembling ends here
   * and the unit phase is re-found after the hole. Call it between endChunk() and the next chunk's feed(); the
   * caller knows the chunk numbers (0x61BE, 0x61BF, ...), the deframer never sees a file name.
   */
  gap(): void {
    if (this.done) throw new Error('QdssDeframer: gap after finish');
    this.stats.add('chunk_gaps');
    // What is buffered belongs to the chunks before the hole, and is a contiguous stream of its own: settle a
    // phase on it if the window never filled, read it, then start again on the far side.
    if (this.phase === null) this.settlePhase();
    this.units(true);
    // A unit straddling the hole can never be completed.
    this.queue.start = this.queue.end;
    this.slipped('gap');
  }

  finish(): DeframeOutput {
    if (this.done) throw new Error('QdssDeframer: finish called twice');
    if (this.fedSinceEnd) this.endChunk();
    this.done = true;
    if (this.phase === null) this.settlePhase();
    this.units(true);
    this.drain();
    return this.output();
  }

  /** Nothing more will arrive for the fragments in flight: those still open close in opening order, then what is
   *  still gathering is emitted. At the end of the stream, and at a resync, where a fragment's leading bytes were
   *  read before the slip and so are good. */
  private drain(): void {
    for (const f of this.open.values()) this.closed(f);
    this.open.clear();
    for (const [key, g] of this.gathering) {
      this.stats.add('gather_left_open');
      this.emit(g.offset, key, concat(g.parts), g.complete, 'unterm');
    }
    this.gathering.clear();
  }

  /** find_phase over the first PHASE_WINDOW bytes, or over the whole stream when it is shorter. */
  private settlePhase(): void {
    const q = this.queue;
    this.phase = findPhase(q.bytes.subarray(q.start, q.end));
    this.stats.set('phase', this.phase);
    q.start += Math.min(this.phase, q.end - q.start);
  }

  /** Every complete unit in the queue (iter_fragments), resolving a pending resync first. `force` decides a
   *  resync on the bytes at hand instead of waiting for its window: the stream, or a chunk sequence, has ended. */
  private units(force = false): void {
    for (;;) {
      if (this.resync !== null && !this.resolveResync(force)) return;
      if (!this.scanUnits()) return;
    }
  }

  /** Consumes complete units. Returns true when it stopped on a slip (a resync is now pending), false when it
   *  ran out of bytes. */
  private scanUnits(): boolean {
    const q = this.queue;
    const s = q.bytes;
    let i = q.start;
    for (; i + UNIT <= q.end; i += UNIT) {
      const h = s[i];
      const t = h & 0x1f;
      const lane = h >> 5;
      if (t === FILL) {
        this.stats.add('u_fill');
      } else if (t === CHANNEL) {
        this.stats.add('u_chan');
        this.lanes[lane] = s[i + 1] | (s[i + 2] << 8);
      } else if (t === START) {
        this.stats.add('u_start');
        const key = this.lanes[lane];
        const was = this.open.get(key);
        if (was) {
          this.open.delete(key);
          this.closed(was);
        }
        const kind = s[i + 1] & 0xf;
        this.open.set(key, new Fragment(q.base + i, key, s, i, kind === 1 || (kind >= 3 && kind <= 5)));
      } else if (t === CONTINUATION) {
        this.stats.add('u_cont');
        const f = this.open.get(this.lanes[lane]);
        if (f) f.add(s, i);
        else this.stats.add('u_cont_orphan');
      } else {
        this.stats.add('u_badtype');
        if (++this.badRun >= RESYNC_RUN) {
          // The phase has slipped: every unit since the run began was read at the wrong offset.
          q.start = i - (RESYNC_RUN - 1) * UNIT;
          this.slipped('slip');
          return true;
        }
        continue; // a bad unit does not break the run
      }
      this.badRun = 0;
    }
    q.start = i;
    return false;
  }

  /** Layer 2 lost the phase (a slip) or the stream jumped (a hole): the fragments in flight cannot be finished, so
   *  they are closed for what they hold, the lanes are unbound, and the phase is re-found from here. Closing them
   *  rather than discarding them is worth about 125 records on the moving capture, all of them short and counted. */
  private slipped(reason: 'slip' | 'gap'): void {
    this.stats.add(`resync_${reason}`);
    this.reset();
    this.resync = this.queue.base + this.queue.start;
  }

  /** Layer 2's state: the fragments in flight and the lane bindings (a channel unit rebinds a lane after a slip). */
  private reset(): void {
    this.badRun = 0;
    this.drain();
    this.lanes.fill(UNBOUND);
  }

  /** Re-finds the phase from `resync` once RESYNC_WINDOW bytes are there, or on `force` with what there is.
   *  Returns false while it waits, so the result never depends on how the bytes were fed. */
  private resolveResync(force: boolean): boolean {
    const q = this.queue;
    const from = this.resync! - q.base;
    const have = q.end - from;
    if (have < RESYNC_WINDOW + UNIT && !force) return false;
    this.resync = null;
    const p = findPhase(q.bytes.subarray(from, from + Math.min(have, RESYNC_WINDOW + UNIT)));
    // Phase 0 is the alignment that just failed, so no better one is in view: step over the bad run instead, so
    // the scan always moves forward and a long damaged stretch cannot loop.
    this.stats.add(p === 0 ? 'resync_kept_phase' : 'resync_new_phase');
    q.start = Math.min(from + (p === 0 ? RESYNC_RUN * UNIT : p), q.end);
    return true;
  }

  /** A fragment closed: assembly counters, then gathering by kind. */
  private closed(f: Fragment): void {
    const complete = f.complete;
    if (!complete) this.fits.add('short');
    else if (f.used < f.units) this.fits.add('extra_units');
    else this.fits.add('exact');
    if (expectedUnits(f.length, f.pad) !== f.units) this.fits.add('count_mismatch');
    const kind = f.kind;
    this.kinds.add(kind);
    if (kind === 2) {
      this.stats.add('qshrink_f3');
      return;
    }
    const key = f.key;
    if (kind === 1) {
      this.flushUnterminated(key);
      this.emit(f.offset, key, f.payload(), complete, '');
    } else if (kind === 3) {
      this.flushUnterminated(key);
      this.gathering.set(key, { offset: f.offset, parts: [f.payload()], complete });
    } else if (kind === 4 || kind === 5) {
      const g = this.gathering.get(key);
      if (!g) {
        this.stats.add(`gather_orphan_kind${kind}`);
        return;
      }
      g.parts.push(f.payload());
      g.complete = g.complete && complete;
      if (kind === 4) return;
      this.gathering.delete(key);
      this.emit(g.offset, key, concat(g.parts), g.complete, '');
    } else {
      this.stats.add(`gather_unknown_kind_${kind}`);
    }
  }

  /** A first(3)[+middle(4)] run followed by a new 3 or 1 without a 5 is emitted as it stands. */
  private flushUnterminated(key: number): void {
    const g = this.gathering.get(key);
    if (!g) return;
    this.stats.add('gather_flushed_unterminated');
    this.gathering.delete(key);
    this.emit(g.offset, key, concat(g.parts), g.complete, 'unterm');
  }

  private emit(offset: number, key: number, msg: Uint8Array, complete: boolean, tag: Tag): void {
    this.stats.add(tag ? `messages_${tag}` : 'messages');
    if (!complete) this.stats.add('messages_incomplete');
    splitPackets(msg, (form, p) => {
      const c = classify(p);
      this.packets.add(tag ? `${c.kind}_${tag}` : c.kind);
      if (c.kind === 'log' || c.kind === 'bare') {
        this.found.push({
          offset, key, form, kind: c.kind, tag, code: c.code,
          hi: tsHi(p, c.tsAt), lo: tsLo(p, c.tsAt), body: this.bodies.put(p.subarray(c.bodyAt)), complete,
        });
      } else if (c.kind === 'secure') {
        this.secure.add(c.code);
      }
    });
  }

  private output(): DeframeOutput {
    const found = this.found;
    const codes = new Counter<number>();
    const ts = new Counter<string>();
    let incomplete = 0;
    for (const r of found) {
      codes.add(r.code);
      ts.add(plausible(r.hi) ? '2026' : r.hi === 0 && r.lo === 0 ? 'zero' : 'other');
      if (!r.complete) incomplete++;
    }

    // Output order: timestamps are monotonic within a channel, but channels interleave with a lag, so records are
    // sorted by an effective timestamp. Records whose code never carries a modem timestamp (0, or not in the
    // 2026 range) inherit the last plausible one seen on their channel; ties keep the emission order.
    const n = found.length;
    const effHi = new Uint32Array(n), effLo = new Uint32Array(n);
    const last = new Map<number, Found>();
    for (let i = 0; i < n; i++) {
      const r = found[i];
      const from = plausible(r.hi) ? r : last.get(r.key);
      if (from === r) last.set(r.key, r);
      if (from) {
        effHi[i] = from.hi;
        effLo[i] = from.lo;
      }
    }
    const order = Array.from({ length: n }, (_, i) => i).sort((a, b) => effHi[a] - effHi[b] || effLo[a] - effLo[b] || a - b);

    const raw = (r: Found) => (BigInt(r.hi) << 32n) | BigInt(r.lo);
    // The Python writes every record back as '<BBHHHQ' with more = 0, so the records carry 0 too.
    const records: LogRecord[] = order.map((i) => ({ code: found[i].code, timestampRaw: raw(found[i]), body: found[i].body, more: 0 }));

    const kinds = [...this.kinds.entries()].sort((a, b) => a[0] - b[0]);
    const stats: DeframeStats = {
      atid32_bytes: this.layer1.written,
      chunks: this.chunks,
      stats: this.stats.toObject(),
      fits: this.fits.toObject(),
      fragment_kinds: Object.fromEntries(kinds.map(([k, v]) => [String(k), v])),
      packets: this.packets.toObject(),
      log_records: n,
      distinct_codes: codes.size,
      ts: ts.toObject(),
      incomplete_records: incomplete,
      targets: Object.fromEntries(TARGETS.map((c) => [hexCode(c), codes.get(c)])),
      top_codes: codes.mostCommon(15).map(([c, k]) => [hexCode(c), k]),
    };

    let secureRecords = 0;
    const byCode: Record<string, number> = {};
    for (const [code, k] of [...this.secure.entries()].sort((a, b) => a[0] - b[0])) {
      byCode[hexCode(code)] = k;
      secureRecords += k;
    }
    const out: DeframeOutput = {
      records,
      secure: { records: secureRecords, codes: this.secure.size, byCode },
      stats,
      bytesPerAtid: this.layer1.bytesPerAtid(),
    };
    if (this.options.index) {
      out.index = order.map((i) => {
        const r = found[i];
        return {
          offset: r.offset,
          channel: r.key === UNBOUND ? null : r.key,
          form: `${r.form}/${r.kind}${r.tag ? '/' + r.tag : ''}`,
          code: r.code,
          timestampRaw: raw(r),
          bodyLength: r.body.length,
          complete: r.complete,
        };
      });
    }
    return out;
  }
}
