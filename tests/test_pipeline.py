"""End to end: synthetic .qmdl -> transport -> client -> decoder -> sinks ->
files, then session sidecar, info, flow. Wireshark checks live in
test_wireshark.py."""

import json
import os
import struct

from fieldtap import fixtures, flow, info, pipeline
from fieldtap.decode import Decoder
from fieldtap.diag import hdlc, protocol
from fieldtap.diag.client import DiagClient
from fieldtap.diag.transport import FileTransport, LoopbackTransport
from fieldtap.output import exported_pdu
from fieldtap.output.pcapng import read_packets
from fieldtap.output.sinks import GsmtapPcapSink, PcapngSink
from fieldtap.session import Session, list_sessions


def _write_qmdl(tmp_path):
    records, expected = fixtures.build_corpus()
    path = tmp_path / "synthetic.qmdl"
    path.write_bytes(fixtures.build_qmdl(records))
    return str(path), records, expected


def test_replay_qmdl_to_pcapng_and_gsmtap(tmp_path):
    qmdl, records, expected = _write_qmdl(tmp_path)
    pcapng = str(tmp_path / "out.pcapng")
    gsm = str(tmp_path / "out_gsmtap.pcap")
    decoder = Decoder()
    result = pipeline.run(FileTransport(qmdl), [PcapngSink(pcapng), GsmtapPcapSink(gsm)], decoder)
    assert result.records == len(records)
    assert result.messages == len(expected)
    assert result.cell_info == 2
    assert result.framing["crc_errors"] == 1
    assert result.client_stats["stray_responses"] == 1     # the 0x7C frame in the noise
    packets = list(read_packets(pcapng))
    # Every record is in the pcap: the messages as native PDUs, the rest under fieldtap-diag.
    assert result.diag_records == len(records) - len(expected)
    assert len(packets) == len(expected) + result.diag_records
    for pkt, exp in zip(packets[:len(expected)], expected):
        options, payload = exported_pdu.parse(pkt.data)
        assert options["dissector"] == exp.dissector
        assert payload == exp.payload
        assert options.get("direction") == exp.direction
        assert pkt.comment.startswith("FieldTap ")
        assert pkt.linktype == exported_pdu.LINKTYPE_WIRESHARK_UPPER_PDU
    # modem timestamps were plausible, so they are the packet times
    assert packets[0].when.year == 2025
    lte_count = sum(1 for e in expected if e.rat == "lte")
    assert result.sinks["GsmtapPcapSink"]["packets"] == lte_count
    assert result.sinks["GsmtapPcapSink"]["skipped_no_gsmtap"] == len(expected) - lte_count
    assert result.sinks["GsmtapPcapSink"]["skipped_diag_record"] == result.diag_records
    from fieldtap.output import fieldtap_diag
    extra = packets[len(expected):]
    for pkt in extra:
        options, payload = exported_pdu.parse(pkt.data)
        assert options["dissector"] == fieldtap_diag.DISSECTOR
        assert fieldtap_diag.parse(payload)["log_code"] in (0xB0C2, 0xB0C1, 0xB193, 0xB0FF)


def test_replay_dlf_matches_qmdl(tmp_path):
    records, expected = fixtures.build_corpus()
    dlf = tmp_path / "synthetic.dlf"
    dlf.write_bytes(fixtures.build_dlf(records))
    out = str(tmp_path / "dlf.pcapng")
    result = pipeline.replay(str(dlf), [PcapngSink(out)])
    assert result.records == len(records) and result.messages == len(expected)


def test_session_sidecar_and_listing(tmp_path):
    qmdl, records, expected = _write_qmdl(tmp_path)
    root = str(tmp_path / "captures")
    session = Session(root, "unit test", note="synthetic", location="lab")
    decoder = Decoder()
    result = pipeline.run(FileTransport(qmdl), [PcapngSink(session.pcapng_path)], decoder, session)
    session.finish({"transport": "file"}, {"model": "SYNTH"}, {"build_id": "MPSS.TEST"}, "signalling",
                   {"enabled": [0xB821], "unsupported": [], "failed": []}, result.client_stats,
                   result.framing, result.decoder, result.sinks, {"pcapng": session.pcapng_path})
    meta = json.load(open(session.sidecar_path))
    assert meta["name"] == "unit test" and meta["handset"]["model"] == "SYNTH"
    assert meta["log_mask"]["enabled"] == ["0xB821"]
    s = meta["summary"]
    assert s["plmns"] == {"310260": 1}
    assert s["cells"][0]["tac"] == 0x1234
    assert s["messages"]["nr_rrc"] == 5 and s["messages"]["lte_nas"] == 6
    assert "nr:245" in s["pcis"] and 636000 in [int(k) for k in s["nr_arfcns"]]
    assert s["modem_time_first_utc"].startswith("2025-11-19T12:00:00")
    assert os.path.isfile(session.path("cells.csv"))
    listing = list_sessions(root)
    assert len(listing) == 1 and listing[0]["messages"] == len(expected) and listing[0]["plmns"] == "310260"


