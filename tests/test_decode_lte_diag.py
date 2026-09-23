"""LTE measurement, MAC and PHY record decoders on the synthetic bodies of
fieldtap/fixtures_lte_diag.py: every field of every implemented version, None on a
truncated or unknown body, and a plausibility failure that drops the number."""

import struct

import pytest

from fieldtap import fixtures_lte_diag as fx
from fieldtap.decode import Decoder, DiagRecord
from fieldtap.decode import cellinfo, lte_ll1, lte_mac, lte_ml1, lte_phy, rf
from fieldtap.decode.registry import LOG_CODES
from fieldtap.diag.protocol import LogRecord
from fieldtap.output.fieldtap_diag import QC_RNTI_TO_WIRESHARK

TS = 1 << 40


def _rec(code, body):
    return LogRecord(code, TS, body)


def _decode(code, body):
    return Decoder().decode(_rec(code, body))


def r1(v):
    return None if v is None else round(v, 1)


# --- 0xB193 ------------------------------------------------------------------------------

def _expect_cell(c, row, version):
    """Every measurement the version carries, compared at one decimal."""
    assert row["pci"] == c["pci"] and row["serving_cell_index"] == c["serving_cell_index"]
    assert row["sfn"] == c["sfn"] and row["subframe"] == c["subframe"]
    if version in fx.SCMR_MULTI_CELL:
        assert row["is_serving_cell"] == c["is_serving"]
    n_rx = 4 if version in (35, 40) else 2
    for i in range(n_rx):
        assert r1(row["rsrp_rx%d" % i]) == r1(c["rsrp_rx"][i]), (version, i)
    assert r1(row["rsrp"]) == r1(c["rsrp"])
    if version == 36:
        for i in range(2):
            assert r1(row["rsrq_rx%d" % i]) == r1(c["rsrq_rx"][i])
        assert r1(row["rsrq"]) == r1(c["rsrq"])
        assert "rssi" not in row and "snr_rx0" not in row
        return
    for i in range(n_rx):
        assert r1(row["rsrq_rx%d" % i]) == r1(c["rsrq_rx"][i]), (version, i)
        assert r1(row["rssi_rx%d" % i]) == r1(c["rssi_rx"][i]), (version, i)
        assert r1(row["snr_rx%d" % i]) == r1(c["snr_rx"][i]), (version, i)
    assert r1(row["rsrq"]) == r1(c["rsrq"]) and r1(row["rssi"]) == r1(c["rssi"])
    assert r1(row["snr"]) == r1(max(c["snr_rx"][:n_rx]))
    if version in (19, 22, 35, 40):
        assert r1(row["projected_sir"]) == r1(c["projected_sir"])
        assert r1(row["post_ic_rsrq"]) == r1(c["post_ic_rsrq"])
    if version in (35, 40):
        assert r1(row["filtered_rsrp"]) == r1(c["filtered_rsrp"])
        assert r1(row["filtered_rsrq"]) == r1(c["filtered_rsrq"])
        assert [row["cinr_rx%d_raw" % i] for i in range(4)] == c["cinr"]
    if version == 22:
        assert [row["cinr_rx%d_raw" % i] for i in range(2)] == c["cinr"][:2]
    if version == 40:
        assert row["residual_freq_error"] == c["residual_freq_error"]


@pytest.mark.parametrize("version", sorted(fx.SCMR_CELL_PACKERS))
def test_scell_meas_every_version(version):
    cells = [fx.SERVING_CELL, fx.NEIGHBOUR_CELL] if version in fx.SCMR_MULTI_CELL else [fx.SERVING_CELL]
    body = fx.ml1_scell_meas_body(version, cells, earfcn=1850)
    assert len(body) == 4 + 4 + (2 if version == 4 else 4) + (4 if version in fx.SCMR_MULTI_CELL else 0) \
        + len(cells) * fx.SCMR_CELL_SIZES[version]
    (rec,) = _decode(0xB193, body)
    assert isinstance(rec, DiagRecord) and rec.decoded == "fields", rec.note
    f = rec.fields
    assert f["version"] == 1 and f["num_subpackets"] == 1
    assert f["subpacket_id"] == 25 and f["subpacket_version"] == version
    assert f["subpacket_size"] == len(body) - 4
    assert f["earfcn"] == 1850 and f["num_cells"] == len(cells)
    if version == 40:
        assert f["valid_rx"] == 3
    rows = dict(rec.sections)["cells"]
    assert len(rows) == len(cells)
    for c, row in zip(cells, rows):
        _expect_cell(c, row, version)
    # headline = the serving cell
    assert f["pci"] == 101 and f["sfn"] == 512 and f["subframe"] == 3
    assert r1(f["rsrp"]) == -95.0 and r1(f["rsrq"]) == -10.5
    if version != 36:
        assert r1(f["rssi"]) == -65.5 and r1(f["snr"]) == 14.1
    assert "layout from documentation" in rec.note
    comment = rec.comment()
    assert comment.startswith("FieldTap 0xB193 LTE ML1 Serving Cell Measurement Result v1 | pci 101")
    assert "rsrp -95.0" in comment and "cells x%d" % len(cells) in comment
    summary = lte_ml1.scell_meas_summary(f)
    assert summary.startswith("PCI 101 EARFCN 1850 RSRP -95.0 dBm RSRQ -10.5 dB")


def test_scell_meas_serving_cell_is_the_flagged_one_not_the_first():
    body = fx.ml1_scell_meas_body(19, [fx.NEIGHBOUR_CELL, fx.SERVING_CELL])
    (rec,) = _decode(0xB193, body)
    assert rec.fields["pci"] == 101 and r1(rec.fields["rsrp"]) == -95.0
    assert dict(rec.sections)["cells"][0]["pci"] == 245


def test_scell_meas_absent_antennas_are_none_not_minus_180():
    cell = dict(fx.SERVING_CELL, rsrp_rx=[-96.0, None, None, None], rsrq_rx=[-11.0, None], rssi_rx=[-66.0, None],
                snr_rx=[12.3, None])
    (rec,) = _decode(0xB193, fx.ml1_scell_meas_body(35, [cell]))
    row = dict(rec.sections)["cells"][0]
    assert rec.decoded == "fields", rec.note
    assert row["rsrp_rx1"] is None and row["rsrp_rx3"] is None and row["snr_rx1"] is None
    assert r1(row["rsrp_rx0"]) == -96.0 and r1(row["snr"]) == 12.3 and r1(rec.fields["snr"]) == 12.3


def test_scell_meas_implausible_value_is_dropped_and_named():
    cell = dict(fx.SERVING_CELL, rsrp=-20.0)          # -20 dBm is not a cellular RSRP
    (rec,) = _decode(0xB193, fx.ml1_scell_meas_body(19, [cell]))
    assert rec.decoded == "partial"
    assert rec.fields["rsrp"] is None and "implausible: rsrp=-20.0" in rec.note
    assert r1(rec.fields["rsrq"]) == -10.5              # the rest is still there
    assert "rsrp" not in rec.comment().split("|")[1]


def test_scell_meas_unknown_subpacket_version_is_partial_with_headers():
    body = fx.ml1_scell_meas_body(19, [fx.SERVING_CELL])
    body = body[:5] + bytes([99]) + body[6:]
    (rec,) = _decode(0xB193, body)
    assert rec.decoded == "partial"
    assert rec.fields == {"version": 1, "num_subpackets": 1, "subpacket_id": 25, "subpacket_version": 99,
                          "subpacket_size": len(body) - 4}
    assert "subpacket version 99 not implemented" in rec.note
    assert dict(rec.sections)["subpackets"] == [{"subpacket_id": 25, "subpacket_version": 99,
                                                 "subpacket_size": len(body) - 4}]


def test_scell_meas_other_subpackets_are_listed_not_decoded():
    body = fx.ml1_scell_meas_body(7, extra_subpackets=[(30, 2, b"\x01\x02\x03")])
    (rec,) = _decode(0xB193, body)
    assert rec.decoded == "fields" and rec.fields["num_subpackets"] == 2
    assert dict(rec.sections)["subpackets"][1] == {"subpacket_id": 30, "subpacket_version": 2, "subpacket_size": 7}


