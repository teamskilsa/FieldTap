"""Rebuild a Qualcomm DIAG log from an iPhone's QDSS baseband trace.

With Apple's Baseband logging profile installed, a sysdiagnose carries the modem's own trace in
``logs/Baseband/log-bb-<time>-qdss/``: a ring of about 1 MiB chunks named ``0x%08X.bin`` (the iPhone 17 kept
130 of them, about 27 s of trace) plus ``header.qmdl2``, a 77-byte descriptor that is not stream data. The
chunks are an ARM CoreSight trace, not HDLC. This module turns them back into the ``.qmdl`` every other FieldTap
tool reads: one HDLC-framed DIAG_LOG_F packet per log record.

It is a port of the verified default rules of the reference deframer (qdss_deframe.py, kept with the local
fixtures) and must write the same bytes; the rejected alternatives it could switch to are not carried over.
docs/research/iphone-baseband-capture.md describes the format.

Layer 1, the CoreSight trace formatter (TMC/ETR memory-aligned 16-byte frames, no FSYNC, aligned to offset 0 of
every chunk, the current trace ID carried across chunks). For an even byte ``x = f[2i]`` (i < 7): if ``x & 1``
it is a change of trace ID to ``x >> 1``, and a set aux bit i (``aux = f[15]``) means the byte after it still
belongs to the old ID; otherwise x is data whose low bit is aux bit i, followed by the data byte ``f[2i + 1]``.
``f[14]`` is an ID or data by aux bit 7. The DIAG traffic is trace ID 0x32.

Layer 2, 16-byte units at a fixed phase in the 0x32 stream. ``u[0] = lane << 5 | type``: 0x00 fill (every 65th
unit), 0x02 binds a lane to the u16 channel at ``u[1:3]``, 0x13 starts a fragment (class byte, u16 length, a u32
word, then ``8 - pad`` payload bytes), 0x03 continues the fragment open on the lane's channel. After the start
unit, while 240 or more bytes are missing, a burst of 16 units carries a 240-byte block: units 0..14 hold bytes
1..15 of a 16-byte line whose byte 0 the unit tag overwrote, and unit 15 holds those 15 displaced bytes. The
rest comes 12 bytes per unit from ``u[4:16]``; in the last unit, when fewer than 12 bytes are missing, the
valid 32-bit words arrive in reverse order. Fragments are gathered per channel by kind: 1 whole, 2 QShrink F3
text (skipped), 3 first, 4 middle, 5 last. A first(+middle) run followed by a new 3 or 1 without a 5 is kept as
it stands; every such message in the reference trace was a valid log packet.

Layer 3, the DIAG packets of a gathered message: ``98 01 00 00 <u32 n>`` wraps n packets; ``10 00`` is a plain
log packet; ``9e 01 c2 00`` is a "secure" log whose body the modem encrypted (counted, never written); 0x79,
0x99, 0x60 and 0x9d are messages, F3 text, events and command responses (counted).

Resync, the one rule beyond the reference's defaults, ported behaviour for behaviour from the streaming TypeScript
deframer (web/engine/src/qdss/deframer.ts). The reference settles one unit phase and keeps it for the whole
stream. That holds for a trace whose chunks are all present, but not for one the sysdiagnose collector took files
out of: the moving capture (08-57-25) is missing 3 of its 133 segments, and its phase slips 8 times, 3 at the holes
and 5 mid-chunk; with one phase it yields 18,667 of its 85,000-odd records. So layer 2 also re-finds the phase when
it loses sync, i.e. RESYNC_RUN consecutive units fail the tag check, scanning RESYNC_WINDOW bytes from the first
unit of the bad run (the reference's own per-4 KB slip hunt, done in line), and at a hole in the chunk numbering
(0x000061BE.bin, 0x000061BF.bin, ...). At either break the fragments in flight are closed for what they already
hold (their leading bytes were read before the break) rather than thrown away, and the lanes are unbound. The
rule is split-invariant: a resync decides on the same window of bytes whatever the chunk boundaries, as the
TypeScript decides once RESYNC_WINDOW bytes have arrived and only a hole or the end of the stream makes it decide
on less. It cannot fire on a whole trace (the first capture has no bad unit in 5.4 M), so such a trace deframes
byte for byte as before, and the resync keys appear in the stats only when a resync happened.

Records are written in the order of an effective timestamp: the modem's own where it is plausible, otherwise the
last plausible one on the same channel, because channels interleave with a lag.
"""

