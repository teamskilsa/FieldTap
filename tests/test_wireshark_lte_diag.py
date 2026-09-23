"""The LTE Lua decoders (wireshark/fieldtap_lte.lua) read the same fields, notes and
summary from the same bytes as the Python decoders, and the MAC transport blocks
dissect as mac-lte in stock Wireshark. Skipped when tshark is not installed."""

import os

import pytest

from fieldtap import fixtures_lte_diag as fx
from fieldtap import tshark as tshark_mod
from fieldtap import wireshark_plugin
from fieldtap.decode import Decoder, DiagRecord
from fieldtap.decode import lte_ll1, lte_mac, lte_ml1, lte_phy, rf
from fieldtap.diag.protocol import LogRecord, qc_timestamp_from_datetime
from fieldtap.fixtures import BASE_TIME
from fieldtap.output.sinks import PcapngSink

TSHARK = tshark_mod.find_tshark()
LUA_PLUGIN = [os.path.join(wireshark_plugin.PLUGIN_DIR, name)
              for name in ("fieldtap.lua", "fieldtap_lte.lua", "fieldtap_nr.lua")]
pytestmark = pytest.mark.skipif(TSHARK is None, reason="tshark not installed")

SUMMARY = {0xB193: lte_ml1.scell_meas_summary, 0xB179: lte_ml1.intra_meas_summary,
           0xB17F: lte_ml1.scell_eval_summary, 0xB180: lte_ml1.ncell_meas_summary,
           0xB063: lte_mac.tb_summary, 0xB064: lte_mac.tb_summary, 0xB062: lte_mac.rach_attempt_summary,
           0xB173: lte_phy.pdsch_stat_summary, 0xB139: lte_phy.pusch_tx_summary,
           0xB14E: lte_ll1.pusch_csf_summary, 0xB14D: lte_ll1.pucch_csf_summary, 0xB126: lte_ll1.pdsch_demapper_summary,
           0xB12A: lte_ll1.pcfich_summary, 0xB16C: lte_ll1.dci_info_summary,
           0x184C: rf.fed_tx_agc_summary, 0x1D0B: rf.modem_clock_summary}

# the field prefix per log code: fieldtap.lte.* for the LTE decoders, fieldtap.rf.* for rf.py
LTE, RF = "fieldtap.lte.", "fieldtap.rf."
PREFIX = {0x184C: RF, 0x1D0B: RF}