def test_scell_meas_v36_uses_the_subpacket_size_for_the_cell_stride():
    (rec,) = _decode(0xB193, fx.ml1_scell_meas_body(36, [fx.SERVING_CELL, fx.NEIGHBOUR_CELL]))
    assert rec.decoded == "fields" and "48 of 64 bytes per cell documented" in rec.note
    assert dict(rec.sections)["cells"][1]["pci"] == 245


def test_scell_meas_truncated_or_short_bodies():
    body = fx.ml1_scell_meas_body(19, [fx.SERVING_CELL])
    for n in (0, 3, 7, 40, len(body) - 1):
        assert lte_ml1.decode_scell_meas(_rec(0xB193, body[:n]), LOG_CODES[0xB193]) is None, n
    # a truncated container is kept raw with a note, never an exception
    decoder = Decoder()
    (rec,) = decoder.decode(_rec(0xB193, body[:40]))
    assert rec.decoded == "raw" and "layout did not fit" in rec.note
    assert decoder.report()["stats"]["errors"] == 0


# --- 0xB179 ------------------------------------------------------------------------------

@pytest.mark.parametrize("version", [3, 4])
def test_intra_meas(version):
    (rec,) = _decode(0xB179, fx.intra_meas_body(version))
    assert rec.decoded == "fields", rec.note
    f = rec.fields
    assert f == {"version": version, "serving_cell_index": 0, "earfcn": 1850, "pci": 101, "subframe_number": 0x2003,
                 "rsrp": -95.0, "rsrq": -10.5, "num_neighbours": 2, "num_detected": 1}
    s = dict(rec.sections)
    assert s["neighbours"] == [{"pci": 245, "rsrp": -103.5, "rsrq": -13.5}, {"pci": 17, "rsrp": -108.0, "rsrq": -16.0}]
    assert s["detected"] == [{"pci": 333, "sss_corr": 0x1234, "reference_time": 0x0102030405060708}]
    assert lte_ml1.intra_meas_summary(f) == "PCI 101 EARFCN 1850 RSRP -95.0 dBm RSRQ -10.5 dB 2 neighbours"
    assert "num_neighbours 2" in rec.comment() and "neighbours x2" in rec.comment()


def test_intra_meas_ten_byte_neighbours_are_noticed():
    (rec,) = _decode(0xB179, fx.intra_meas_body(4, neighbour_size=10))
    assert rec.decoded == "fields" and "10-byte neighbour records" in rec.note
    assert dict(rec.sections)["neighbours"][1]["pci"] == 17


def test_intra_meas_bad_neighbour_is_dropped():
    (rec,) = _decode(0xB179, fx.intra_meas_body(4, neighbours=[(245, -103.5, -13.5), (700, -30.0, -16.0)]))
    assert rec.decoded == "partial"
    assert dict(rec.sections)["neighbours"][1] == {"pci": None, "rsrp": None, "rsrq": -16.0}
    assert "neighbour1.pci=700" in rec.note and "neighbour1.rsrp=-30.0" in rec.note


def test_intra_meas_truncated_and_unknown():
    body = fx.intra_meas_body(4)
    for n in (0, 7, 20, len(body) - 1):
        assert lte_ml1.decode_intra_meas(_rec(0xB179, body[:n])) is None, n
    (rec,) = _decode(0xB179, bytes([9]) + body[1:])
    assert rec.decoded == "partial" and "version 9 not implemented" in rec.note


# --- 0xB17F / 0xB180 -----------------------------------------------------------------------

@pytest.mark.parametrize("version", [4, 5])
def test_scell_eval_header_only(version):
    (rec,) = _decode(0xB17F, fx.scell_eval_body(version))
    assert rec.decoded == "partial"
    assert rec.fields == {"version": version, "rrc_release": 1, "earfcn": 1850, "pci": 101, "serving_layer_priority": 5,
                          "rsrp": -95.0, "rsrp_avg": -95.5, "rsrq": -10.5, "rsrq_avg": -11.0, "rssi": -65.5}
    assert "single-sourced" in rec.note
    assert lte_ml1.scell_eval_summary(rec.fields) == "v%d PCI 101 EARFCN 1850 RSRP -95.0 dBm (partial)" % version


def test_scell_eval_implausible_measurements_are_not_reported():
    (rec,) = _decode(0xB17F, fx.scell_eval_body(4, rssi=10.0, rsrp=-95.0))
    assert "rssi" not in rec.fields and "rsrp" not in rec.fields
    assert "measurement words implausible (rssi)" in rec.note
    assert rec.fields["pci"] == 101
    (rec,) = _decode(0xB17F, fx.scell_eval_body(5)[:20])
    assert rec.decoded == "raw"
    (rec,) = _decode(0xB17F, bytes([6, 1]) + bytes(40))
    assert rec.decoded == "partial" and "version 6 not documented" in rec.note


@pytest.mark.parametrize("version,shift", [(4, 0), (5, 0), (4, 6), (5, 6)])
def test_ncell_meas_header_and_fitted_count(version, shift):
    (rec,) = _decode(0xB180, fx.ncell_meas_body(version, num_cells=3, count_shift=shift))
    assert rec.decoded == "partial"
    assert rec.fields == {"version": version, "rrc_release": 1, "earfcn": 1850, "num_cells": 3}
    assert ("low 10 bits" if shift == 0 else "bits 6..15") in rec.note
    assert lte_ml1.ncell_meas_summary(rec.fields) == "v%d EARFCN 1850 3 cells (partial)" % version


def test_ncell_meas_count_not_forced():
    (rec,) = _decode(0xB180, fx.ncell_meas_body(4, num_cells=3, cell_size=20))
    assert "num_cells" not in rec.fields and "cell count not determined" in rec.note
    assert lte_ml1.decode_ncell_meas(_rec(0xB180, b"\x04\x01\x00")) is None
    (rec,) = _decode(0xB180, bytes([7, 1]) + bytes(20))
    assert rec.decoded == "partial" and "version 7 not documented" in rec.note


# --- 0xB0C1 ------------------------------------------------------------------------------

@pytest.mark.parametrize("version", [1, 2, 3, 17])
def test_mib_versions(version):
    cell, rec = _decode(0xB0C1, fx.mib_body(version))
    f = cell.fields
    assert cell.kind == "mib" and f["version"] == version and f["plausible"]
    assert f["pci"] == 101 and f["earfcn"] == 1850 and f["sfn"] == 512 and f["num_tx_antennas"] == 2
    if version != 17:
        assert f["dl_bw"] == 5 and f["dl_bw_mhz"] == 20.0 and f["dl_bw_reading"] == "code"
    if version == 3:
        assert f["sib1_br_sch_info"] == 7
    if version == 17:
        assert f["sfn_msb4"] == 3 and f["hsfn_lsb2"] == 1 and f["sib1_sch_info"] == 4 and f["sys_info_value_tag"] == 9
        assert f["access_barring_enabled"] == 0 and f["op_mode_type"] == 3 and f["op_mode"] == "standalone"
        assert f["raster_offset"] == 2 and f["raster_offset_khz"] == "+2.5 kHz"
        assert "dl_bw" not in f
    assert rec.decoded == "fields" and rec.fields == f
    assert cellinfo.decode_mib(_rec(0xB0C1, fx.mib_body(version)[:-1])) is None


def test_mib_bandwidth_as_prb_count():
    cell, _ = _decode(0xB0C1, fx.mib_body(2, dl_bw=50))
    assert cell.fields["dl_bw_mhz"] == 10.0 and cell.fields["dl_bw_reading"] == "prb"
    cell, _ = _decode(0xB0C1, fx.mib_body(2, dl_bw=7))
    assert cell.fields["dl_bw_mhz"] is None and cell.fields["dl_bw_reading"] == "unknown"


# --- 0xB063 / 0xB064 -----------------------------------------------------------------------

