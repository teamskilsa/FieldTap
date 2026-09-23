"""The QDSS deframer's resync (fieldtap.diag.qdss) on constructed traces, mirroring the 'resync:' tests of
web/engine/tests/qdss_test.ts: a phase slip mid-stream, a hole in the chunk numbering (and that the result does
not depend on how the stream is cut into chunk files), and a long damaged stretch. Nothing here is capture-derived;
the builders are test_qdss.py's.
"""

import random

from fieldtap.diag import qdss
from test_qdss import T, channel_unit, formatted, fragment_units, log_packet


def payload(seed, n):
    """Record bodies whose bytes never look like a unit tag (low 5 bits 0x00, 0x02, 0x03 or 0x13), as real modem
    payload mostly does not. Read out of phase they fail the tag check at once, which is what the slip detector
    keys on; uniform random bytes would pass it one time in eight and hide the slip."""
    r = random.Random(seed)
    low = [v for v in range(32) if v not in (0x00, 0x02, 0x03, 0x13)]
    return bytes(r.randrange(8) << 5 | r.choice(low) for _ in range(n))


def noise(seed, n):
    """Uniform random bytes: garbage between two good runs, or the few bytes that put a run out of phase."""
    r = random.Random(seed)
    return bytes(r.randrange(256) for _ in range(n))


def log_units(start, count, lane=0):
    """A run of whole (kind 1) fragments on one channel, each carrying one log packet, as a raw unit stream."""
    units = [channel_unit(lane, 0x150 + lane)]
    for i in range(count):
        units += fragment_units(1, log_packet(0xB0C0 + i % 3, T + start + i, payload(start + i, 120)), lane=lane)
    return b"".join(units)


def deframe(tmp_path, name, chunks, numbers=None):
    """``chunks`` (formatter frames, one per file) written under ``tmp_path/name`` with the segment numbers
    ``numbers`` in their names (consecutive from 0x61BE by default), then deframed."""
    directory = tmp_path / name
    directory.mkdir()
    paths = []
    for k, data in enumerate(chunks):
        number = numbers[k] if numbers else 0x61BE + k
        path = directory / ("0x%08X.bin" % number)
        path.write_bytes(data)
        paths.append(str(path))
    return qdss.deframe_chunks(paths)


def keys(result):
    """The codes and stamps of a run's records, to check which survived."""
    return ["%04X@%d" % (code, ts) for code, ts, _body in result.records]


def pieces(data, seed):
    """``data`` cut into random pieces at frame boundaries: chunk files that continue one another."""
    r = random.Random(seed)
    frames = len(data) // 16
    cuts = sorted(set(r.randrange(1, frames) for _ in range(6)))
    bounds = [0] + cuts + [frames]
    return [data[16 * a:16 * b] for a, b in zip(bounds, bounds[1:])]


def test_a_phase_slip_mid_stream_is_found_and_the_records_after_it_are_recovered(tmp_path):
    # Two runs of the same length, the second written 5 bytes out of phase with the first.
    before = log_units(0, 40)
    after = log_units(100, 40)
    slipped = deframe(tmp_path, "slipped", [formatted(before + noise(7, 5) + after)])
    aligned = deframe(tmp_path, "aligned", [formatted(before + after)])
    stats = slipped.stats["stats"]
    assert stats["resync_slip"] == 1                                   # one slip, found once
    assert stats["resync_new_phase"] == 1                              # and a different phase after it
    assert "chunk_gaps" not in stats and "resync_gap" not in stats     # no hole here
    # Everything before the slip, and everything after it bar the fragments the 8-unit detection ran over.
    survived = set(keys(slipped))
    wanted = keys(aligned)
    assert len(wanted) == 80 and len([k for k in wanted if k in survived]) >= 70
    assert all(k in survived for k in wanted[:40])                     # every record before the slip
    assert all(k in survived for k in wanted[-20:])                    # the records well past the slip
    # A stream that never loses sync sees none of it: no resync key, no bad unit.
    assert not [k for k in aligned.stats["stats"] if k.startswith("resync") or k == "u_badtype"]


def test_a_hole_in_the_chunk_numbering_re_finds_the_phase_and_the_cut_into_files_does_not_matter(tmp_path):
    first = formatted(log_units(0, 40))
    # The chunk after the hole begins 9 bytes out of phase with the one before it.
    second = formatted(noise(3, 9) + log_units(200, 40))
    whole = deframe(tmp_path, "whole", [first, second], numbers=[0x61BE, 0x61C0])
    stats = whole.stats["stats"]
    assert (stats["chunk_gaps"], stats["resync_gap"], stats["resync_new_phase"]) == (1, 1, 1)
    assert len(whole.records) == 80                                    # both chunks recovered in full
    assert "resync_slip" not in stats
    # The stream, the phase and the offset of the hole are the same however the files are cut, so the decision
    # is too: the resync waits for its window across file boundaries rather than deciding at each one.
    want = (keys(whole), {k: v for k, v in whole.stats.items() if k != "chunks"})
    for seed in range(1, 9):
        cut = pieces(first, seed) + pieces(second, seed + 50)
        numbers = list(range(0x61BE, 0x61BE + len(cut)))
        numbers[len(pieces(first, seed)):] = [n + 1 for n in numbers[len(pieces(first, seed)):]]
        split = deframe(tmp_path, "split%d" % seed, cut, numbers)
        assert (keys(split), {k: v for k, v in split.stats.items() if k != "chunks"}) == want, "split %d" % seed
        assert split.stats["chunks"] == len(cut)

    # Without a hole in the numbering the slip detector finds the same jump on its own, a few fragments later.
    unsignalled = deframe(tmp_path, "unsignalled", [first, second])
    stats = unsignalled.stats["stats"]
    assert "chunk_gaps" not in stats
    assert stats["resync_slip"] == 1
    assert len(unsignalled.records) > 70


def test_a_long_damaged_stretch_always_moves_forward_and_never_loops(tmp_path):
    out = deframe(tmp_path, "garbage", [formatted(log_units(0, 20) + noise(5, 40000) + log_units(300, 20))])
    assert out.stats["stats"].get("resync_slip", 0) > 0               # the garbage is noticed
    # The runs on both sides of the garbage still come out.
    assert len([r for r in out.records if r[1] < T + 100]) == 20      # the run before it
    assert any(r[1] >= T + 300 for r in out.records)                  # and the run after it


def test_the_holes_come_from_the_chunk_names():
    assert qdss.chunk_number("C:/x/0x000061BE.bin") == 0x61BE
    assert qdss.chunk_number("C:/x/header.qmdl2") is None
    paths = ["0x00000010.bin", "0x00000011.bin", "0x00000013.bin", "notes.txt", "0x00000020.bin"]
    # A hole sits where the chunk before it ended; a name without a number breaks the run without making a hole.
    assert qdss.chunk_gaps(paths, [100, 250, 400, 400, 900]) == [250]