# the headline fields compared one by one, by log code
HEADLINE = {
    0xB193: ["version", "num_subpackets", "subpacket_id", "subpacket_version", "subpacket_size", "earfcn", "num_cells",
             "valid_rx", "pci", "serving_cell_index", "sfn", "subframe", "rsrp", "rsrq", "rssi", "snr", "filtered_rsrp",
             "filtered_rsrq", "projected_sir", "post_ic_rsrq", "rx_map", "num_rx"],
    0xB179: ["version", "serving_cell_index", "earfcn", "pci", "subframe_number", "rsrp", "rsrq", "num_neighbours",
             "num_detected", "unidentified_word", "tti", "sfn", "subframe"],
    0xB17F: ["version", "rrc_release", "earfcn", "pci", "serving_layer_priority", "rsrp", "rsrp_avg", "rsrq", "rsrq_avg",
             "rssi"],
    0xB180: ["version", "rrc_release", "earfcn", "num_cells"],
    0xB0C1: ["version", "pci", "earfcn", "sfn", "num_tx_antennas", "dl_bw", "dl_bw_mhz", "dl_bw_reading", "sib1_br_sch_info",
             "sfn_msb4", "hsfn_lsb2", "sib1_sch_info", "sys_info_value_tag", "access_barring_enabled", "op_mode_type",
             "op_mode", "raster_offset", "raster_offset_khz"],
    0xB063: ["version", "num_subpackets", "direction", "num_samples", "tbs_bytes", "sfn", "subframe", "harq_id",
             "rnti_type", "rnti_type_name", "cell_id", "lcids", "num_transport_blocks", "num_found", "walk_exact",
             "resynced", "padding_bytes"],
    0xB064: ["version", "num_subpackets", "direction", "num_samples", "grant_bytes", "sfn", "subframe", "harq_id",
             "rnti_type", "rnti_type_name", "cell_id", "lcids", "power_headroom_db"],
    0xB062: ["version", "num_subpackets", "cell_id", "num_attempts", "result", "contention", "msg_mask", "preamble",
             "preamble_target_dbm", "ta_rar", "ul_earfcn", "num_rach_attempts"],
    0xB173: ["version", "num_records", "sfn", "subframe", "tbs_bytes", "num_tb", "harq_id", "rnti_type", "rnti_type_name",
             "mcs", "modulation", "num_rbs", "crc_pass", "crc_fail"],
    0xB139: ["version", "serving_cell_id", "num_records", "dispatch_sfn_sf_raw", "sfn", "subframe", "tbs_bytes",
             "tx_power_dbm", "modulation", "mod_order", "coding_rate", "num_rbs", "tti", "required_power_dbm"],
    0xB14E: ["version", "sfn", "subframe", "carrier", "ri", "cqi_cw0", "cqi_cw1", "wideband_pmi", "tx_mode"],
    0xB14D: ["version", "sfn", "subframe", "carrier", "report_type", "tx_mode", "ri", "cqi_cw0", "cqi_cw1", "wideband_pmi"],
    0xB126: ["version", "num_subframes", "sfn", "subframe", "tx_antennas", "rx_antennas", "rank", "num_prb"],
    0xB12A: ["version", "sfn", "num_subframes", "num_decoded", "cfi1", "cfi2", "cfi3", "num_consistent"],
    0xB16C: ["version", "num_declared", "num_subframes", "num_ul_grants", "num_dl_assignments", "walk_exact", "sfn",
             "subframe", "start_rb", "num_rbs", "modulation"],
    0x184C: ["version", "num_blocks_declared", "num_blocks", "walk_exact", "subframes_in_range", "num_chain_samples",
             "chain", "gain_state", "tx_power_dbm", "tx_power2_dbm", "limit_dbm", "max_tx_power_dbm", "num_live"],
    0x1D0B: ["version", "ticks_1024hz", "ticks_19m2", "sequence"],
}
# per-row fields, by section label -> Lua group
ROWS = {
    "cells": ("cell", ["cell", "pci", "serving_cell_index", "is_serving_cell", "sfn", "subframe", "rsrp_rx0", "rsrp_rx1",
                       "rsrp_rx2", "rsrp_rx3", "rsrp", "filtered_rsrp", "rsrq_rx0", "rsrq_rx1", "rsrq_rx2", "rsrq_rx3",
                       "rsrq", "filtered_rsrq", "rssi_rx0", "rssi_rx1", "rssi_rx2", "rssi_rx3", "rssi", "snr_rx0",
                       "snr_rx1", "snr_rx2", "snr_rx3", "snr", "projected_sir", "post_ic_rsrq", "cinr_rx0_raw",
                       "cinr_rx1_raw", "cinr_rx2_raw", "cinr_rx3_raw", "residual_freq_error", "rx_map", "num_rx"]),
    "neighbours": ("ncell", ["pci", "rsrp", "rsrq"]),
    "detected": ("det", ["pci", "sss_corr", "reference_time"]),
    "samples": ("sample", ["sample", "sub_id", "cell_id", "sfn", "subframe", "rnti_type", "rnti_type_name", "harq_id",
                           "pmch_id", "tbs_bytes", "grant_bytes", "rlc_pdus", "padding_bytes", "bsr_event",
                           "bsr_event_name", "bsr_trigger", "bsr_trigger_name", "hdr_len", "lcids", "header_note",
                           "power_headroom_db", "header_consistent"]),
    "subheaders": ("subhdr", ["sample", "lcid", "lcid_name", "extension", "length"]),
    "sdus": ("sdu", ["tb", "control", "lcid", "lcid_name", "length_bytes"]),
    "attempts": ("rach", ["attempt", "cell_id", "num_attempts", "result", "contention", "msg_mask", "preamble",
                          "preamble_target_dbm", "ta_rar", "ul_earfcn"]),
    "demapper": ("dmp", ["index", "sfn", "subframe", "tx_antennas", "rx_antennas", "rank", "prb_mask_lo", "prb_mask_hi",
                         "num_prb"]),
    "pcfich": ("cfi", ["index", "subframe", "decoded_flag", "cfi", "consistent"]),
    "dci": ("dci", ["index", "sfn", "subframe", "tti", "num_ul_grants", "num_dl_assignments"]),
    "ul_grants": ("ulg", ["subframe_index", "start_rb", "num_rbs", "modulation_code", "modulation"]),
    "blocks": ("blk", ["block", "subframe_counter", "frame", "subframe"]),
    "chains": ("chain", ["block", "subframe_counter", "chain", "gain_state", "tx_power_dbm", "tx_power2_dbm", "limit0_dbm",
                         "limit1_dbm", "limit2_dbm", "live"]),
    "records": ("record", ["record", "sfn", "subframe", "num_rbs", "num_layers", "num_tb", "serving_cell_index",
                           "hsic_enabled", "pmch_id", "area_id"]),
    "transport_blocks": ("tb", ["record", "tb", "harq_id", "rv", "ndi", "crc_pass", "rnti_type", "rnti_type_name",
                                "tb_index", "discarded_retx_present", "did_recombining", "tb_size", "mcs", "num_rbs",
                                "modulation_code", "modulation", "qed2_interim_status", "qed_iteration", "qm",
                                "size_bytes", "padding_bytes", "carrier", "header_length", "num_sdus", "lcids"]),
    "grants": ("grant", ["grant", "sfn", "subframe", "coding_rate", "ack", "cqi", "ri", "frequency_hopping", "rv",
                         "mirror_hopping", "dmrs_cyclic_shift_slot0", "dmrs_cyclic_shift_slot1", "dmrs_root_slot0",
                         "ue_srs", "dmrs_root_slot1", "start_rb_slot0", "start_rb_slot1", "num_rbs", "tb_size",
                         "num_ack_bits", "ack_payload", "rate_matched_ack_bits", "num_ri_bits", "ri_payload",
                         "rate_matched_ri_bits", "mod_order", "modulation", "digital_gain_db", "srs_occasion",
                         "retx_index", "tx_power_dbm", "num_cqi_bits", "rate_matched_cqi_bits", "cqi_payload",
                         "tx_resampler", "num_repetition", "rb_nb_start_index", "tti", "carrier", "start_rb",
                         "modulation_code", "power_raw", "required_power_dbm"]),
}
# section labels whose rows live under fieldtap.rf.*
ROW_PREFIX = {"blocks": RF, "chains": RF}


