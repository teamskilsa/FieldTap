"""NR MAC / L2 records: 0xB888 MAC PDSCH Stats (DL BLER and bytes), 0xB883 MAC
UL Physical Channel Schedule Report, 0xB872 L2 UL Transport Block (UL bytes).

Layout facts: MobileInsight nr_mac_pdsch_stats.h,
nr_mac_ul_physical_channel_schedule_report.h and nr_l2_ul_tb.h (Apache License
2.0), as restated in docs/research/qualcomm-measurement-log-layouts.md; the
3.1 record of 0xB888 (one more u32 after the carrier id, 16-byte header) is
what this repository's iOS decoder found on an iPhone 17 capture
(ios/FieldTapKit/Sources/FTPhy/Decoders/B888.swift). No code was copied.

Every container is checked by size: header plus the counted records must be
the body, or the layout is not the one applied. 0xB883 is documented as a
heavily bit-packed three-level nest whose carrier count is not given, so only
its header and first slot are read (decoded="partial").

Layout from documentation; confirm on a hardware capture.
"""

from __future__ import annotations

import struct

from ..diag.protocol import LogRecord
from .nr_common import (DOC_NOTE, check_fields, check_rows, diag_record, implausible_note, read_version,
                        version_label)

# The header the two MAC containers share: version pair, six change flags, a change
# bitmask and the record count.
MAC_HEADER_LEN = 16
MAC_HEADER_NAMES = ("sleep", "beam_change", "signal_change", "dl_dyn_cfg_change", "dl_config", "ul_config")


def _mac_header(body: bytes) -> dict:
    fields = dict(zip(MAC_HEADER_NAMES, body[4:10]))
    fields["log_fields_change_bmask"] = struct.unpack_from("<H", body, 12)[0]
    fields["num_records"] = body[15]
    return fields


# --- 0xB888 NR MAC PDSCH Stats ----------------------------------------------------------------

PDSCH_U32_NAMES = ("num_slots_elapsed", "num_pdsch_decode", "num_crc_pass_tb", "num_crc_fail_tb",
                   "num_retx", "ack_as_nack", "harq_failure")
PDSCH_U64_NAMES = ("crc_pass_tb_bytes", "crc_fail_tb_bytes", "tb_bytes", "padding_bytes", "retx_bytes")
# (header length, record length, u32 words between the carrier id and the counters)
PDSCH_22 = (28, 72, 0)          # the documented 2.2 header ends in 12 reserved bytes
PDSCH_22_SHORT = (16, 72, 0)
PDSCH_31 = (16, 76, 1)
PDSCH_CANDIDATES = {(2, 2): [PDSCH_22, PDSCH_22_SHORT], (3, 1): [PDSCH_31]}
PDSCH_PROBE = [PDSCH_31, PDSCH_22_SHORT, PDSCH_22]


def _pdsch_fits(body: bytes, cand: tuple) -> bool:
    header, record, _extra = cand
    return len(body) >= MAC_HEADER_LEN and len(body) == header + body[15] * record


def _pdsch_records(body: bytes, cand: tuple) -> list:
    header, record, extra = cand
    rows = []
    off = header
    for index in range(body[15]):
        row = {"record": index, "carrier_id": struct.unpack_from("<I", body, off)[0]}
        pos = off + 4 + 4 * extra
        row.update(zip(PDSCH_U32_NAMES, struct.unpack_from("<7I", body, pos)))
        row.update(zip(PDSCH_U64_NAMES, struct.unpack_from("<5Q", body, pos + 28)))
        total = row["num_crc_pass_tb"] + row["num_crc_fail_tb"]
        row["bler_pct"] = (100.0 * row["num_crc_fail_tb"] / total) if total else None
        rows.append(row)
        off += record
    return rows


def _pdsch_plausible(rows: list) -> list:
    bad = []
    for row in rows:
        for name in ("num_crc_pass_tb", "num_crc_fail_tb"):
            if row[name] > row["num_pdsch_decode"]:
                bad.append("record[%d].%s" % (row["record"], name))
        for name in ("crc_pass_tb_bytes", "crc_fail_tb_bytes"):
            if row[name] > row["tb_bytes"]:
                bad.append("record[%d].%s" % (row["record"], name))
    return bad


