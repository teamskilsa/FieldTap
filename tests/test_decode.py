"""Decoder behaviour on the synthetic corpus: layouts, maps, NAS locator,
direction cross-check, cell info, robustness."""

import struct

from fieldtap import fixtures
from fieldtap.decode import CellInfo, Decoder, DecodedMessage, DiagRecord
from fieldtap.decode import lte_rrc, nr_rrc
from fieldtap.decode.msgnames import rrc_message_name
from fieldtap.diag.protocol import LogRecord


def _decode_all():
    records, expected = fixtures.build_corpus()
    decoder = Decoder()
    messages = []
    cells = []
    diag = []
    for code, ts, body in records:
        for obj in decoder.decode(LogRecord(code, ts, body)):
            if isinstance(obj, DecodedMessage):
                messages.append(obj)
            elif isinstance(obj, CellInfo):
                cells.append(obj)
            else:
                assert isinstance(obj, DiagRecord)
                diag.append(obj)
    _decode_all.diag = diag
    return decoder, messages, cells, expected


def test_every_expected_message_decodes_as_specified():
    decoder, messages, cells, expected = _decode_all()
    assert len(messages) == len(expected)
    for msg, exp in zip(messages, expected):
        assert msg.log_code == exp.log_code
        assert msg.version == exp.version
        assert msg.rat == exp.rat and msg.layer == exp.layer
        assert msg.channel.key == exp.channel, (exp, msg.channel)
        assert msg.direction == exp.direction, (exp, msg.fields)
        assert msg.dissector == exp.dissector
        assert msg.payload == exp.payload, (exp, msg.payload.hex())
        assert msg.name == exp.name, (exp.name, msg.name)
        src = msg.fields.get("layout_source") or msg.fields.get("nas_locate")
        assert src == exp.layout_source, (exp, msg.fields)
        assert bool(msg.fields.get("direction_conflict")) == exp.conflict


def test_decoder_statistics():
    decoder, messages, cells, expected = _decode_all()
    rep = decoder.report()
    assert rep["stats"]["messages"] == len(expected)
    assert rep["stats"]["cell_info"] == 2
    assert rep["unknown_codes"] == {"0xB0FF": 1}
    assert rep["stats"]["direction_conflicts"] == 1
    assert rep["layout_sources"]["probed"] >= 3
    assert rep["stats"]["errors"] == 0
    # Nothing is dropped: every record that is not a message is a DiagRecord on its way to the pcap.
    diag = _decode_all.diag
    assert rep["stats"]["diag_records"] == len(diag) == len(records_total()) - len(expected)
    assert rep["coverage"]["0xB0FF"] == {"name": "unknown log 0xB0FF", "records": 1, "as": {"raw": 1}, "confidence": "low"}
    assert rep["coverage"]["0xB0C2"]["as"] == {"cell": 1}
    assert rep["coverage"]["0xB0C0"]["as"] == {"message": 6}
    raw = [d for d in diag if d.log_code == 0xB0FF][0]
    assert raw.decoded == "raw" and raw.body == b"\x00\x01\x02" and "no layout" in raw.comment()
    cell = [d for d in diag if d.log_code == 0xB0C2][0]
    assert cell.decoded == "fields" and cell.fields["plmn"] == "310260" and "plmn 310260" in cell.comment()


def records_total():
    records, _ = fixtures.build_corpus()
    return records


def test_cell_info_fields():
    _, _, cells, _ = _decode_all()
    serving = [c for c in cells if c.kind == "serving_cell"][0]
    f = serving.fields
    assert f["plmn"] == "310260" and f["tac"] == 0x1234 and f["band"] == 3
    assert f["enb_id"] == 0x1234 and f["sector"] == 0x5A and f["dl_bw_mhz"] == 20.0
    assert f["plausible"]
    mib = [c for c in cells if c.kind == "mib"][0]
    assert mib.fields["sfn"] == 512 and mib.fields["pci"] == 101