@pytest.mark.parametrize("version", [2, 4])
def test_mac_dl_tb(version):
    (rec,) = _decode(0xB063, fx.mac_tb_body(True, version))
    assert rec.decoded == "fields", rec.note
    f = rec.fields
    expected = {"version": 1, "num_subpackets": 1, "direction": "dl", "num_samples": 1, "tbs_bytes": 1421, "sfn": 512,
                "subframe": 3, "harq_id": 5, "rnti_type": 0, "rnti_type_name": "C-RNTI", "lcids": "1,3,31"}
    if version == 4:
        expected["cell_id"] = 0
    assert f == expected
    s = dict(rec.sections)
    sample = s["samples"][0]
    assert sample["pmch_id"] == 0 and sample["rlc_pdus"] == 2 and sample["padding_bytes"] == 3 and sample["hdr_len"] == 6
    assert s["subheaders"] == [
        {"sample": 0, "lcid": 1, "lcid_name": "DTCH/DCCH 1", "extension": 1, "length": 120},
        {"sample": 0, "lcid": 3, "lcid_name": "DTCH/DCCH 3", "extension": 1, "length": 1290},
        {"sample": 0, "lcid": 31, "lcid_name": "Padding", "extension": 0, "length": None}]
    assert s["subpackets"] == [{"subpacket_id": 7, "subpacket_version": version, "subpacket_size": 4 + 1 + (12 if version == 2 else 14) + 6,
                                "num_samples": 1}]
    assert rec.mac_pdus == [{"pdu": fx.mac_subheaders(fx.DL_SAMPLE["subheaders"]), "downlink": True,
                             "rnti_type": QC_RNTI_TO_WIRESHARK[0], "sfn": 512, "subframe": 3,
                             "note": "only the MAC header was logged (6 of 1421 bytes)"}]
    assert lte_mac.tb_summary(f) == "1 samples TBS 1421 bytes C-RNTI LCID 1,3,31"
    assert "tbs_bytes 1421" in rec.comment() and "subheaders x3" in rec.comment()


@pytest.mark.parametrize("version", [1, 2, 3, 5, 8])
def test_mac_ul_tb(version):
    (rec,) = _decode(0xB064, fx.mac_tb_body(False, version))
    assert rec.decoded == "fields", rec.note
    f = rec.fields
    assert f["grant_bytes"] == 328 and f["sfn"] == 513 and f["subframe"] == 7 and f["harq_id"] == 2
    assert f["lcids"] == "29,1,31" and f["direction"] == "ul"
    sample = dict(rec.sections)["samples"][0]
    assert sample["bsr_event"] == 1 and sample["bsr_event_name"] == "periodic"
    assert sample["bsr_trigger"] == 3 and sample["bsr_trigger_name"] == "S-BSR"
    assert sample["header_note"] == "1 control-element bytes after the sub-headers"
    rows = dict(rec.sections)["subheaders"]
    assert [(r["lcid"], r["length"], r["lcid_name"]) for r in rows] == [(29, None, "Short BSR"), (1, 300, "DTCH/DCCH 1"),
                                                                        (31, None, "Padding")]
    assert rec.mac_pdus[0]["downlink"] is False and rec.mac_pdus[0]["pdu"].endswith(b"\x1f")
    assert lte_mac.tb_summary(f) == "1 samples grant 328 bytes C-RNTI LCID 29,1,31"


def test_mac_tb_several_samples_and_short_pdu():
    tiny = dict(fx.UL_SAMPLE, grant_bytes=2, subheaders=[(29, None)], extra_bytes=b"\x1f", sfn=1000, subframe=9)
    (rec,) = _decode(0xB064, fx.mac_tb_body(False, 2, [fx.UL_SAMPLE, tiny]))
    assert rec.fields["num_samples"] == 2 and rec.fields["grant_bytes"] == 330
    assert rec.mac_pdus[1]["note"] == "2 bytes logged" and rec.mac_pdus[1]["sfn"] == 1000
    assert len(dict(rec.sections)["subheaders"]) == 4


def test_mac_tb_plausibility_and_fit():
    bad = dict(fx.DL_SAMPLE, subframe=12)
    (rec,) = _decode(0xB063, fx.mac_tb_body(True, 2, [bad]))
    assert rec.decoded == "partial" and "sample0.subframe=12" in rec.note
    assert rec.fields["subframe"] is None and rec.mac_pdus[0]["subframe"] is None
    (rec,) = _decode(0xB063, fx.mac_tb_body(True, 9))
    assert rec.decoded == "partial" and "subpacket version 9 not documented" in rec.note and rec.mac_pdus == []
    body = fx.mac_tb_body(True, 2)
    for n in (0, 3, 6, len(body) - 3):
        result = lte_mac.decode_dl_tb(_rec(0xB063, body[:n]))
        assert result is None or result.decoded == "partial", n
    assert lte_mac.decode_dl_tb(_rec(0xB063, body[:8])) is None
    assert lte_mac.parse_subheaders(b"\x21", True) == ([{"lcid": 1, "lcid_name": "DTCH/DCCH 1", "extension": 1,
                                                          "length": None}], "sub-header truncated")


# --- 0xB173 ------------------------------------------------------------------------------

@pytest.mark.parametrize("version", [5, 16, 24, 32, 36])
def test_pdsch_stat(version):
    body = fx.pdsch_stat_body(version)
    (rec,) = _decode(0xB173, body)
    assert rec.decoded == "fields", rec.note
    f = rec.fields
    assert f["version"] == version and f["num_records"] == 2 and f["num_tb"] == 3
    assert f["tbs_bytes"] == 2792 + 1608 + 2792 and f["crc_pass"] == 2 and f["crc_fail"] == 1
    assert f["sfn"] == 512 and f["subframe"] == 3 and f["harq_id"] == 6 and f["mcs"] == 20 and f["num_rbs"] == 25
    assert f["rnti_type"] == 0 and f["rnti_type_name"] == "C-RNTI"
    s = dict(rec.sections)
    r0, r1_ = s["records"]
    assert r0["sfn"] == 512 and r0["subframe"] == 3 and r0["num_rbs"] == 25 and r0["num_layers"] == 2 and r0["num_tb"] == 2
    assert r0["serving_cell_index"] == 0 and r0["pmch_id"] == 0 and r0["area_id"] == 0
    assert r1_["sfn"] == 513 and r1_["subframe"] == 4 and r1_["num_layers"] == 1 and r1_["num_tb"] == 1
    if version != 5:
        assert r0["hsic_enabled"] == 1
    tb0, tb1, tb2 = s["transport_blocks"]
    assert (tb0["record"], tb0["tb"], tb1["tb"], tb2["record"]) == (0, 0, 1, 1)
    assert tb0["harq_id"] == 6 and tb0["rv"] == 0 and tb0["ndi"] == 1 and tb0["crc_pass"] == 1
    assert tb0["tb_index"] == 0 and tb0["discarded_retx_present"] == 0 and tb0["did_recombining"] == 0
    assert tb0["tb_size"] == 2792 and tb0["mcs"] == 20 and tb0["num_rbs"] == 25
    assert tb1["harq_id"] == 7 and tb1["rv"] == 2 and tb1["ndi"] == 0 and tb1["crc_pass"] == 0 and tb1["tb_index"] == 1
    assert tb1["did_recombining"] == 1 and tb1["tb_size"] == 1608 and tb1["mcs"] == 14
    if version == 5:
        assert (tb0["modulation"], tb1["modulation"]) == ("64QAM", "16QAM")
    elif version == 16:
        assert tb0["modulation"] is None
    else:
        assert (tb0["modulation_code"], tb0["modulation"], tb1["modulation"]) == (6, "64QAM", "16QAM")
    if version == 36:
        assert tb0["qed2_interim_status"] == 1 and tb0["qed_iteration"] == 2
    assert lte_phy.pdsch_stat_summary(f) == "3 TB 7192 bytes MCS 20 %s CRC 2/3" % (f["modulation"] or "n/a")
    for n in (0, 3, len(body) - 1):
        assert lte_phy.decode_pdsch_stat(_rec(0xB173, body[:n])) is None, n


def test_pdsch_stat_unknown_version_and_plausibility():
    (rec,) = _decode(0xB173, bytes([7, 2]) + bytes(60))
    assert rec.decoded == "partial" and rec.fields == {"version": 7, "num_records": 2}
    assert "version 7 not documented" in rec.note
    assert lte_phy.pdsch_stat_summary(rec.fields) == "v7, 2 records (partial)"
    bad = dict(fx.PDSCH_RECORD, subframe=11, tbs=[dict(fx.PDSCH_TB, mcs=40)])
    (rec,) = _decode(0xB173, fx.pdsch_stat_body(24, [bad]))
    assert rec.decoded == "partial" and "record0.subframe=11" in rec.note and "record0.tb0.mcs=40" in rec.note
    assert rec.fields["subframe"] is None and rec.fields["mcs"] is None


# --- 0xB139 ------------------------------------------------------------------------------

