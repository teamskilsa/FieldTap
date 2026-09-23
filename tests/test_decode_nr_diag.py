"""The NR record decoders (0xB822, 0xB823, 0xB80C, 0xB975, 0xB97F, 0xB888, 0xB883,
0xB872) on synthetic records packed independently of their tables: every field of
every version, None on truncated or misfitting bodies, "partial" with a note when a
value is implausible, and the 0xB80C NAS fallback on the synthetic corpus record."""

import csv
import os

import pytest

from fieldtap import fixtures
from fieldtap import fixtures_nr_diag as fx
from fieldtap.decode import CellInfo, Decoder, DecodedMessage, DiagRecord
from fieldtap.decode import nr_cell, nr_common, nr_mac, nr_ml1, nr_state
from fieldtap.decode.registry import LOG_CODES
from fieldtap.diag.protocol import LogRecord
from fieldtap.session import CELLS_COLUMNS, Session

TS = 0x0123456789ABCDEF
DOC = nr_common.DOC_NOTE


def rec(code, body):
    return LogRecord(code, TS, body)


def decode(code, body):
    """Through the Decoder, the way the pipeline does it: the list of objects."""
    return Decoder().decode(rec(code, body))


def diag(code, body) -> DiagRecord:
    out = decode(code, body)
    assert len(out) == 1 and isinstance(out[0], DiagRecord), out
    return out[0]


# --- the Q7 fixed point ------------------------------------------------------------------------

@pytest.mark.parametrize("db", [-90.0, -90.5, -97.25, -101.75, -156.0, -31.0, -10.5, -43.0, -0.5, -255.0])
def test_q7_round_trip(db):
    assert nr_common.nr_q7(fx.q7_raw(db)) == pytest.approx(fx.q7_value(db))
    assert nr_common.nr_q7(fx.q7_raw(db)) == pytest.approx(db, abs=0.004)


def test_q7_zero_is_not_available():
    assert nr_common.nr_q7(0) is None
    assert nr_common.nr_q7(fx.q7_raw(-90.0)) == -90.0
    assert nr_common.nr_q7(fx.q7_raw(-90.5)) == -90.5


# --- 0xB822 NR RRC MIB Info -------------------------------------------------------------------

@pytest.mark.parametrize("major,minor,layout,size", [(2, 0, "bits5", 15), (0, 3, "bits4", 14)])
def test_mib_every_field(major, minor, layout, size):
    body = fx.nr_mib_body(major, minor, pci=417, arfcn=647328, sfn=777, scs=2)
    assert len(body) == size
    out = decode(0xB822, body)
    assert isinstance(out[0], CellInfo) and isinstance(out[1], DiagRecord)
    cell = out[0]
    assert cell.rat == "nr" and cell.kind == "mib"
    f = cell.fields
    assert f["version"] == "%d.%d" % (major, minor) and f["layout"] == layout and f["layout_source"] == "table"
    assert (f["pci"], f["earfcn"], f["sfn"], f["scs"], f["scs_khz"]) == (417, 647328, 777, 2, 60)
    assert f["plausible"] is True and DOC in f["layout_note"]
    assert cell.version == (major << 16) | minor
    wrapped = out[1]
    assert wrapped.decoded == "fields" and wrapped.body == body and wrapped.confidence == LOG_CODES[0xB822].confidence
    assert wrapped.comment().startswith("FieldTap 0xB822 NR RRC MIB Info v%d | pci 417 | earfcn 647328 | sfn 777" % cell.version)


def test_mib_bit_positions_are_the_documented_ones():
    # SFN in the top ten bits of the bit string, SCS in bits 30..31 (four bytes) or 31..32 (five)
    body = fx.nr_mib_body(0, 3, sfn=0x2AB, scs=3)
    assert body[10:] == bytes([0xAA, 0xC0, 0x00, 0x03])
    body = fx.nr_mib_body(2, 0, sfn=0x2AB, scs=3)
    assert body[10:] == bytes([0xAA, 0xC0, 0x00, 0x01, 0x80])
    assert decode(0xB822, body)[0].fields["sfn"] == 0x2AB


def test_mib_sfn_and_scs_extremes():
    for sfn in (0, 1, 1023):
        for scs in (0, 1, 2, 3):
            for v in ((2, 0), (0, 3)):
                f = decode(0xB822, fx.nr_mib_body(*v, sfn=sfn, scs=scs))[0].fields
                assert (f["sfn"], f["scs"]) == (sfn, scs), (v, sfn, scs)


def test_mib_truncated_and_misfitting_bodies_are_left_raw():
    good = fx.nr_mib_body(2, 0)
    for cut in (0, 3, 4, 9, 13):
        assert nr_cell.decode_mib(rec(0xB822, good[:cut])) is None, cut
    # the wrong size for either bit-string width
    assert nr_cell.decode_mib(rec(0xB822, good[:13])) is None
    out = diag(0xB822, good[:13])
    assert out.decoded == "raw" and "layout did not fit" in out.note


def test_mib_version_probed_by_size_and_trailing_bytes_noted():
    # an unknown version pair whose size is the five-byte layout
    f = decode(0xB822, fx.nr_mib_body(2, 1))[0].fields
    assert f["layout"] == "bits5" and f["layout_source"] == "probed"
    # a known version with bytes after the layout: the table layout is used and the rest noted
    out = decode(0xB822, fx.nr_mib_body(2, 0, trailing=b"\x00\x00"))
    assert out[0].fields["layout_source"] == "table" and "2 trailing bytes" in out[0].fields["layout_note"]
    assert out[0].fields["sfn"] == 512


