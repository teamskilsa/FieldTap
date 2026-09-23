"""The iPhone 17 (M25) layouts on a real capture: with FT_REAL_QMDL pointing at one of the
2026-09-21/22 .qmdl files (never committed), replay it and check that the ported decoders
read (nearly) every record and that what they read is physically plausible. Skipped
otherwise. Nothing here prints or stores a subscriber identifier."""

from __future__ import annotations

import os
from collections import defaultdict

import pytest

from fieldtap import pipeline
from fieldtap.decode import Decoder, DiagRecord

QMDL = os.environ.get("FT_REAL_QMDL", "")
pytestmark = pytest.mark.skipif(not QMDL or not os.path.isfile(QMDL), reason="FT_REAL_QMDL not set")

# the AT&T cells of both captures: bands 12, 2, 30 and 66 (downlink EARFCNs and the uplinks of the serving ones)
PCIS = {80, 235}
EARFCNS = {650, 975, 5110, 9820, 67086}
UL_EARFCNS = {18650, 23110, 132622}

# the ported codes and the share of their records that must decode as "fields"
PORTED = {0xB193: 0.99, 0xB179: 0.95, 0xB173: 0.99, 0xB139: 0.99, 0xB063: 0.99, 0xB064: 0.95, 0xB062: 0.99,
          0xB14E: 0.99, 0xB14D: 0.99, 0xB126: 0.99, 0xB12A: 0.99, 0xB16C: 0.99, 0x184C: 0.99, 0x1D0B: 0.99}


class _Grab:
    stats: dict = {}

    def __init__(self):
        self.records = defaultdict(list)

    def write(self, obj):
        if isinstance(obj, DiagRecord):
            self.records[obj.log_code].append(obj)

    def flush(self):
        pass

    def close(self):
        pass

    def report(self):
        return {}


@pytest.fixture(scope="module")
def records():
    grab = _Grab()
    decoder = Decoder()
    pipeline.replay(QMDL, [grab], decoder)
    assert decoder.report()["stats"]["errors"] == 0
    return grab.records


