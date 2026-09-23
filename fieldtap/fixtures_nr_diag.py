"""Synthetic NR diag records for the NR record decoders (0xB822, 0xB823, 0xB80C,
0xB975, 0xB97F, 0xB888, 0xB883, 0xB872).

The builders pack every layout explicitly and independently of the decoders'
tables, so an accidental edit to one side shows up as a failure. The values are
the ones a real OnePlus 10 Pro logged on a commercial n77 cell (see
android/diag/src/test/resources/oneplus-5g-registration.md): PCI 417, NR-ARFCN
647328, PLMN 311-480, TAC 360102, band n77, SS-RSRP around -90 dBm. What these
records cannot prove is that the layouts match real modems; only hardware
captures do that.
"""

from __future__ import annotations

import math
import struct
from datetime import timedelta

from .diag import protocol
from .fixtures import BASE_TIME

PCI = 417
ARFCN = 647328
TAC = 360102
BAND = 77
MCC, MNC = 311, 480
NCI = 0x2167F401A          # Wireshark shows the 36-bit cellIdentity left-aligned as 2167f401a0


def q7_raw(db: float) -> int:
    """The inverse of the NR ML1 Q7 fixed point: integer part offset by 256 in bits
    7..14, fraction in 1/128 dB in bits 0..6. Only negative values are representable."""
    integer = math.floor(db)
    frac = int(round((db - integer) * 128))
    return ((256 + integer) << 7) | frac


def q7_value(db: float) -> float:
    """What the decoder reads back for q7_raw(db): the fraction snaps to 1/128 dB."""
    integer = math.floor(db)
    return integer + int(round((db - integer) * 128)) * 0.0078125


def _version(major: int, minor: int) -> bytes:
    return struct.pack("<HH", minor, major)


# --- 0xB822 NR RRC MIB Info ----------------------------------------------------------------

