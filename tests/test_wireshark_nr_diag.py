"""The NR record decoders in Wireshark: wireshark/fieldtap_nr.lua must read the same
fields from the same bytes as fieldtap/decode/nr_*.py. Skipped when tshark is not
installed; CI installs it."""

import os

import pytest

from fieldtap import fixtures_nr_diag as fx
from fieldtap import tshark as tshark_mod
from fieldtap import wireshark_plugin
from fieldtap.decode import Decoder, DiagRecord
from fieldtap.decode import nr_mac, nr_ml1, nr_state
from fieldtap.decode.nr_common import DOC_NOTE, IPHONE_NOTE
from fieldtap.diag.protocol import LogRecord
from fieldtap.output.sinks import PcapngSink

TSHARK = tshark_mod.find_tshark()
pytestmark = pytest.mark.skipif(TSHARK is None, reason="tshark not installed")


def _plugin(*names):
    return [os.path.join(wireshark_plugin.PLUGIN_DIR, name) for name in names]


# Wireshark 4.0.1 runs each -X lua_script file in its own environment: bare globals are
# private, reads fall through to _G. Every file publishes the shared table through _G,
# so the load order must not matter (test_load_order_does_not_matter).
LUA_PLUGIN = _plugin("fieldtap.lua", "fieldtap_lte.lua", "fieldtap_nr.lua")
NR_FIRST = _plugin("fieldtap_nr.lua", "fieldtap_lte.lua", "fieldtap.lua")


def _records():
    """The corpus plus records that exercise the plausibility gate and the raw fallback."""
    records = fx.build_nr_corpus()
    ts = records[-1][1]
    bad_cell = fx.carrier(647328, 417, [fx.cell(417, 1024, -90.0, -10.5, [fx.beam(3, -90.5, -92.25, -90.0, -10.5)])])
    extra = [
        (0xB975, fx.nr_beam_mgmt_body(rsrp=-20.0)),
        (0xB823, fx.nr_serving_cell_body(3, 0, band=0)),
        (0xB822, fx.nr_mib_body(2, 0, pci=1008)),
        (0xB97F, fx.nr_search_meas_body(2, 7, carriers=[bad_cell])),
        (0xB888, fx.nr_pdsch_stats_body(3, 1, [fx.pdsch_record(crc_pass=1501)])),
        (0xB872, fx.nr_ul_tb_body(4, [fx.ul_tti(tbs=[fx.ul_tb(grant=1000, built=1001)])])),
        (0xB872, fx.nr_ul_tb_body()[:20]),
        (0xB97F, fx.nr_search_meas_body(2, 7)[:100]),
        (0xB823, fx.nr_serving_cell_body(3, 0)[:30]),
        # the iPhone 17 layouts: the plausibility gate, an empty record, the other version
        (0xB887, fx.nr_pdsch_info_body(3, 13, [fx.pdsch_slot(pci=1010), fx.pdsch_slot(pci=80, crc_ok=False)])),
        (0xB887, fx.nr_pdsch_info_body(3, 13, [])),
        (0xB887, fx.nr_pdsch_info_body(3, 12)),
        (0xB887, fx.nr_pdsch_info_body()[:30]),
        (0xB888, fx.nr_pdsch_stats_body(3, 1, records=[])),
        (0xB80C, fx.nr_mm5g_state_body(version=0x00030000, amf_region=7, amf_set=33, amf_pointer=2)),
        (0xB97F, fx.nr_search_meas_body(3, 0, carriers=[fx.carrier(650000, 0xFFFF, [fx.cell(300, 1, -110.0, -17.5)], cc_id=255)])),
        (0xB97F, fx.nr_search_meas_body(3, 0)[:60]),
    ]
    for code, body in extra:
        ts += 1 << 16
        records.append((code, ts, body))
    return records


