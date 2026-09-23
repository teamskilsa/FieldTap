"""NR ML1 measurement records: 0xB97F Searcher Measurement Database Update Ext
and 0xB975 Serving Cell Beam Management. The NR counterpart of 0xB193: the
SS-RSRP / SS-RSRQ a field engineer reads while walking.

Layout facts: MobileInsight nr_ml1_search_meas_database_update.h and
nr_ml1_serving_cell_beam_mngt.h (Apache License 2.0), as restated in
docs/research/qualcomm-measurement-log-layouts.md. The 3.0 layout of 0xB97F is a
port, field for field, of this repository's TypeScript engine
(web/engine/src/phy/decoders/nr.ts decodeB97F) and iOS decoder
(ios/FieldTapKit/Sources/FTPhy/Decoders/B97F.swift): SCAT's 3.0 field order as
facts only, validated on the iPhone 17 (M25) captures of 2026-09-21/22, where the
walk consumes every record exactly and the cell SS-RSRP is within 0.2 dB of the
NR measurement reports. No code was copied from any of them.

Each record is a container: a header, then per carrier a carrier record, per
carrier its cells, per cell its beams. The layout candidates for a version are
walked in turn and the one that consumes the body exactly is the one reported;
a body no candidate fits stays raw. Measurements of major.minor 2.7 and later
are the Q7 fixed point (nr_common.nr_q7). The 2.6 scaling is flagged by its
own source as an approximation, so 2.6 values are reported raw. Versions 2.9
and 2.10 carry 84-byte beam records nobody has fully documented: their header,
carriers and cells are decoded and the beams skipped by size, decoded="partial".
3.0 carries the same 84-byte beams; there they are counted per cell and skipped,
as nr.ts does, and the record is decoded="fields" because everything it reports
was validated on hardware. The 3.0 carrier's per-Rx serving fields are zero on
the iPhone 17 and are not read; nor is the cell's second u16, which the 2.x
layouts call the PBCH SFN and nr.ts does not read.

2.x layouts from documentation; confirm on a hardware capture.
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from .nr_common import (DOC_NOTE, IPHONE_NOTE, check_fields, check_rows, diag_record, implausible_note, nr_q7,
                        read_version, version_label)

NA16 = 0xFFFF

# --- 0xB97F ------------------------------------------------------------------------------------

CELL_LEN = 16
MAX_BEAMS = 64            # TS 38.213: at most 64 SSBs (L_max) in a burst
CELL_KINDS = {"pci": "pci", "pbch_sfn": "sfn", "rsrp": "rsrp", "rsrq": "rsrq"}
CARRIER_KINDS = {"arfcn": "arfcn", "serving_pci": "pci", "serving_rsrp_rx0": "rsrp", "serving_rsrp_rx1": "rsrp"}
BEAM_KINDS = {"rsrp_rx0": "rsrp", "rsrp_rx1": "rsrp", "nr2nr_rsrp_l3": "rsrp", "nr2nr_rsrq_l3": "rsrq",
              "l2_rsrp_l3": "rsrp", "l2_rsrq_l3": "rsrq"}

# A layout candidate: header length, where the layer count sits, the carrier and beam
# record lengths, how measurements are scaled ("q7" | "raw" | None = not read), the
# carrier record shape ("v2" | "v3"), and the beams: "full" (the 44-byte record read),
# "index" (skipped by size, SSB index kept) or "count" (skipped by size, counted only).
def _cand(header, count_off, carrier, beam, scale, shape="v2", beams="full"):
    return {"header": header, "count_off": count_off, "carrier": carrier, "beam": beam, "scale": scale,
            "shape": shape, "beams": beams}


C26 = _cand(8, 4, 32, 44, "raw")
C27 = _cand(16, 4, 32, 44, "q7")            # header + the 2.7 format subpacket (freq/timing offset)
C27_NOFMT = _cand(8, 4, 32, 44, "q7")
C29 = _cand(16, 4, 32, 84, "q7", beams="index")
C29_NOFMT = _cand(8, 4, 32, 84, "q7", beams="index")
C30 = _cand(20, 8, 40, 84, "q7", shape="v3", beams="count")
CANDIDATES = {
    (2, 6): [C26],
    (2, 7): [C27, C27_NOFMT],
    (2, 9): [C29, C29_NOFMT, C27, C27_NOFMT],
    (2, 10): [C29, C29_NOFMT, C27, C27_NOFMT],
    (3, 0): [C30],
}
PROBE_ORDER = [C30, C27, C29, C27_NOFMT, C29_NOFMT]


def _walk(body: bytes, cand: dict) -> Optional[dict]:
    """Read the container under one candidate layout; None unless it consumes the body exactly."""
    header, carrier_len, beam_len = cand["header"], cand["carrier"], cand["beam"]
    if len(body) < header:
        return None
    scale = nr_q7 if cand["scale"] == "q7" else (lambda raw: raw)
    suffix = "" if cand["scale"] == "q7" else "_raw"
    num_layers = body[cand["count_off"]]
    carriers, cells, beams = [], [], []
    off = header
    for layer in range(num_layers):
        if len(body) < off + carrier_len:
            return None
        arfcn = struct.unpack_from("<I", body, off)[0]
        if cand["shape"] == "v3":
            cc_id, num_cells = body[off + 4], body[off + 5]
            serving_pci = struct.unpack_from("<H", body, off + 6)[0]
            serving_index = body[off + 8]
            # On the iPhone 17 a count of 0 or 0xFF means "see the serving index".
            if num_cells in (0, 0xFF):
                num_cells = serving_index if 0 < serving_index < 0xFF else 0
            carrier = {"layer": layer, "arfcn": arfcn, "cc_id": cc_id, "num_cells": num_cells,
                       "serving_pci": None if serving_pci == NA16 else serving_pci}
        else:
            num_cells, serving_index = body[off + 4], body[off + 5]
            serving_pci, serving_ssb = struct.unpack_from("<HB", body, off + 6)
            rx0, rx1 = struct.unpack_from("<II", body, off + 12)
            beam0, beam1, rfic = struct.unpack_from("<HHH", body, off + 20)
            sub0, sub1 = struct.unpack_from("<HH", body, off + 28)
            carrier = {"layer": layer, "arfcn": arfcn, "num_cells": num_cells, "serving_cell_index": serving_index,
                       "serving_pci": None if serving_pci == NA16 else serving_pci, "serving_ssb": serving_ssb,
                       "serving_rsrp_rx0" + suffix: scale(rx0), "serving_rsrp_rx1" + suffix: scale(rx1),
                       "serving_rx_beam0": None if beam0 == NA16 else beam0,
                       "serving_rx_beam1": None if beam1 == NA16 else beam1,
                       "serving_rfic_id": rfic, "serving_subarray0": sub0, "serving_subarray1": sub1}
        carriers.append(carrier)
        off += carrier_len
        for cell_index in range(num_cells):
            if len(body) < off + CELL_LEN:
                return None
            pci, pbch_sfn, num_beams = struct.unpack_from("<HHB", body, off)
            rsrp, rsrq = struct.unpack_from("<II", body, off + 8)
            cell = {"layer": layer, "cell": cell_index, "pci": pci}
            if cand["shape"] == "v2":
                cell["pbch_sfn"] = pbch_sfn
            cell.update({"num_beams": num_beams, "rsrp" + suffix: scale(rsrp), "rsrq" + suffix: scale(rsrq)})
            cells.append(cell)
            off += CELL_LEN
            if cand["beams"] == "count":
                # nr.ts: the 84-byte beam records are counted, not read
                off += num_beams * beam_len
                if off > len(body):
                    return None
                continue
            for beam_index in range(num_beams):
                if len(body) < off + beam_len:
                    return None
                ssb_index = struct.unpack_from("<H", body, off)[0]
                row = {"layer": layer, "cell": cell_index, "beam": beam_index, "ssb_index": ssb_index}
                if cand["beams"] == "full":
                    b0, b1 = struct.unpack_from("<HH", body, off + 4)
                    row["rx_beam_id0"] = None if b0 == NA16 else b0
                    row["rx_beam_id1"] = None if b1 == NA16 else b1
                    if cand["scale"] == "raw":
                        row["ssb_ref_timing1"], row["ssb_ref_timing2"] = struct.unpack_from("<II", body, off + 12)
                    else:
                        row["ssb_ref_timing"] = struct.unpack_from("<Q", body, off + 12)[0]
                    values = struct.unpack_from("<6I", body, off + 20)
                    for name, raw in zip(("rsrp_rx0", "rsrp_rx1", "nr2nr_rsrp_l3", "nr2nr_rsrq_l3",
                                          "l2_rsrp_l3", "l2_rsrq_l3"), values):
                        row[name + suffix] = scale(raw)
                beams.append(row)
                off += beam_len
    if off != len(body):
        return None
    out = {"num_layers": num_layers, "carriers": carriers, "cells": cells, "beams": beams,
           "num_beams": sum(c["num_beams"] for c in cells)}
    if cand["shape"] == "v2":
        out["ssb_periodicity"] = body[5]
    if cand["header"] == 16:
        out["freq_offset"], out["timing_offset"] = struct.unpack_from("<II", body, 8)
    return out


def decode_search_meas(rec: LogRecord, info=None):
    """0xB97F NR ML1 Searcher Measurement Database Update Ext."""
    body = rec.body
    ver = read_version(body)
    if ver is None:
        return None
    major, minor, raw_version = ver
    known = (major, minor) in CANDIDATES
    walked = None
    for cand in CANDIDATES.get((major, minor), PROBE_ORDER):
        walked = _walk(body, cand)
        if walked is not None:
            break
    if walked is None:
        return None
    carriers, cells, beams = walked["carriers"], walked["cells"], walked["beams"]
    fields = {"version": version_label(major, minor), "num_layers": walked["num_layers"]}
    for key in ("ssb_periodicity", "freq_offset", "timing_offset"):
        if key in walked:
            fields[key] = walked[key]
    fields["num_cells"] = len(cells)
    fields["num_beams"] = walked["num_beams"]
    if carriers:
        fields["arfcn"] = carriers[0]["arfcn"]
        fields["pci"] = carriers[0]["serving_pci"]
        serving = [c for c in cells if c["layer"] == 0 and c["pci"] == fields["pci"]]
        if serving and cand["scale"] == "q7":
            fields["rsrp"], fields["rsrq"] = serving[0]["rsrp"], serving[0]["rsrq"]
    notes = []
    bad = []
    if cand["scale"] == "q7":
        bad += check_fields(fields, {"arfcn": "arfcn", "pci": "pci", "rsrp": "rsrp", "rsrq": "rsrq"})
        bad += check_rows(carriers, CARRIER_KINDS, "carrier")
        bad += check_rows(cells, CELL_KINDS, "cell")
        bad += check_rows(beams, BEAM_KINDS, "beam")
        bad += ["cell[%d].num_beams" % i for i, row in enumerate(cells) if row["num_beams"] > MAX_BEAMS]
    else:
        bad += check_fields(fields, {"arfcn": "arfcn", "pci": "pci"})
        bad += check_rows(carriers, {"arfcn": "arfcn", "serving_pci": "pci"}, "carrier")
        bad += check_rows(cells, {"pci": "pci", "pbch_sfn": "sfn"}, "cell")
        notes.append("2.6 RSRP/RSRQ scaling is unverified: raw values kept")
    bad += check_rows(beams, {"ssb_index": "ssb_index"}, "beam")
    decoded = "fields"
    if bad:
        decoded = "partial"
        notes.insert(0, implausible_note(bad))
    if cand["beams"] == "index":
        decoded = "partial"
        notes.append("%d-byte beam records skipped by size" % cand["beam"])
    elif cand["beams"] == "count":
        notes.append("%d-byte beam records counted per cell, not read" % cand["beam"])
    if not known:
        decoded = "partial"
        notes.append("version %s not in the table; layout probed by size" % fields["version"])
    notes.append(IPHONE_NOTE if cand is C30 else DOC_NOTE)
    sections = [("carriers", carriers), ("cells", cells)]
    if cand["beams"] != "count":
        sections.append(("beams", beams))
    return diag_record(rec, info, "NR ML1 Searcher Measurement DB Update Ext", raw_version, fields, sections,
                       decoded, notes)


# --- 0xB975 ------------------------------------------------------------------------------------

BEAM_HEADER_LEN = 40     # documented as 24 bytes, but its own field table sums to 40
BEAM_RECORD_LENS = (12, 16)   # the documented 2+2+4+4, with or without a trailing reserved u32
BEAM_TABLE = {(2, 1)}
BEAM_ROW_KINDS = {"rsrp": "rsrp", "rsrq": "rsrq"}


def decode_beam_mgmt(rec: LogRecord, info=None):
    """0xB975 NR ML1 Serving Cell Beam Management, major.minor 2.1."""
    body = rec.body
    ver = read_version(body)
    if ver is None or len(body) < BEAM_HEADER_LEN:
        return None
    major, minor, raw_version = ver
    num_beams = body[36]
    beam_len = None
    for candidate in BEAM_RECORD_LENS:
        if BEAM_HEADER_LEN + num_beams * candidate == len(body):
            beam_len = candidate
            break
    if beam_len is None:
        return None
    pci = struct.unpack_from("<H", body, 4)[0]
    rsrp_raw, rsrq_raw = struct.unpack_from("<II", body, 12)
    freq_offset, time_offset = struct.unpack_from("<II", body, 28)
    fields = {
        "version": version_label(major, minor), "pci": pci, "ssb_periodicity": body[8],
        "serving_beam_ssb_index": body[9], "rsrp": nr_q7(rsrp_raw), "rsrq": nr_q7(rsrq_raw),
        "freq_offset": freq_offset, "time_offset": time_offset, "num_beams": num_beams,
    }
    beams = []
    off = BEAM_HEADER_LEN
    for index in range(num_beams):
        tx_beam = struct.unpack_from("<H", body, off)[0]
        rsrp_b, rsrq_b = struct.unpack_from("<II", body, off + 4)
        beams.append({"beam": index, "tx_beam_index": tx_beam, "rsrp": nr_q7(rsrp_b), "rsrq": nr_q7(rsrq_b)})
        off += beam_len
    bad = check_fields(fields, {"pci": "pci", "rsrp": "rsrp", "rsrq": "rsrq"})
    bad += check_rows(beams, BEAM_ROW_KINDS, "beam")
    notes = []
    decoded = "fields"
    if bad:
        decoded = "partial"
        notes.append(implausible_note(bad))
    if (major, minor) not in BEAM_TABLE:
        decoded = "partial"
        notes.append("version %s not in the table; read with the 2.1 layout, which fits by size" % fields["version"])
    if beam_len != 12:
        notes.append("%d-byte beam records" % beam_len)
    notes.append(DOC_NOTE)
    return diag_record(rec, info, "NR ML1 Serving Cell Beam Management", raw_version, fields,
                       [("beams", beams)], decoded, notes)


def _n(value) -> str:
    return "n/a" if value is None else "%d" % value


def _db(value, unit: str) -> str:
    return "n/a" if value is None else "%.1f %s" % (value, unit)


def summary_search_meas(fields: dict) -> str:
    """The Info-column line of 0xB97F; wireshark/fieldtap_nr.lua prints the same."""
    out = "PCI %s NR-ARFCN %s" % (_n(fields.get("pci")), _n(fields.get("arfcn")))
    if fields.get("rsrp") is not None:
        out += " SS-RSRP %s SS-RSRQ %s" % (_db(fields["rsrp"], "dBm"), _db(fields.get("rsrq"), "dB"))
    return out + " %d cells %d beams" % (fields["num_cells"], fields["num_beams"])


def summary_beam_mgmt(fields: dict) -> str:
    return "PCI %s SS-RSRP %s SS-RSRQ %s %d beams" % (_n(fields.get("pci")), _db(fields.get("rsrp"), "dBm"),
                                                      _db(fields.get("rsrq"), "dB"), fields["num_beams"])


DECODERS = {"nr_ml1_search_meas": decode_search_meas, "nr_ml1_beam": decode_beam_mgmt}
SUMMARIES = {0xB97F: summary_search_meas, 0xB975: summary_beam_mgmt}