def nr_mib_body(major: int = 2, minor: int = 0, pci: int = PCI, arfcn: int = ARFCN, sfn: int = 512,
                scs: int = 1, trailing: bytes = b"") -> bytes:
    """The bit string after PCI and NR-ARFCN is read MSB-first: SFN in bits 0..9, SCS in
    bits 30..31 (four bytes, 0.3) or 31..32 (five bytes, 2.0)."""
    width = 32 if (major, minor) == (0, 3) else 40
    scs_at = 30 if width == 32 else 31
    value = (sfn << (width - 10)) | (scs << (width - scs_at - 2))
    bits = value.to_bytes(width // 8, "big")
    return _version(major, minor) + struct.pack("<HI", pci, arfcn) + bits + trailing


# --- 0xB823 NR RRC Serving Cell Info ---------------------------------------------------------

def nr_serving_cell_body(major: int = 3, minor: int = 0, pci: int = PCI, dl_arfcn: int = ARFCN,
                         ul_arfcn: int = ARFCN, dl_bw: int = 100, ul_bw: int = 100, cell_id: int = NCI,
                         mcc: int = MCC, mnc_digits: int = 3, mnc: int = MNC, allowed_access: int = 0,
                         tac: int = TAC, band: int = BAND, nr_cgi: int = (311480 << 36) | NCI,
                         trailing: bytes = b"") -> bytes:
    tail = struct.pack("<IIHHQHBHBIH", dl_arfcn, ul_arfcn, dl_bw, ul_bw, cell_id, mcc, mnc_digits, mnc,
                       allowed_access, tac, band)
    if (major, minor) == (0, 4):
        head = struct.pack("<H", pci)
    elif (major, minor) in ((3, 2), (3, 3)):     # three bytes before the PCI
        head = b"\xa5\xa5\xa5" + struct.pack("<HQ", pci, nr_cgi)
    else:                                        # 3.0, and what an unlisted version is packed as
        head = struct.pack("<HQ", pci, nr_cgi)
    return _version(major, minor) + head + tail + trailing


# --- 0xB80C NR NAS MM5G State ------------------------------------------------------------------

def plmn_octets(mcc: int, mnc: int, mnc_digits: int = 3) -> bytes:
    """3GPP TS 24.501 PLMN encoding: digit nibbles, MNC digit 3 = 0xF for two-digit MNCs."""
    m = "%03d" % mcc
    n = "%0*d" % (mnc_digits, mnc)
    d = [int(c) for c in m] + ([int(n[2])] if mnc_digits == 3 else [0xF]) + [int(n[0]), int(n[1])]
    return bytes([d[0] | (d[1] << 4), d[2] | (d[3] << 4), d[4] | (d[5] << 4)])


def nr_mm5g_state_body(state: int = 3, substate: int = 0, mcc: int = MCC, mnc: int = MNC, mnc_digits: int = 3,
                       amf_region: int = 1, amf_set: int = 1, amf_pointer: int = 0,
                       tmsi: int = 0x0CC6E898, update_status: int = 0, tac: int = TAC) -> bytes:
    plmn = plmn_octets(mcc, mnc, mnc_digits)
    return (struct.pack("<I", 1) + bytes([state]) + struct.pack("<H", substate) + plmn + bytes([2]) + plmn
            + bytes([amf_region]) + struct.pack(">H", amf_set) + bytes([amf_pointer]) + struct.pack(">I", tmsi)
            + bytes([update_status]) + tac.to_bytes(3, "big"))


# --- 0xB975 NR ML1 Serving Cell Beam Management ------------------------------------------------

def nr_beam_mgmt_body(major: int = 2, minor: int = 1, pci: int = PCI, ssb_periodicity: int = 20,
                      serving_beam: int = 3, rsrp: float = -90.5, rsrq: float = -10.5, freq_offset: int = 120,
                      time_offset: int = 45, beams=((3, -90.5, -10.5), (5, -97.25, -13.0)),
                      beam_len: int = 12) -> bytes:
    head = _version(major, minor) + struct.pack("<HxxBBxxII", pci, ssb_periodicity, serving_beam,
                                                q7_raw(rsrp), q7_raw(rsrq))
    head += bytes(8) + struct.pack("<IIBxxx", freq_offset, time_offset, len(beams))
    out = bytearray(head)
    for tx_beam, b_rsrp, b_rsrq in beams:
        out += struct.pack("<HxxII", tx_beam, q7_raw(b_rsrp), q7_raw(b_rsrq))
        out += bytes(beam_len - 12)
    return bytes(out)


# --- 0xB97F NR ML1 Searcher Measurement Database Update Ext -----------------------------------

def beam(ssb_index: int, rsrp_rx0: float, rsrp_rx1: float, l3_rsrp: float, l3_rsrq: float,
         l2_rsrp: float = None, l2_rsrq: float = None, rx_beam0: int = 0xFFFF, rx_beam1: int = 0xFFFF,
         timing: int = 0x1122334455667788) -> dict:
    return {"ssb_index": ssb_index, "rsrp_rx0": rsrp_rx0, "rsrp_rx1": rsrp_rx1, "l3_rsrp": l3_rsrp,
            "l3_rsrq": l3_rsrq, "l2_rsrp": l3_rsrp if l2_rsrp is None else l2_rsrp,
            "l2_rsrq": l3_rsrq if l2_rsrq is None else l2_rsrq, "rx_beam0": rx_beam0, "rx_beam1": rx_beam1,
            "timing": timing}


def cell(pci: int, sfn: int, rsrp: float, rsrq: float, beams=()) -> dict:
    return {"pci": pci, "sfn": sfn, "rsrp": rsrp, "rsrq": rsrq, "beams": list(beams)}


def carrier(arfcn: int, serving_pci: int, cells=(), serving_index: int = 0, serving_ssb: int = 3,
            rsrp_rx0: float = -91.0, rsrp_rx1: float = -93.5, rx_beam0: int = 0xFFFF, rx_beam1: int = 0xFFFF,
            rfic_id: int = 0, subarray0: int = 0, subarray1: int = 0, cc_id: int = 0) -> dict:
    return {"arfcn": arfcn, "serving_pci": serving_pci, "cells": list(cells), "serving_index": serving_index,
            "serving_ssb": serving_ssb, "rsrp_rx0": rsrp_rx0, "rsrp_rx1": rsrp_rx1, "rx_beam0": rx_beam0,
            "rx_beam1": rx_beam1, "rfic_id": rfic_id, "subarray0": subarray0, "subarray1": subarray1,
            "cc_id": cc_id}


def default_carriers() -> list:
    """One n77 layer: the serving cell PCI 417 with two beams, a neighbour with one."""
    return [carrier(ARFCN, PCI, [
        cell(PCI, 512, -90.0, -10.5, [beam(3, -90.5, -92.25, -90.0, -10.5), beam(5, -97.0, -99.5, -97.25, -13.0)]),
        cell(418, 513, -101.75, -15.0, [beam(1, -102.0, -103.5, -101.75, -15.0)]),
    ])]


def raw26(db: float) -> int:
    """A stand-in for the 2.6 measurement word, whose scaling is unverified: the decoder
    reports it untouched, so any integer will do; this one keeps -90 dBm and -91 apart."""
    return int(round(-db * 128))


def _meas(value, raw: bool) -> int:
    """A measurement as the 2.6 layout (raw integer) or the 2.7+ Q7 word packs it."""
    return raw26(value) if raw else q7_raw(value)


def nr_search_meas_body(major: int = 2, minor: int = 7, carriers=None, ssb_periodicity: int = 20,
                        with_fmt: bool = None, freq_offset: int = 120, timing_offset: int = 45,
                        raw: bool = None) -> bytes:
    """2.6: 8-byte header, 32-byte carriers, 16-byte cells, 44-byte beams, raw measurements.
    2.7: the same after an 8-byte format subpacket, Q7 measurements.
    2.9 / 2.10: as 2.7 with 84-byte beams. 3.0: 20-byte header (layers at 8), 40-byte
    carriers (cc id at 4, cells at 5), 84-byte beams."""
    carriers = default_carriers() if carriers is None else carriers
    v = (major, minor)
    raw = (v == (2, 6)) if raw is None else raw
    if with_fmt is None:
        with_fmt = v not in ((2, 6), (3, 0))
    beam_len = 44 if v in ((2, 6), (2, 7)) else 84
    out = bytearray()
    if v == (3, 0):
        out += _version(major, minor) + bytes(4) + bytes([len(carriers)]) + bytes(11)
    else:
        out += _version(major, minor) + struct.pack("<BBxx", len(carriers), ssb_periodicity)
        if with_fmt:
            out += struct.pack("<II", freq_offset, timing_offset)
    for c in carriers:
        if v == (3, 0):
            out += struct.pack("<IBBHB", c["arfcn"], c["cc_id"], len(c["cells"]), c["serving_pci"], c["serving_index"])
            out += bytes(40 - 9)
        else:
            out += struct.pack("<IBBHBxxx", c["arfcn"], len(c["cells"]), c["serving_index"], c["serving_pci"],
                               c["serving_ssb"])
            out += struct.pack("<II", _meas(c["rsrp_rx0"], raw), _meas(c["rsrp_rx1"], raw))
            out += struct.pack("<HHHxxHH", c["rx_beam0"], c["rx_beam1"], c["rfic_id"], c["subarray0"], c["subarray1"])
        for ce in c["cells"]:
            out += struct.pack("<HHBxxxII", ce["pci"], ce["sfn"], len(ce["beams"]), _meas(ce["rsrp"], raw),
                               _meas(ce["rsrq"], raw))
            for b in ce["beams"]:
                rec = struct.pack("<HxxHHxxxxQ", b["ssb_index"], b["rx_beam0"], b["rx_beam1"], b["timing"])
                rec += struct.pack("<II", _meas(b["rsrp_rx0"], raw), _meas(b["rsrp_rx1"], raw))
                rec += bytes(beam_len - 44)
                rec += struct.pack("<IIII", _meas(b["l3_rsrp"], raw), _meas(b["l3_rsrq"], raw),
                                   _meas(b["l2_rsrp"], raw), _meas(b["l2_rsrq"], raw))
                assert len(rec) == beam_len
                out += rec
    return bytes(out)


# --- 0xB888 NR MAC PDSCH Stats -----------------------------------------------------------------

def pdsch_record(carrier_id: int = 0, slots: int = 2000, decodes: int = 1500, crc_pass: int = 1470,
                 crc_fail: int = 30, retx: int = 28, ack_as_nack: int = 1, harq_failure: int = 0,
                 pass_bytes: int = 4_400_000, fail_bytes: int = 90_000, tb_bytes: int = 4_490_000,
                 padding_bytes: int = 120_000, retx_bytes: int = 84_000) -> dict:
    return dict(carrier_id=carrier_id, slots=slots, decodes=decodes, crc_pass=crc_pass, crc_fail=crc_fail,
                retx=retx, ack_as_nack=ack_as_nack, harq_failure=harq_failure, pass_bytes=pass_bytes,
                fail_bytes=fail_bytes, tb_bytes=tb_bytes, padding_bytes=padding_bytes, retx_bytes=retx_bytes)


def _mac_header(major: int, minor: int, num_records: int, flags=(0, 1, 0, 0, 1, 1), bmask: int = 0x0003) -> bytes:
    return _version(major, minor) + bytes(flags) + bytes(2) + struct.pack("<H", bmask) + bytes([0, num_records])


def nr_pdsch_stats_body(major: int = 3, minor: int = 1, records=None, header_len: int = None,
                        flags=(0, 1, 0, 0, 1, 1), bmask: int = 0x0003) -> bytes:
    """2.2: 28-byte header (12 reserved bytes after the count), 72-byte records.
    3.1: 16-byte header, 76-byte records with an extra u32 after the carrier id."""
    records = [pdsch_record()] if records is None else records
    v31 = (major, minor) == (3, 1)
    if header_len is None:
        header_len = 16 if v31 else 28
    out = bytearray(_mac_header(major, minor, len(records), flags, bmask))
    out += bytes(header_len - 16)
    for r in records:
        out += struct.pack("<I", r["carrier_id"])
        if v31:
            out += struct.pack("<I", 0xDEADBEEF)
        out += struct.pack("<7I", r["slots"], r["decodes"], r["crc_pass"], r["crc_fail"], r["retx"],
                           r["ack_as_nack"], r["harq_failure"])
        out += struct.pack("<5Q", r["pass_bytes"], r["fail_bytes"], r["tb_bytes"], r["padding_bytes"], r["retx_bytes"])
    return bytes(out)


# --- 0xB883 NR MAC UL Physical Channel Schedule Report ------------------------------------------

def nr_ul_sched_body(major: int = 2, minor: int = 11, num_records: int = 1, slot: int = 7, numerology: int = 1,
                     frame: int = 512, carrier_rnti: int = 0x20, phychan: int = 0x01, rest: bytes = bytes(72)) -> bytes:
    out = _mac_header(major, minor, num_records)
    out += struct.pack("<BBH", slot, numerology, frame) + bytes([carrier_rnti, phychan, 0, 0]) + rest
    return out


# --- 0xB872 NR L2 UL Transport Block ---------------------------------------------------------

def ul_tb(harq: int = 2, numerology: int = 1, carrier: int = 0, tb_type: int = 0, rnti_type: int = 0,
          grant: int = 1024, built: int = 1000, req_mask: int = 0, build_mask: int = 0, phr_reason: int = 0,
          bsr_reason: int = 0, mce_payload: bytes = b"", start_segment: int = 0, end_segment: int = 0) -> dict:
    return dict(harq=harq, numerology=numerology, carrier=carrier, tb_type=tb_type, rnti_type=rnti_type,
                grant=grant, built=built, req_mask=req_mask, build_mask=build_mask, phr_reason=phr_reason,
                bsr_reason=bsr_reason, mce_payload=mce_payload, start_segment=start_segment, end_segment=end_segment)


def ul_tti(slot: int = 7, sfn: int = 512, tbs=None) -> dict:
    return {"slot": slot, "sfn": sfn, "tbs": [ul_tb()] if tbs is None else list(tbs)}


def nr_ul_tb_body(version: int = 4, ttis=None, type2_scell: int = 0, type2_other: int = 0) -> bytes:
    """Version u32; count byte (low 4 bits, bit 4 type-2 SCell, bit 5 type-2 other cell);
    8-byte TTI records; TB records of 18 bytes plus the PHR/BSR reason bytes the build
    bitmask announces plus the MAC-CE payload."""
    ttis = [ul_tti()] if ttis is None else ttis
    out = bytearray(struct.pack("<I", version))
    out += bytes([len(ttis) | (type2_scell << 4) | (type2_other << 5), 0, 0, 0])
    for t in ttis:
        out += struct.pack("<BxHBxxx", t["slot"], t["sfn"], len(t["tbs"]))
        for tb in t["tbs"]:
            b0 = tb["numerology"] | (tb["harq"] << 3) | ((tb["carrier"] & 1) << 7)
            b1 = (tb["carrier"] >> 1) | (tb["tb_type"] << 1) | (tb["rnti_type"] << 5)
            out += bytes([b0, b1, tb["start_segment"], tb["end_segment"]])
            out += struct.pack("<II", tb["grant"], tb["built"]) + bytes([tb["req_mask"], tb["build_mask"]])
            if tb["build_mask"] & 1:
                out += bytes([tb["phr_reason"]])
            if tb["build_mask"] & 2:
                out += bytes([tb["bsr_reason"]])
            out += bytes([len(tb["mce_payload"]), 0, 0, 0]) + tb["mce_payload"]
    return bytes(out)


# --- the NR record corpus, for the pcap / tshark round trip ------------------------------------

def build_nr_corpus() -> list:
    """-> [(code, timestamp_raw, body)], one record per layout the decoders know."""
    t = [BASE_TIME + timedelta(seconds=30)]

    def ts():
        t[0] += timedelta(milliseconds=20)
        return protocol.qc_timestamp_from_datetime(t[0])

    records = [
        (0xB822, ts(), nr_mib_body(2, 0)),
        (0xB822, ts(), nr_mib_body(0, 3, sfn=1023, scs=3)),
        (0xB823, ts(), nr_serving_cell_body(3, 0)),
        (0xB823, ts(), nr_serving_cell_body(0, 4)),
        (0xB823, ts(), nr_serving_cell_body(3, 2)),
        (0xB80C, ts(), nr_mm5g_state_body()),
        (0xB975, ts(), nr_beam_mgmt_body()),
        (0xB975, ts(), nr_beam_mgmt_body(beam_len=16)),
        (0xB97F, ts(), nr_search_meas_body(2, 7)),
        (0xB97F, ts(), nr_search_meas_body(2, 6)),
        (0xB97F, ts(), nr_search_meas_body(3, 0)),
        (0xB888, ts(), nr_pdsch_stats_body(3, 1)),
        (0xB888, ts(), nr_pdsch_stats_body(2, 2)),
        (0xB883, ts(), nr_ul_sched_body()),
        (0xB872, ts(), nr_ul_tb_body()),
    ]
    return records