@pytest.fixture(scope="module")
def outputs(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("nr")
    pcapng = str(tmp / "nr.pcapng")
    decoder = Decoder()
    diag = []
    sink = PcapngSink(pcapng)
    for code, ts, body in _records():
        for obj in decoder.decode(LogRecord(code, ts, body)):
            if isinstance(obj, DiagRecord):
                sink.write(obj)
                diag.append(obj)
    sink.close()
    assert decoder.report()["stats"]["errors"] == 0
    return pcapng, diag


def _expected_note(rec: DiagRecord) -> str:
    return rec.note or rec.fields.get("layout_note", "")


# The Python Info line per code; the Lua must print it character for character.
SUMMARIES = {**nr_state.SUMMARIES, **nr_ml1.SUMMARIES, **nr_mac.SUMMARIES}


def _summary_parts(rec: DiagRecord) -> list:
    """What the Info column must contain for this record, from the Python fields."""
    f = rec.fields
    parts = []
    if rec.log_code == 0xB822:
        parts.append("MIB")
        if f["pci"] is not None:
            parts.append("PCI %d" % f["pci"])
        parts += ["NR-ARFCN %d" % f["earfcn"], "SFN %d" % f["sfn"], "SCS %d kHz" % f["scs_khz"]]
    elif rec.log_code == 0xB823:
        parts += ["PLMN %s" % f["plmn"], "TAC %d" % f["tac"], "PCI %d" % f["pci"], "NR-ARFCN %d" % f["dl_earfcn"]]
        if f["band"] is not None:
            parts.append("band n%d" % f["band"])
    elif rec.log_code == 0xB80C:
        parts += [f["state"], "PLMN %s" % f["plmn"], "TAC %d" % f["tac"]]
    elif rec.log_code == 0xB975:
        parts += ["PCI %d" % f["pci"], "SS-RSRP %s" % ("%.1f dBm" % f["rsrp"] if f["rsrp"] is not None else "n/a"),
                  "SS-RSRQ %.1f dB" % f["rsrq"], "%d beams" % f["num_beams"]]
    elif rec.log_code == 0xB97F:
        parts += ["PCI %d" % f["pci"], "NR-ARFCN %d" % f["arfcn"], "%d cells" % f["num_cells"], "%d beams" % f["num_beams"]]
        if f.get("rsrp") is not None:
            parts += ["SS-RSRP %.1f dBm" % f["rsrp"], "SS-RSRQ %.1f dB" % f["rsrq"]]
    elif rec.log_code == 0xB888:
        parts.append("%d records" % f["num_records"] if "num_pdsch_decode" not in f else
                     "%d decodes BLER %.1f %% TB bytes %d" % (f["num_pdsch_decode"], f["bler_pct"], f["tb_bytes"]))
    elif rec.log_code == 0xB883:
        parts += ["%d records" % f["num_records"], "SFN %d" % f["sfn"], "slot %d" % f["slot"]]
    elif rec.log_code == 0xB872:
        if "num_tb" in f:
            parts.append("%d TTIs %d TBs" % (f["num_tti"], f["num_tb"]))
            if "grant_bytes" in f:
                parts.append("grant %d built %d" % (f["grant_bytes"], f["bytes_built"]))
        else:
            parts.append("%d TTIs (records did not fit)" % f["num_tti"])
    return parts


def test_every_record_has_the_python_outcome_and_a_summary(outputs):
    pcapng, diag = outputs
    rows = tshark_mod.fields(pcapng, ["frame.number", "fieldtap.code", "fieldtap.version", "fieldtap.nr.decoded",
                                      "fieldtap.nr.note", "_ws.col.Info"], tshark=TSHARK, lua_scripts=LUA_PLUGIN)
    assert len(rows) == len(diag) == len(_records())
    seen = set()
    for rec, (number, code, version, decoded, note, info) in zip(diag, rows):
        assert int(code, 16) == rec.log_code, number
        assert info.startswith("0x%04X %s" % (rec.log_code, rec.name)), info
        if rec.decoded == "raw":
            assert decoded == "" and note == "" and version == "" and " · " not in info, (number, info)
            continue
        assert int(version) == rec.version, number
        assert decoded == rec.decoded, (number, info)
        assert note == _expected_note(rec), (number, note)
        assert DOC_NOTE in note or IPHONE_NOTE in note or "not implemented" in note, (number, note)
        if rec.log_code in SUMMARIES:
            # tshark's stdout is not always UTF-8 on Windows: compare what follows the "·"
            assert info.partition("·")[2].strip() == SUMMARIES[rec.log_code](rec.fields), (number, info)
        else:
            for part in _summary_parts(rec):
                assert part in info, (number, part, info)
        seen.add((rec.log_code, rec.decoded))
    assert {(0xB822, "fields"), (0xB823, "fields"), (0xB80C, "fields"), (0xB975, "fields"), (0xB97F, "fields"),
            (0xB97F, "partial"), (0xB888, "fields"), (0xB883, "partial"), (0xB872, "fields"), (0xB872, "partial"),
            (0xB823, "partial"), (0xB822, "partial"), (0xB975, "partial"), (0xB888, "partial"),
            (0xB887, "fields"), (0xB887, "partial")} <= seen
    assert [r.decoded for r in diag].count("raw") >= 4      # the misfits stay bare, on both sides


def _top(name):
    return lambda r: [] if r.fields.get(name) is None else [r.fields[name]]


def _rows(section, name):
    return lambda r: [row[name] for row in dict(r.sections).get(section, []) if row.get(name) is not None]


# Lua field -> the Python values it must equal, in occurrence order.
FIELDS = {
    "fieldtap.nr.version": lambda r: [str(r.fields.get("version", r.version))],
    "fieldtap.nr.pci": _top("pci"),
    "fieldtap.nr.arfcn": lambda r: _top("earfcn" if r.log_code == 0xB822 else "arfcn")(r),
    "fieldtap.nr.dl_arfcn": _top("dl_earfcn"), "fieldtap.nr.ul_arfcn": _top("ul_earfcn"),
    "fieldtap.nr.sfn": _top("sfn"), "fieldtap.nr.scs_khz": _top("scs_khz"),
    "fieldtap.nr.dl_bw": _top("dl_bw"), "fieldtap.nr.dl_bw_mhz": _top("dl_bw_mhz"), "fieldtap.nr.ul_bw_mhz": _top("ul_bw_mhz"),
    "fieldtap.nr.cell_id": _top("cell_id"), "fieldtap.nr.nr_cgi": _top("nr_cgi"),
    "fieldtap.nr.mcc": _top("mcc"), "fieldtap.nr.mnc": _top("mnc"), "fieldtap.nr.plmn": _top("plmn"),
    "fieldtap.nr.allowed_access": _top("allowed_access"), "fieldtap.nr.tac": _top("tac"), "fieldtap.nr.band": _top("band"),
    "fieldtap.nr.state": _top("state"), "fieldtap.nr.substate": _top("substate"), "fieldtap.nr.guti_plmn": _top("guti_plmn"),
    "fieldtap.nr.amf_region_id": _top("amf_region_id"), "fieldtap.nr.amf_set_id": _top("amf_set_id"),
    "fieldtap.nr.amf_pointer": _top("amf_pointer"), "fieldtap.nr.tmsi_5g": _top("tmsi_5g"),
    "fieldtap.nr.update_status": _top("update_status"),
    "fieldtap.nr.guti_assigned": lambda r: [] if "guti_assigned" not in r.fields else [int(r.fields["guti_assigned"])],
    "fieldtap.nr.tbs_bytes": _top("tbs_bytes"), "fieldtap.nr.crc_fail": _top("crc_fail"),
    "fieldtap.nr.pdsch_info.frame": _rows("slots", "frame"), "fieldtap.nr.pdsch_info.slot": _rows("slots", "slot"),
    "fieldtap.nr.pdsch_info.pci": _rows("slots", "pci"), "fieldtap.nr.pdsch_info.tbs_bytes": _rows("slots", "tbs_bytes"),
    "fieldtap.nr.pdsch_info.mcs": _rows("slots", "mcs"), "fieldtap.nr.pdsch_info.num_rb": _rows("slots", "num_rb"),
    "fieldtap.nr.pdsch_info.harq_id": _rows("slots", "harq_id"), "fieldtap.nr.pdsch_info.layers": _rows("slots", "layers"),
    "fieldtap.nr.pdsch_info.crc_pass": lambda r: [int(row["crc_pass"]) for row in dict(r.sections).get("slots", [])],
    "fieldtap.nr.rsrp": _top("rsrp"), "fieldtap.nr.rsrq": _top("rsrq"),
    "fieldtap.nr.num_layers": _top("num_layers"), "fieldtap.nr.num_cells": _top("num_cells"),
    "fieldtap.nr.num_beams": _top("num_beams"), "fieldtap.nr.ssb_periodicity": _top("ssb_periodicity"),
    "fieldtap.nr.serving_beam_ssb_index": _top("serving_beam_ssb_index"),
    "fieldtap.nr.freq_offset": _top("freq_offset"), "fieldtap.nr.timing_offset": _top("timing_offset"),
    "fieldtap.nr.time_offset": _top("time_offset"),
    "fieldtap.nr.carrier.arfcn": _rows("carriers", "arfcn"), "fieldtap.nr.carrier.cc_id": _rows("carriers", "cc_id"),
    "fieldtap.nr.carrier.num_cells": _rows("carriers", "num_cells"),
    "fieldtap.nr.carrier.serving_pci": _rows("carriers", "serving_pci"),
    "fieldtap.nr.carrier.serving_ssb": _rows("carriers", "serving_ssb"),
    "fieldtap.nr.carrier.serving_rsrp_rx0": _rows("carriers", "serving_rsrp_rx0"),
    "fieldtap.nr.carrier.serving_rsrp_rx1": _rows("carriers", "serving_rsrp_rx1"),
    "fieldtap.nr.carrier.serving_rsrp_rx0_raw": _rows("carriers", "serving_rsrp_rx0_raw"),
    "fieldtap.nr.carrier.serving_rsrp_rx1_raw": _rows("carriers", "serving_rsrp_rx1_raw"),
    "fieldtap.nr.cell.pci": _rows("cells", "pci"), "fieldtap.nr.cell.sfn": _rows("cells", "pbch_sfn"),
    "fieldtap.nr.cell.num_beams": _rows("cells", "num_beams"),
    "fieldtap.nr.cell.rsrp": _rows("cells", "rsrp"), "fieldtap.nr.cell.rsrq": _rows("cells", "rsrq"),
    "fieldtap.nr.cell.rsrp_raw": _rows("cells", "rsrp_raw"), "fieldtap.nr.cell.rsrq_raw": _rows("cells", "rsrq_raw"),
    "fieldtap.nr.beam.ssb_index": _rows("beams", "ssb_index"), "fieldtap.nr.beam.tx_beam_index": _rows("beams", "tx_beam_index"),
    "fieldtap.nr.beam.rsrp": _rows("beams", "rsrp"), "fieldtap.nr.beam.rsrq": _rows("beams", "rsrq"),
    "fieldtap.nr.beam.rsrp_rx0": _rows("beams", "rsrp_rx0"), "fieldtap.nr.beam.rsrp_rx1": _rows("beams", "rsrp_rx1"),
    "fieldtap.nr.beam.rsrp_l3": _rows("beams", "nr2nr_rsrp_l3"), "fieldtap.nr.beam.rsrq_l3": _rows("beams", "nr2nr_rsrq_l3"),
    "fieldtap.nr.beam.l2_rsrp_l3": _rows("beams", "l2_rsrp_l3"), "fieldtap.nr.beam.l2_rsrq_l3": _rows("beams", "l2_rsrq_l3"),
    "fieldtap.nr.beam.rsrp_rx0_raw": _rows("beams", "rsrp_rx0_raw"), "fieldtap.nr.beam.rsrp_rx1_raw": _rows("beams", "rsrp_rx1_raw"),
    "fieldtap.nr.beam.rsrp_l3_raw": _rows("beams", "nr2nr_rsrp_l3_raw"), "fieldtap.nr.beam.rsrq_l3_raw": _rows("beams", "nr2nr_rsrq_l3_raw"),
    "fieldtap.nr.num_records": _top("num_records"), "fieldtap.nr.sleep": _top("sleep"),
    "fieldtap.nr.beam_change": _top("beam_change"), "fieldtap.nr.signal_change": _top("signal_change"),
    "fieldtap.nr.dl_dyn_cfg_change": _top("dl_dyn_cfg_change"), "fieldtap.nr.dl_config": _top("dl_config"),
    "fieldtap.nr.ul_config": _top("ul_config"), "fieldtap.nr.log_fields_change_bmask": _top("log_fields_change_bmask"),
    "fieldtap.nr.pdsch.carrier_id": _rows("records", "carrier_id"), "fieldtap.nr.pdsch.slots": _rows("records", "num_slots_elapsed"),
    "fieldtap.nr.pdsch.decodes": _rows("records", "num_pdsch_decode"), "fieldtap.nr.pdsch.crc_pass": _rows("records", "num_crc_pass_tb"),
    "fieldtap.nr.pdsch.crc_fail": _rows("records", "num_crc_fail_tb"), "fieldtap.nr.pdsch.retx": _rows("records", "num_retx"),
    "fieldtap.nr.pdsch.ack_as_nack": _rows("records", "ack_as_nack"), "fieldtap.nr.pdsch.harq_failure": _rows("records", "harq_failure"),
    "fieldtap.nr.pdsch.pass_bytes": _rows("records", "crc_pass_tb_bytes"), "fieldtap.nr.pdsch.fail_bytes": _rows("records", "crc_fail_tb_bytes"),
    "fieldtap.nr.pdsch.tb_bytes": _rows("records", "tb_bytes"), "fieldtap.nr.pdsch.padding_bytes": _rows("records", "padding_bytes"),
    "fieldtap.nr.pdsch.retx_bytes": _rows("records", "retx_bytes"), "fieldtap.nr.pdsch.bler_pct": _rows("records", "bler_pct"),
    "fieldtap.nr.slot": _top("slot"), "fieldtap.nr.numerology": _top("numerology"),
    "fieldtap.nr.carrier_rnti_raw": _top("carrier_rnti_raw"), "fieldtap.nr.phychan_mask": _top("phychan_mask"),
    "fieldtap.nr.num_tti": _top("num_tti"), "fieldtap.nr.type2_scell": _top("type2_scell"),
    "fieldtap.nr.type2_other_cell": _top("type2_other_cell"), "fieldtap.nr.num_tb": _top("num_tb"),
    "fieldtap.nr.grant_bytes": _top("grant_bytes"), "fieldtap.nr.bytes_built": _top("bytes_built"), "fieldtap.nr.harq_id": _top("harq_id"),
    "fieldtap.nr.tti.slot": _rows("ttis", "slot"), "fieldtap.nr.tti.sfn": _rows("ttis", "sfn"), "fieldtap.nr.tti.num_tb": _rows("ttis", "num_tb"),
    "fieldtap.nr.tb.harq_id": _rows("tbs", "harq_id"), "fieldtap.nr.tb.numerology": _rows("tbs", "numerology"),
    "fieldtap.nr.tb.carrier_id": _rows("tbs", "carrier_id"), "fieldtap.nr.tb.tb_type": _rows("tbs", "tb_type"),
    "fieldtap.nr.tb.rnti_type": _rows("tbs", "rnti_type"), "fieldtap.nr.tb.grant_bytes": _rows("tbs", "grant_bytes"),
    "fieldtap.nr.tb.bytes_built": _rows("tbs", "bytes_built"), "fieldtap.nr.tb.mce_length": _rows("tbs", "mce_length"),
    "fieldtap.nr.tb.phr_reason": _rows("tbs", "phr_reason"), "fieldtap.nr.tb.bsr_reason": _rows("tbs", "bsr_reason"),
}


def _parse(cell: str) -> list:
    return cell.split(",") if cell else []


def _same(lua, py) -> bool:
    """tshark prints every occurrence as text; compare each in the Python value's own type:
    floats rounded to one decimal, integers exactly (hex or decimal), strings as they are."""
    if len(lua) != len(py):
        return False
    for a, b in zip(lua, py):
        if isinstance(b, float):
            if round(float(a), 1) != round(b, 1):
                return False
        elif isinstance(b, int):
            if int(a, 0) != b:
                return False
        elif b.startswith("0x"):
            if int(a, 16) != int(b, 16):
                return False
        elif a != b:
            return False
    return True


def test_every_field_equals_the_python_value(outputs):
    pcapng, diag = outputs
    names = list(FIELDS)
    rows = tshark_mod.fields(pcapng, ["frame.number"] + names, tshark=TSHARK, lua_scripts=LUA_PLUGIN)
    assert len(rows) == len(diag)
    checked = 0
    for rec, row in zip(diag, rows):
        for name, cell in zip(names, row[1:]):
            expected = [] if rec.decoded == "raw" else FIELDS[name](rec)
            got = _parse(cell)
            assert _same(got, expected), (row[0], name, cell, expected)
            checked += len(expected)
    assert checked > 300


def test_no_malformed_frames(outputs):
    pcapng, _ = outputs
    assert tshark_mod.malformed(pcapng, tshark=TSHARK) == []
    assert tshark_mod.malformed(pcapng, tshark=TSHARK, lua_scripts=LUA_PLUGIN) == []
    assert tshark_mod.malformed(pcapng, tshark=TSHARK, lua_scripts=NR_FIRST) == []


def test_without_the_plugin_the_frames_are_bare_exported_pdus(outputs):
    pcapng, diag = outputs
    rows = tshark_mod.fields(pcapng, ["frame.protocols", "frame.comment"], tshark=TSHARK)
    assert [p for p, _c in rows] == ["exported_pdu"] * len(diag)
    for rec, (_p, comment) in zip(diag, rows):
        assert comment == rec.comment()


def test_load_order_does_not_matter(outputs):
    """The NR file before the core, or after it: the same decode either way."""
    pcapng, diag = outputs
    names = ["fieldtap.nr.decoded", "fieldtap.nr.pci", "fieldtap.nr.rsrp", "_ws.col.Info"]
    core_first = tshark_mod.fields(pcapng, names, tshark=TSHARK, lua_scripts=LUA_PLUGIN)
    nr_first = tshark_mod.fields(pcapng, names, tshark=TSHARK, lua_scripts=NR_FIRST)
    assert core_first == nr_first
    assert core_first[0][0] == diag[0].decoded == "fields" and core_first[0][1] == "417"