def corpus():
    two = [fx.SERVING_CELL, fx.NEIGHBOUR_CELL]
    absent = dict(fx.SERVING_CELL, rsrp_rx=[-96.0, None, None, None], rsrq_rx=[-11.0, None], rssi_rx=[-66.0, None],
                  snr_rx=[12.3, None])
    implausible = dict(fx.SERVING_CELL, rsrp=-20.0)
    unknown_version = fx.ml1_scell_meas_body(19)
    unknown_version = unknown_version[:5] + bytes([99]) + unknown_version[6:]
    return [
        (0xB193, fx.ml1_scell_meas_body(4)), (0xB193, fx.ml1_scell_meas_body(7)), (0xB193, fx.ml1_scell_meas_body(18)),
        (0xB193, fx.ml1_scell_meas_body(19, two)), (0xB193, fx.ml1_scell_meas_body(22, two)),
        (0xB193, fx.ml1_scell_meas_body(24, two)), (0xB193, fx.ml1_scell_meas_body(35, [absent, fx.NEIGHBOUR_CELL])),
        (0xB193, fx.ml1_scell_meas_body(36, two)), (0xB193, fx.ml1_scell_meas_body(40, two)),
        (0xB193, fx.ml1_scell_meas_body(19, [implausible])), (0xB193, unknown_version),
        (0xB193, fx.ml1_scell_meas_body(7, extra_subpackets=[(30, 2, b"\x01\x02\x03")])),
        (0xB193, fx.ml1_scell_meas_body(19)[:40]),                    # truncated: raw in Python, no fit in Lua
        (0xB179, fx.intra_meas_body(3)), (0xB179, fx.intra_meas_body(4)),
        (0xB179, fx.intra_meas_body(4, neighbours=[(245, -103.5, -13.5), (700, -30.0, -16.0)])),
        (0xB17F, fx.scell_eval_body(4)), (0xB17F, fx.scell_eval_body(5)),
        (0xB180, fx.ncell_meas_body(4)), (0xB180, fx.ncell_meas_body(5, count_shift=6)),
        (0xB0C1, fx.mib_body(1)), (0xB0C1, fx.mib_body(2, dl_bw=50)), (0xB0C1, fx.mib_body(3)), (0xB0C1, fx.mib_body(17)),
        (0xB063, fx.mac_tb_body(True, 2)), (0xB063, fx.mac_tb_body(True, 4)),
        (0xB064, fx.mac_tb_body(False, 1)), (0xB064, fx.mac_tb_body(False, 2)),
        (0xB064, fx.mac_tb_body(False, 3, [fx.UL_SAMPLE, dict(fx.UL_SAMPLE, grant_bytes=2, subheaders=[(29, None)],
                                                            extra_bytes=b"\x1f", sfn=1000, subframe=9)])),
        (0xB063, fx.mac_tb_body(True, 2, [dict(fx.DL_SAMPLE, subframe=12)])),
        (0xB173, fx.pdsch_stat_body(5)), (0xB173, fx.pdsch_stat_body(16)), (0xB173, fx.pdsch_stat_body(24)),
        (0xB173, fx.pdsch_stat_body(32)), (0xB173, fx.pdsch_stat_body(36)),
        (0xB173, fx.pdsch_stat_body(24, [dict(fx.PDSCH_RECORD, subframe=11)])),
        (0xB139, fx.pusch_tx_body(23)), (0xB139, fx.pusch_tx_body(24)), (0xB139, fx.pusch_tx_body(26)),
        (0xB139, fx.pusch_tx_body(23, [dict(fx.PUSCH_GRANT, tx_power_dbm=200)])),
        # the iPhone 17 layouts
        (0xB193, fx.ml1_scell_meas_v66_body([fx.IPHONE_NEIGHBOUR, fx.IPHONE_SCELL, fx.IPHONE_CELL])),
        (0xB193, fx.ml1_scell_meas_v66_body([dict(fx.IPHONE_CELL, rsrp=-20.0)])),
        (0xB193, fx.ml1_scell_meas_v66_body()[:-1]),                  # short: raw in Python, no fit in Lua
        (0xB179, fx.intra_meas_v56_body()), (0xB179, fx.intra_meas_v56_body(neighbours=[])),
        (0xB179, fx.intra_meas_v56_body(pci=600, rsrp=-20.0, neighbours=[(235, -116.25, 10.0)])),
        (0xB179, fx.intra_meas_v56_body(trailing=b"\x00")),
        (0xB173, fx.pdsch_stat_v50_body()),
        (0xB173, fx.pdsch_stat_v50_body([dict(fx.PDSCH_V50_RECORD, subframe=11, tbs=[dict(fx.PDSCH_V50_TB, mcs=40, qm=5)])])),
        (0xB139, fx.pusch_tx_v162_body()),
        (0xB139, fx.pusch_tx_v162_body([dict(fx.PUSCH_V162_GRANT, tti=10300, num_rbs=111, modulation_code=6)])),
        (0xB063, fx.mac_dl_tb_v50_body()), (0xB063, fx.mac_dl_tb_v50_body(tail_extra={0: 8})),
        (0xB063, fx.mac_dl_tb_v50_body(declared=3)), (0xB063, fx.mac_dl_tb_v50_body() + bytes(4)),
        (0xB063, bytes([0x32, 0, 0, 0, 1, 0, 0, 0]) + bytes(20)),
        (0xB064, fx.mac_tb_body(False, 7, [fx.UL_SAMPLE_PHR])),
        (0xB064, fx.mac_tb_body(False, 7, [dict(fx.UL_SAMPLE, subheaders=[(29, None), (26, None), (1, 300), (31, None)],
                                                 extra_bytes=b"\x1f\x1c"), fx.UL_SAMPLE_PHR])),
        (0xB062, fx.rach_attempt_body()), (0xB062, fx.rach_attempt_body(msg_mask=1, size=48, extra_subpackets=[(9, 1, b"\x01\x02")])),
        (0xB062, fx.rach_attempt_body(sp_version=3)),
        (0xB14E, fx.pusch_csf_body()), (0xB14E, fx.pusch_csf_body(subframe=12)), (0xB14E, fx.pusch_csf_body(version=142)),
        (0xB14D, fx.pucch_csf_body(2)), (0xB14D, fx.pucch_csf_body(3, ri=2)), (0xB14D, fx.pucch_csf_body(1)),
        (0xB14D, fx.pucch_csf_body(version=142)),
        (0xB126, fx.pdsch_demapper_body()), (0xB126, fx.pdsch_demapper_body(version=150)),
        (0xB12A, fx.pcfich_body()), (0xB12A, fx.pcfich_body(version=140)),
        (0xB16C, fx.dci_info_body()), (0xB16C, fx.dci_info_body(truncate=8)), (0xB16C, bytes([50, 0, 0, 0])),
        (0x184C, fx.fed_tx_agc_body()), (0x184C, fx.fed_tx_agc_body(junk=bytes(8))),
        (0x184C, fx.fed_tx_agc_body([{"frame": 1, "subframe": 12, "chains": [fx.FED_CHAIN_OFF]}])),
        (0x184C, fx.fed_tx_agc_body(version=0x12)),
        (0x1D0B, fx.modem_clock_body()), (0x1D0B, fx.modem_clock_body(version=8)),
    ]