from __future__ import annotations

import collections
import os
import plistlib
import re
import shutil
import struct
import tarfile
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Iterator, Optional, Sequence

from . import hdlc, protocol

ATID = 0x32
FILL_TAIL = b"\x01" * 11
CHUNK_NAME = re.compile(r"0x[0-9A-Fa-f]+\.bin")
TRACE_DIR = re.compile(r"log-bb-[^/]*-qdss")
PROFILE_STUB = re.compile(r"profile-[0-9A-Fa-f]+\.stub")
BASEBAND_PROFILE = b"com.apple.basebandlogging"
#: iOS names the archive after the moment the buttons were pressed, in local time with its UTC offset.
ARCHIVE_NAME = re.compile(r"sysdiagnose_(\d{4})\.(\d{2})\.(\d{2})_(\d{2})-(\d{2})-(\d{2})([+-])(\d{2})(\d{2})")

#: The log codes the stats count individually: the signalling FieldTap decodes.
TARGET_CODES = (0xB0C0, 0xB0C1, 0xB0C2, 0xB0E2, 0xB0E3, 0xB0EC, 0xB0ED, 0xB0E4, 0xB0E5,
                0xB821, 0xB825, 0xB826, 0xB80A, 0xB80B, 0xB80C)

_OTHER_KINDS = {0x79: "extmsg_0x79", 0x99: "qsr4_0x99", 0x60: "event_0x60", 0x9D: "cmd_0x9d"}

#: find_phase's sample, 20,000 candidate units per phase, so the first PHASE_WINDOW bytes give the answer the
#: whole stream gives; deframer.ts settles the phase there, or at the first hole when that comes sooner.
PHASE_SAMPLE = 16 * 20000
PHASE_WINDOW = PHASE_SAMPLE + 16 + 15
#: Consecutive units failing the tag check that mean the phase has slipped, not that one unit is damaged: a
#: correctly phased stream has essentially none (the first capture: 0 in 5,411,059), so 8 is already decisive.
RESYNC_RUN = 8
#: Bytes scanned to re-find the phase, as the reference's slip hunt scanned per 4 KB: 256 candidate units per phase.
RESYNC_WINDOW = 4096


@dataclass
class DeframeResult:
    #: (log code, raw modem timestamp, body) per DIAG log record, in the order the .qmdl holds them.
    records: list[tuple[int, int, bytes]] = field(default_factory=list)
    #: (log code, raw timestamp) of each encrypted "secure" record, in trace order; their bodies are unreadable.
    secure: list[tuple[int, int]] = field(default_factory=list)
    #: The counters, in the reference deframer's stats.json shape.
    stats: dict = field(default_factory=dict)


# --- layer 1 ------------------------------------------------------------------------------------------------

