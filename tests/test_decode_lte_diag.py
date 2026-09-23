"""LTE measurement, MAC and PHY record decoders on the synthetic bodies of
fieldtap/fixtures_lte_diag.py: every field of every implemented version, None on a
truncated or unknown body, and a plausibility failure that drops the number."""

import struct

import pytest

from fieldtap import fixtures_lte_diag as fx
from fieldtap.decode import Decoder, DiagRecord
from fieldtap.decode import cellinfo, lte_mac, lte_ml1, lte_phy
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
