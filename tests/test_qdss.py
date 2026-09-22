"""The iPhone QDSS deframer (fieldtap.diag.qdss) on constructed traces, and on the real capture when it is there.

The synthetic tests build each layer the way the modem writes it and check the deframer reads it back. The
fixture tests need capture-derived files that are never committed (ios/Fixtures/local, the user's sysdiagnose):
  FT_QDSS_FIXTURES=<Fixtures/local>  the first3 and attach4 chunk windows give their manifests' md5s
  FT_SYSDIAGNOSE=<archive>           the whole trace gives iphone-recovered.qmdl (needs FT_FIXTURES for the stats)
Everything they unpack or write is deleted before the test ends: it holds subscriber identifiers.
"""

import collections
import hashlib
import io
import json
import os
import plistlib
import struct
import tarfile
from datetime import datetime, timedelta, timezone

import pytest

from fieldtap import cli
from fieldtap.diag import hdlc, protocol, qdss

FULL_MD5 = "e53a167b29b25560938d1f089e719d33"
T = 0x0112_8000 << 32          # a plausible modem timestamp (its upper word is in this trace's 2026 range)


# --- builders: the inverse of each layer ------------------------------------------------------------------

def log_packet(code, ts, body=b"\x01\x02\x03\x04"):
    inner = 12 + len(body)
    return struct.pack("<BBHHHQ", 0x10, 0, inner, inner, code, ts) + body


def secure_packet(code, ts, body=b"\xee" * 8):
    tail = struct.pack("<HHQ", 12 + len(body), code, ts) + body
    return b"\x9e\x01\xc2\x00" + bytes(16) + tail


def fill_unit():
    return b"\x00" * 5 + qdss.FILL_TAIL


def channel_unit(lane, channel):
    return bytes([lane << 5 | 0x02, channel & 0xFF, channel >> 8, 0, 0]) + qdss.FILL_TAIL