@pytest.mark.parametrize("version", [23, 24, 26])
def test_pusch_tx(version):
    body = fx.pusch_tx_body(version)
    assert len(body) == 8 + 2 * (52 if version == 26 else 48)
    (rec,) = _decode(0xB139, body)
    assert rec.decoded == "fields", rec.note
    f = rec.fields
    assert f["version"] == version and f["serving_cell_id"] == 101 and f["num_records"] == 2
    assert f["dispatch_sfn_sf_raw"] == 0x2008
    assert f["sfn"] == 512 and f["subframe"] == 8 and f["tbs_bytes"] == 2 * 1736 and f["tx_power_dbm"] == 17
    assert f["modulation"] == "16QAM" and f["mod_order"] == 2 and r1(f["coding_rate"]) == 0.6 and f["num_rbs"] == 20
    g0, g1 = dict(rec.sections)["grants"]
    e = fx.PUSCH_GRANT
    assert g0["sfn"] == 512 and g0["subframe"] == 8 and round(g0["coding_rate"], 4) == round(614 / 1024, 4)
    for key, exp_key in (("ack", "ack"), ("cqi", "cqi"), ("ri", "ri"), ("frequency_hopping", "freq_hopping"), ("rv", "rv"),
                         ("mirror_hopping", "mirror_hopping"), ("dmrs_cyclic_shift_slot0", "cs_slot0"),
                         ("dmrs_cyclic_shift_slot1", "cs_slot1"), ("dmrs_root_slot0", "dmrs_root_slot0"), ("ue_srs", "ue_srs"),
                         ("dmrs_root_slot1", "dmrs_root_slot1"), ("start_rb_slot0", "start_rb_slot0"),
                         ("start_rb_slot1", "start_rb_slot1"), ("num_rbs", "num_rbs"), ("tb_size", "tb_size"),
                         ("num_ack_bits", "num_ack_bits"), ("ack_payload", "ack_payload"),
                         ("rate_matched_ack_bits", "rate_matched_ack_bits"), ("num_ri_bits", "num_ri_bits"),
                         ("ri_payload", "ri_payload"), ("rate_matched_ri_bits", "rate_matched_ri_bits"),
                         ("mod_order", "mod_order"), ("digital_gain_db", "digital_gain"), ("srs_occasion", "srs_occasion"),
                         ("retx_index", "retx_index"), ("tx_power_dbm", "tx_power_dbm"), ("num_cqi_bits", "num_cqi_bits"),
                         ("rate_matched_cqi_bits", "rate_matched_cqi_bits"), ("tx_resampler", "tx_resampler")):
        assert g0[key] == e[exp_key], key
    assert g0["cqi_payload"] == bytes(range(16)).hex() and g0["modulation"] == "16QAM"
    assert g1["sfn"] == 513 and g1["subframe"] == 2 and g1["rv"] == 2 and g1["retx_index"] == 1
    assert g1["tx_power_dbm"] == -7 and g1["modulation"] == "QPSK" and g1["ack"] == 0
    if version == 26:
        assert g0["num_repetition"] == 1 and g0["rb_nb_start_index"] == 0
    else:
        assert "num_repetition" not in g0
    assert lte_phy.pusch_tx_summary(f) == "2 grants 3472 bytes 16QAM Tx 17 dBm"
    for n in (0, 7, len(body) - 1):
        assert lte_phy.decode_pusch_tx(_rec(0xB139, body[:n])) is None, n


def test_pusch_tx_unknown_version_and_plausibility():
    (rec,) = _decode(0xB139, fx.pusch_tx_body(23)[:1].replace(b"\x17", b"\x63") + fx.pusch_tx_body(23)[1:])
    assert rec.decoded == "partial" and rec.fields["version"] == 99 and "version 99 not documented" in rec.note
    assert rec.fields["num_records"] == 2 and rec.fields["serving_cell_id"] == 101
    bad = dict(fx.PUSCH_GRANT, subframe=13, tx_power_dbm=200)
    (rec,) = _decode(0xB139, fx.pusch_tx_body(23, [bad]))
    assert rec.decoded == "partial" and "grant0.subframe=13" in rec.note and "grant0.tx_power_dbm=200" in rec.note
    assert rec.fields["tx_power_dbm"] is None and lte_phy.pusch_tx_summary(rec.fields).endswith("Tx n/a")


# --- registration and statistics -------------------------------------------------------------

def test_every_lte_decoder_is_registered_and_counted():
    bodies = {0xB193: fx.ml1_scell_meas_body(19, [fx.SERVING_CELL]), 0xB179: fx.intra_meas_body(4),
              0xB17F: fx.scell_eval_body(4), 0xB180: fx.ncell_meas_body(4), 0xB0C1: fx.mib_body(17),
              0xB063: fx.mac_tb_body(True, 2), 0xB064: fx.mac_tb_body(False, 2),
              0xB173: fx.pdsch_stat_body(36), 0xB139: fx.pusch_tx_body(26)}
    decoder = Decoder()
    for code, body in bodies.items():
        decoder.decode(_rec(code, body))
    rep = decoder.report()
    assert rep["stats"]["errors"] == 0 and rep["unknown_codes"] == {}
    cov = rep["coverage"]
    assert cov["0xB193"]["as"] == {"fields": 1} and cov["0xB17F"]["as"] == {"partial": 1}
    assert cov["0xB180"]["as"] == {"partial": 1} and cov["0xB0C1"]["as"] == {"cell": 1}
    for code in ("0xB179", "0xB063", "0xB064", "0xB173", "0xB139"):
        assert cov[code]["as"] == {"fields": 1}, code
    assert rep["versions"]["0xB173"] == {36: 1} and rep["versions"]["0xB139"] == {26: 1}


# =============================================================================================
# The iPhone 17 (M25) layouts: fieldtap/fixtures_lte_diag.py "iPhone 17 layouts"
# =============================================================================================

HW = "layout validated on the iPhone 17 (M25) captures of 2026-09-21/22"


# --- 0xB193 subpacket 0x19 v66 -----------------------------------------------------------------

def test_scell_meas_v66_cells_rx_map_and_pcell_headline():
    (rec,) = _decode(0xB193, fx.ml1_scell_meas_v66_body([fx.IPHONE_NEIGHBOUR, fx.IPHONE_SCELL, fx.IPHONE_CELL]))
    assert rec.decoded == "fields", rec.note
    f = rec.fields
    assert f["subpacket_version"] == 66 and f["subpacket_size"] == 4 + 8 + 3 * 144 and f["earfcn"] == 650
    assert f["num_cells"] == 3 and f["valid_rx"] == 0
    # the headline is the PCell (serving, carrier 0), not the first row and not the SCell
    assert f["pci"] == 80 and f["serving_cell_index"] == 0 and f["rx_map"] == 3 and f["num_rx"] == 2
    assert r1(f["rsrp"]) == -113.0 and r1(f["rsrq"]) == -14.5 and r1(f["rssi"]) == -82.0
    assert r1(f["filtered_rsrp"]) == -113.5 and r1(f["filtered_rsrq"]) == -14.8
    assert f["snr"] is None and "sfn" not in f
    rows = dict(rec.sections)["cells"]
    nb, scell, pcell = rows
    assert (nb["pci"], nb["is_serving_cell"], nb["rx_map"], nb["num_rx"]) == (388, 0, 15, 4)
    assert [r1(nb["rsrp_rx%d" % i]) for i in range(4)] == [-116.0, -117.0, -118.0, -119.0]
    assert [r1(nb["rsrq_rx%d" % i]) for i in range(4)] == [-17.0, -17.5, -18.0, -18.5]
    assert [r1(nb["rssi_rx%d" % i]) for i in range(4)] == [-84.0, -85.0, -86.0, -87.0]
    assert r1(nb["rsrp"]) == -116.5 and r1(nb["filtered_rsrp"]) == -117.0 and r1(nb["rsrq"]) == -17.2
    assert (scell["pci"], scell["is_serving_cell"], scell["serving_cell_index"]) == (235, 1, 1)
    assert pcell["rsrp_rx2"] is None and pcell["rsrp_rx3"] is None and r1(pcell["rsrp_rx1"]) == -115.2
    assert rec.note == HW + "; v66: no SNR field (the older versions' projected-SIR slot is not SIR here)"
    assert lte_ml1.scell_meas_summary(f) == "PCI 80 EARFCN 650 RSRP -113.0 dBm RSRQ -14.5 dB RSSI -82.0 dBm"
    assert "num_cells 3" in rec.comment() and "cells x3" in rec.comment()