@pytest.fixture(scope="module")
def capture(tmp_path_factory):
    """-> (pcapng path, [(kind, object)] in frame order): "diag" for a record, "mac" for a MAC PDU."""
    path = str(tmp_path_factory.mktemp("lte") / "lte_diag.pcapng")
    decoder = Decoder()
    frames = []
    ts = qc_timestamp_from_datetime(BASE_TIME)
    sink = PcapngSink(path)
    for code, body in corpus():
        for obj in decoder.decode(LogRecord(code, ts, body)):
            if isinstance(obj, DiagRecord):       # CellInfo feeds the sidecar, not the pcap
                sink.write(obj)
                frames.append(("diag", obj))
                frames.extend(("mac", (obj, pdu)) for pdu in obj.mac_pdus)
    sink.close()
    assert decoder.report()["stats"]["errors"] == 0
    return path, frames


def _fields(path, names, display_filter=None):
    return tshark_mod.fields(path, names, display_filter=display_filter, tshark=TSHARK, lua_scripts=LUA_PLUGIN)


def _same(python_value, lua_text, key):
    if python_value is None:
        assert lua_text == "", (key, lua_text)
    elif isinstance(python_value, float):
        assert lua_text != "", key
        assert round(float(lua_text), 1) == round(python_value, 1), (key, python_value, lua_text)
    elif isinstance(python_value, bool):
        assert lua_text == str(python_value).lower(), key
    elif isinstance(python_value, int):
        assert lua_text != "" and int(lua_text, 0) == python_value, (key, python_value, lua_text)
    else:
        assert lua_text == str(python_value), (key, python_value, lua_text)


