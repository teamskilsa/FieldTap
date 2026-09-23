"""The NR decoders on a real iPhone 17 (M25) capture: the layouts ported from
web/engine/src/phy/decoders/nr.ts must fit every record and give plausible values.

Runs only when FT_REAL_QMDL names a .qmdl (the captures are never committed):

    FT_REAL_QMDL=path/to/2026.09.21_15-41-47.qmdl pytest tests/test_decode_nr_real.py

A code the capture does not hold is skipped, not failed. Nothing here prints a
record body or a subscriber identifier.
"""

import os
from collections import defaultdict

import pytest

from fieldtap import pipeline
from fieldtap.decode import Decoder, DiagRecord
from fieldtap.decode.nr_common import RANGES

QMDL = os.environ.get("FT_REAL_QMDL")
pytestmark = pytest.mark.skipif(not QMDL or not QMDL.lower().endswith(".qmdl") or not os.path.isfile(QMDL),
                                reason="FT_REAL_QMDL does not name a .qmdl")

NR_CODES = (0xB80C, 0xB872, 0xB883, 0xB887, 0xB888, 0xB97F)


class _Grab:
    stats = {}

    def __init__(self):
        self.records = defaultdict(list)

    def write(self, obj):
        if isinstance(obj, DiagRecord) and obj.log_code in NR_CODES:
            self.records[obj.log_code].append(obj)

    def close(self):
        pass

    def flush(self):
        pass

    def report(self):
        return {}


@pytest.fixture(scope="module")
def capture():
    grab = _Grab()
    decoder = Decoder()
    pipeline.replay(QMDL, [grab], decoder)
    return grab.records, decoder.report()


def _records(capture, code):
    records = capture[0].get(code, [])
    if not records:
        pytest.skip("the capture holds no 0x%04X" % code)
    return records


def _in(kind, value):
    lo, hi = RANGES[kind]
    return value is not None and lo <= value <= hi


def test_no_nr_decoder_misses(capture):
    _records, report = capture
    misses = {k: v for k, v in report["errors"].items() if any("0x%04X" % c in k for c in NR_CODES)}
    assert misses == {}
    for code in NR_CODES:
        ways = report["coverage"].get("0x%04X" % code, {}).get("as", {})
        assert "raw" not in ways, (hex(code), ways)


def test_pdsch_info_every_slot_is_a_real_transmission(capture):
    records = _records(capture, 0xB887)
    assert all(r.decoded == "fields" and r.fields["version"] == "3.13" for r in records)
    slots = [row for r in records for row in dict(r.sections)["slots"]]
    assert len(slots) == sum(r.fields["num_records"] for r in records) > 0
    assert len({row["pci"] for row in slots}) <= 2                   # one serving cell, maybe a change
    assert all(_in("pci", row["pci"]) and _in("mcs", row["mcs"]) for row in slots)
    assert all(0 < row["num_rb"] <= 273 and 1 <= row["layers"] <= 4 and row["harq_id"] <= 15 for row in slots)
    assert all(0 < row["tbs_bytes"] < 1 << 18 for row in slots)
    fails = sum(1 for row in slots if not row["crc_pass"])
    assert fails / len(slots) <= 0.30
    # new transmissions carry more resource blocks than the smallest grant; retransmissions use MCS 28-31
    assert max(row["num_rb"] for row in slots) >= 24


def test_pdsch_stats_counters_are_cumulative_and_consistent(capture):
    records = _records(capture, 0xB888)
    assert all(r.decoded == "fields" and r.fields["version"] == "3.1" and r.fields["num_records"] == 1 for r in records)
    rows = [dict(r.sections)["records"][0] for r in records]
    for row in rows:
        assert row["num_crc_pass_tb"] + row["num_crc_fail_tb"] == row["num_pdsch_decode"]
        assert row["crc_pass_tb_bytes"] + row["crc_fail_tb_bytes"] == row["tb_bytes"]
        assert row["bler_pct"] is None or 0.0 <= row["bler_pct"] <= 30.0
    by_carrier = defaultdict(list)
    for row in rows:
        by_carrier[row["carrier_id"]].append(row)
    for series in by_carrier.values():
        for name in ("num_slots_elapsed", "num_pdsch_decode", "tb_bytes"):
            values = [row[name] for row in series]
            assert values == sorted(values), name
    # the per-slot log and the counters describe the same downlink: the bytes 0xB887 saw
    # pass CRC are within a tenth of what the counters grew by over the capture
    info = capture[0].get(0xB887)
    if info and len(rows) > 1:
        seen = sum(row["tbs_bytes"] for r in info for row in dict(r.sections)["slots"] if row["crc_pass"])
        grown = rows[-1]["crc_pass_tb_bytes"] - rows[0]["crc_pass_tb_bytes"]
        if grown:
            assert abs(seen - grown) <= 0.1 * grown + 4096, (seen, grown)


def test_search_meas_serving_cell_is_measured(capture):
    records = _records(capture, 0xB97F)
    assert all(r.decoded == "fields" and r.fields["version"] == "3.0" for r in records)
    assert all("84-byte beam records counted per cell, not read" in r.note for r in records)
    cells = [row for r in records for row in dict(r.sections)["cells"]]
    assert cells and all(_in("pci", c["pci"]) for c in cells)
    # a Q7 word of 0 is "not measured" (None), which a freshly found neighbour can carry
    measured = [c for c in cells if c["rsrp"] is not None]
    assert len(measured) >= 0.9 * len(cells)
    assert all(_in("rsrp", c["rsrp"]) and _in("rsrq", c["rsrq"]) for c in measured)
    assert all(-140.0 <= c["rsrp"] <= -40.0 for c in measured)
    carriers = [row for r in records for row in dict(r.sections)["carriers"]]
    assert all(_in("arfcn", c["arfcn"]) for c in carriers)
    serving = [r for r in records if r.fields.get("rsrp") is not None]
    assert serving, "no record measured its own serving cell"
    assert len({r.fields["pci"] for r in serving}) <= 2


def test_mm5g_state_names_the_operator_and_never_the_tmsi(capture):
    records = _records(capture, 0xB80C)
    for r in records:
        assert r.decoded == "fields" and r.fields["version"] == "3.0"
        assert r.fields["state"] in ("deregistered", "registered_initiated", "registered", "service_request_initiated")
        assert len(r.fields["plmn"]) in (5, 6) and r.fields["plmn"].isdigit()
        assert "tmsi_5g" not in r.fields and "5G-TMSI not reported" in r.note
        assert not any(isinstance(v, str) and v.lower().startswith("0x") and len(v) >= 10 for v in r.fields.values())


@pytest.mark.parametrize("code,version", [(0xB883, "3.26"), (0xB872, "3.17")])
def test_unimplemented_versions_are_partial_not_misses(capture, code, version):
    records = _records(capture, code)
    assert all(r.decoded == "partial" for r in records)
    assert all(r.note == "version %s not implemented; only %s is" % (version, "2.11" if code == 0xB883 else "4")
               for r in records)