def test_mib_implausible_value_is_partial_not_a_cell():
    out = decode(0xB822, fx.nr_mib_body(2, 0, pci=1008))
    assert len(out) == 1 and isinstance(out[0], DiagRecord)
    r = out[0]
    assert r.decoded == "partial" and "implausible: pci" in r.note and DOC in r.note
    assert r.fields["pci"] is None and r.fields["earfcn"] == 647328
    assert "pci None" not in r.comment()
    r = decode(0xB822, fx.nr_mib_body(2, 0, arfcn=3279166))[0]
    assert r.decoded == "partial" and "implausible: earfcn" in r.note and r.fields["earfcn"] is None


# --- 0xB823 NR RRC Serving Cell Info -------------------------------------------------------------

@pytest.mark.parametrize("major,minor,layout,size", [(0, 4, "v0", 38), (3, 0, "v3", 46), (3, 2, "v3p", 49), (3, 3, "v3p", 49)])
def test_serving_cell_every_field(major, minor, layout, size):
    body = fx.nr_serving_cell_body(major, minor)
    assert len(body) == size
    out = decode(0xB823, body)
    cell = out[0]
    assert isinstance(cell, CellInfo) and cell.rat == "nr" and cell.kind == "serving_cell"
    f = cell.fields
    assert f["version"] == "%d.%d" % (major, minor) and f["layout"] == layout and f["layout_source"] == "table"
    assert f["pci"] == 417 and f["dl_earfcn"] == 647328 and f["ul_earfcn"] == 647328
    assert f["dl_bw"] == 100 and f["dl_bw_mhz"] == 100 and f["ul_bw_mhz"] == 100
    assert f["cell_id"] == 0x2167F401A and f["mcc"] == 311 and f["mnc"] == 480 and f["mnc_digits"] == 3
    assert f["plmn"] == "311480" and f["tac"] == 360102 and f["band"] == 77 and f["allowed_access"] == 0
    assert f["plausible"] is True and DOC in f["layout_note"]
    if layout == "v0":
        assert "nr_cgi" not in f
    else:
        assert f["nr_cgi"] == (311480 << 36) | 0x2167F401A
    wrapped = out[1]
    assert wrapped.decoded == "fields" and wrapped.fields["plmn"] == "311480"
    assert " | plmn 311480 | pci 417 | dl_earfcn 647328 | band 77 | tac 360102 | cell_id 8967372826" in wrapped.comment()


def test_serving_cell_two_digit_mnc_and_test_plmn():
    f = decode(0xB823, fx.nr_serving_cell_body(3, 0, mcc=1, mnc_digits=2, mnc=1))[0].fields
    assert f["plmn"] == "00101" and f["plausible"] is True
    f = decode(0xB823, fx.nr_serving_cell_body(0, 4, mcc=234, mnc_digits=2, mnc=15))[0].fields
    assert f["plmn"] == "23415"


def test_serving_cell_bandwidth_units_are_not_assumed():
    f = decode(0xB823, fx.nr_serving_cell_body(3, 0, dl_bw=3, ul_bw=273))[0].fields
    assert f["dl_bw"] == 3 and f["dl_bw_mhz"] is None and f["ul_bw_mhz"] is None


def test_serving_cell_truncated_and_misfitting_bodies_are_left_raw():
    for v in ((0, 4), (3, 0), (3, 2)):
        good = fx.nr_serving_cell_body(*v)
        for cut in (0, 3, 4, len(good) - 1):
            assert nr_cell.decode_serving_cell(rec(0xB823, good[:cut])) is None, (v, cut)
    out = diag(0xB823, fx.nr_serving_cell_body(3, 0)[:40])
    assert out.decoded == "raw"


def test_serving_cell_layout_probed_by_size_for_unknown_versions():
    # version 3.1 is not in the table; 42 bytes after the version is the 3.0 layout
    f = decode(0xB823, fx.nr_serving_cell_body(3, 1))[0].fields
    assert f["layout"] == "v3" and f["layout_source"] == "probed" and f["plmn"] == "311480"
    # version 3.0 with a 0.4-sized body: probed as 0.4, no guessing
    body = fx.nr_serving_cell_body(0, 4)
    body = body[:0] + fx._version(3, 0) + body[4:]
    f = decode(0xB823, body)[0].fields
    assert f["layout"] == "v0" and f["layout_source"] == "probed" and f["tac"] == 360102
    # trailing bytes after a table layout are noted, not misread
    out = decode(0xB823, fx.nr_serving_cell_body(3, 0, trailing=bytes(2)))[0]
    assert out.fields["layout_source"] == "table" and "2 trailing bytes" in out.fields["layout_note"]
    # ... unless they make the body another layout's exact size: 3.0 plus three bytes is the 3.2 shape
    out = decode(0xB823, fx.nr_serving_cell_body(3, 0, trailing=bytes(3)))[0]
    assert out.fields["layout"] == "v3p" and out.fields["layout_source"] == "probed"


@pytest.mark.parametrize("kw,field", [
    ({"pci": 1008}, "pci"), ({"band": 0}, "band"), ({"band": 1025}, "band"), ({"tac": 0x1000000}, "tac"),
    ({"mcc": 199}, "mcc"), ({"mcc": 1000}, "mcc"), ({"mnc_digits": 4}, "mnc"), ({"mnc": 1000}, "mnc"),
    ({"cell_id": 1 << 36}, "cell_id"), ({"dl_arfcn": 3279166}, "dl_earfcn"),
])
def test_serving_cell_implausible_value_is_partial_not_a_cell(kw, field):
    out = decode(0xB823, fx.nr_serving_cell_body(3, 0, **kw))
    assert len(out) == 1 and isinstance(out[0], DiagRecord)
    r = out[0]
    assert r.decoded == "partial" and ("implausible: %s" % field) in r.note and DOC in r.note
    assert r.fields[field] is None
    if field in ("mcc", "mnc"):
        assert r.fields["plmn"] is None
    assert "plausible" not in r.fields