def test_scell_meas_v66_rx_map_masks_stale_antenna_values():
    cell = dict(fx.IPHONE_CELL, rsrp_rx=[-113.0, -115.25, -100.0, -101.0], rsrq_rx=[-15.0, -14.5, -9.0, -9.0],
                rssi_rx=[-82.0, -83.5, -60.0, -60.0])           # Rx2/Rx3 hold numbers, the map says 0b0011
    (rec,) = _decode(0xB193, fx.ml1_scell_meas_v66_body([cell]))
    row = dict(rec.sections)["cells"][0]
    assert rec.decoded == "fields" and row["num_rx"] == 2
    assert row["rsrp_rx2"] is None and row["rsrq_rx3"] is None and row["rssi_rx2"] is None
    assert r1(row["rsrp_rx1"]) == -115.2


def test_scell_meas_v66_short_body_is_not_read():
    body = fx.ml1_scell_meas_v66_body([fx.IPHONE_CELL])
    assert lte_ml1.decode_scell_meas(_rec(0xB193, body[:-1])) is None
    (rec,) = _decode(0xB193, body[:-1])
    assert rec.decoded == "raw"


# --- 0xB179 v56 --------------------------------------------------------------------------------

def test_intra_meas_v56():
    (rec,) = _decode(0xB179, fx.intra_meas_v56_body())
    assert rec.decoded == "fields", rec.note
    assert rec.fields == {"version": 56, "unidentified_word": 9, "earfcn": 650, "tti": 2093, "sfn": 209, "subframe": 3,
                          "pci": 80, "rsrp": -113.5, "rsrq": -13.5, "num_neighbours": 2}
    assert dict(rec.sections) == {"neighbours": [{"pci": 235, "rsrp": -116.25, "rsrq": -17.5},
                                                 {"pci": 388, "rsrp": -120.0, "rsrq": -19.0}], "detected": []}
    assert rec.note == HW + "; no DIAG timestamp on this version; the TTI is the record's clock"
    assert lte_ml1.intra_meas_summary(rec.fields) == "PCI 80 EARFCN 650 RSRP -113.5 dBm RSRQ -13.5 dB 2 neighbours"
    assert rec.version == 56


def test_intra_meas_v56_length_identity_is_the_framing():
    for body in (fx.intra_meas_v56_body(trailing=b"\x00"), fx.intra_meas_v56_body()[:-1], fx.intra_meas_v56_body()[:20]):
        assert lte_ml1.decode_intra_meas(_rec(0xB179, body)) is None
    (rec,) = _decode(0xB179, fx.intra_meas_v56_body(neighbours=[]))
    assert rec.decoded == "fields" and rec.fields["num_neighbours"] == 0


def test_intra_meas_v56_implausible_values_are_dropped():
    (rec,) = _decode(0xB179, fx.intra_meas_v56_body(pci=600, rsrp=-20.0, neighbours=[(235, -116.25, 10.0)]))
    assert rec.decoded == "partial"
    assert rec.fields["pci"] is None and rec.fields["rsrp"] is None and rec.fields["rsrq"] == -13.5
    assert dict(rec.sections)["neighbours"] == [{"pci": 235, "rsrp": -116.25, "rsrq": None}]
    assert rec.note.endswith("implausible: pci=600, rsrp=-20.0, neighbour0.rsrq=10.0")
    assert lte_ml1.intra_meas_summary(rec.fields) == "PCI n/a EARFCN 650 RSRQ -13.5 dB 1 neighbours"


# --- 0xB173 v50 --------------------------------------------------------------------------------

def test_pdsch_stat_v50():
    body = fx.pdsch_stat_v50_body()
    assert len(body) == 4 + 2 * 40
    (rec,) = _decode(0xB173, body)
    assert rec.decoded == "fields", rec.note
    f = rec.fields
    assert f == {"version": 50, "num_records": 2, "sfn": 512, "subframe": 3, "tbs_bytes": 2792 + 1608 + 7, "num_tb": 3,
                 "harq_id": 6, "rnti_type": 0, "rnti_type_name": "C-RNTI", "mcs": 20, "modulation": "64QAM", "num_rbs": 25,
                 "crc_pass": 2, "crc_fail": 1}
    s = dict(rec.sections)
    assert s["records"] == [{"record": 0, "subframe": 3, "sfn": 512, "num_layers": 2, "num_tb": 2, "serving_cell_index": 0},
                            {"record": 1, "subframe": 4, "sfn": 513, "num_layers": 1, "num_tb": 1, "serving_cell_index": 1}]
    tb0, tb1, tb2 = s["transport_blocks"]
    assert tb0 == {"record": 0, "tb": 0, "harq_id": 6, "rv": 0, "ndi": 1, "crc_pass": 1, "rnti_type": 0, "tb_index": 0,
                   "tb_size": 2792, "mcs": 20, "num_rbs": 25, "qm": 6, "modulation": "64QAM", "rnti_type_name": "C-RNTI"}
    assert (tb1["harq_id"], tb1["rv"], tb1["crc_pass"], tb1["tb_index"], tb1["qm"], tb1["modulation"]) == (7, 2, 0, 1, 4, "16QAM")
    assert (tb2["record"], tb2["tb_size"], tb2["mcs"], tb2["num_rbs"], tb2["modulation"]) == (1, 7, 0, 3, "QPSK")
    assert rec.note == HW
    assert lte_phy.pdsch_stat_summary(f) == "3 TB 4407 bytes MCS 20 64QAM CRC 2/3"
    for n in (3, len(body) - 1):
        assert lte_phy.decode_pdsch_stat(_rec(0xB173, body[:n])) is None, n


def test_pdsch_stat_v50_plausibility():
    bad = dict(fx.PDSCH_V50_RECORD, subframe=11, tbs=[dict(fx.PDSCH_V50_TB, mcs=40, qm=5)])
    (rec,) = _decode(0xB173, fx.pdsch_stat_v50_body([bad]))
    assert rec.decoded == "partial"
    assert "implausible: record0.subframe=11, record0.tb0.mcs=40, record0.tb0.qm=5" in rec.note
    assert rec.fields["subframe"] is None and rec.fields["mcs"] is None and rec.fields["modulation"] is None
    assert lte_phy.pdsch_stat_summary(rec.fields) == "1 TB 2792 bytes MCS n/a n/a CRC 1/1"


# --- 0xB139 v162 -------------------------------------------------------------------------------

def test_pusch_tx_v162():
    body = fx.pusch_tx_v162_body()
    assert len(body) == 8 + 2 * 100
    (rec,) = _decode(0xB139, body)
    assert rec.decoded == "fields", rec.note
    f = rec.fields
    assert f["version"] == 162 and f["serving_cell_id"] == 80 and f["num_records"] == 2 and f["dispatch_sfn_sf_raw"] == 0x2008
    assert f["tti"] == 5128 and f["sfn"] == 512 and f["subframe"] == 8 and f["tbs_bytes"] == 1736 + 328
    assert f["required_power_dbm"] == 90 / 4 - 1.5 and f["modulation"] == "16QAM" and f["mod_order"] == 4
    assert round(f["coding_rate"], 4) == round(614 / 1024, 4) and f["num_rbs"] == 20
    assert "tx_power_dbm" not in f
    g0, g1 = dict(rec.sections)["grants"]
    assert g0 == {"grant": 0, "tti": 5128, "sfn": 512, "subframe": 8, "carrier": 0, "retx_index": 0, "start_rb": 12,
                  "num_rbs": 20, "tb_size": 1736, "coding_rate": 614 / 1024, "modulation_code": 2, "modulation": "16QAM",
                  "mod_order": 4, "power_raw": 90, "required_power_dbm": 21.0}
    assert (g1["tti"], g1["sfn"], g1["subframe"], g1["retx_index"], g1["start_rb"], g1["num_rbs"]) == (5132, 513, 2, 1, 30, 8)
    assert (g1["modulation"], g1["mod_order"], g1["required_power_dbm"], g1["tb_size"]) == ("QPSK", 2, 14.0, 328)
    assert rec.note == HW
    assert lte_phy.pusch_tx_summary(f) == "2 grants 2064 bytes 16QAM Tx 21.00 dBm"
    for n in (7, len(body) - 1):
        assert lte_phy.decode_pusch_tx(_rec(0xB139, body[:n])) is None, n