def test_lte_layout_falls_back_when_version_table_is_wrong():
    # Claim version 2 (16-bit EARFCN) but pack a 32-bit EARFCN body: the length
    # check must reject layout A and pick B.
    body = fixtures.lte_rrc_body(2, 5, fixtures.LTE_RRC_CONN_REL, earfcn_width=4)
    msg = lte_rrc.decode(LogRecord(0xB0C0, 1 << 20, body))
    assert msg.fields["layout"] == "B" and msg.fields["layout_source"] == "probed"
    assert msg.payload == fixtures.LTE_RRC_CONN_REL


def test_nr_unknown_pdu_type_is_kept_as_data():
    body = fixtures.nr_rrc_body(9, 42, b"\x01\x02\x03")
    msg = nr_rrc.decode(LogRecord(0xB821, 1 << 20, body))
    assert msg.dissector == "data" and "42" in msg.channel.label
    assert "not decoded" in msg.comment()


def test_truncated_records_do_not_raise():
    """Short or empty bodies are rejected quietly: no exception, no error
    counted, no RRC/NAS message invented. A zero-filled body long enough for
    a cell-info layout may still parse, and that is not an error."""
    decoder = Decoder()
    for code in (0xB0C0, 0xB821, 0xB0EC, 0xB80A, 0xB0C2, 0xB0C1):
        for n in range(0, 12):
            for obj in decoder.decode(LogRecord(code, 1 << 20, bytes(n))):
                assert not isinstance(obj, DecodedMessage), (hex(code), n, obj)
    assert decoder.report()["stats"]["errors"] == 0


def test_comment_carries_diag_metadata():
    body = fixtures.nr_rrc_body(9, 4, fixtures.NR_RRC_RELEASE, pci=77, arfcn=636000, sfn=100, subfn=7)
    msg = nr_rrc.decode(LogRecord(0xB821, 1 << 20, body))
    c = msg.comment()
    assert c.startswith("FieldTap NR RRC DL-DCCH rrcRelease")
    assert "PCI 77" in c and "NR-ARFCN 636000" in c and "SFN 100.7" in c and "log 0xB821 v9" in c


def test_gsmtap_mapping_only_for_lte():
    _, messages, _, _ = _decode_all()
    for msg in messages:
        if msg.rat == "lte":
            assert msg.gsmtap is not None
            assert msg.gsmtap[0] == (13 if msg.layer == "rrc" else 18)
        else:
            assert msg.gsmtap is None


def test_rrc_message_name_peek():
    assert rrc_message_name("lte", "UL_CCCH", fixtures.LTE_RRC_CONN_REQ) == "rrcConnectionRequest"
    assert rrc_message_name("lte", "DL_DCCH", fixtures.LTE_RRC_CONN_REL) == "rrcConnectionRelease"
    assert rrc_message_name("nr", "UL_CCCH", fixtures.NR_RRC_SETUP_REQ) == "rrcSetupRequest"
    assert rrc_message_name("nr", "DL_DCCH", fixtures.NR_RRC_RELEASE) == "rrcRelease"
    assert rrc_message_name("nr", "BCCH_BCH", fixtures.NR_MIB) == "mib"
    assert rrc_message_name("lte", "DL_DCCH", b"") is None


def test_nas_service_request_short_header():
    from fieldtap.decode import nas
    from fieldtap.decode.registry import LOG_CODES
    body = fixtures.lte_nas_body(bytes.fromhex("C7" + "12" + "3456"))
    msg = nas.decode(LogRecord(0xB0ED, 1 << 20, body), LOG_CODES[0xB0ED])
    assert msg.name == "Service request" and msg.direction == "ul"
    assert msg.fields["security_header"] == 12


def test_nr_nas_header_scan_beyond_table():
    from fieldtap.decode import nas
    from fieldtap.decode.registry import LOG_CODES
    body = struct.pack("<I", 1) + bytes(11) + fixtures.MM5G_IDENTITY_REQUEST
    msg = nas.decode(LogRecord(0xB80A, 1 << 20, body), LOG_CODES[0xB80A])
    assert msg.payload == fixtures.MM5G_IDENTITY_REQUEST
    assert msg.fields["nas_locate"] == "scanned" and msg.fields["nas_offset"] == 15