def deformat_chunks(paths: Sequence[str], want: int = ATID) -> tuple[bytes, list[int]]:
    """The bytes of trace ID ``want``, with the formatter state carried from one chunk into the next, and the
    stream offset at which each chunk's bytes end: where a hole in the chunk numbering sits in the stream."""
    out = bytearray()
    ends = []
    cur = None
    for path in paths:
        with open(path, "rb") as fh:
            b = fh.read()
        n = len(b) - len(b) % 16
        for k in range(0, n, 16):
            if b[k] == 0xFF and b[k + 1] == 0xFF and b[k + 2] == 0xFF and b[k + 3] == 0x7F:
                continue                                  # formatter padding
            aux = b[k + 15]
            if not (b[k] | b[k + 2] | b[k + 4] | b[k + 6] | b[k + 8] | b[k + 10] | b[k + 12] | b[k + 14]) & 1:
                # No trace-ID change in this frame: 15 data bytes, their low bits in aux.
                if cur == want:
                    base = len(out)
                    out += b[k:k + 15]
                    if aux:
                        for i in range(8):
                            if (aux >> i) & 1:
                                out[base + 2 * i] |= 1
                continue
            for i in range(8):
                x = b[k + 2 * i]
                bit = (aux >> i) & 1
                if x & 1:
                    nid = x >> 1
                    if i == 7:
                        cur = nid
                    elif bit:
                        if cur == want:
                            out.append(b[k + 2 * i + 1])  # the byte after still belongs to the old ID
                        cur = nid
                    else:
                        cur = nid
                        if cur == want:
                            out.append(b[k + 2 * i + 1])
                elif cur == want:
                    out.append(x | bit)
                    if i < 7:
                        out.append(b[k + 2 * i + 1])
        ends.append(len(out))
    return bytes(out), ends


def deformat(paths: Sequence[str], want: int = ATID) -> bytes:
    """The bytes of trace ID ``want`` over the chunks."""
    return deformat_chunks(paths, want)[0]


# --- layer 2 ------------------------------------------------------------------------------------------------

def find_phase(s: bytes, sample: int = PHASE_SAMPLE) -> int:
    """The offset (0..15) at which 16-byte units line up: the one where most units have a known shape."""
    best = None
    for p in range(16):
        good = 0
        for i in range(p, min(len(s) - 16, p + sample), 16):
            t = s[i] & 0x1F
            if t in (0x03, 0x13) or (t in (0x00, 0x02) and s[i + 5:i + 16] == FILL_TAIL):
                good += 1
        if best is None or good > best[1]:
            best = (p, good)
    return best[0] if best else 0


def expected_units(length: int, pad: int) -> int:
    """How many continuation units a fragment of ``length`` bytes should take."""
    remaining = length - (8 - pad)
    if remaining <= 0:
        return 0
    bursts = remaining // 240
    return 16 * bursts + (remaining - 240 * bursts + 11) // 12