def test_pusch_tx_v162_plausibility_and_unknown_modulation():
    bad = dict(fx.PUSCH_V162_GRANT, tti=10300, num_rbs=111, modulation_code=6)
    (rec,) = _decode(0xB139, fx.pusch_tx_v162_body([bad]))
    assert rec.decoded == "partial" and "implausible: grant0.sfn=1030, grant0.num_rbs=111" in rec.note
    g = dict(rec.sections)["grants"][0]
    assert g["sfn"] is None and g["subframe"] is None and g["num_rbs"] is None
    assert g["modulation"] is None and g["mod_order"] is None and g["modulation_code"] == 6
    assert lte_phy.pusch_tx_summary(rec.fields) == "1 grants 1736 bytes n/a Tx 21.00 dBm"


# --- 0xB063 v50 --------------------------------------------------------------------------------

def test_mac_dl_tb_v50_walk():
    body = fx.mac_dl_tb_v50_body()
    (rec,) = _decode(0xB063, body)
    assert rec.decoded == "fields", rec.note
    assert rec.version == 50 and rec.mac_pdus == []
    assert rec.fields == {"version": 50, "direction": "dl", "num_transport_blocks": 2, "num_found": 2, "walk_exact": 1,
                          "resynced": 0, "tbs_bytes": 1428, "padding_bytes": 5, "sfn": 512, "subframe": 3, "harq_id": 5,
                          "cell_id": 0, "lcids": "3,29"}
    s = dict(rec.sections)
    assert s["transport_blocks"] == [
        {"size_bytes": 1421, "padding_bytes": 3, "sfn": 512, "subframe": 3, "carrier": 0, "harq_id": 5, "header_length": 6,
         "num_sdus": 2, "tb": 0, "lcids": "3,29"},
        {"size_bytes": 7, "padding_bytes": 2, "sfn": 513, "subframe": 1, "carrier": 1, "harq_id": 1, "header_length": 3,
         "num_sdus": 1, "tb": 1, "lcids": "1"}]
    assert s["sdus"] == [{"tb": 0, "control": 0, "lcid": 3, "lcid_name": "DTCH/DCCH 3", "length_bytes": 1290},
                         {"tb": 0, "control": 1, "lcid": 29, "lcid_name": "Timing Advance Command", "length_bytes": 1},
                         {"tb": 1, "control": 0, "lcid": 1, "lcid_name": "DTCH/DCCH 1", "length_bytes": 2}]
    assert rec.note == HW + "; no MAC PDU bytes in this version"
    assert lte_mac.tb_summary(rec.fields) == "2 of 2 TB TBS 1428 bytes LCID 3,29"
    assert "tbs_bytes 1428" in rec.comment() and "sdus x3" in rec.comment()
    assert lte_mac.decode_dl_tb(_rec(0xB063, body[:6])) is None


def test_mac_dl_tb_v50_resyncs_when_the_tail_rule_misses():
    (rec,) = _decode(0xB063, fx.mac_dl_tb_v50_body(tail_extra={0: 8}))
    assert rec.decoded == "fields" and rec.fields["resynced"] == 1 and rec.fields["walk_exact"] == 1
    assert rec.fields["num_found"] == 2 and dict(rec.sections)["transport_blocks"][1]["sfn"] == 513


def test_mac_dl_tb_v50_reports_a_walk_that_does_not_close():
    (rec,) = _decode(0xB063, fx.mac_dl_tb_v50_body(declared=3))
    assert rec.decoded == "fields" and rec.fields["walk_exact"] == 0 and rec.fields["num_found"] == 2
    assert "walk found 2 of 3 declared transport blocks (0 resyncs); the rest is not read" in rec.note
    assert lte_mac.tb_summary(rec.fields) == "2 of 3 TB TBS 1428 bytes LCID 3,29"
    (rec,) = _decode(0xB063, fx.mac_dl_tb_v50_body() + bytes(4))
    assert rec.decoded == "fields" and rec.fields["walk_exact"] == 0
    assert "walk found all 2 transport blocks but ended 4 bytes before the end of the body (0 resyncs)" in rec.note
    (rec,) = _decode(0xB063, bytes([0x32, 0, 0, 0, 1, 0, 0, 0]) + bytes(20))
    assert rec.decoded == "partial" and "tbs_bytes" not in rec.fields
    assert lte_mac.tb_summary(rec.fields) == "v50, 1 TB declared, none found (partial)"


# --- 0xB064 subpacket 0x08 v7 ----------------------------------------------------------------------

def test_mac_ul_tb_v7_with_power_headroom():
    (rec,) = _decode(0xB064, fx.mac_tb_body(False, 7, [fx.UL_SAMPLE_PHR]))
    assert rec.decoded == "fields", rec.note
    f = rec.fields
    assert f["grant_bytes"] == 328 and f["sfn"] == 513 and f["subframe"] == 7 and f["harq_id"] == 2 and f["cell_id"] == 0
    assert f["lcids"] == "26,29,1,31" and f["power_headroom_db"] == 10
    sample = dict(rec.sections)["samples"][0]
    assert sample["hdr_len"] == 8 and sample["header_consistent"] == 1 and sample["power_headroom_db"] == 10
    assert sample["bsr_event_name"] == "periodic" and sample["header_note"] == "2 control-element bytes after the sub-headers"
    assert [(r["lcid"], r["lcid_name"]) for r in dict(rec.sections)["subheaders"]] == [(26, "PHR"), (29, "Short BSR"),
                                                                                       (1, "DTCH/DCCH 1"), (31, "Padding")]
    assert rec.mac_pdus[0]["pdu"] == fx.mac_subheaders(fx.UL_SAMPLE_PHR["subheaders"]) + b"\x21\x1f"
    assert rec.note == HW
    assert lte_mac.tb_summary(f) == "1 samples grant 328 bytes C-RNTI LCID 26,29,1,31"


def test_mac_ul_tb_v7_alignment_padding_and_dc_phr_length():
    dc = dict(fx.UL_SAMPLE, subheaders=[(29, None), (24, 7), (1, 300), (31, None)], extra_bytes=b"\x1f" + bytes(7))
    (rec,) = _decode(0xB064, fx.mac_tb_body(False, 7, [dc, fx.UL_SAMPLE_PHR]))
    assert rec.decoded == "fields", rec.note                      # the 1-3 padding bytes are not a note on v7
    s0, s1 = dict(rec.sections)["samples"]
    assert s0["header_consistent"] == 1 and "power_headroom_db" not in s0 and s1["power_headroom_db"] == 10
    assert rec.fields["power_headroom_db"] == 10
    rows = dict(rec.sections)["subheaders"]
    assert (rows[1]["lcid"], rows[1]["lcid_name"], rows[1]["length"]) == (24, "Dual Connectivity PHR", 7)
    # the same bytes on a documented version keep the note (no alignment rule there)
    (rec,) = _decode(0xB064, fx.mac_tb_body(False, 2, [fx.UL_SAMPLE]) + b"")
    assert rec.decoded == "fields"
    assert lte_mac.ul_control_elements(b"\x3a\x1d\xa1\x1f") == ([(26, b"\xa1"), (29, b"\x1f")], 4)
    assert lte_mac.power_headroom_db([(29, b"\x1f"), (26, b"\x80")]) == -23


# --- 0xB062 --------------------------------------------------------------------------------------

def test_rach_attempt():
    (rec,) = _decode(0xB062, fx.rach_attempt_body())
    assert rec.decoded == "fields", rec.note
    assert rec.fields == {"version": 1, "num_subpackets": 1, "cell_id": 0, "num_attempts": 1, "result": 0, "contention": 1,
                          "msg_mask": 7, "preamble": 27, "preamble_target_dbm": -110, "ta_rar": 18, "ul_earfcn": 132622,
                          "num_rach_attempts": 1}
    s = dict(rec.sections)
    assert s["attempts"] == [{"attempt": 0, "cell_id": 0, "num_attempts": 1, "result": 0, "contention": 1, "msg_mask": 7,
                              "preamble": 27, "preamble_target_dbm": -110, "ta_rar": 18, "ul_earfcn": 132622}]
    assert s["subpackets"] == [{"subpacket_id": 6, "subpacket_version": 50, "subpacket_size": 41}]
    assert rec.note == HW
    assert lte_mac.rach_attempt_summary(rec.fields) == "cell 0 attempt 1 result 0 preamble 27 target -110 dBm TA 18 UL EARFCN 132622"
    assert "preamble 27" in rec.comment()


