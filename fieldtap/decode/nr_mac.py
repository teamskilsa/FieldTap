"""NR MAC / L2 records: 0xB887 MAC PDSCH Info (per-slot TBS, MCS, CRC), 0xB888
MAC PDSCH Stats (cumulative DL counters, BLER), 0xB883 MAC UL Physical Channel
Schedule Report, 0xB872 L2 UL Transport Block (UL bytes).

Layout facts:

- 0xB887 3.13 and 0xB888 3.1 are ports, field for field, of this repository's
  TypeScript engine (web/engine/src/phy/decoders/nr.ts decodeB887 / decodeB888)
  and iOS decoders (ios/FieldTapKit/Sources/FTPhy/Decoders/B887.swift,
  B888.swift), whose positions were derived and validated on the iPhone 17 (M25)
  captures of 2026-09-21/22: 0xB887's TBS against TS 38.214 5.1.3.2 on every new
  transmission, its per-slot sums against the 0xB888 counters; 0xB888's identities
  pass + fail = decodes and pass bytes + fail bytes = TB bytes in 602 of 602
  records. 0xB887 has no public layout; 0xB888 3.1 is the MobileInsight 2.2 field
  order (Apache License 2.0) with one extra u32 after the carrier id and a
  different 16-byte header.
- 0xB888 2.2, 0xB883 2.11 and 0xB872 4 are the MobileInsight layouts
  (nr_mac_pdsch_stats.h, nr_mac_ul_physical_channel_schedule_report.h,
  nr_l2_ul_tb.h; Apache License 2.0) as restated in
  docs/research/qualcomm-measurement-log-layouts.md. No code was copied.

Every container is checked by size: header plus the counted records must be
the body, or the layout is not the one applied. 0xB883 3.26 and 0xB872 3.17,
the versions the iPhone 17 logs, have no implemented layout
(docs/research/iphone-named-log-codes.md: 0xB883's payload failed every
identity check); such a record is returned decoded="partial" with a note that
names the version, so the coverage table counts a known-unimplemented version
rather than a layout miss.
"""

from __future__ import annotations

import struct

from ..diag.protocol import LogRecord
from .nr_common import (DOC_NOTE, IPHONE_NOTE, check_fields, check_rows, diag_record, implausible_note,
                        read_version, version_label)

# The header the documented MAC containers share (0xB888 2.2, 0xB883 2.11): version pair,
# six change flags, a change bitmask and the record count.
MAC_HEADER_LEN = 16
MAC_HEADER_NAMES = ("sleep", "beam_change", "signal_change", "dl_dyn_cfg_change", "dl_config", "ul_config")


def _mac_header(body: bytes) -> dict:
    fields = dict(zip(MAC_HEADER_NAMES, body[4:10]))
    fields["log_fields_change_bmask"] = struct.unpack_from("<H", body, 12)[0]
    fields["num_records"] = body[15]
    return fields


def _bits(word: int, shift: int, width: int) -> int:
    return (word >> shift) & ((1 << width) - 1)


def _n(value) -> str:
    """A headline number for the Info line; "n/a" when it failed plausibility."""
    return "n/a" if value is None else "%d" % value


# --- 0xB887 NR MAC PDSCH Info ------------------------------------------------------------------

INFO_VERSION = (3, 13)
INFO_HEADER_LEN = 8
INFO_RECORD_LEN = 44
INFO_ROW_KINDS = {"pci": "pci", "frame": "sfn", "slot": "slot", "tbs_bytes": "tb_bytes", "mcs": "mcs",
                  "num_rb": "num_rb", "harq_id": "harq_id", "layers": "layers"}