def test_headline_fields_notes_and_summary_agree(capture):
    path, frames = capture
    diag = [obj for kind, obj in frames if kind == "diag"]
    keys = sorted({PREFIX.get(code, LTE) + k for code, code_keys in HEADLINE.items() for k in code_keys})
    names = ["fieldtap.code", "_ws.col.Info", LTE + "note", RF + "note"] + keys
    rows = _fields(path, names, display_filter="fieldtap-diag")
    assert len(rows) == len(diag)
    for rec, row in zip(diag, rows):
        assert int(row[0], 16) == rec.log_code
        prefix = PREFIX.get(rec.log_code, LTE)
        values = {k[len(prefix):]: v for k, v in zip(keys, row[4:]) if k.startswith(prefix)}
        if rec.decoded == "raw":
            assert "layout did not fit" in row[1]
            continue
        note = row[3] if prefix == RF else row[2]
        assert note == rec.note, (rec.summary(), note, rec.note)
        if rec.log_code in SUMMARY:
            summary = SUMMARY[rec.log_code](rec.fields)
            assert summary in row[1], (rec.summary(), summary, row[1])
        for key in HEADLINE[rec.log_code]:
            _same(rec.fields.get(key), values[key], (rec.summary(), key))


@pytest.mark.parametrize("label", sorted(ROWS))
def test_section_rows_agree(capture, label):
    path, frames = capture
    group, keys = ROWS[label]
    diag = [obj for kind, obj in frames if kind == "diag"]
    names = ["fieldtap.code"] + ["%s%s.%s" % (ROW_PREFIX.get(label, LTE), group, k) for k in keys]
    rows = _fields(path, names, display_filter="fieldtap-diag")
    assert len(rows) == len(diag)
    seen = 0
    for rec, row in zip(diag, rows):
        expected = dict(rec.sections).get(label, [])
        if rec.decoded == "raw":
            continue
        for key, cell in zip(keys, row[1:]):
            lua = cell.split(",") if cell else []
            python = [r.get(key) for r in expected]
            present = [v for v in python if v is not None]
            if key == "lcids":          # the value itself is comma-separated; compare the joined text
                assert cell == ",".join(present), (rec.summary(), label, key, python, cell)
                seen += len(present)
                continue
            assert len(lua) == len(present), (rec.summary(), label, key, python, lua)
            for p, l in zip(present, lua):
                if key == "cqi_payload":
                    l = l.replace(":", "")
                _same(p, l, (rec.summary(), label, key))
            seen += len(present)
    assert seen > 0