def test_rach_attempt_without_msg2_and_other_versions():
    (rec,) = _decode(0xB062, fx.rach_attempt_body(msg_mask=1, size=48, extra_subpackets=[(9, 1, b"\x01\x02")]))
    assert rec.decoded == "fields" and rec.fields["ta_rar"] is None and rec.fields["num_subpackets"] == 2
    assert lte_mac.rach_attempt_summary(rec.fields).startswith("cell 0 attempt 1 result 0 preamble 27 target -110 dBm TA n/a")
    (rec,) = _decode(0xB062, fx.rach_attempt_body(sp_version=3))
    assert rec.decoded == "partial" and "subpacket version 3 not implemented" in rec.note
    assert lte_mac.rach_attempt_summary(rec.fields) == "v1 (partial)"
    assert lte_mac.decode_rach_attempt(_rec(0xB062, fx.rach_attempt_body()[:30])) is None
    assert lte_mac.decode_rach_attempt(_rec(0xB062, fx.rach_attempt_body(size=40)[:44])) is None


# --- 0xB14E / 0xB14D ---------------------------------------------------------------------------------

def test_pusch_csf():
    (rec,) = _decode(0xB14E, fx.pusch_csf_body())
    assert rec.decoded == "fields", rec.note
    assert rec.fields == {"version": 164, "sfn": 512, "subframe": 3, "carrier": 0, "ri": 2, "cqi_cw0": 9, "cqi_cw1": 7,
                          "wideband_pmi": 6, "tx_mode": 4}
    assert rec.note == HW and rec.sections == []
    assert lte_ll1.pusch_csf_summary(rec.fields) == "SFN 512.3 CQI 9/7 RI 2 PMI 6 TM 4"
    (rec,) = _decode(0xB14E, fx.pusch_csf_body(version=142))
    assert rec.decoded == "partial" and rec.fields == {"version": 142} and "version 142 not implemented (only v164)" in rec.note
    assert lte_ll1.pusch_csf_summary(rec.fields) == "v142 (partial)"
    (rec,) = _decode(0xB14E, fx.pusch_csf_body(subframe=12))
    assert rec.decoded == "partial" and rec.fields["subframe"] is None and rec.note.endswith("implausible: subframe=12")
    assert lte_ll1.pusch_csf_summary(rec.fields) == "SFN 512.n/a CQI 9/7 RI 2 PMI 6 TM 4"
    assert lte_ll1.decode_pusch_csf(_rec(0xB14E, fx.pusch_csf_body()[:9])) is None


def test_pucch_csf_report_types():
    (rec,) = _decode(0xB14D, fx.pucch_csf_body(2))
    assert rec.decoded == "fields", rec.note
    assert rec.fields == {"version": 164, "sfn": 512, "subframe": 6, "carrier": 0, "report_type": 2, "tx_mode": 4, "cqi_cw0": 7,
                          "cqi_cw1": 0, "wideband_pmi": 6}
    assert lte_ll1.pucch_csf_summary(rec.fields) == "SFN 512.6 type 2 CQI 7/0 PMI 6 TM 4"
    (rec,) = _decode(0xB14D, fx.pucch_csf_body(3, ri=2))
    assert rec.fields == {"version": 164, "sfn": 512, "subframe": 6, "carrier": 0, "report_type": 3, "tx_mode": 4, "ri": 2}
    assert lte_ll1.pucch_csf_summary(rec.fields) == "SFN 512.6 type 3 RI 2 TM 4"
    (rec,) = _decode(0xB14D, fx.pucch_csf_body(1))
    assert rec.decoded == "fields" and "ri" not in rec.fields and "cqi_cw0" not in rec.fields
    assert lte_ll1.pucch_csf_summary(rec.fields) == "SFN 512.6 type 1 TM 4"
    (rec,) = _decode(0xB14D, fx.pucch_csf_body(version=142))
    assert rec.decoded == "partial" and lte_ll1.pucch_csf_summary(rec.fields) == "v142 (partial)"
    assert lte_ll1.decode_pucch_csf(_rec(0xB14D, fx.pucch_csf_body()[:13])) is None


# --- 0xB126 --------------------------------------------------------------------------------------

def test_pdsch_demapper():
    body = fx.pdsch_demapper_body()
    assert len(body) == 968
    (rec,) = _decode(0xB126, body)
    assert rec.decoded == "fields", rec.note
    assert rec.fields == {"version": 163, "num_subframes": 20, "sfn": 501, "subframe": 9, "tx_antennas": 4, "rx_antennas": 4,
                          "rank": 2, "num_prb": 25}
    rows = dict(rec.sections)["demapper"]
    assert len(rows) == 20
    assert rows[0] == {"index": 0, "sfn": 500, "subframe": 0, "tx_antennas": 4, "rx_antennas": 2, "rank": 1, "prb_mask_lo": 32,
                       "prb_mask_hi": 0, "num_prb": 1}
    assert rows[18]["num_prb"] == 19 and rows[18]["sfn"] == 501 and rows[18]["subframe"] == 8
    assert rows[19]["prb_mask_lo"] == (((1 << 25) - 1) << 10) & 0xFFFFFFFF and rows[19]["prb_mask_hi"] == 0x7
    assert rec.note == HW + "; headline = the last (newest) subframe"
    assert lte_ll1.pdsch_demapper_summary(rec.fields) == "SFN 501.9 Tx ant 4 Rx ant 4 rank 2 25 PRB"
    # any other length is not a layout to guess at; any other version is a partial record
    assert lte_ll1.decode_pdsch_demapper(_rec(0xB126, body[:-1])) is None
    assert lte_ll1.decode_pdsch_demapper(_rec(0xB126, body + b"\x00")) is None
    (rec,) = _decode(0xB126, fx.pdsch_demapper_body(version=150))
    assert rec.decoded == "partial" and lte_ll1.pdsch_demapper_summary(rec.fields) == "v150 (partial)"


# --- 0xB12A --------------------------------------------------------------------------------------

def test_pcfich():
    body = fx.pcfich_body()
    assert len(body) == 176
    (rec,) = _decode(0xB12A, body)
    assert rec.decoded == "fields", rec.note
    assert rec.fields == {"version": 161, "sfn": 520, "num_subframes": 20, "num_decoded": 19, "cfi1": 16, "cfi2": 1, "cfi3": 2,
                          "num_consistent": 20}
    rows = dict(rec.sections)["pcfich"]
    assert rows[3] == {"index": 3, "subframe": 3, "decoded_flag": 1, "cfi": 2, "consistent": 1}
    assert rows[7] == {"index": 7, "subframe": 7, "decoded_flag": 0, "cfi": None, "consistent": 1}
    assert rec.note == HW
    assert lte_ll1.pcfich_summary(rec.fields) == "SFN 520 CFI 1/2/3 x16/1/2 decoded 19/20"
    elements = fx.pcfich_elements()
    elements[2]["raw"] = 16                                        # 4 x 4: not a CFI on a 50-PRB cell
    elements[9]["decoded"] = 0                                     # decoded flag 0 with a CFI present
    (rec,) = _decode(0xB12A, fx.pcfich_body(elements=elements))
    assert rec.decoded == "partial" and rec.fields["num_consistent"] == 18 and rec.fields["cfi1"] == 15
    assert "2 elements break the CFI/decode-flag identity" in rec.note
    rows = dict(rec.sections)["pcfich"]
    assert rows[2]["cfi"] is None and rows[2]["consistent"] == 0 and rows[9]["cfi"] == 1 and rows[9]["consistent"] == 0
    assert lte_ll1.decode_pcfich(_rec(0xB12A, body[:-1])) is None
    (rec,) = _decode(0xB12A, fx.pcfich_body(version=140))
    assert rec.decoded == "partial" and lte_ll1.pcfich_summary(rec.fields) == "v140 (partial)"


# --- 0xB16C --------------------------------------------------------------------------------------