def decode_pdsch_info(rec: LogRecord, info=None):
    """0xB887 NR MAC PDSCH Info, major.minor 3.13: one row per PDSCH slot.

    8-byte header (u8 record count @7); 44-byte records: u32 @8 frame bits 5-14, slot
    bits 15-19; u16 @12 & 0x3FF PCI; u32 @16 TBS bytes bits 5-22, MCS bits 26-30; u32 @20
    nRB bits 0-7, HARQ bits 11-14, layers-1 bits 29-30; byte @24 bit 0 CRC pass. The
    widths are the ones nr.ts settled on with the wider n77 carrier (217 PRB, 4 layers)
    of the second capture; w4 bit 23 is a flag, not TBS."""
    body = rec.body
    ver = read_version(body)
    if ver is None or len(body) < INFO_HEADER_LEN:
        return None
    major, minor, raw_version = ver
    fields = {"version": version_label(major, minor)}
    if (major, minor) != INFO_VERSION:
        return diag_record(rec, info, "NR MAC PDSCH Info", raw_version, fields, [], "partial",
                           ["version %s not implemented; only 3.13 is" % fields["version"]])
    num_records = body[7]
    if len(body) != INFO_HEADER_LEN + num_records * INFO_RECORD_LEN:
        return None
    rows = []
    for index in range(num_records):
        off = INFO_HEADER_LEN + index * INFO_RECORD_LEN
        w2, w4, w5 = (struct.unpack_from("<I", body, off + at)[0] for at in (8, 16, 20))
        rows.append({
            "record": index,
            "frame": _bits(w2, 5, 10), "slot": _bits(w2, 15, 5),
            "pci": struct.unpack_from("<H", body, off + 12)[0] & 0x3FF,
            "tbs_bytes": _bits(w4, 5, 18), "mcs": _bits(w4, 26, 5),
            "num_rb": _bits(w5, 0, 8), "harq_id": _bits(w5, 11, 4), "layers": _bits(w5, 29, 2) + 1,
            "crc_pass": (body[off + 24] & 1) == 1,
        })
    bad = check_rows(rows, INFO_ROW_KINDS, "slot")
    fields["num_records"] = num_records
    if rows:
        fields["pci"] = rows[0]["pci"]
        fields["sfn"], fields["slot"] = rows[0]["frame"], rows[0]["slot"]
    fields["tbs_bytes"] = sum(r["tbs_bytes"] or 0 for r in rows)
    fields["crc_fail"] = sum(1 for r in rows if not r["crc_pass"])
    notes = []
    decoded = "fields"
    if bad:
        decoded = "partial"
        notes.append(implausible_note(bad))
    notes.append(IPHONE_NOTE)
    return diag_record(rec, info, "NR MAC PDSCH Info", raw_version, fields, [("slots", rows)], decoded, notes)