def _share(recs, low, high, key=None, rows=None):
    """Fraction of the values inside [low, high]; values come from fields[key] or from section rows."""
    values = []
    for rec in recs:
        if rows:
            values += [r.get(key) for r in dict(rec.sections).get(rows, [])]
        else:
            values.append(rec.fields.get(key))
    values = [v for v in values if v is not None]
    assert values, key
    return sum(1 for v in values if low <= v <= high) / len(values), sorted(values)[len(values) // 2]


def _fields(recs):
    return [r for r in recs if r.decoded == "fields"]


def _need(records, code):
    """The decoded records of `code`, or a skip when the capture holds none."""
    if not records[code]:
        pytest.skip("0x%04X not in this capture" % code)
    return _fields(records[code])


# --- TS 36.212 5.1.2: a transport block size is one whose TB + CRC segments into turbo code blocks without filler

_K = list(range(40, 513, 8)) + list(range(528, 1025, 16)) + list(range(1056, 2049, 32)) + list(range(2112, 6145, 64))


def tbs_is_valid(bits: int) -> bool:
    b = bits + 24
    if b <= 6144:
        return b in _K
    c = -(-b // 6120)
    b += c * 24
    k_plus = min(k for k in _K if c * k >= b)
    k_minus = max(k for k in _K if k < k_plus)
    c_minus = (c * k_plus - b) // (k_plus - k_minus)
    c_plus = c - c_minus
    return c_plus * k_plus + c_minus * k_minus - b == 0


def test_the_turbo_segmentation_check_knows_the_table():
    assert all(tbs_is_valid(bits) for bits in (16, 56, 144, 328, 1736, 2792, 6200, 12960, 75376))
    assert not any(tbs_is_valid(bits) for bits in (60, 100, 6208))


@pytest.mark.parametrize("code", sorted(PORTED))
def test_ported_codes_decode_nearly_every_record(records, code):
    recs = records[code]
    if not recs:
        pytest.skip("0x%04X not in this capture" % code)
    share = len(_fields(recs)) / len(recs)
    assert share >= PORTED[code], "0x%04X: %d of %d records decoded (%s)" % (
        code, len(_fields(recs)), len(recs), sorted({r.note for r in recs if r.decoded != "fields"})[:3])
    assert all("iPhone 17 (M25) captures" in r.note for r in _fields(recs))


def test_serving_cell_measurements_are_the_att_cells(records):
    recs = _fields(records[0xB193])
    assert {r.fields["pci"] for r in recs} <= PCIS and {r.fields["earfcn"] for r in recs} <= EARFCNS
    assert all(r.fields["subpacket_version"] == 66 and r.fields["snr"] is None for r in recs)
    share, median = _share(recs, -130.0, -85.0, "rsrp")
    assert share >= 0.99 and -125.0 <= median <= -90.0
    share, median = _share(recs, -25.0, -3.0, "rsrq")
    assert share >= 0.95 and -20.0 <= median <= -5.0
    share, _ = _share(recs, -110.0, -40.0, "rssi")
    assert share >= 0.99
    share, _ = _share(recs, -135.0, -80.0, "rsrp", rows="cells")
    assert share >= 0.98
    assert {r.fields["num_rx"] for r in recs} <= {1, 2, 3, 4}
    # every per-Rx value is either measured (the Rx map says so) or absent
    for r in recs[:500]:
        for row in dict(r.sections)["cells"]:
            for i in range(4):
                if not (row["rx_map"] >> i) & 1:
                    assert row["rsrp_rx%d" % i] is None


def test_intra_frequency_measurements_agree_with_the_serving_cell(records):
    recs = _fields(records[0xB179])
    assert {r.fields["pci"] for r in recs} <= PCIS and EARFCNS & {r.fields["earfcn"] for r in recs}
    share, median = _share(recs, -130.0, -85.0, "rsrp")
    assert share >= 0.99 and -125.0 <= median <= -90.0
    share, _ = _share(recs, -25.0, -3.0, "rsrq")
    assert share >= 0.95
    assert all(0 <= r.fields["sfn"] <= 1023 and 0 <= r.fields["subframe"] <= 9 for r in recs)
    assert all(r.timestamp is None for r in records[0xB179])            # no DIAG timestamp on v56
    share, _ = _share(recs, -135.0, -80.0, "rsrp", rows="neighbours")
    assert share >= 0.98
    # the length identity is the framing: the few records it rejects are raw, never misread
    assert all(r.decoded in ("fields", "raw") for r in records[0xB179])


def test_pdsch_transport_blocks_are_real_tbs_values(records):
    recs = _fields(records[0xB173])
    tbs = [tb for r in recs for tb in dict(r.sections)["transport_blocks"]]
    assert tbs
    valid = sum(1 for tb in tbs if tbs_is_valid(8 * tb["tb_size"])) / len(tbs)
    assert valid >= 0.98, valid
    assert all(0 <= row["sfn"] <= 1023 and 0 <= row["subframe"] <= 9 for r in recs for row in dict(r.sections)["records"])
    assert all(tb["mcs"] <= 31 and tb["num_rbs"] <= 50 and tb["qm"] in (2, 4, 6, 8) for tb in tbs)
    assert {tb["rnti_type_name"] for tb in tbs} <= {"C-RNTI", "SI-RNTI", "P-RNTI", "RA-RNTI", "Temp C-RNTI", "SPS C-RNTI"}
    assert all(r.fields["crc_pass"] + r.fields["crc_fail"] == r.fields["num_tb"] for r in recs)


def test_pusch_reports_fit_a_10_mhz_cell(records):
    recs = _fields(records[0xB139])
    assert {r.fields["serving_cell_id"] for r in recs} <= PCIS
    grants = [g for r in recs for g in dict(r.sections)["grants"]]
    assert all(0 <= g["tti"] <= 10239 and 0 <= g["sfn"] <= 1023 for g in grants)
    share, _ = _share(recs, 1, 50, "num_rbs", rows="grants")
    assert share >= 0.99
    share, median = _share(recs, 0.0, 50.0, "required_power_dbm", rows="grants")   # before Pcmax capping
    assert share >= 0.99 and 5.0 <= median <= 45.0
    assert {g["modulation"] for g in grants} <= {"QPSK", "16QAM", "64QAM", "256QAM"}


def test_mac_downlink_blocks_and_uplink_headroom(records):
    dl = _fields(records[0xB063])
    blocks = [b for r in dl for b in dict(r.sections)["transport_blocks"]]
    assert blocks and all(1 <= b["size_bytes"] <= 9422 and b["sfn"] <= 1023 and b["subframe"] <= 9 for b in blocks)
    assert sum(r.fields["walk_exact"] for r in dl) / len(dl) >= 0.4      # the tail rule reaches about 80% of the blocks
    assert all(r.mac_pdus == [] for r in dl)
    ul = _fields(records[0xB064])
    samples = [s for r in ul for s in dict(r.sections)["samples"]]
    assert samples and all(s["sfn"] <= 1023 and s["subframe"] <= 9 for s in samples)
    assert sum(s["header_consistent"] for s in samples) / len(samples) >= 0.95
    phr = [s["power_headroom_db"] for s in samples if "power_headroom_db" in s]
    assert phr and all(-23 <= p <= 40 for p in phr)
    assert all(r.mac_pdus for r in ul)


def test_rach_attempts_target_the_uplink_of_the_serving_cell(records):
    recs = _need(records, 0xB062)
    assert recs and {r.fields["ul_earfcn"] for r in recs} <= UL_EARFCNS
    assert all(0 <= r.fields["preamble"] <= 63 and -130 <= r.fields["preamble_target_dbm"] <= -80 for r in recs)
    assert all(r.fields["ta_rar"] is None or 0 <= r.fields["ta_rar"] <= 1282 for r in recs)


def test_channel_state_feedback(records):
    for code in (0xB14E, 0xB14D):
        recs = _fields(records[code])
        assert recs and all(r.fields["sfn"] <= 1023 and r.fields["subframe"] <= 9 for r in recs)
        assert all(r.fields["tx_mode"] == 4 for r in recs)                  # the RRC's tm4
        assert all(1 <= r.fields["ri"] <= 4 for r in recs if "ri" in r.fields)
        assert all(r.fields["cqi_cw0"] <= 15 for r in recs if "cqi_cw0" in r.fields)
    assert {r.fields["report_type"] for r in _fields(records[0xB14D])} <= {1, 2, 3, 4}


def test_ll1_per_subframe_reports(records):
    demapper = _fields(records[0xB126])
    assert demapper and all(r.fields["tx_antennas"] in (1, 2, 4) and 1 <= r.fields["rank"] <= 4 for r in demapper)
    share, _ = _share(demapper, 1, 50, "num_prb", rows="demapper")
    assert share >= 0.99
    pcfich = _fields(records[0xB12A])
    assert pcfich and sum(1 for r in pcfich if r.fields["num_consistent"] == 20) / len(pcfich) >= 0.99
    assert all(r.fields["cfi1"] + r.fields["cfi2"] + r.fields["cfi3"] == r.fields["num_decoded"] for r in pcfich)
    dci = _fields(records[0xB16C])
    assert dci and sum(r.fields["walk_exact"] for r in dci) / len(dci) >= 0.99
    share, _ = _share(dci, 1, 50, "num_rbs", rows="ul_grants")
    assert share >= 0.99


def test_front_end_and_clock_records(records):
    agc = _need(records, 0x184C)
    chains = [c for r in agc for c in dict(r.sections)["chains"] if c["live"]]
    assert chains and all(-70.0 < c["tx_power_dbm"] <= 35.0 for c in chains)
    assert all(10.0 <= c["limit0_dbm"] <= 30.0 for c in chains)
    assert sum(r.fields["subframes_in_range"] for r in agc) == sum(r.fields["num_blocks"] for r in agc)
    clocks = _need(records, 0x1D0B)
    seq = [r.fields["sequence"] for r in clocks]
    steps = [b - a for a, b in zip(seq, seq[1:])]
    assert steps and sum(1 for s in steps if s == 1) / len(steps) >= 0.95
    ticks = [r.fields["ticks_1024hz"] for r in clocks]
    assert all(b >= a for a, b in zip(ticks, ticks[1:]))