def test_info_and_flow(tmp_path):
    qmdl, records, expected = _write_qmdl(tmp_path)
    report = info.inspect(qmdl)
    assert report["log_records"] == len(records)
    assert report["framing"]["crc_errors"] == 1
    codes = {c["code"]: c for c in report["codes"]}
    assert codes["0xB821"]["count"] == 5 and codes["0xB821"]["versions"] == {9: 2, 15: 2, 33: 1}
    assert codes["0xB0FF"]["name"] == "(unknown)"
    text = info.render(report)
    assert "NR RRC OTA Packet" in text and "crc errors" in text
    out = str(tmp_path / "flow.pcapng")
    pipeline.run(FileTransport(qmdl), [PcapngSink(out)])
    events = flow.load_events(out, use_tshark=False)
    assert len(events) == len(expected)
    assert events[1].direction == "ul" and events[1].name == "rrcConnectionRequest"
    ladder = flow.render_text(events)
    assert "rrcConnectionRequest" in ladder and "->|" in ladder and "|<-" in ladder
    mermaid = flow.render_mermaid(events)
    assert mermaid.startswith("sequenceDiagram") and "UE->>NW: LTE RRC rrcConnectionRequest" in mermaid
    pc = info.inspect(out)
    assert pc["packets"] == len(expected) + 4 and pc["dissectors"]["nr-rrc.ul.ccch"] == 1
    assert pc["dissectors"]["fieldtap-diag"] == 4


def test_client_handshake_over_loopback():
    """The modem side of configure_logs, scripted: disable, ranges, set mask."""
    seen = []

    def modem(frame_bytes):
        req = hdlc.decode(frame_bytes)
        seen.append(req)
        if req[0] == protocol.DIAG_VERNO_F:
            return hdlc.encode(bytes([0]) + b"Sep 08 2026\0" + b"12:00:00" + b"Sep 01 2026\0" + b"08:00:00" + b"MPSS.HI\0" + bytes(7))
        if req[0] == protocol.DIAG_EXT_BUILD_ID_F:
            return hdlc.encode(bytes([0x7C, 0, 0, 0]) + struct.pack("<II", 1, 2) + b"MPSS.HI.TEST\0SYNTH\0")
        if req[0] == protocol.DIAG_LOG_CONFIG_F:
            op = struct.unpack_from("<I", req, 4)[0]
            if op == protocol.LOG_CONFIG_DISABLE_OP:
                return hdlc.encode(struct.pack("<BBBBII", 0x73, 0, 0, 0, 0, 0))
            if op == protocol.LOG_CONFIG_RETRIEVE_ID_RANGES_OP:
                return hdlc.encode(protocol.build_log_config_ranges_response([0] * 11 + [0x8FF] + [0] * 4))
            if op == protocol.LOG_CONFIG_SET_MASK_OP:
                equip, last = struct.unpack_from("<II", req, 8)
                return hdlc.encode(protocol.build_log_config_set_mask_response(equip, last, req[16:]))
        return hdlc.encode(bytes([protocol.DIAG_BAD_CMD_F]) + req)

    records, expected = fixtures.build_corpus()
    stream = fixtures.build_qmdl(records, with_noise=False)
    transport = LoopbackTransport(modem, stream)
    client = DiagClient(transport)
    transport.open()
    devinfo = client.probe()
    assert devinfo.build_id == "MPSS.HI.TEST" and devinfo.model_string == "SYNTH"
    mask = client.configure_logs([0xB0C0, 0xB821, 0xB0EC, 0xB97F])
    assert set(mask.enabled) == {0xB0C0, 0xB821, 0xB0EC}
    assert mask.unsupported == [0xB97F]            # beyond the reported range 0x8FF
    assert mask.ranges[0xB] == 0x8FF
    got = list(client.stream())
    assert len(got) == len(records)
    assert client.stats["logs"] == len(records)
    client.close()
    assert any(r[0] == protocol.DIAG_LOG_CONFIG_F and struct.unpack_from("<I", r, 4)[0] == 0 for r in seen[-2:])