def fragment_units(kind, payload, lane=1, pad=0):
    """A start unit and the continuation units that carry ``payload``: 240-byte bursts, then 12-byte words with
    the last partial unit's words reversed."""
    cls = pad << 4 | kind
    first = payload[:8 - pad]
    units = [bytes([lane << 5 | 0x13, cls, len(payload) & 0xFF, len(payload) >> 8]) + b"\x9d\x45\x00\x00"
             + bytes(pad) + first.ljust(8 - pad, b"\x00")]
    tag = bytes([lane << 5 | 0x03])
    rest = payload[8 - pad:]
    while len(rest) >= 240:
        lines = [rest[16 * j:16 * j + 16] for j in range(15)]
        units += [tag + line[1:] for line in lines]
        units.append(tag + bytes(line[0] for line in lines))
        rest = rest[240:]
    while rest:
        piece, rest = rest[:12], rest[12:]
        if len(piece) < 12:
            piece = piece.ljust(-(-len(piece) // 4) * 4, b"\x00")
            piece = b"".join(reversed([piece[i:i + 4] for i in range(0, len(piece), 4)]))
        units.append(tag + b"\x00\x00\x00" + piece.ljust(12, b"\x00"))
    return units


def formatted(stream, atid=qdss.ATID):
    """CoreSight formatter frames carrying ``stream`` on trace ID ``atid``: one frame that switches to the ID,
    then frames with no ID change, each data byte at an even position giving its low bit to the aux byte."""
    frames = []
    first = bytearray(16)
    first[0] = atid << 1 | 1
    first[1] = stream[0]
    aux = 0
    for i in range(1, 7):
        x = stream[2 * i - 1]
        first[2 * i] = x & 0xFE
        aux |= (x & 1) << i
        first[2 * i + 1] = stream[2 * i]
    first[14] = stream[13] & 0xFE
    aux |= (stream[13] & 1) << 7
    first[15] = aux
    frames.append(bytes(first))
    rest = stream[14:]
    rest += bytes(-len(rest) % 15)
    for k in range(0, len(rest), 15):
        d = rest[k:k + 15]
        f = bytearray(16)
        aux = 0
        for i in range(8):
            f[2 * i] = d[2 * i] & 0xFE
            aux |= (d[2 * i] & 1) << i
            if i < 7:
                f[2 * i + 1] = d[2 * i + 1]
        f[15] = aux
        frames.append(bytes(f))
    return b"".join(frames)


def trace(units, lead=30):
    """An ATID-0x32 unit stream behind ``lead`` fill units, which make phase 0 the obvious one."""
    return b"".join([fill_unit()] * lead + list(units) + [fill_unit()] * 2)


def write_chunks(tmp_path, data, parts=1):
    """Split formatter frames over ``parts`` chunk files at frame boundaries."""
    frames = len(data) // 16
    per = -(-frames // parts)
    paths = []
    for i in range(parts):
        p = tmp_path / ("0x%08X.bin" % (0x6F + i))
        p.write_bytes(data[16 * per * i:16 * per * (i + 1)])
        paths.append(str(p))
    return paths


# --- layer 1 ----------------------------------------------------------------------------------------------

def test_layer1_frame_with_atid_changes_and_aux_bits(tmp_path):
    frame = bytearray(16)
    frame[0] = 0x32 << 1 | 1          # switch to 0x32; aux bit 0 clear, so the next byte is 0x32's
    frame[1] = 0xA1
    frame[2] = 0x10                   # data; aux bit 1 gives it its low bit
    frame[3] = 0xA2
    frame[4] = 0x10 << 1 | 1          # switch to 0x10, aux bit 2 set: the next byte still belongs to 0x32
    frame[5] = 0xA3
    frame[6], frame[7] = 0x44, 0x45   # 0x10's bytes, dropped
    frame[8] = 0x32 << 1 | 1          # back to 0x32, aux bit 4 clear: the next byte is 0x32's
    frame[9] = 0xA4
    frame[10], frame[11] = 0x12, 0xA5
    frame[12], frame[13] = 0x14, 0xA6
    frame[14] = 0x1C                  # data by aux bit 7, which also sets its low bit
    frame[15] = 1 << 1 | 1 << 2 | 1 << 7
    padding = b"\xff\xff\xff\x7f" + bytes(12)
    path = tmp_path / "0x00000001.bin"
    path.write_bytes(bytes(frame) + padding)
    assert qdss.deformat([str(path)]) == bytes([0xA1, 0x11, 0xA2, 0xA3, 0xA4, 0x12, 0xA5, 0x14, 0xA6, 0x1D])


def test_layer1_fast_path_restores_low_bits_and_state_carries_across_chunks(tmp_path):
    stream = bytes(range(1, 60))                       # odd and even bytes alike
    paths = write_chunks(tmp_path, formatted(stream), parts=2)
    out = qdss.deformat(paths)
    assert out[:len(stream)] == stream                 # the second chunk has no ID change of its own
    assert qdss.deformat(paths[1:]) == b""              # without the first, nobody said which ID it was


# --- layer 2 ----------------------------------------------------------------------------------------------

def test_fill_channel_start_and_continuation_units():
    payload = bytes(range(40))
    s = trace([channel_unit(1, 0x0105)] + fragment_units(1, payload))
    stats = collections.Counter()
    assert qdss.find_phase(s) == 0
    fragments = list(qdss.iter_fragments(s, 0, stats))
    assert len(fragments) == 1
    _off, channel, start, conts = fragments[0]
    assert channel == 0x0105
    assert len(conts) == qdss.expected_units(40, 0) == 3
    data, used, complete = qdss.assemble(start, conts)
    assert (data, used, complete) == (payload, 3, True)
    assert stats["u_fill"] == 32 and stats["u_chan"] == 1 and stats["u_start"] == 1 and stats["u_cont"] == 3


def test_a_240_byte_burst_puts_the_displaced_bytes_back():
    payload = bytes((7 * i + 3) % 256 for i in range(8 + 240 + 20))
    units = fragment_units(1, payload)
    assert len(units) == 1 + 16 + 2
    # Unit 15 of the burst carries byte 0 of each of the 15 lines the unit tags overwrote.
    assert units[16][1:] == bytes(payload[8 + 16 * j] for j in range(15))
    data, used, complete = qdss.assemble(units[0], units[1:])
    assert (data, used, complete) == (payload, 18, True)


def test_the_last_partial_unit_carries_its_words_in_reverse():
    payload = bytes(range(8)) + b"ABCDEFGHIJKL" + b"wxyz12"          # R = 6 in the last unit: 2 words
    last = fragment_units(1, payload)[-1]
    assert last[4:12] == b"12\x00\x00wxyz"
    data, _used, complete = qdss.assemble(fragment_units(1, payload)[0], fragment_units(1, payload)[1:])
    assert data == payload and complete


def test_a_truncated_fragment_is_short():
    payload = bytes(8 + 240)
    units = fragment_units(1, payload)
    data, used, complete = qdss.assemble(units[0], units[1:10])
    assert not complete and used == 0


# --- layer 3 ----------------------------------------------------------------------------------------------

def test_classify_the_packet_kinds():
    assert qdss.classify(log_packet(0xB0C0, T, b"\x05\x06")) == ("log", 0xB0C0, T, b"\x05\x06")
    assert qdss.classify(secure_packet(0xB8C9, T)) == ("secure", 0xB8C9, T, b"\xee" * 8)
    assert qdss.classify(b"\x79" + bytes(20))[0] == "extmsg_0x79"
    assert qdss.classify(b"\x99" + bytes(20))[0] == "qsr4_0x99"
    assert qdss.classify(log_packet(0xB0C0, T)[:-1])[0] == "log_bad"      # lengths disagree


def test_a_multi_packet_message_splits():
    msg = b"\x98\x01\x00\x00" + struct.pack("<I", 2) + log_packet(0xB0C0, T) + log_packet(0xB821, T + 1)
    assert [qdss.classify(p)[1] for _form, p in qdss.split_packets(msg)] == [0xB0C0, 0xB821]


# --- the whole trace --------------------------------------------------------------------------------------

def test_gathering_by_kind_including_unterminated_and_left_open_runs(tmp_path):
    p1 = log_packet(0xB0C0, T + 1)
    p2 = log_packet(0xB0ED, T + 2, bytes(range(30)))
    p3 = log_packet(0xB0EC, T + 3)
    p4 = log_packet(0xB821, T + 4)
    p5 = log_packet(0xB80B, T + 5)
    units = [channel_unit(1, 0x0105)]
    units += fragment_units(1, p1)                                     # whole
    units += fragment_units(3, p2[:16]) + fragment_units(4, p2[16:30]) + fragment_units(5, p2[30:])
    units += fragment_units(2, b"F3 text record..")                    # QShrink F3: skipped
    units += fragment_units(3, p3)                                     # a first with no last ...
    units += fragment_units(1, p4)                                     # ... flushed by the next whole one
    units += fragment_units(3, secure_packet(0xB8C9, T + 6))
    units += fragment_units(5, b"")                                    # an empty last closes it
    units += fragment_units(3, p5)                                     # left open at the end
    result = qdss.deframe_chunks(write_chunks(tmp_path, formatted(trace(units))))
    assert [code for code, _ts, _body in result.records] == [0xB0C0, 0xB0ED, 0xB0EC, 0xB821, 0xB80B]
    assert result.records[1] == (0xB0ED, T + 2, p2[16:])
    assert result.secure == [(0xB8C9, T + 6)]
    s = result.stats
    assert s["stats"]["qshrink_f3"] == 1
    assert s["stats"]["gather_flushed_unterminated"] == 1
    assert s["stats"]["gather_left_open"] == 1
    assert s["fragment_kinds"] == {"1": 2, "2": 1, "3": 4, "4": 1, "5": 2}
    assert s["packets"]["log"] == 3 and s["packets"]["log_unterm"] == 2 and s["packets"]["secure"] == 1
    assert s["log_records"] == 5 and s["ts"] == {"2026": 5}


def test_records_are_ordered_by_effective_timestamp(tmp_path):
    # Channel 1: a record at T+10, then one without a modem timestamp; channel 2 lags: T+5, then T+20.
    units = [channel_unit(1, 0x0101), channel_unit(2, 0x0202)]
    units += fragment_units(1, log_packet(0x1001, T + 10), lane=1)
    units += fragment_units(1, log_packet(0x1002, 0), lane=1)
    units += fragment_units(1, log_packet(0x2001, T + 5), lane=2)
    units += fragment_units(1, log_packet(0x2002, T + 20), lane=2)
    result = qdss.deframe_chunks(write_chunks(tmp_path, formatted(trace(units))))
    # The untimed record keeps its place right after the one before it on its channel.
    assert [code for code, _ts, _body in result.records] == [0x2001, 0x1001, 0x1002, 0x2002]
    assert result.stats["ts"] == {"2026": 3, "zero": 1}


def test_write_qmdl_frames_one_log_packet_per_record(tmp_path):
    records = [(0xB0C0, T, b"\x01\x02"), (0xB821, T + 1, b"\x7e\x7d")]
    out = tmp_path / "out.qmdl"
    qdss.write_qmdl(records, str(out))
    frames = [f for f in hdlc.Unframer().feed(out.read_bytes())]
    parsed = [protocol.parse_log_packet(f) for f in frames]
    assert [(r.code, r.timestamp_raw, r.body) for r in parsed] == records
    assert os.listdir(tmp_path) == ["out.qmdl"]                        # no layer-1 cache beside it


# --- the sysdiagnose archive ------------------------------------------------------------------------------

def _add(tar, name, data):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))


def test_chunks_from_sysdiagnose_keeps_the_newest_trace_and_skips_appledouble(tmp_path):
    root = "sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84"
    new = root + "/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss/"
    old = root + "/logs/Baseband/log-bb-2026-09-20-10-00-00-000-qdss/"
    archive = tmp_path / "sysdiagnose.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        _add(tar, new + "0x00000071.bin", b"c" * 32)
        _add(tar, new + "0x0000006F.bin", b"a" * 32)
        _add(tar, new + "._0x0000006F.bin", b"\x00\x05\x16\x07AppleDouble")
        _add(tar, new + "0x00000070.bin", b"b" * 32)
        _add(tar, new + "header.qmdl2", bytes(77))
        _add(tar, old + "0x00000001.bin", b"z" * 32)
        _add(tar, root + "/logs/Baseband/ambtool_output.log", b"ok\n")
        _add(tar, root + "/logs/MCState/Shared/profile-00ff.stub", b"<plist>com.apple.wifi.managed</plist>")
        _add(tar, root + "/logs/MCState/Shared/profile-abcd.stub", b"<plist>com.apple.basebandlogging</plist>")
        _add(tar, root + "/logs/MCState/Shared/._profile-abcd.stub", b"\x00\x05\x16\x07")
    work = tmp_path / "work"
    paths, info = qdss.chunks_from_sysdiagnose(str(archive), str(work))
    assert [os.path.basename(p) for p in paths] == ["0x0000006F.bin", "0x00000070.bin", "0x00000071.bin"]
    assert [open(p, "rb").read()[:1] for p in paths] == [b"a", b"b", b"c"]
    assert info["trace_dir"] == "log-bb-2026-09-21-15-42-33-844-qdss"
    assert info["trace_dirs"] == ["log-bb-2026-09-20-10-00-00-000-qdss", "log-bb-2026-09-21-15-42-33-844-qdss"]
    assert info["profile_stub"] == b"<plist>com.apple.basebandlogging</plist>"
    assert info["appledouble_skipped"] == 2
    assert os.listdir(work) == ["log-bb-2026-09-21-15-42-33-844-qdss"]     # the older trace is not kept
    qdss.remove_workdir(str(work))
    assert not work.exists()


@pytest.mark.parametrize("removal, says", [
    (None, "modem logging is off"),
    (datetime(2026, 9, 20, 12, 0), "had expired"),
    (datetime(2026, 9, 28, 19, 40), "restart the iPhone"),
])
def test_an_archive_without_a_trace_says_why(tmp_path, capsys, removal, says):
    root = "sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84"
    archive = tmp_path / (root + ".tar.gz")
    with tarfile.open(archive, "w:gz") as tar:
        _add(tar, root + "/logs/Baseband/ambtool_output.log", b"Baseband logs are not enabled\n")
        if removal is not None:
            stub = plistlib.dumps({"PayloadIdentifier": "com.apple.basebandlogging",
                                   "InstallDate": removal - timedelta(days=7), "RemovalDate": removal})
            _add(tar, root + "/logs/MCState/Shared/profile-abcd.stub", stub)
    paths, info = qdss.chunks_from_sysdiagnose(str(archive), str(tmp_path / "work"))
    assert paths == [] and info["trace_dir"] is None and (info["profile_stub"] is None) == (removal is None)
    assert cli.main(["qdss", str(archive), "-o", str(tmp_path / "x.qmdl")]) == 1
    err = capsys.readouterr().err
    assert "no modem trace" in err and says in err
    assert not (tmp_path / "x.qmdl").exists()


def test_the_press_time_comes_from_the_archive_name():
    pressed = qdss.pressed_at("/x/sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84.tar.gz")
    assert pressed == datetime(2026, 9, 21, 19, 41, 47, tzinfo=timezone.utc)
    assert qdss.pressed_at("capture.tar.gz") is None


def test_the_trace_window_is_measured_from_the_press():
    pressed = datetime(2026, 9, 21, 19, 41, 47, tzinfo=timezone.utc)
    stamp = protocol.qc_timestamp_from_datetime
    records = [(0xB193, 1 << 20, b""),                                  # before network time: ignored
               (0xB0C0, stamp(pressed + timedelta(seconds=19)), b""),
               (0xB0C0, stamp(pressed + timedelta(seconds=46)), b"")]
    first, last = qdss.trace_window(records, pressed)
    assert abs(first - 19) < 0.01 and abs(last - 46) < 0.01
    assert qdss.trace_window(records[:1], pressed) is None


def test_the_profile_dates_come_from_its_record():
    stub = plistlib.dumps({"PayloadIdentifier": "com.apple.basebandlogging",
                           "InstallDate": datetime(2026, 9, 21, 19, 40, 6),
                           "RemovalDate": datetime(2026, 9, 28, 19, 40, 2)})
    installed, removal = qdss.profile_dates(stub)
    assert removal - installed == timedelta(days=7, seconds=-4)
    assert removal.tzinfo == timezone.utc
    assert qdss.profile_dates(b"not a plist") == (None, None)


# --- the real capture (skipped unless the environment names it) ------------------------------------------

def _md5(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


@pytest.mark.skipif(not os.environ.get("FT_QDSS_FIXTURES"), reason="FT_QDSS_FIXTURES not set")
@pytest.mark.parametrize("window", ["first3", "attach4"])
def test_the_fixture_windows_give_their_manifests(tmp_path, window):
    base = os.path.join(os.environ["FT_QDSS_FIXTURES"], "qdss-" + window)
    manifest = json.load(open(os.path.join(base, "manifest.json")))
    result = qdss.deframe_chunks(qdss.chunk_paths(os.path.join(base, "chunks")))
    out = tmp_path / (window + ".qmdl")
    try:
        qdss.write_qmdl(result.records, str(out))
        assert _md5(out) == manifest["outputs"][window + ".qmdl"]["md5"]
        assert json.loads(json.dumps(result.stats)) == json.load(open(os.path.join(base, "expected", "stats.json")))
    finally:
        out.unlink(missing_ok=True)


@pytest.mark.skipif(not os.environ.get("FT_SYSDIAGNOSE") or not os.environ.get("FT_FIXTURES"),
                    reason="FT_SYSDIAGNOSE and FT_FIXTURES not set")
def test_the_whole_sysdiagnose_gives_the_recovered_qmdl(tmp_path):
    archive = os.environ["FT_SYSDIAGNOSE"]
    if not os.path.isfile(archive):
        pytest.fail("FT_SYSDIAGNOSE names no file")
    work = tmp_path / "work"
    out = tmp_path / "iphone.qmdl"
    try:
        paths, info = qdss.chunks_from_sysdiagnose(archive, str(work))
        assert len(paths) == 130 and info["profile_stub"] is not None
        result = qdss.deframe_chunks(paths)
        qdss.write_qmdl(result.records, str(out))
        assert len(result.records) == 92_133
        assert _md5(out) == FULL_MD5
        expected = json.load(open(os.path.join(os.environ["FT_FIXTURES"], "qdss-full-stats.json")))
        assert json.loads(json.dumps(result.stats)) == expected
        assert len(result.secure) == expected["packets"]["secure"]
        # The kept trace ran from about 19 to 46 s after the press (the R2 timing evidence).
        first, last = qdss.trace_window(result.records, qdss.pressed_at(archive))
        assert 18.5 < first < 19.5 and 45.5 < last < 46.5
    finally:
        qdss.remove_workdir(str(work))
        out.unlink(missing_ok=True)