def decode_pdsch_stats(rec: LogRecord, info=None):
    """0xB888 NR MAC PDSCH Stats, major.minor 2.2 and 3.1."""
    body = rec.body
    ver = read_version(body)
    if ver is None or len(body) < MAC_HEADER_LEN:
        return None
    major, minor, raw_version = ver
    known = (major, minor) in PDSCH_CANDIDATES
    fits = [c for c in PDSCH_CANDIDATES.get((major, minor), PDSCH_PROBE) if _pdsch_fits(body, c)]
    if not fits:
        return None
    fields = {"version": version_label(major, minor)}
    fields.update(_mac_header(body))
    notes = []
    decoded = "fields"
    rows = []
    if not known and len(fits) > 1:
        decoded = "partial"
        notes.append("version %s not in the table and more than one record layout fits; header only"
                     % fields["version"])
    else:
        rows = _pdsch_records(body, fits[0])
        bad = _pdsch_plausible(rows)
        if bad:
            decoded = "partial"
            notes.append(implausible_note(bad))
            for row in rows:
                for name in PDSCH_U32_NAMES + PDSCH_U64_NAMES + ("bler_pct",):
                    row[name] = None
        elif rows:
            for name in ("num_pdsch_decode", "num_crc_pass_tb", "num_crc_fail_tb", "tb_bytes", "bler_pct"):
                fields[name] = rows[0][name]
        if not known:
            decoded = "partial"
            notes.append("version %s not in the table; record layout probed by size" % fields["version"])
    notes.append(DOC_NOTE)
    return diag_record(rec, info, "NR MAC PDSCH Stats", raw_version, fields, [("records", rows)], decoded, notes)


# --- 0xB883 NR MAC UL Physical Channel Schedule Report ------------------------------------------

SLOT_LEN = 4
CARRIER_HEADER_LEN = 4


def decode_ul_sched(rec: LogRecord, info=None):
    """0xB883: the container header and the first slot record; the rest is bit-packed
    and its carrier count undocumented, so the record is always "partial"."""
    body = rec.body
    ver = read_version(body)
    if ver is None or len(body) < MAC_HEADER_LEN:
        return None
    major, minor, raw_version = ver
    fields = {"version": version_label(major, minor)}
    fields.update(_mac_header(body))
    notes = []
    if fields["num_records"] and len(body) >= MAC_HEADER_LEN + SLOT_LEN:
        fields["slot"], fields["numerology"] = body[16], body[17]
        fields["sfn"] = struct.unpack_from("<H", body, 18)[0]
        if len(body) >= MAC_HEADER_LEN + SLOT_LEN + CARRIER_HEADER_LEN:
            fields["carrier_rnti_raw"], fields["phychan_mask"] = body[20], body[21]
        bad = check_fields(fields, {"slot": "slot", "numerology": "numerology", "sfn": "sfn"})
        if bad:
            notes.append(implausible_note(bad))
    notes.append("header and first slot only: the per-carrier records are bit-packed and their count "
                 "is not documented")
    notes.append(DOC_NOTE)
    return diag_record(rec, info, "NR MAC UL Physical Channel Schedule Report", raw_version, fields, [],
                       "partial", notes)


# --- 0xB872 NR L2 UL Transport Block ---------------------------------------------------------

UL_TB_VERSION = 4
TTI_LEN = 8
TB_FIXED_LEN = 18          # before the conditional PHR/BSR reason bytes and the MAC-CE payload
TB_KINDS = {"numerology": "numerology", "harq_id": "harq_id", "grant_bytes": "tb_bytes", "bytes_built": "tb_bytes"}