def summary_pdsch_info(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_nr.lua prints the same."""
    if "num_records" not in fields:
        return "version %s not implemented" % fields["version"]
    return "%d slots PCI %s TBS %d bytes CRC fail %d" % (fields["num_records"], _n(fields.get("pci")),
                                                          fields["tbs_bytes"], fields["crc_fail"])


# --- 0xB888 NR MAC PDSCH Stats ----------------------------------------------------------------

PDSCH_U32_NAMES = ("num_slots_elapsed", "num_pdsch_decode", "num_crc_pass_tb", "num_crc_fail_tb",
                   "num_retx", "ack_as_nack", "harq_failure")
PDSCH_U64_NAMES = ("crc_pass_tb_bytes", "crc_fail_tb_bytes", "tb_bytes", "padding_bytes", "retx_bytes")
# (header length, record length, u32 words between the carrier id and the counters, record-count offset)
PDSCH_22 = (28, 72, 0, 15)          # the documented 2.2 header ends in 12 reserved bytes
PDSCH_22_SHORT = (16, 72, 0, 15)
# 3.1 (nr.ts / B888.swift): 16-byte header whose count is the u8 @12 (u32 @4 and a running
# u32 @8 are not read), then 76-byte records: u32 carrier, u32, the seven u32 counters, the
# five u64 byte counters. The iPhone 17 writes exactly one record per log.
PDSCH_31 = (16, 76, 1, 12)
PDSCH_CANDIDATES = {(2, 2): [PDSCH_22, PDSCH_22_SHORT], (3, 1): [PDSCH_31]}
PDSCH_PROBE = [PDSCH_31, PDSCH_22_SHORT, PDSCH_22]


def _pdsch_fits(body: bytes, cand: tuple) -> bool:
    header, record, _extra, count_off = cand
    return len(body) >= MAC_HEADER_LEN and len(body) == header + body[count_off] * record


def _pdsch_records(body: bytes, cand: tuple) -> list:
    header, record, extra, count_off = cand
    rows = []
    off = header
    for index in range(body[count_off]):
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
    """0xB888 NR MAC PDSCH Stats, major.minor 2.2 (documented) and 3.1 (iPhone 17).
    The counters are cumulative since the modem started counting."""
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
    if fits[0][3] == 12:
        fields["num_records"] = body[12]
    else:
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
            # the first record's headline, the ones a packet comment leads with first
            for name in ("num_pdsch_decode", "num_crc_pass_tb", "num_crc_fail_tb", "tb_bytes", "bler_pct",
                         "num_slots_elapsed", "num_retx", "crc_pass_tb_bytes", "crc_fail_tb_bytes"):
                fields[name] = rows[0][name]
            fields["carrier"] = rows[0]["carrier_id"]
        if not known:
            decoded = "partial"
            notes.append("version %s not in the table; record layout probed by size" % fields["version"])
    notes.append(IPHONE_NOTE if (major, minor) == (3, 1) else DOC_NOTE)
    return diag_record(rec, info, "NR MAC PDSCH Stats", raw_version, fields, [("records", rows)], decoded, notes)


def summary_pdsch_stats(fields: dict) -> str:
    if "num_pdsch_decode" not in fields:
        return "%d records" % fields["num_records"]
    bler = fields["bler_pct"]
    return "%d decodes BLER %s TB bytes %d" % (fields["num_pdsch_decode"],
                                               "n/a" if bler is None else "%.1f %%" % bler, fields["tb_bytes"])


# --- 0xB883 NR MAC UL Physical Channel Schedule Report ------------------------------------------

SLOT_LEN = 4
CARRIER_HEADER_LEN = 4
UL_SCHED_VERSIONS = {(2, 11)}


def decode_ul_sched(rec: LogRecord, info=None):
    """0xB883: the documented 2.11 container header and its first slot record; the rest is
    bit-packed and its carrier count undocumented, so the record is always "partial". The
    iPhone 17's 3.26 has no implemented layout: version and note only."""
    body = rec.body
    ver = read_version(body)
    if ver is None or len(body) < MAC_HEADER_LEN:
        return None
    major, minor, raw_version = ver
    fields = {"version": version_label(major, minor)}
    if (major, minor) not in UL_SCHED_VERSIONS:
        return diag_record(rec, info, "NR MAC UL Physical Channel Schedule Report", raw_version, fields, [],
                           "partial", ["version %s not implemented; only 2.11 is" % fields["version"]])
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


def summary_ul_sched(fields: dict) -> str:
    if "num_records" not in fields:
        return "version %s not implemented" % fields["version"]
    out = "%d records" % fields["num_records"]
    if "slot" in fields:
        out += " SFN %s slot %s" % (_n(fields["sfn"]), _n(fields["slot"]))
    return out


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
    """0xB872 NR L2 UL Transport Block, version 4 (a plain u32). A version word with a
    non-zero high half is the NR minor/major pair (the iPhone 17 writes 0x00030011 = 3.17),
    which has no implemented layout: version and note only, decoded="partial"."""
    body = rec.body
    if len(body) < 8:
        return None
    version = struct.unpack_from("<I", body, 0)[0]
    if version >> 16:
        label = version_label(version >> 16, version & 0xFFFF)
        return diag_record(rec, info, "NR L2 UL Transport Block", version, {"version": label}, [], "partial",
                           ["version %s not implemented; only 4 is" % label])
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


def summary_ul_tb(fields: dict) -> str:
    if "num_tti" not in fields:
        return "version %s not implemented" % fields["version"]
    if "num_tb" not in fields:
        return "%d TTIs (records did not fit)" % fields["num_tti"]
    out = "%d TTIs %d TBs" % (fields["num_tti"], fields["num_tb"])
    if "grant_bytes" in fields:
        out += " grant %d built %d" % (fields["grant_bytes"], fields["bytes_built"])
    return out


DECODERS = {"nr_mac_pdsch_info": decode_pdsch_info, "nr_mac_pdsch_stats": decode_pdsch_stats,
            "nr_mac_ul_sched": decode_ul_sched, "nr_l2_ul_tb": decode_ul_tb}
SUMMARIES = {0xB887: summary_pdsch_info, 0xB888: summary_pdsch_stats, 0xB883: summary_ul_sched,
             0xB872: summary_ul_tb}