def test_serving_cell_lands_in_the_session_sidecar_and_cells_csv(tmp_path):
    session = Session(str(tmp_path), name="nr")
    for code, ts, body in fx.build_nr_corpus():
        for obj in Decoder().decode(LogRecord(code, ts, body)):
            session.observe(obj)
    # the three 0xB823 records describe one cell: one row, keyed on plmn/cell_id/pci/dl_earfcn
    assert len(session._cells) == 1
    cell = session._cells[0]
    assert cell["rat"] == "nr" and cell["plmn"] == "311480" and cell["cell_id"] == 0x2167F401A
    assert cell["pci"] == 417 and cell["dl_earfcn"] == 647328 and cell["band"] == 77 and cell["tac"] == 360102
    assert cell["first_seen_utc"].startswith("2025-11-19T12:00:30")
    assert session._plmns == {"311480": 3}
    session.write_cells_csv()
    with open(os.path.join(session.dir, "cells.csv"), newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    assert list(rows[0]) == CELLS_COLUMNS
    assert rows[0]["rat"] == "nr" and rows[0]["plmn"] == "311480" and rows[0]["mcc"] == "311" and rows[0]["mnc"] == "480"
    assert rows[0]["cell_id"] == str(0x2167F401A) and rows[0]["dl_bw_mhz"] == "100" and rows[0]["plausible"] == "True"
    assert rows[0]["enb_id"] == "" and rows[0]["sector"] == ""


# --- 0xB80C NR NAS MM5G State ----------------------------------------------------------------------

def test_mm5g_state_record_every_field():
    body = fx.nr_mm5g_state_body(state=3, substate=0, tmsi=0x0CC6E898, amf_region=1, amf_set=1, amf_pointer=0)
    assert len(body) == nr_state.STATE_LAYOUT_LEN
    r = diag(0xB80C, body)
    assert r.decoded == "fields" and r.version == 1 and r.note == DOC
    f = r.fields
    assert f["state"] == "registered" and f["state_code"] == 3 and f["substate"] == "normal_service"
    assert f["plmn"] == "311480" and f["guti_plmn"] == "311480" and f["guti_ue_id_type"] == "5g_guti"
    assert f["amf_region_id"] == 1 and f["amf_set_id"] == 1 and f["amf_pointer"] == 0
    assert f["tmsi_5g"] == "0x0CC6E898" and f["update_status"] == "updated" and f["tac"] == 360102
    assert r.comment().startswith("FieldTap 0xB80C NR NAS MM5G State v1 | state registered | plmn 311480 | tac 360102")
    r = diag(0xB80C, fx.nr_mm5g_state_body(state=1, substate=5, mcc=1, mnc=1, mnc_digits=2, update_status=1))
    assert r.fields["state"] == "deregistered" and r.fields["substate"] == "limited_service"
    assert r.fields["plmn"] == "00101" and r.fields["update_status"] == "not_updated"


def test_mm5g_state_plmn_encoding():
    assert nr_state.decode_plmn(fx.plmn_octets(311, 480, 3)) == "311480"
    assert nr_state.decode_plmn(fx.plmn_octets(1, 1, 2)) == "00101"
    assert nr_state.decode_plmn(bytes([0x13, 0x01, 0x81])) == "311180"    # AT&T, as the Jul 2024 capture had it


def test_mm5g_state_falls_back_to_the_nas_locator():
    """The synthetic corpus carries a 0xB80C record that holds a NAS message; a body that is
    not the state layout is offered to the NAS locator as before."""
    body = fixtures.nr_nas_body(fixtures.MM5G_IDENTITY_REQUEST_INTEGRITY, header=7)
    out = decode(0xB80C, body)
    assert len(out) == 1 and isinstance(out[0], DecodedMessage)
    msg = out[0]
    assert msg.rat == "nr" and msg.layer == "nas" and msg.payload == fixtures.MM5G_IDENTITY_REQUEST_INTEGRITY
    assert msg.name == "Identity request" and msg.dissector == "nas-5gs"
    # a state-shaped record is never mistaken for a message, and an empty one is raw
    info = LOG_CODES[0xB80C]
    assert isinstance(nr_state.decode_mm5g_state(rec(0xB80C, fx.nr_mm5g_state_body()), info), DiagRecord)
    assert nr_state.decode_mm5g_state(rec(0xB80C, b""), info) is None
    # version 1 but an unknown state code: not the state layout; the locator finds no NAS in it
    wrong = bytearray(fx.nr_mm5g_state_body())
    wrong[4] = 9
    assert nr_state.decode_mm5g_state(rec(0xB80C, bytes(wrong)), info) is None


# --- 0xB975 NR ML1 Serving Cell Beam Management ----------------------------------------------------

@pytest.mark.parametrize("beam_len", [12, 16])
def test_beam_mgmt_every_field(beam_len):
    beams = ((3, -90.5, -10.5), (5, -97.25, -13.0), (7, -104.0, -18.75))
    body = fx.nr_beam_mgmt_body(pci=417, ssb_periodicity=20, serving_beam=3, rsrp=-90.5, rsrq=-10.5,
                                freq_offset=120, time_offset=45, beams=beams, beam_len=beam_len)
    assert len(body) == 40 + 3 * beam_len
    r = diag(0xB975, body)
    assert r.decoded == "fields" and r.version == (2 << 16) | 1 and DOC in r.note
    f = r.fields
    assert f["version"] == "2.1" and f["pci"] == 417 and f["ssb_periodicity"] == 20 and f["serving_beam_ssb_index"] == 3
    assert f["rsrp"] == -90.5 and f["rsrq"] == -10.5 and f["freq_offset"] == 120 and f["time_offset"] == 45
    assert f["num_beams"] == 3
    assert r.sections == [("beams", [
        {"beam": 0, "tx_beam_index": 3, "rsrp": -90.5, "rsrq": -10.5},
        {"beam": 1, "tx_beam_index": 5, "rsrp": -97.25, "rsrq": -13.0},
        {"beam": 2, "tx_beam_index": 7, "rsrp": -104.0, "rsrq": -18.75},
    ])]
    assert ("16-byte beam records" in r.note) == (beam_len == 16)
    assert "| pci 417 | rsrp -90.5 | rsrq -10.5 |" in r.comment() and "beams x3" in r.comment()


def test_beam_mgmt_not_available_and_no_beams():
    body = fx.nr_beam_mgmt_body(beams=())
    body = body[:12] + bytes(8) + body[20:]          # RSRP/RSRQ raw 0: not available
    r = diag(0xB975, body)
    assert len(body) == 40 and r.decoded == "fields"
    assert r.fields["rsrp"] is None and r.fields["rsrq"] is None and r.sections == [("beams", [])]
    assert "rsrp" not in r.comment()


def test_beam_mgmt_truncated_or_misfitting_bodies_are_left_raw():
    good = fx.nr_beam_mgmt_body()
    for cut in (0, 4, 39, len(good) - 1):
        assert nr_ml1.decode_beam_mgmt(rec(0xB975, good[:cut])) is None, cut
    assert nr_ml1.decode_beam_mgmt(rec(0xB975, good + b"\x00")) is None
    assert diag(0xB975, good[:50]).decoded == "raw"


def test_beam_mgmt_unknown_version_is_partial():
    r = diag(0xB975, fx.nr_beam_mgmt_body(major=2, minor=2))
    assert r.decoded == "partial" and "version 2.2 not in the table" in r.note
    assert r.fields["pci"] == 417 and r.fields["rsrp"] == -90.5


def test_beam_mgmt_implausible_values_are_partial():
    r = diag(0xB975, fx.nr_beam_mgmt_body(rsrp=-20.0))
    assert r.decoded == "partial" and "implausible: rsrp" in r.note and r.fields["rsrp"] is None
    assert r.fields["rsrq"] == -10.5
    r = diag(0xB975, fx.nr_beam_mgmt_body(pci=1008, beams=((3, -90.5, 21.0),)))
    assert r.decoded == "partial" and "implausible: pci, beam[0].rsrq" in r.note
    assert r.fields["pci"] is None and r.sections[0][1][0]["rsrq"] is None and r.sections[0][1][0]["rsrp"] == -90.5


# --- 0xB97F NR ML1 Searcher Measurement Database Update Ext ----------------------------------------

def _expected_rows_27():
    return {
        "carriers": [{"layer": 0, "arfcn": 647328, "num_cells": 2, "serving_cell_index": 0, "serving_pci": 417,
                      "serving_ssb": 3, "serving_rsrp_rx0": -91.0, "serving_rsrp_rx1": -93.5,
                      "serving_rx_beam0": None, "serving_rx_beam1": None, "serving_rfic_id": 0,
                      "serving_subarray0": 0, "serving_subarray1": 0}],
        "cells": [{"layer": 0, "cell": 0, "pci": 417, "pbch_sfn": 512, "num_beams": 2, "rsrp": -90.0, "rsrq": -10.5},
                  {"layer": 0, "cell": 1, "pci": 418, "pbch_sfn": 513, "num_beams": 1, "rsrp": -101.75, "rsrq": -15.0}],
        "beams": [
            {"layer": 0, "cell": 0, "beam": 0, "ssb_index": 3, "rx_beam_id0": None, "rx_beam_id1": None,
             "ssb_ref_timing": 0x1122334455667788, "rsrp_rx0": -90.5, "rsrp_rx1": -92.25, "nr2nr_rsrp_l3": -90.0,
             "nr2nr_rsrq_l3": -10.5, "l2_rsrp_l3": -90.0, "l2_rsrq_l3": -10.5},
            {"layer": 0, "cell": 0, "beam": 1, "ssb_index": 5, "rx_beam_id0": None, "rx_beam_id1": None,
             "ssb_ref_timing": 0x1122334455667788, "rsrp_rx0": -97.0, "rsrp_rx1": -99.5, "nr2nr_rsrp_l3": -97.25,
             "nr2nr_rsrq_l3": -13.0, "l2_rsrp_l3": -97.25, "l2_rsrq_l3": -13.0},
            {"layer": 0, "cell": 1, "beam": 0, "ssb_index": 1, "rx_beam_id0": None, "rx_beam_id1": None,
             "ssb_ref_timing": 0x1122334455667788, "rsrp_rx0": -102.0, "rsrp_rx1": -103.5, "nr2nr_rsrp_l3": -101.75,
             "nr2nr_rsrq_l3": -15.0, "l2_rsrp_l3": -101.75, "l2_rsrq_l3": -15.0},
        ],
    }


@pytest.mark.parametrize("with_fmt", [True, False])
def test_search_meas_2_7_every_field(with_fmt):
    body = fx.nr_search_meas_body(2, 7, with_fmt=with_fmt)
    assert len(body) == (16 if with_fmt else 8) + 32 + 2 * 16 + 3 * 44
    r = diag(0xB97F, body)
    assert r.decoded == "fields" and r.version == (2 << 16) | 7 and r.note == DOC
    f = r.fields
    assert f["version"] == "2.7" and f["num_layers"] == 1 and f["ssb_periodicity"] == 20
    assert f["num_cells"] == 2 and f["num_beams"] == 3
    assert f["arfcn"] == 647328 and f["pci"] == 417 and f["rsrp"] == -90.0 and f["rsrq"] == -10.5
    if with_fmt:
        assert f["freq_offset"] == 120 and f["timing_offset"] == 45
    else:
        assert "freq_offset" not in f
    assert dict(r.sections) == _expected_rows_27()
    assert "| pci 417 | arfcn 647328 | rsrp -90.0 | rsrq -10.5 | num_cells 2 |" in r.comment()
    assert "carriers x1 | cells x2 | beams x3" in r.comment()


def test_search_meas_2_6_reports_raw_measurements():
    body = fx.nr_search_meas_body(2, 6)
    assert len(body) == 8 + 32 + 2 * 16 + 3 * 44
    r = diag(0xB97F, body)
    assert r.decoded == "fields" and "2.6 RSRP/RSRQ scaling is unverified" in r.note and DOC in r.note
    f = r.fields
    assert f["version"] == "2.6" and f["pci"] == 417 and f["arfcn"] == 647328 and "rsrp" not in f and "rsrq" not in f
    rows = dict(r.sections)
    assert rows["carriers"][0]["serving_rsrp_rx0_raw"] == fx.raw26(-91.0)
    assert rows["cells"][0]["rsrp_raw"] == fx.raw26(-90.0) and rows["cells"][0]["rsrq_raw"] == fx.raw26(-10.5)
    assert "rsrp" not in rows["cells"][0]
    b = rows["beams"][0]
    assert (b["ssb_ref_timing1"], b["ssb_ref_timing2"]) == (0x55667788, 0x11223344)
    assert b["rsrp_rx0_raw"] == fx.raw26(-90.5) and b["l2_rsrq_l3_raw"] == fx.raw26(-10.5)
    assert rows["cells"][1]["pci"] == 418 and rows["cells"][1]["pbch_sfn"] == 513


@pytest.mark.parametrize("major,minor", [(2, 9), (2, 10)])
def test_search_meas_2_9_and_2_10_skip_the_84_byte_beams(major, minor):
    body = fx.nr_search_meas_body(major, minor)
    assert len(body) == 16 + 32 + 2 * 16 + 3 * 84
    r = diag(0xB97F, body)
    assert r.decoded == "partial" and "84-byte beam records skipped by size" in r.note
    f = r.fields
    assert f["version"] == "%d.%d" % (major, minor) and f["pci"] == 417 and f["rsrp"] == -90.0 and f["freq_offset"] == 120
    rows = dict(r.sections)
    assert rows["cells"] == _expected_rows_27()["cells"]
    assert rows["carriers"][0]["serving_rsrp_rx0"] == -91.0
    assert rows["beams"] == [{"layer": 0, "cell": 0, "beam": 0, "ssb_index": 3}, {"layer": 0, "cell": 0, "beam": 1, "ssb_index": 5},
                             {"layer": 0, "cell": 1, "beam": 0, "ssb_index": 1}]


def test_search_meas_3_0_layout():
    body = fx.nr_search_meas_body(3, 0)
    assert len(body) == 20 + 40 + 2 * 16 + 3 * 84 and body[8] == 1
    r = diag(0xB97F, body)
    assert r.decoded == "partial" and "84-byte beam records skipped by size" in r.note
    f = r.fields
    assert f["version"] == "3.0" and f["num_layers"] == 1 and "ssb_periodicity" not in f and "freq_offset" not in f
    assert f["pci"] == 417 and f["arfcn"] == 647328 and f["rsrp"] == -90.0 and f["rsrq"] == -10.5
    rows = dict(r.sections)
    assert rows["carriers"] == [{"layer": 0, "arfcn": 647328, "cc_id": 0, "num_cells": 2, "serving_pci": 417}]
    assert rows["cells"] == _expected_rows_27()["cells"]
    assert [b["ssb_index"] for b in rows["beams"]] == [3, 5, 1]


def test_search_meas_3_0_count_sentinel_uses_the_serving_index():
    # On the iPhone 17 a cell count of 0xFF means "see the serving index".
    cells = [fx.cell(417, 512, -90.0, -10.5), fx.cell(418, 513, -101.75, -15.0)]
    body = bytearray(fx.nr_search_meas_body(3, 0, carriers=[fx.carrier(647328, 417, cells, serving_index=2)]))
    body[20 + 5] = 0xFF
    r = diag(0xB97F, bytes(body))
    assert r.decoded == "partial" and [c["pci"] for c in dict(r.sections)["cells"]] == [417, 418]


def test_search_meas_two_carriers_and_no_serving_cell():
    carriers = [
        fx.carrier(647328, 417, [fx.cell(417, 512, -90.0, -10.5, [fx.beam(3, -90.5, -92.25, -90.0, -10.5)])]),
        fx.carrier(636000, 0xFFFF, [fx.cell(300, 7, -110.0, -17.5)], rsrp_rx0=-110.0, rsrp_rx1=-111.0),
    ]
    r = diag(0xB97F, fx.nr_search_meas_body(2, 7, carriers=carriers))
    assert r.decoded == "fields" and r.fields["num_layers"] == 2 and r.fields["num_cells"] == 2
    rows = dict(r.sections)
    assert rows["carriers"][1]["serving_pci"] is None and rows["carriers"][1]["arfcn"] == 636000
    assert rows["cells"][1] == {"layer": 1, "cell": 0, "pci": 300, "pbch_sfn": 7, "num_beams": 0, "rsrp": -110.0, "rsrq": -17.5}
    # a first carrier without a serving cell: no headline PCI or RSRP, but nothing implausible
    r = diag(0xB97F, fx.nr_search_meas_body(2, 7, carriers=carriers[1:]))
    assert r.decoded == "fields" and r.fields["pci"] is None and "rsrp" not in r.fields


def test_search_meas_truncated_or_misfitting_bodies_are_left_raw():
    for v in ((2, 6), (2, 7), (2, 9), (3, 0)):
        good = fx.nr_search_meas_body(*v)
        for cut in (0, 3, 7, 15, 40, len(good) - 1):
            assert nr_ml1.decode_search_meas(rec(0xB97F, good[:cut])) is None, (v, cut)
        assert nr_ml1.decode_search_meas(rec(0xB97F, good + b"\x00")) is None, v
    # a 2.7 record whose beam records are the 84-byte kind does not fit any 2.7 layout
    assert nr_ml1.decode_search_meas(rec(0xB97F, fx.nr_search_meas_body(2, 9)[:0] + fx._version(2, 7)
                                         + fx.nr_search_meas_body(2, 9)[4:])) is None
    assert diag(0xB97F, fx.nr_search_meas_body(2, 7)[:100]).decoded == "raw"


def test_search_meas_unknown_version_is_probed_and_partial():
    body = fx.nr_search_meas_body(2, 7)
    body = fx._version(2, 8) + body[4:]
    r = diag(0xB97F, body)
    assert r.decoded == "partial" and "version 2.8 not in the table; layout probed by size" in r.note
    assert r.fields["pci"] == 417 and dict(r.sections)["cells"] == _expected_rows_27()["cells"]


def test_search_meas_implausible_values_are_partial():
    carriers = [fx.carrier(647328, 417, [fx.cell(417, 1024, -90.0, -10.5, [fx.beam(64, -90.5, -20.0, -90.0, -10.5)])])]
    r = diag(0xB97F, fx.nr_search_meas_body(2, 7, carriers=carriers))
    assert r.decoded == "partial"
    assert r.note.startswith("implausible: cell[0].pbch_sfn, beam[0].rsrp_rx1, beam[0].ssb_index; ")
    rows = dict(r.sections)
    assert rows["cells"][0]["pbch_sfn"] is None and rows["cells"][0]["rsrp"] == -90.0
    assert rows["beams"][0]["rsrp_rx1"] is None and rows["beams"][0]["ssb_index"] is None and rows["beams"][0]["rsrp_rx0"] == -90.5
    assert r.fields["rsrp"] == -90.0
    # the headline serving cell itself
    carriers = [fx.carrier(647328, 417, [fx.cell(417, 512, -30.0, -10.5)])]
    r = diag(0xB97F, fx.nr_search_meas_body(2, 7, carriers=carriers))
    assert r.decoded == "partial" and "implausible: rsrp, cell[0].rsrp" in r.note and r.fields["rsrp"] is None


# --- 0xB888 NR MAC PDSCH Stats ------------------------------------------------------------------------

_RECORD_KEYS = {"carrier_id": "carrier_id", "num_slots_elapsed": "slots", "num_pdsch_decode": "decodes",
                "num_crc_pass_tb": "crc_pass", "num_crc_fail_tb": "crc_fail", "num_retx": "retx",
                "ack_as_nack": "ack_as_nack", "harq_failure": "harq_failure", "crc_pass_tb_bytes": "pass_bytes",
                "crc_fail_tb_bytes": "fail_bytes", "tb_bytes": "tb_bytes", "padding_bytes": "padding_bytes",
                "retx_bytes": "retx_bytes"}


@pytest.mark.parametrize("major,minor,header_len,record_len", [(3, 1, 16, 76), (2, 2, 28, 72), (2, 2, 16, 72)])
def test_pdsch_stats_every_field(major, minor, header_len, record_len):
    records = [fx.pdsch_record(), fx.pdsch_record(carrier_id=1, decodes=400, crc_pass=300, crc_fail=100,
                                                  pass_bytes=1000, fail_bytes=500, tb_bytes=1500)]
    body = fx.nr_pdsch_stats_body(major, minor, records, header_len=header_len, flags=(1, 0, 1, 0, 1, 0), bmask=0x1234)
    assert len(body) == header_len + 2 * record_len
    r = diag(0xB888, body)
    assert r.decoded == "fields" and r.version == (major << 16) | minor and r.note == DOC
    f = r.fields
    assert f["version"] == "%d.%d" % (major, minor) and f["num_records"] == 2
    assert (f["sleep"], f["beam_change"], f["signal_change"], f["dl_dyn_cfg_change"], f["dl_config"], f["ul_config"]) == (1, 0, 1, 0, 1, 0)
    assert f["log_fields_change_bmask"] == 0x1234
    assert f["num_pdsch_decode"] == 1500 and f["num_crc_pass_tb"] == 1470 and f["num_crc_fail_tb"] == 30
    assert f["tb_bytes"] == 4_490_000 and f["bler_pct"] == pytest.approx(2.0)
    rows = dict(r.sections)["records"]
    assert len(rows) == 2
    for row, exp in zip(rows, records):
        for key, src in _RECORD_KEYS.items():
            assert row[key] == exp[src], key
    assert rows[1]["bler_pct"] == pytest.approx(25.0) and rows[1]["record"] == 1
    assert "num_pdsch_decode 1500" in r.comment() and "records x2" in r.comment()


def test_pdsch_stats_no_records_and_zero_totals():
    r = diag(0xB888, fx.nr_pdsch_stats_body(3, 1, records=[]))
    assert r.decoded == "fields" and r.fields["num_records"] == 0 and r.sections == [("records", [])]
    r = diag(0xB888, fx.nr_pdsch_stats_body(3, 1, [fx.pdsch_record(decodes=0, crc_pass=0, crc_fail=0, pass_bytes=0, fail_bytes=0)]))
    assert r.fields["bler_pct"] is None


def test_pdsch_stats_misfitting_bodies_are_left_raw():
    good = fx.nr_pdsch_stats_body(3, 1)
    for cut in (0, 4, 15, len(good) - 1):
        assert nr_mac.decode_pdsch_stats(rec(0xB888, good[:cut])) is None, cut
    assert nr_mac.decode_pdsch_stats(rec(0xB888, good + b"\x00")) is None
    # a 3.1 record that is 2.2-sized does not fit the 3.1 layout: raw, no guessing
    assert nr_mac.decode_pdsch_stats(rec(0xB888, fx.nr_pdsch_stats_body(2, 2)[:0] + fx._version(3, 1)
                                         + fx.nr_pdsch_stats_body(2, 2)[4:])) is None
    assert diag(0xB888, good[:50]).decoded == "raw"


def test_pdsch_stats_unknown_version_is_probed_or_header_only():
    body = fx._version(3, 2) + fx.nr_pdsch_stats_body(3, 1)[4:]
    r = diag(0xB888, body)
    assert r.decoded == "partial" and "version 3.2 not in the table; record layout probed by size" in r.note
    assert dict(r.sections)["records"][0]["num_pdsch_decode"] == 1500
    # three records: 16 + 3*76 == 28 + 3*72, so two layouts fit and neither is chosen
    body = fx._version(3, 2) + fx.nr_pdsch_stats_body(3, 1, [fx.pdsch_record()] * 3)[4:]
    r = diag(0xB888, body)
    assert r.decoded == "partial" and "more than one record layout fits; header only" in r.note
    assert r.fields["num_records"] == 3 and r.sections == [("records", [])] and "num_pdsch_decode" not in r.fields


def test_pdsch_stats_implausible_counters_are_partial():
    r = diag(0xB888, fx.nr_pdsch_stats_body(3, 1, [fx.pdsch_record(crc_pass=1501)]))
    assert r.decoded == "partial" and "implausible: record[0].num_crc_pass_tb" in r.note
    row = dict(r.sections)["records"][0]
    assert row["num_crc_pass_tb"] is None and row["bler_pct"] is None and row["carrier_id"] == 0
    assert "num_pdsch_decode" not in r.fields
    r = diag(0xB888, fx.nr_pdsch_stats_body(2, 2, [fx.pdsch_record(fail_bytes=5_000_000)]))
    assert r.decoded == "partial" and "implausible: record[0].crc_fail_tb_bytes" in r.note


# --- 0xB883 NR MAC UL Physical Channel Schedule Report ---------------------------------------------

def test_ul_sched_header_and_first_slot_are_partial():
    r = diag(0xB883, fx.nr_ul_sched_body(slot=7, numerology=1, frame=512, carrier_rnti=0x20, phychan=0x01))
    assert r.decoded == "partial" and "header and first slot only" in r.note and DOC in r.note
    f = r.fields
    assert f["version"] == "2.11" and f["num_records"] == 1 and f["beam_change"] == 1 and f["log_fields_change_bmask"] == 3
    assert (f["slot"], f["numerology"], f["sfn"], f["carrier_rnti_raw"], f["phychan_mask"]) == (7, 1, 512, 0x20, 0x01)
    assert "| sfn 512 |" in r.comment()
    # no records: header only
    r = diag(0xB883, fx.nr_ul_sched_body(num_records=0, rest=b""))
    assert r.decoded == "partial" and "slot" not in r.fields
    # a header with the slot record but no carrier header
    r = diag(0xB883, fx.nr_ul_sched_body(rest=b"")[:20])
    assert r.fields["sfn"] == 512 and "phychan_mask" not in r.fields


def test_ul_sched_short_and_implausible():
    assert nr_mac.decode_ul_sched(rec(0xB883, fx.nr_ul_sched_body()[:15])) is None
    r = diag(0xB883, fx.nr_ul_sched_body(slot=160, numerology=5, frame=1024))
    assert "implausible: slot, numerology, sfn" in r.note and r.fields["sfn"] is None and r.fields["slot"] is None


# --- 0xB872 NR L2 UL Transport Block ---------------------------------------------------------------

def test_ul_tb_every_field():
    tbs = [fx.ul_tb(harq=2, numerology=1, carrier=0, tb_type=0, rnti_type=0, grant=1024, built=1000),
           fx.ul_tb(harq=15, numerology=3, carrier=3, tb_type=8, rnti_type=7, grant=2048, built=2048,
                    req_mask=3, build_mask=3, phr_reason=1, bsr_reason=2, mce_payload=bytes.fromhex("3d5a39c3ff"),
                    start_segment=1, end_segment=1)]
    ttis = [fx.ul_tti(slot=7, sfn=512, tbs=tbs), fx.ul_tti(slot=19, sfn=513, tbs=[fx.ul_tb(grant=100, built=100)])]
    body = fx.nr_ul_tb_body(4, ttis, type2_scell=1, type2_other=0)
    assert len(body) == 8 + 8 + 18 + (18 + 2 + 5) + 8 + 18
    r = diag(0xB872, body)
    assert r.decoded == "fields" and r.version == 4 and r.note == DOC
    f = r.fields
    assert f["version"] == 4 and f["num_tti"] == 2 and f["type2_scell"] == 1 and f["type2_other_cell"] == 0
    assert f["num_tb"] == 3 and f["sfn"] == 512 and f["slot"] == 7 and f["harq_id"] == 2
    assert f["grant_bytes"] == 1024 + 2048 + 100 and f["bytes_built"] == 1000 + 2048 + 100
    rows = dict(r.sections)
    assert rows["ttis"] == [{"tti": 0, "slot": 7, "sfn": 512, "num_tb": 2}, {"tti": 1, "slot": 19, "sfn": 513, "num_tb": 1}]
    assert rows["tbs"][0] == {"tti": 0, "tb": 0, "numerology": 1, "harq_id": 2, "carrier_id": 0, "tb_type": 0, "rnti_type": 0,
                              "start_pdu_segment": 0, "end_pdu_segment": 0, "grant_bytes": 1024, "bytes_built": 1000,
                              "mce_req_bmask": 0, "mce_build_bmask": 0, "phr_reason": None, "bsr_reason": None,
                              "mce_length": 0, "mce_payload": ""}
    assert rows["tbs"][1] == {"tti": 0, "tb": 1, "numerology": 3, "harq_id": 15, "carrier_id": 3, "tb_type": 8, "rnti_type": 7,
                              "start_pdu_segment": 1, "end_pdu_segment": 1, "grant_bytes": 2048, "bytes_built": 2048,
                              "mce_req_bmask": 3, "mce_build_bmask": 3, "phr_reason": 1, "bsr_reason": 2,
                              "mce_length": 5, "mce_payload": "3d5a39c3ff"}
    assert rows["tbs"][2]["tti"] == 1 and rows["tbs"][2]["grant_bytes"] == 100
    assert "| sfn 512 | grant_bytes 3172 | harq_id 2 |" in r.comment() and "ttis x2 | tbs x3" in r.comment()


def test_ul_tb_reason_bytes_follow_the_build_bitmask():
    only_bsr = fx.ul_tb(build_mask=2, bsr_reason=4, mce_payload=b"\x3d\x21")
    body = fx.nr_ul_tb_body(4, [fx.ul_tti(tbs=[only_bsr])])
    assert len(body) == 8 + 8 + 18 + 1 + 2
    row = dict(diag(0xB872, body).sections)["tbs"][0]
    assert row["phr_reason"] is None and row["bsr_reason"] == 4 and row["mce_length"] == 2 and row["mce_payload"] == "3d21"


def test_ul_tb_records_that_do_not_fit_leave_the_header_only():
    good = fx.nr_ul_tb_body()
    for cut in (8, 12, 20, len(good) - 1):
        r = diag(0xB872, good[:cut])
        assert r.decoded == "partial" and "did not fit" in r.note and r.fields["num_tti"] == 1 and "sfn" not in r.fields, cut
    r = diag(0xB872, good + b"\x00")
    assert r.decoded == "partial" and r.sections == []
    for cut in (0, 4, 7):
        assert nr_mac.decode_ul_tb(rec(0xB872, good[:cut])) is None, cut


def test_ul_tb_other_versions():
    # version 5 with records that fit the version-4 walk: decoded, marked partial
    r = diag(0xB872, fx.nr_ul_tb_body(version=5))
    assert r.decoded == "partial" and "version 5 not in the table" in r.note and r.fields["grant_bytes"] == 1024
    # version 5 with records that do not fit: nothing is claimed
    assert nr_mac.decode_ul_tb(rec(0xB872, fx.nr_ul_tb_body(version=5)[:20])) is None
    assert diag(0xB872, fx.nr_ul_tb_body(version=5)[:20]).decoded == "raw"


def test_ul_tb_implausible_values_are_partial():
    r = diag(0xB872, fx.nr_ul_tb_body(4, [fx.ul_tti(slot=7, sfn=512, tbs=[fx.ul_tb(grant=1000, built=1001)])]))
    assert r.decoded == "partial" and "implausible: tb[0].bytes_built" in r.note
    row = dict(r.sections)["tbs"][0]
    assert row["bytes_built"] is None and row["grant_bytes"] == 1000 and "grant_bytes" not in r.fields
    r = diag(0xB872, fx.nr_ul_tb_body(4, [fx.ul_tti(slot=160, sfn=512, tbs=[fx.ul_tb(numerology=7, grant=1 << 21, built=0)])]))
    assert "implausible: tti[0].slot, tb[0].numerology, tb[0].grant_bytes" in r.note
    assert dict(r.sections)["ttis"][0]["slot"] is None


# --- the whole corpus through the Decoder --------------------------------------------------------

def test_nr_corpus_decodes_without_errors_and_every_record_is_kept():
    decoder = Decoder()
    records = fx.build_nr_corpus()
    out = []
    for code, ts, body in records:
        out += decoder.decode(LogRecord(code, ts, body))
    report = decoder.report()
    assert report["errors"] == {} and report["stats"]["errors"] == 0
    assert report["stats"]["cell_info"] == 5 and report["stats"]["diag_records"] == len(records)
    diags = [o for o in out if isinstance(o, DiagRecord)]
    assert [d.body for d in diags] == [body for _c, _t, body in records]
    assert {d.decoded for d in diags} == {"fields", "partial"}
    assert report["coverage"]["0xB823"]["as"] == {"cell": 3}
    assert report["coverage"]["0xB97F"]["as"] == {"fields": 2, "partial": 1}
    assert report["coverage"]["0xB883"]["as"] == {"partial": 1}
    for d in diags:
        assert DOC in d.note or DOC in d.fields.get("layout_note", ""), d.summary()
        assert d.confidence == LOG_CODES[d.log_code].confidence


def test_registry_names_every_nr_decoder():
    from fieldtap.decode.records import decoders
    table = decoders()
    for code in (0xB822, 0xB823, 0xB80C, 0xB975, 0xB97F, 0xB888, 0xB883, 0xB872):
        assert LOG_CODES[code].decoder in table, hex(code)