def test_dci_info():
    body = fx.dci_info_body()
    assert len(body) == 4 + (4 + 16) + (4 + 32 + 16) + (4 + 8)
    (rec,) = _decode(0xB16C, body)
    assert rec.decoded == "fields", rec.note
    assert rec.fields == {"version": 50, "num_declared": 3, "num_subframes": 3, "num_ul_grants": 3, "num_dl_assignments": 3,
                          "walk_exact": 1, "sfn": 187, "subframe": 9, "start_rb": 4, "num_rbs": 1, "modulation": "QPSK"}
    s = dict(rec.sections)
    assert s["dci"] == [{"index": 0, "sfn": 187, "subframe": 9, "tti": 1879, "num_ul_grants": 1, "num_dl_assignments": 0},
                        {"index": 1, "sfn": 188, "subframe": 3, "tti": 1883, "num_ul_grants": 2, "num_dl_assignments": 2},
                        {"index": 2, "sfn": 188, "subframe": 5, "tti": 1885, "num_ul_grants": 0, "num_dl_assignments": 1}]
    assert s["ul_grants"] == [{"subframe_index": 0, "start_rb": 4, "num_rbs": 1, "modulation_code": 1, "modulation": "QPSK"},
                              {"subframe_index": 1, "start_rb": 12, "num_rbs": 20, "modulation_code": 2, "modulation": "16QAM"},
                              {"subframe_index": 1, "start_rb": 30, "num_rbs": 8, "modulation_code": 3, "modulation": "64QAM"}]
    assert rec.note == HW + "; downlink assignments counted, contents not read"
    assert lte_ll1.dci_info_summary(rec.fields) == "3 subframes 3 UL grants 3 DL assignments"


def test_dci_info_chain_that_does_not_close():
    (rec,) = _decode(0xB16C, fx.dci_info_body(truncate=8))
    assert rec.decoded == "fields" and rec.fields["walk_exact"] == 0 and rec.fields["num_subframes"] == 2
    assert "element chain did not consume the body (2 of 3 elements)" in rec.note
    (rec,) = _decode(0xB16C, fx.dci_info_body(declared=2))
    assert rec.fields["walk_exact"] == 0 and rec.fields["num_subframes"] == 2 and "2 of 2 elements" in rec.note
    (rec,) = _decode(0xB16C, bytes([50, 0, 0, 0]))
    assert rec.decoded == "partial" and rec.fields["walk_exact"] == 1 and lte_ll1.dci_info_summary(rec.fields) == "v50 (partial)"
    (rec,) = _decode(0xB16C, fx.dci_info_body()[:1].replace(b"\x32", b"\x31") + fx.dci_info_body()[1:])
    assert rec.decoded == "partial" and "version 49 not implemented (only v50)" in rec.note
    assert lte_ll1.decode_dci_info(_rec(0xB16C, bytes([50, 0]))) is None


# --- 0x184C / 0x1D0B (fieldtap/decode/rf.py) --------------------------------------------------------------

def test_fed_tx_agc():
    body = fx.fed_tx_agc_body()
    assert len(body) == 2 * 16 + 3 * 120
    (rec,) = _decode(0x184C, body)
    assert rec.decoded == "fields", rec.note
    assert rec.fields == {"version": 0x11, "num_blocks_declared": 2, "num_blocks": 2, "walk_exact": 1, "subframes_in_range": 2,
                          "num_chain_samples": 3, "chain": 0x10, "gain_state": 0x24, "tx_power_dbm": 10.0, "tx_power2_dbm": 12.6,
                          "limit_dbm": 22.7, "max_tx_power_dbm": 15.5, "num_live": 2}
    s = dict(rec.sections)
    assert s["blocks"] == [{"block": 0, "subframe_counter": 2039, "frame": 203, "subframe": 9},
                           {"block": 1, "subframe_counter": 2040, "frame": 204, "subframe": 0}]
    c0, c1, c2 = s["chains"]
    assert c0 == {"block": 0, "subframe_counter": 2039, "chain": 0x10, "gain_state": 0x24, "tx_power_dbm": 10.0,
                  "tx_power2_dbm": 12.6, "limit0_dbm": 22.7, "limit1_dbm": 23.0, "limit2_dbm": 25.0, "live": 1}
    assert (c1["chain"], c1["tx_power_dbm"], c1["tx_power2_dbm"], c1["live"]) == (0x11, -70.0, -2.9, 0)
    assert (c2["block"], c2["tx_power_dbm"], c2["gain_state"]) == (1, 15.5, 0x10)
    assert rec.note == HW + "; front-end Tx power, not the PUSCH target; the block counter is not the cell's SFN"
    assert rf.fed_tx_agc_summary(rec.fields) == "2 blocks 3 chain samples Tx 10.0 dBm chain 0x10 gain state 0x24 limit 22.7 dBm"
    assert rec.name == "LTE RF FED Tx AGC" and rec.confidence == "high"


def test_fed_tx_agc_walk_that_does_not_close_reads_no_chains():
    (rec,) = _decode(0x184C, fx.fed_tx_agc_body(junk=bytes(8)))
    assert rec.decoded == "partial" and rec.fields["walk_exact"] == 0 and rec.fields["num_blocks"] == 2
    assert "num_chain_samples" not in rec.fields and dict(rec.sections)["chains"] == []
    assert "block walk did not consume the body; no chain samples read" in rec.note
    assert rf.fed_tx_agc_summary(rec.fields) == "v17 (partial)"
    (rec,) = _decode(0x184C, fx.fed_tx_agc_body([{"frame": 1, "subframe": 12, "chains": [fx.FED_CHAIN_OFF]}]))
    assert rec.decoded == "fields" and rec.fields["subframes_in_range"] == 0 and rec.fields["num_live"] == 0
    assert "1 block counters outside subframes 0..9" in rec.note
    assert rf.fed_tx_agc_summary(rec.fields) == "1 blocks 1 chain samples no chain transmitting"
    (rec,) = _decode(0x184C, fx.fed_tx_agc_body(version=0x12))
    assert rec.decoded == "partial" and "version 18 not implemented (only v17)" in rec.note
    assert rf.decode_fed_tx_agc(_rec(0x184C, b"\x11")) is None


def test_modem_clock():
    (rec,) = _decode(0x1D0B, fx.modem_clock_body())
    assert rec.decoded == "fields", rec.note
    assert rec.fields == {"version": 7, "ticks_1024hz": 44728, "ticks_19m2": 11435733, "sequence": 1707}
    assert rec.version == 7 and rec.name == "Modem 100 Hz sampler"
    assert rec.note == HW + "; only the clocks and the sequence number are read; the five 2 ms entries are not identified"
    assert rf.modem_clock_summary(rec.fields) == "seq 1707 sleep clock 44728 (1024 Hz) TCXO 11435733 (19.2 MHz)"
    assert rf.decode_modem_clock(_rec(0x1D0B, fx.modem_clock_body()[:87])) is None
    (rec,) = _decode(0x1D0B, fx.modem_clock_body(version=8))
    assert rec.decoded == "partial" and rec.fields == {"version": 8} and rf.modem_clock_summary(rec.fields) == "v8 (partial)"


def test_iphone_decoders_are_registered_and_counted():
    bodies = {0xB193: fx.ml1_scell_meas_v66_body(), 0xB179: fx.intra_meas_v56_body(), 0xB173: fx.pdsch_stat_v50_body(),
              0xB139: fx.pusch_tx_v162_body(), 0xB063: fx.mac_dl_tb_v50_body(), 0xB064: fx.mac_tb_body(False, 7),
              0xB062: fx.rach_attempt_body(), 0xB14E: fx.pusch_csf_body(), 0xB14D: fx.pucch_csf_body(),
              0xB126: fx.pdsch_demapper_body(), 0xB12A: fx.pcfich_body(), 0xB16C: fx.dci_info_body(),
              0x184C: fx.fed_tx_agc_body(), 0x1D0B: fx.modem_clock_body()}
    decoder = Decoder()
    for code, body in bodies.items():
        decoder.decode(_rec(code, body))
    rep = decoder.report()
    assert rep["stats"]["errors"] == 0 and rep["unknown_codes"] == {}
    for code in bodies:
        assert rep["coverage"]["0x%04X" % code]["as"] == {"fields": 1}, hex(code)
        assert LOG_CODES[code].decoder and "iPhone 17 (M25) captures of 2026-09-21/22" in LOG_CODES[code].note, hex(code)
    assert rep["versions"]["0xB193"] == {1: 1} and rep["versions"]["0xB179"] == {56: 1} and rep["versions"]["0x1D0B"] == {7: 1}