def assemble(start: bytes, conts: Sequence[bytes]) -> tuple:
    """(payload, continuation units used, complete?) of one fragment."""
    cls = start[1]
    pad = (cls >> 4) & 7
    length = start[2] | start[3] << 8
    out = bytearray(start[8 + pad:16])
    remaining = length - len(out)
    k = 0
    while remaining >= 240 and k + 16 <= len(conts):
        displaced = conts[k + 15]
        for j in range(15):
            out.append(displaced[1 + j])
            out += conts[k + j][1:16]
        k += 16
        remaining -= 240
    if remaining >= 240:                                  # a truncated burst
        return bytes(out[:length]), k, False
    while remaining > 0 and k < len(conts):
        unit = conts[k]
        if remaining < 12:
            words = [unit[4:8], unit[8:12], unit[12:16]][:(remaining + 3) // 4]
            out += b"".join(reversed(words))
        else:
            out += unit[4:16]
        k += 1
        remaining -= 12
    return bytes(out[:length]), k, remaining <= 0


def iter_fragments(s: bytes, phase: int, stats: collections.Counter,
                   gaps: Sequence[int] = ()) -> Iterator[Optional[tuple]]:
    """(offset, channel, start unit, [continuation units]) of every fragment, in the order they close.

    ``gaps`` are the stream offsets where chunk files are missing (:func:`chunk_gaps`); ``phase`` is the unit
    phase of the stream's head (:func:`find_phase` over its first PHASE_WINDOW bytes, or over what precedes the
    first hole when that comes sooner, which is where deframer.ts settles it). The phase is re-found after every
    hole and after every run of RESYNC_RUN units that fail the tag check (a slip), over RESYNC_WINDOW bytes from
    the first unit of the run, or over what is left before the next hole or the end of the stream. At either break
    nothing more arrives for what is in flight: the open fragments are yielded as they stand, in opening order,
    then ``None`` once, meaning that what is gathering on every channel is left open too, and the lanes are
    unbound. The stats are counted in the order deframer.ts counts them, so they serialise the same.
    """
    chan = {}                                             # lane -> channel it is bound to
    open_ = {}                                            # channel -> [offset, channel, start, conts]
    bad_run = 0                                           # units failing the tag check in a row
    resync = None                                         # stream offset the phase is being re-found from
    bounds = list(gaps) + [len(s)]
    i = phase
    for k, seg_end in enumerate(bounds):
        hole = k < len(gaps)                              # the segment ends at a hole, not at the stream's end
        counted = False                                   # that hole is in the stats already
        if k == 0:
            if hole and seg_end < PHASE_WINDOW:           # settled at the hole, which is counted first
                stats["chunk_gaps"] += 1
                counted = True
            stats["phase"] = phase
        while True:
            if resync is not None:
                have = seg_end - resync
                if have < RESYNC_WINDOW + 16 and hole and not counted:
                    stats["chunk_gaps"] += 1              # the hole forces the decision on what there is
                    counted = True
                p = find_phase(s[resync:resync + min(have, RESYNC_WINDOW + 16)])
                # Phase 0 is the alignment that just failed, so no better one is in view: step over the bad run
                # instead, so the scan always moves forward and a long damaged stretch cannot loop.
                stats["resync_kept_phase" if p == 0 else "resync_new_phase"] += 1
                i = min(resync + (RESYNC_RUN * 16 if p == 0 else p), seg_end)
                resync = None
            slipped = False
            for i in range(i, seg_end - 15, 16):
                h = s[i]
                t = h & 0x1F
                if t == 0x00:
                    stats["u_fill"] += 1
                elif t == 0x02:
                    stats["u_chan"] += 1
                    chan[h >> 5] = s[i + 1] | s[i + 2] << 8
                elif t == 0x13:
                    stats["u_start"] += 1
                    key = chan.get(h >> 5)
                    if key in open_:
                        yield tuple(open_.pop(key))
                    open_[key] = [i, key, s[i:i + 16], []]
                elif t == 0x03:
                    stats["u_cont"] += 1
                    m = open_.get(chan.get(h >> 5))
                    if m is None:
                        stats["u_cont_orphan"] += 1
                    else:
                        m[3].append(s[i:i + 16])
                else:
                    stats["u_badtype"] += 1
                    bad_run += 1
                    if bad_run >= RESYNC_RUN:
                        slipped = True
                        break
                    continue                              # a bad unit does not end the run
                bad_run = 0
            if not slipped:
                break
            # The phase has slipped: every unit since the run began was read at the wrong offset.
            stats["resync_slip"] += 1
            bad_run = 0
            for m in open_.values():
                yield tuple(m)
            open_.clear()
            yield None
            chan.clear()
            resync = i - (RESYNC_RUN - 1) * 16
        if hole:
            # The stream jumps here, and a unit straddling the hole can never be completed.
            if not counted:
                stats["chunk_gaps"] += 1
            stats["resync_gap"] += 1
            bad_run = 0
            for m in open_.values():
                yield tuple(m)
            open_.clear()
            yield None
            chan.clear()
            resync = seg_end
    for m in open_.values():
        yield tuple(m)


# --- layer 3 ------------------------------------------------------------------------------------------------

def ts_ok(ts: int) -> bool:
    """A modem timestamp in the range this trace's network time falls in (its upper 32 bits, 2026)."""
    return 0x0112_0000 <= (ts >> 32) <= 0x0113_FFFF


def split_packets(msg: bytes) -> Iterator[tuple]:
    """(form, packet) for each DIAG packet in a gathered message."""
    if msg[:4] == b"\x98\x01\x00\x00" and len(msg) >= 8:
        n = struct.unpack_from("<I", msg, 4)[0]
        off = 8
        seen = 0
        while off < len(msg) and (seen < n or n == 0):
            if msg[off] == 0x10 and off + 16 <= len(msg):
                ln = struct.unpack_from("<H", msg, off + 2)[0]
                yield "multi98", msg[off:off + 4 + ln]
                off += 4 + ln
            else:
                yield "multi98", msg[off:]
                break
            seen += 1
        return
    yield "plain", msg


def classify(pkt: bytes) -> tuple:
    """(kind, code, ts, body) of a DIAG packet; code, ts and body are None for kinds that are only counted."""
    if not pkt:
        return "empty", None, None, None
    c = pkt[0]
    if c == 0x10:
        if len(pkt) >= 16:
            outer, inner, code, ts = struct.unpack_from("<HHHQ", pkt, 2)
            if outer == inner == len(pkt) - 4:
                return "log", code, ts, pkt[16:]
        return "log_bad", None, None, None
    if c == 0x9E and pkt[:4] == b"\x9e\x01\xc2\x00" and len(pkt) >= 32:
        inner, code, ts = struct.unpack_from("<HHQ", pkt, 20)
        if inner == len(pkt) - 20:
            return "secure", code, ts, pkt[32:]
        return "secure_bad", None, None, None
    if c in _OTHER_KINDS:
        return _OTHER_KINDS[c], None, None, None
    if len(pkt) >= 12:
        inner, code, ts = struct.unpack_from("<HHQ", pkt, 0)
        if inner == len(pkt) and code != 0:
            return "bare", code, ts, pkt[12:]
    return "other_0x%02x" % c, None, None, None


# --- the whole trace ----------------------------------------------------------------------------------------

def chunk_number(path: str) -> Optional[int]:
    """The segment number in a chunk's name (0x000061BE.bin -> 0x61BE); None for another name."""
    name = os.path.basename(path)
    return int(name[2:-4], 16) if CHUNK_NAME.fullmatch(name) else None


def chunk_gaps(paths: Sequence[str], ends: Sequence[int]) -> list[int]:
    """The stream offsets at which chunk files are missing: a chunk numbered other than the previous one plus
    one begins after a hole, at the offset where the previous chunk's bytes end (:func:`deformat_chunks`)."""
    gaps = []
    previous = None
    for k, path in enumerate(paths):
        number = chunk_number(path)
        if previous is not None and number is not None and number != previous + 1:
            gaps.append(ends[k - 1])
        previous = number
    return gaps


def deframe_chunks(paths: Sequence[str]) -> DeframeResult:
    """Deframe the chunks, given in trace order, into DIAG log records."""
    s, ends = deformat_chunks(paths)
    gaps = chunk_gaps(paths, ends)
    stats = collections.Counter()
    fits = collections.Counter()
    kinds = collections.Counter()
    pkts = collections.Counter()
    found = []                                            # (channel, code, ts, body, complete)
    secure = []
    phase = find_phase(s[:gaps[0]] if gaps and gaps[0] < PHASE_WINDOW else s)

    def emit(key, msg, complete, tag):
        stats["messages" + ("_" + tag if tag else "")] += 1
        if not complete:
            stats["messages_incomplete"] += 1
        for _form, pkt in split_packets(msg):
            kind, code, ts, body = classify(pkt)
            pkts[kind + ("_" + tag if tag else "")] += 1
            if kind in ("log", "bare"):
                found.append((key, code, ts, body, complete))
            elif kind == "secure":
                secure.append((code, ts))

    pending = {}                                          # channel -> [bytearray, complete]

    def left_open():
        """Nothing more arrives for what is gathering: at a break in the stream, and at its end."""
        for key, p in pending.items():
            stats["gather_left_open"] += 1
            emit(key, bytes(p[0]), p[1], "unterm")
        pending.clear()

    for fragment in iter_fragments(s, phase, stats, gaps):
        if fragment is None:
            left_open()
            continue
        _off, key, start, conts = fragment
        cls = start[1]
        kind = cls & 0xF
        length = start[2] | start[3] << 8
        need = expected_units(length, (cls >> 4) & 7)
        data, used, complete = assemble(start, conts)
        if not complete:
            fits["short"] += 1
        elif used < len(conts):
            fits["extra_units"] += 1
        else:
            fits["exact"] += 1
        if need != len(conts):
            fits["count_mismatch"] += 1
        kinds[kind] += 1
        if kind == 2:
            stats["qshrink_f3"] += 1
            continue
        if kind in (1, 3):
            if key in pending:
                stats["gather_flushed_unterminated"] += 1
                p = pending.pop(key)
                emit(key, bytes(p[0]), p[1], "unterm")
            if kind == 3:
                pending[key] = [bytearray(data), complete]
                continue
            msg = data
        elif kind in (4, 5):
            p = pending.get(key)
            if p is None:
                stats["gather_orphan_kind%d" % kind] += 1
                continue
            p[0] += data
            p[1] = p[1] and complete
            if kind == 4:
                continue
            pending.pop(key)
            msg, complete = bytes(p[0]), p[1]
        else:
            stats["gather_unknown_kind_%d" % kind] += 1
            continue
        emit(key, msg, complete, "")
    left_open()

    codes = collections.Counter(r[1] for r in found)
    ts_kinds = collections.Counter(
        "2026" if ts_ok(r[2]) else ("zero" if r[2] == 0 else "other") for r in found)
    summary = {
        "atid32_bytes": len(s), "chunks": len(paths), "stats": dict(stats), "fits": dict(fits),
        "fragment_kinds": {str(k): v for k, v in sorted(kinds.items())},
        "packets": dict(pkts), "log_records": len(found), "distinct_codes": len(codes),
        "ts": dict(ts_kinds), "incomplete_records": sum(1 for r in found if not r[4]),
        "targets": {"0x%04X" % t: codes.get(t, 0) for t in TARGET_CODES},
        "top_codes": [["0x%04X" % c, n] for c, n in codes.most_common(15)],
    }

    # Timestamps rise within a channel but channels interleave with a lag. A record without a plausible stamp
    # (zero, or a code whose stamp is not in modem time) takes the last plausible one on its channel.
    last = {}
    effective = []
    for idx, (key, _code, ts, _body, _complete) in enumerate(found):
        if ts_ok(ts):
            last[key] = ts
            effective.append((ts, idx))
        else:
            effective.append((last.get(key, 0), idx))
    records = [found[idx][1:4] for _eff, idx in sorted(effective)]
    return DeframeResult(records=records, secure=secure, stats=summary)


def write_qmdl(records, path: str) -> None:
    """One HDLC-framed DIAG_LOG_F packet per (code, ts, body), as the reference deframer and CallFlow read them."""
    with open(path, "wb") as fh:
        for code, ts, body in records:
            inner = 12 + len(body)
            fh.write(hdlc.encode(struct.pack("<BBHHHQ", 0x10, 0, inner, inner, code, ts) + body))


def chunk_paths(directory: str) -> list[str]:
    """The trace chunks of a qdss directory in trace order (by name), without AppleDouble '._' copies."""
    return sorted(os.path.join(directory, n) for n in os.listdir(directory)
                  if CHUNK_NAME.fullmatch(n))


def chunks_from_sysdiagnose(tar_path: str, workdir: str) -> tuple[list[str], dict]:
    """Stream a sysdiagnose archive and keep only the QDSS trace chunks.

    Writes ``*/logs/Baseband/log-bb-*-qdss/0x*.bin`` into ``workdir``, keeps the newest trace directory by name
    (the one the sysdiagnose was taken for) and returns its chunk paths, sorted by name, with an info dict:
    ``trace_dir`` (None when the archive has no trace), ``trace_dirs`` (every one found), ``profile_stub`` (the
    bytes of the com.apple.basebandlogging profile record under logs/MCState/Shared, or None) and
    ``appledouble_skipped``. The chunks hold subscriber identifiers: delete ``workdir`` with
    :func:`remove_workdir` when done. Nothing is extracted by the archive's own paths.
    """
    os.makedirs(workdir, exist_ok=True)
    dirs = set()
    stub = None
    skipped = 0
    with tarfile.open(tar_path, "r|*") as tar:
        for member in tar:
            if not member.isfile():
                continue
            parts = member.name.split("/")
            leaf = parts[-1]
            if leaf.startswith("._"):
                skipped += 1                              # AppleDouble metadata from macOS tar, not trace data
                continue
            if (len(parts) >= 4 and parts[-4:-2] == ["logs", "Baseband"] and TRACE_DIR.fullmatch(parts[-2])
                    and CHUNK_NAME.fullmatch(leaf)):
                target = os.path.join(workdir, parts[-2])
                os.makedirs(target, exist_ok=True)
                source = tar.extractfile(member)
                with open(os.path.join(target, leaf), "wb") as out:
                    shutil.copyfileobj(source, out, 1 << 20)
                dirs.add(parts[-2])
            elif (len(parts) >= 4 and parts[-4:-1] == ["logs", "MCState", "Shared"]
                    and PROFILE_STUB.fullmatch(leaf) and member.size < (1 << 20)):
                data = tar.extractfile(member).read()
                if BASEBAND_PROFILE in data:
                    stub = data
    newest = max(dirs) if dirs else None
    for other in dirs - {newest}:
        shutil.rmtree(os.path.join(workdir, other), ignore_errors=True)
    paths = chunk_paths(os.path.join(workdir, newest)) if newest else []
    return paths, {"trace_dir": newest, "trace_dirs": sorted(dirs), "profile_stub": stub,
                   "appledouble_skipped": skipped}


def pressed_at(archive_name: str) -> Optional[datetime]:
    """When the sysdiagnose buttons were pressed, from the archive's name; None for another name."""
    m = ARCHIVE_NAME.search(os.path.basename(archive_name))
    if not m:
        return None
    y, mo, d, h, mi, sec, sign, oh, om = m.groups()
    offset = timedelta(hours=int(oh), minutes=int(om)) * (-1 if sign == "-" else 1)
    return datetime(int(y), int(mo), int(d), int(h), int(mi), int(sec), tzinfo=timezone(offset))


def trace_window(records, pressed: datetime) -> Optional[tuple]:
    """(first, last) plausible modem timestamp of the records, in seconds after the button press.

    On the one capture measured the kept trace ran from 19 to 46 s after the press: the ring keeps the last
    ~27 s before the dump, not the seconds before the press (docs/research/iphone-baseband-capture.md).
    """
    times = [t for t in (protocol.qc_timestamp(ts) for _code, ts, _body in records) if protocol.timestamp_is_plausible(t)]
    if not times:
        return None
    return (min(times) - pressed).total_seconds(), (max(times) - pressed).total_seconds()


def profile_dates(stub: bytes) -> tuple:
    """(InstallDate, RemovalDate) of the Baseband logging profile record, as UTC datetimes (None when absent)."""
    try:
        record = plistlib.loads(stub)
    except Exception:  # a malformed record says nothing about the dates
        return None, None
    dates = []
    for key in ("InstallDate", "RemovalDate"):
        value = record.get(key) if isinstance(record, dict) else None
        dates.append(value.replace(tzinfo=timezone.utc) if isinstance(value, datetime) else None)
    return dates[0], dates[1]


def remove_workdir(workdir: str) -> None:
    """Delete what :func:`chunks_from_sysdiagnose` wrote."""
    shutil.rmtree(workdir, ignore_errors=True)