def _walk_ul_tb(body: bytes):
    """-> (ttis, tbs) or None unless the walk consumes the body exactly."""
    num_tti = body[4] & 0xF
    ttis, tbs = [], []
    off = 8
    for tti_index in range(num_tti):
        if len(body) < off + TTI_LEN:
            return None
        slot = body[off]
        sfn = struct.unpack_from("<H", body, off + 2)[0] & 0x3FF
        num_tb = body[off + 4] & 0xF
        ttis.append({"tti": tti_index, "slot": slot, "sfn": sfn, "num_tb": num_tb})
        off += TTI_LEN
        for tb_index in range(num_tb):
            if len(body) < off + TB_FIXED_LEN:
                return None
            b0, b1, b2, b3 = body[off:off + 4]
            grant, built = struct.unpack_from("<II", body, off + 4)
            req_mask, build_mask = body[off + 12], body[off + 13]
            pos = off + 14
            row = {"tti": tti_index, "tb": tb_index, "numerology": b0 & 0x7, "harq_id": (b0 >> 3) & 0xF,
                   "carrier_id": (b0 >> 7) | ((b1 & 0x1) << 1), "tb_type": (b1 >> 1) & 0xF, "rnti_type": b1 >> 5,
                   "start_pdu_segment": b2 & 0x1, "end_pdu_segment": b3 & 0x1,
                   "grant_bytes": grant, "bytes_built": built,
                   "mce_req_bmask": req_mask, "mce_build_bmask": build_mask, "phr_reason": None, "bsr_reason": None}
            if build_mask & 0x1:
                row["phr_reason"] = body[pos]
                pos += 1
            if build_mask & 0x2:
                row["bsr_reason"] = body[pos]
                pos += 1
            if len(body) < pos + 4:
                return None
            row["mce_length"] = body[pos]
            pos += 4
            if len(body) < pos + row["mce_length"]:
                return None
            row["mce_payload"] = body[pos:pos + row["mce_length"]].hex()
            pos += row["mce_length"]
            tbs.append(row)
            off = pos
    if off != len(body):
        return None
    return ttis, tbs


def decode_ul_tb(rec: LogRecord, info=None):
    """0xB872 NR L2 UL Transport Block, version 4."""
    body = rec.body
    if len(body) < 8:
        return None
    version = struct.unpack_from("<I", body, 0)[0]
    fields = {"version": version, "num_tti": body[4] & 0xF, "type2_scell": (body[4] >> 4) & 1,
              "type2_other_cell": (body[4] >> 5) & 1}
    notes = []
    walked = _walk_ul_tb(body)
    if walked is None:
        if version != UL_TB_VERSION:
            return None
        notes.append("TTI/TB records did not fit the documented layout; header only")
        notes.append(DOC_NOTE)
        return diag_record(rec, info, "NR L2 UL Transport Block", version, fields, [], "partial", notes)
    ttis, tbs = walked
    fields["num_tb"] = len(tbs)
    if ttis:
        fields["sfn"], fields["slot"] = ttis[0]["sfn"], ttis[0]["slot"]
    if tbs:
        fields["grant_bytes"] = sum(t["grant_bytes"] for t in tbs)
        fields["bytes_built"] = sum(t["bytes_built"] for t in tbs)
        fields["harq_id"] = tbs[0]["harq_id"]
    bad = check_rows(ttis, {"slot": "slot", "sfn": "sfn"}, "tti")
    bad += check_rows(tbs, TB_KINDS, "tb")
    for row in tbs:
        if row["grant_bytes"] is not None and row["bytes_built"] is not None and row["bytes_built"] > row["grant_bytes"]:
            row["bytes_built"] = None
            bad.append("tb[%d].bytes_built" % row["tb"])
    decoded = "fields"
    if bad:
        decoded = "partial"
        notes.append(implausible_note(bad))
        for name in ("sfn", "slot", "grant_bytes", "bytes_built", "harq_id"):
            fields.pop(name, None)
    if version != UL_TB_VERSION:
        decoded = "partial"
        notes.append("version %d not in the table; read with the version-4 layout, which fits by size" % version)
    notes.append(DOC_NOTE)
    return diag_record(rec, info, "NR L2 UL Transport Block", version, fields, [("ttis", ttis), ("tbs", tbs)],
                       decoded, notes)


DECODERS = {"nr_mac_pdsch_stats": decode_pdsch_stats, "nr_mac_ul_sched": decode_ul_sched, "nr_l2_ul_tb": decode_ul_tb}
