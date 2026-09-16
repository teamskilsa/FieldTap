import struct
from datetime import datetime, timezone

import pytest

from fieldtap.diag import hdlc, protocol


def test_crc16_check_value():
    # CRC-16/X-25 published check value
    assert hdlc.crc16(b"123456789") == 0x906E


def test_encode_decode_roundtrip_with_escapes():
    payload = bytes([0x10, 0x7E, 0x7D, 0x00, 0xFF, 0x7E])
    frame = hdlc.encode(payload)
    assert frame[-1] == 0x7E
    # every 0x7E / 0x7D in the body must be escaped
    assert frame[:-1].count(0x7E) == 0
    assert hdlc.decode(frame) == payload


def test_decode_rejects_bad_crc():
    frame = bytearray(hdlc.encode(b"\x00\x01\x02"))
    frame[1] ^= 0xFF
    with pytest.raises(hdlc.HdlcError):
        hdlc.decode(bytes(frame))


def test_unframer_handles_split_and_concatenated_frames():
    a = hdlc.encode(b"\x73\x00\x00\x00")
    b = hdlc.encode(bytes(range(64)))
    stream = a + b
    un = hdlc.Unframer()
    out = []
    for i in range(0, len(stream), 5):
        out += un.feed(stream[i:i + 5])
    assert out == [b"\x73\x00\x00\x00", bytes(range(64))]
    assert un.frames == 2 and un.crc_errors == 0


def test_unframer_counts_corrupt_frames_and_keeps_going():
    good = hdlc.encode(b"\x00\x01")
    bad = bytearray(hdlc.encode(b"\x00\x02"))
    bad[0] ^= 0x55
    un = hdlc.Unframer()
    out = un.feed(bytes(bad) + good + b"\x7e" + good)
    assert out == [b"\x00\x01", b"\x00\x01"]
    assert un.crc_errors == 1


def test_log_config_set_mask_layout():
    req = protocol.build_log_config_set_mask(0xB, 0x900, [0xB0C0, 0xB821])
    assert req[:4] == b"\x73\x00\x00\x00"
    op, equip, last = struct.unpack_from("<III", req, 4)
    assert (op, equip, last) == (3, 0xB, 0x900)
    mask = req[16:]
    assert len(mask) == (0x900 + 8) // 8
    assert mask[0x0C0 >> 3] & (1 << (0x0C0 & 7))
    assert mask[0x821 >> 3] & (1 << (0x821 & 7))
    assert sum(bin(b).count("1") for b in mask) == 2


def test_log_config_rejects_wrong_equipment_id():
    with pytest.raises(ValueError):
        protocol.build_log_config_set_mask(0xB, 0x900, [0x1234])


def test_log_config_response_parsers():
    ranges = protocol.build_log_config_ranges_response([0] * 11 + [0x9FF] + [0] * 4)
    resp = protocol.parse_log_config_response(ranges)
    assert resp.op == 1 and resp.ok and resp.ranges[0xB] == 0x9FF
    setmask = protocol.build_log_config_set_mask_response(0xB, 0x9FF, b"\x01\x02", status=0)
    resp = protocol.parse_log_config_response(setmask)
    assert resp.op == 3 and resp.equip == 0xB and resp.last_item == 0x9FF and resp.mask == b"\x01\x02"


def test_log_packet_roundtrip():
    ts = protocol.qc_timestamp_from_datetime(datetime(2025, 11, 19, 12, 0, 0, tzinfo=timezone.utc))
    pkt = protocol.build_log_packet(0xB821, ts, b"\x09\x00\x00\x00hello")
    rec = protocol.parse_log_packet(pkt)
    assert rec.code == 0xB821
    assert rec.body == b"\x09\x00\x00\x00hello"
    assert abs((rec.timestamp - datetime(2025, 11, 19, 12, 0, 0, tzinfo=timezone.utc)).total_seconds()) < 0.002


def test_log_packet_tolerates_short_inner_length():
    pkt = bytearray(protocol.build_log_packet(0xB0C0, 1 << 20, b"abcdef"))
    struct.pack_into("<H", pkt, 4, 0xFFFF)   # bogus inner length
    rec = protocol.parse_log_packet(bytes(pkt))
    assert rec.body == b"abcdef"


def test_dlf_entries_iterate():
    a = protocol.build_log_entry(0xB0C0, 1 << 20, b"aa")
    b = protocol.build_log_entry(0xB821, 2 << 20, b"bbbb")
    recs = list(protocol.iter_log_entries(a + b))
    assert [r.code for r in recs] == [0xB0C0, 0xB821]
    assert recs[1].body == b"bbbb"