def test_mac_pdus_dissect_as_mac_lte(capture):
    path, frames = capture
    pdus = [obj for kind, obj in frames if kind == "mac"]
    rows = _fields(path, ["frame.protocols", "mac-lte.direction", "mac-lte.rnti-type", "mac-lte.sfn", "mac-lte.subframe",
                          "mac-lte.dlsch.lcid", "mac-lte.ulsch.lcid", "_ws.col.Info"],
                   display_filter="mac-lte")
    assert len(rows) == len(pdus) > 0
    for (rec, pdu), row in zip(pdus, rows):
        assert "mac-lte" in row[0], row
        assert int(row[1]) == (1 if pdu["downlink"] else 0)
        assert int(row[2]) == pdu["rnti_type"]
        if pdu["sfn"] is not None and pdu["subframe"] is not None:
            assert int(row[3]) == pdu["sfn"] and int(row[4]) == pdu["subframe"]
        lcids = [r["lcid"] for r in dict(rec.sections)["subheaders"] if r["sample"] == rec.mac_pdus.index(pdu)]
        col = row[5] if pdu["downlink"] else row[6]
        assert [int(x, 0) for x in col.split(",")] == lcids, (rec.summary(), col, lcids)
    # the same frames without the plugin: still mac-lte, still whole
    bare = tshark_mod.fields(path, ["frame.protocols"], display_filter="mac-lte", tshark=TSHARK)
    assert len(bare) == len(pdus)


def test_no_malformed_frames_with_or_without_plugin(capture):
    path, _ = capture
    assert tshark_mod.malformed(path, tshark=TSHARK) == []
    assert tshark_mod.malformed(path, tshark=TSHARK, lua_scripts=LUA_PLUGIN) == []


def test_lua_files_load_in_either_order(capture):
    path, frames = capture
    reordered = [LUA_PLUGIN[1], LUA_PLUGIN[2], LUA_PLUGIN[0]]
    rows = tshark_mod.fields(path, ["fieldtap.lte.pci"], display_filter="fieldtap.code == 0xb193", tshark=TSHARK,
                             lua_scripts=reordered)
    assert rows[0] == ["101"]