def test_timestamp_epoch_and_plausibility():
    assert protocol.qc_timestamp(0) is None
    assert protocol.qc_timestamp(1 << 16) == protocol.QC_EPOCH.replace(microsecond=1250)
    assert not protocol.timestamp_is_plausible(protocol.qc_timestamp(1 << 16))
    now = datetime(2026, 9, 8, tzinfo=timezone.utc)
    assert protocol.timestamp_is_plausible(protocol.qc_timestamp(protocol.qc_timestamp_from_datetime(now)))


def test_verno_and_build_id_parsers():
    verno = bytes([0]) + b"Sep 08 2026".ljust(11, b"\0") + b"12:00:00".ljust(8, b"\0") \
        + b"Sep 01 2026".ljust(11, b"\0") + b"08:00:00".ljust(8, b"\0") + b"MPSS.HI\0" \
        + bytes([0, 0, 0x42]) + struct.pack("<H", 0x0102) + bytes([0, 1, 0])
    info = protocol.parse_verno_response(verno)
    assert info.compile_date == "Sep 08 2026" and info.version_dir == "MPSS.HI"
    assert info.mobile_model == 0x42 and info.mobile_firmware_rev == 0x0102
    build = bytes([0x7C, 0, 0, 0]) + struct.pack("<II", 0x1234, 0x5678) + b"MPSS.HI.4.3.5-00123\0SM8550\0"
    info = protocol.parse_ext_build_id_response(build, info)
    assert info.build_id == "MPSS.HI.4.3.5-00123" and info.model_string == "SM8550"
    assert info.msm_revision == 0x1234


def _multi_log(packets, count=None, version=1):
    body = b"".join(packets)
    n = len(packets) if count is None else count
    return protocol.MULTI_LOG_HEADER.pack(protocol.DIAG_MULTI_LOG_F, version, 0, n) + body


def test_qmdl2_container_yields_the_single_packet_diag_mdlog_writes():
    packet = protocol.build_log_packet(0xB0C0, 0x1234, b"\x01\x02\x03\x04")
    got = list(protocol.iter_qmdl2_log_packets(_multi_log([packet])))
    assert got == [packet]
    rec = protocol.parse_log_packet(got[0])
    assert rec.code == 0xB0C0 and rec.body == b"\x01\x02\x03\x04"


def test_qmdl2_container_yields_every_packet_when_it_holds_several():
    packets = [
        protocol.build_log_packet(0xB0C0, 1, b"a" * 10),
        protocol.build_log_packet(0xB821, 2, b"b" * 3),
        protocol.build_log_packet(0xB0EC, 3, b""),
    ]
    got = list(protocol.iter_qmdl2_log_packets(_multi_log(packets)))
    assert got == packets
    assert [protocol.parse_log_packet(p).code for p in got] == [0xB0C0, 0xB821, 0xB0EC]


def test_qmdl2_container_stops_at_the_count_it_declares():
    packets = [protocol.build_log_packet(0xB0C0, 1, b"x" * 4),
               protocol.build_log_packet(0xB821, 2, b"y" * 4)]
    got = list(protocol.iter_qmdl2_log_packets(_multi_log(packets, count=1)))
    assert got == packets[:1]


def test_a_truncated_qmdl2_container_yields_what_it_holds():
    packet = protocol.build_log_packet(0xB0C0, 1, b"z" * 20)
    frame = _multi_log([packet])[:-5]
    got = list(protocol.iter_qmdl2_log_packets(frame))
    assert len(got) == 1 and len(got[0]) < len(packet)


def test_a_frame_that_is_not_a_qmdl2_container_yields_nothing():
    packet = protocol.build_log_packet(0xB0C0, 1, b"q")
    assert list(protocol.iter_qmdl2_log_packets(packet)) == []
    assert list(protocol.iter_qmdl2_log_packets(b"")) == []
    assert list(protocol.iter_qmdl2_log_packets(b"\x98\x01")) == []


def test_the_client_unwraps_a_qmdl2_container_into_records():
    from fieldtap.diag.client import DiagClient
    from fieldtap.diag.transport import Transport

    client = DiagClient(Transport())
    packet = protocol.build_log_packet(0xB0C0, 7, b"\xaa\xbb")
    assert client._absorb_async(_multi_log([packet])) is True
    assert client.stats["logs"] == 1
    assert client._pending[0].code == 0xB0C0
