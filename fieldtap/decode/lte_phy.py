"""LTE PHY reports: 0xB173 PDSCH Stat Indication and 0xB139 PUSCH Tx Report.

Per-TB downlink decode results (TB size, MCS, CRC pass/fail for BLER) and per-grant
uplink transmissions (TB size, modulation order, Tx power). Both are single-sourced:
MobileInsight lte_pdsch_stat_indication.h and lte_phy_pusch_tx_report.h (Apache-2.0),
restated in docs/research/qualcomm-measurement-log-layouts.md. Written from those
facts, not from any other decoder's code. Layout from documentation; confirm on a
hardware capture.

0xB173: Version u8, Num Records u8, 2 reserved; then per record a P1 header, two
transport-block slots (the second is skipped when only one TB is present), and a P2
trailer (PMCH id, area id). Record sizes: v5/v16 20, v24/v32 24, v36 40 bytes.

0xB139: Version u8; word u16 = serving cell id (9 bits) | number of records (5 bits);
1 reserved; dispatch SFN/SF u16; 2 reserved; then per record 48 bytes (v23, v24) or
52 bytes (v26, adds Num Repetition / RB NB Start Index).

Two fields are interpreted beyond what the source states, each guarded by a
plausibility check: "Current SFN SF" in 0xB139 is read as SFN << 4 | subframe (the
packing every other Qualcomm SFN/SF word uses), and the 10-bit PUSCH Tx power is read
as two's complement dBm (signedness unconfirmed).

The iPhone 17 (Qualcomm M25) logs 0xB173 v50 and 0xB139 v162, neither documented.
Both layouts were derived and validated on the captures of 2026-09-21/22 by this
repository's TypeScript engine (web/engine/src/phy/decoders/b173.ts, b139.ts) and
are ported here field for field:

0xB173 v50: 4-byte header (version, record count, 2 reserved); 40-byte records:
u16 @0 = SFN << 4 | subframe, u8 layers @2, u8 TB count @3, u8 carrier @4 (& 7);
TB slots @12 and @24, 12 bytes each: u8 = HARQ 4b | RV 2b | NDI 1b | CRC 1b,
u16 @1 = RNTI type 4b | TB index bit 4, u16 TBS bytes @4, u8 MCS @6, u8 nRB @7,
u8 Qm @8 (2/4/6/8; 0 when the slot is unused). TBS sizes match TS 36.213.

0xB139 v162: the same 8-byte header; 100-byte records: u32 @0 = TTI (low 16 bits,
SFN * 10 + subframe) | flags (carrier 2b @16, retx index 5b @23); u32 @4: start RB
bits 1-7, nRB bits 15-21; u16 TBS bytes @8; u16 code rate x1024 @10; byte @36
bits 2-4 modulation (1 QPSK, 2 16QAM, 3 64QAM, 4 256QAM); byte @46 required PUSCH
power in 0.25 dB steps, dBm = raw / 4 - 1.5 (offset from 442 TTI-matched power
headroom reports, assuming Pcmax,c = 23 dBm, so the absolute value is good to
about 1.5 dB; before Pcmax capping, so it may exceed 23 dBm).
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from .records import DiagRecord

DOC_NOTE = "layout from documentation; confirm on a hardware capture"
HW_NOTE = "layout validated on the iPhone 17 (M25) captures of 2026-09-21/22"

RNTI_NAMES = {0: "C-RNTI", 1: "SPS C-RNTI", 2: "P-RNTI", 3: "RA-RNTI", 4: "Temp C-RNTI", 5: "SI-RNTI"}
# v5 derives modulation from the MCS index; v24+ carry a modulation byte with these codes
MODULATION_FROM_MCS = ((17, "64QAM"), (10, "16QAM"), (0, "QPSK"))
MODULATION_V24 = {2: "QPSK", 4: "16QAM", 6: "64QAM", 8: "256QAM"}
PUSCH_MOD_ORDER = {0: "BPSK", 1: "QPSK", 2: "16QAM", 3: "64QAM"}
# v162 modulation codes and the Qm they stand for
PUSCH_MOD_V162 = {1: "QPSK", 2: "16QAM", 3: "64QAM", 4: "256QAM"}
PUSCH_QM_V162 = {1: 2, 2: 4, 3: 6, 4: 8}

# version -> (P1 length, TB slot length, P2 length, has modulation byte, has HSIC bits, has QED byte)
_PDSCH_LAYOUT = {
    5: (6, 6, 2, False, False, False),
    16: (6, 6, 2, False, True, False),
    24: (6, 8, 2, True, True, False),
    32: (6, 8, 2, True, True, False),
    36: (12, 12, 4, True, True, True),
}


def _record(rec, info, version, fields, sections, decoded, notes, default_name):
    return DiagRecord(rec.code, info.name if info else default_name, version, rec.timestamp, rec.timestamp_raw,
                      rec.body, fields=fields, sections=sections, decoded=decoded,
                      confidence=info.confidence if info else "low", note="; ".join(notes))


# --- 0xB173 LTE PDSCH Stat Indication -----------------------------------------------------

_PDSCH_V50_VERSION = 50
_PDSCH_V50_RECORD = 40


def decode_pdsch_stat(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB173, versions 5, 16, 24, 32 and 36 from documentation, v50 from the iPhone 17."""
    body = rec.body
    if len(body) < 4:
        return None
    version = body[0]
    num_records = body[1]
    fields = {"version": version, "num_records": num_records}
    if version == _PDSCH_V50_VERSION:
        return _decode_pdsch_stat_v50(rec, info, fields)
    notes = [DOC_NOTE]
    layout = _PDSCH_LAYOUT.get(version)
    if layout is None:
        notes.append("version %d not documented" % version)
        return _record(rec, info, version, fields, [], "partial", notes, "LTE PDSCH Stat Indication")
    p1_len, tb_len, p2_len, has_mod, has_hsic, has_qed = layout
    rec_len = p1_len + 2 * tb_len + p2_len
    if len(body) < 4 + num_records * rec_len:
        return None
    bad = []
    records, tbs = [], []
    off = 4
    for i in range(num_records):
        sf_word, num_rbs, num_layers, num_tb, cell_byte = struct.unpack_from("<HBBBB", body, off)
        row = {"record": i, "subframe": sf_word & 0xF, "sfn": (sf_word >> 4) & 0xFFF, "num_rbs": num_rbs,
               "num_layers": num_layers, "num_tb": num_tb, "serving_cell_index": cell_byte & 7}
        if has_hsic:
            row["hsic_enabled"] = (cell_byte >> 3) & 0xF
        for key, limit in (("subframe", 9), ("sfn", 1023), ("num_rbs", 110)):
            if row[key] > limit:
                bad.append("record%d.%s=%d" % (i, key, row[key]))
                row[key] = None
        if num_tb not in (1, 2):
            bad.append("record%d.num_tb=%d" % (i, num_tb))
            num_tb = 0
        p = off + p1_len
        for t in range(num_tb):
            tb = _pdsch_tb(body, p, version, has_mod, has_qed)
            tb["record"] = i
            tb["tb"] = t
            for key, limit in (("mcs", 31), ("num_rbs", 110)):
                if tb[key] > limit:
                    bad.append("record%d.tb%d.%s=%d" % (i, t, key, tb[key]))
                    tb[key] = None
            if tb["rnti_type"] not in RNTI_NAMES:
                bad.append("record%d.tb%d.rnti_type=%d" % (i, t, tb["rnti_type"]))
            tbs.append(tb)
            p += tb_len
        p = off + p1_len + 2 * tb_len
        row["pmch_id"], row["area_id"] = body[p], body[p + 1]
        records.append(row)
        off += rec_len
    if tbs:
        first = tbs[0]
        fields.update({"sfn": records[0]["sfn"], "subframe": records[0]["subframe"],
                       "tbs_bytes": sum(t["tb_size"] for t in tbs), "num_tb": len(tbs),
                       "harq_id": first["harq_id"], "rnti_type": first["rnti_type"],
                       "rnti_type_name": first["rnti_type_name"], "mcs": first["mcs"],
                       "modulation": first["modulation"], "num_rbs": records[0]["num_rbs"],
                       "crc_pass": sum(1 for t in tbs if t["crc_pass"] == 1),
                       "crc_fail": sum(1 for t in tbs if t["crc_pass"] == 0)})
    decoded = "fields"
    if bad:
        notes.append("implausible: " + ", ".join(bad))
        decoded = "partial"
    return _record(rec, info, version, fields, [("records", records), ("transport_blocks", tbs)], decoded, notes,
                   "LTE PDSCH Stat Indication")


def _pdsch_tb(body: bytes, p: int, version: int, has_mod: bool, has_qed: bool) -> dict:
    harq_byte, rnti_byte = body[p], body[p + 1]
    q = p + 2
    if version == 36:
        q += 2
    tb_size, mcs, num_rbs = struct.unpack_from("<HBB", body, q)
    tb = {"harq_id": harq_byte & 0xF, "rv": (harq_byte >> 4) & 3, "ndi": (harq_byte >> 6) & 1,
          "crc_pass": (harq_byte >> 7) & 1, "rnti_type": rnti_byte & 0xF, "tb_index": (rnti_byte >> 4) & 1,
          "discarded_retx_present": (rnti_byte >> 5) & 1, "did_recombining": (rnti_byte >> 6) & 1,
          "tb_size": tb_size, "mcs": mcs, "num_rbs": num_rbs}
    tb["rnti_type_name"] = RNTI_NAMES.get(tb["rnti_type"], "unknown")
    if has_mod:
        code = body[q + 4]
        tb["modulation_code"] = code
        tb["modulation"] = MODULATION_V24.get(code, "unknown")
    elif version == 5:
        tb["modulation"] = next(name for floor, name in MODULATION_FROM_MCS if mcs >= floor)
    else:
        tb["modulation"] = None
    if has_qed:
        qed = body[q + 5]
        tb["qed2_interim_status"] = qed & 3
        tb["qed_iteration"] = qed >> 2
    return tb


def _decode_pdsch_stat_v50(rec: LogRecord, info, fields: dict) -> Optional[DiagRecord]:
    """v50: fixed 40-byte records with two 12-byte TB slots (web/engine/src/phy/decoders/b173.ts)."""
    body = rec.body
    num_records = fields["num_records"]
    if len(body) < 4 + num_records * _PDSCH_V50_RECORD:
        return None
    notes = [HW_NOTE]
    bad = []
    records, tbs = [], []
    for i in range(num_records):
        r = 4 + _PDSCH_V50_RECORD * i
        sf_word = struct.unpack_from("<H", body, r)[0]
        num_tb = body[r + 3]
        row = {"record": i, "subframe": sf_word & 0xF, "sfn": (sf_word >> 4) & 0xFFF, "num_layers": body[r + 2],
               "num_tb": num_tb, "serving_cell_index": body[r + 4] & 7}
        for key, limit in (("subframe", 9), ("sfn", 1023)):
            if row[key] > limit:
                bad.append("record%d.%s=%d" % (i, key, row[key]))
                row[key] = None
        if num_tb > 2:
            bad.append("record%d.num_tb=%d" % (i, num_tb))
            num_tb = 2
        for t in range(num_tb):
            p = r + 12 + 12 * t
            harq_byte = body[p]
            rnti_word = struct.unpack_from("<H", body, p + 1)[0]
            qm = body[p + 8]
            tb = {"record": i, "tb": t, "harq_id": harq_byte & 0xF, "rv": (harq_byte >> 4) & 3,
                  "ndi": (harq_byte >> 6) & 1, "crc_pass": (harq_byte >> 7) & 1, "rnti_type": rnti_word & 0xF,
                  "tb_index": (rnti_word >> 4) & 1, "tb_size": struct.unpack_from("<H", body, p + 4)[0],
                  "mcs": body[p + 6], "num_rbs": body[p + 7], "qm": qm, "modulation": MODULATION_V24.get(qm)}
            tb["rnti_type_name"] = RNTI_NAMES.get(tb["rnti_type"], "unknown")
            for key, limit in (("mcs", 31), ("num_rbs", 110)):
                if tb[key] > limit:
                    bad.append("record%d.tb%d.%s=%d" % (i, t, key, tb[key]))
                    tb[key] = None
            if tb["rnti_type"] not in RNTI_NAMES:
                bad.append("record%d.tb%d.rnti_type=%d" % (i, t, tb["rnti_type"]))
            if qm not in MODULATION_V24 and qm != 0:
                bad.append("record%d.tb%d.qm=%d" % (i, t, qm))
            tbs.append(tb)
        records.append(row)
    if tbs:
        first = tbs[0]
        fields.update({"sfn": records[0]["sfn"], "subframe": records[0]["subframe"],
                       "tbs_bytes": sum(t["tb_size"] for t in tbs), "num_tb": len(tbs),
                       "harq_id": first["harq_id"], "rnti_type": first["rnti_type"],
                       "rnti_type_name": first["rnti_type_name"], "mcs": first["mcs"],
                       "modulation": first["modulation"], "num_rbs": first["num_rbs"],
                       "crc_pass": sum(1 for t in tbs if t["crc_pass"] == 1),
                       "crc_fail": sum(1 for t in tbs if t["crc_pass"] == 0)})
    decoded = "fields"
    if bad:
        notes.append("implausible: " + ", ".join(bad))
        decoded = "partial"
    return _record(rec, info, _PDSCH_V50_VERSION, fields, [("records", records), ("transport_blocks", tbs)], decoded,
                   notes, "LTE PDSCH Stat Indication")


def pdsch_stat_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "tbs_bytes" not in fields:
        return "v%d, %d records (partial)" % (fields.get("version", 0), fields.get("num_records", 0))
    mcs = "n/a" if fields["mcs"] is None else str(fields["mcs"])
    return "%d TB %d bytes MCS %s %s CRC %d/%d" % (fields["num_tb"], fields["tbs_bytes"], mcs,
                                                   fields["modulation"] or "n/a", fields["crc_pass"],
                                                   fields["crc_pass"] + fields["crc_fail"])


# --- 0xB139 LTE PHY PUSCH Tx Report ------------------------------------------------------

_PUSCH_RECORD_LEN = {23: 48, 24: 48, 26: 52}
_PUSCH_V162_VERSION = 162
_PUSCH_V162_RECORD = 100


def _signed(raw: int, bits: int) -> int:
    return raw - (1 << bits) if raw & (1 << (bits - 1)) else raw


def decode_pusch_tx(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB139, versions 23, 24 and 26."""
    body = rec.body
    if len(body) < 8:
        return None
    version = body[0]
    word = struct.unpack_from("<H", body, 1)[0]
    fields = {"version": version, "serving_cell_id": word & 0x1FF, "num_records": (word >> 9) & 0x1F,
              "dispatch_sfn_sf_raw": struct.unpack_from("<H", body, 4)[0]}
    if version == _PUSCH_V162_VERSION:
        return _decode_pusch_tx_v162(rec, info, fields)
    notes = [DOC_NOTE]
    rec_len = _PUSCH_RECORD_LEN.get(version)
    if rec_len is None:
        notes.append("version %d not documented" % version)
        return _record(rec, info, version, fields, [], "partial", notes, "LTE PHY PUSCH Tx Report")
    if len(body) < 8 + fields["num_records"] * rec_len:
        return None
    bad = []
    grants = []
    off = 8
    for i in range(fields["num_records"]):
        sfn_sf, coding_raw, a, b, tb_size, ack_word, c = struct.unpack_from("<HHIIHHI", body, off)
        gain, srs_byte = body[off + 20], body[off + 21]
        d = struct.unpack_from("<I", body, off + 24)[0]
        row = {
            "grant": i, "sfn": sfn_sf >> 4, "subframe": sfn_sf & 0xF, "coding_rate": coding_raw / 1024.0,
            "ack": a & 1, "cqi": (a >> 1) & 1, "ri": (a >> 2) & 1, "frequency_hopping": (a >> 3) & 3,
            "rv": (a >> 5) & 3, "mirror_hopping": (a >> 7) & 3, "dmrs_cyclic_shift_slot0": (a >> 9) & 0xF,
            "dmrs_cyclic_shift_slot1": (a >> 13) & 0xF, "dmrs_root_slot0": (a >> 17) & 0x7FF, "ue_srs": (a >> 28) & 1,
            "dmrs_root_slot1": b & 0x7FF, "start_rb_slot0": (b >> 11) & 0x7F, "start_rb_slot1": (b >> 18) & 0x7F,
            "num_rbs": (b >> 25) & 0x7F, "tb_size": tb_size,
            "num_ack_bits": ack_word & 7, "ack_payload": (ack_word >> 3) & 0xF,
            "rate_matched_ack_bits": c & 0x7FF, "num_ri_bits": (c >> 11) & 3, "ri_payload": (c >> 13) & 3,
            "rate_matched_ri_bits": (c >> 15) & 0x7FF, "mod_order": (c >> 26) & 3,
            "digital_gain_db": gain, "srs_occasion": srs_byte & 1, "retx_index": (srs_byte >> 1) & 0x1F,
            "tx_power_dbm": _signed(d & 0x3FF, 10), "num_cqi_bits": (d >> 10) & 0xFF,
            "rate_matched_cqi_bits": (d >> 18) & 0x3FFF,
            "cqi_payload": body[off + 28:off + 44].hex(),
            "tx_resampler": struct.unpack_from("<I", body, off + 44)[0],
        }
        row["modulation"] = PUSCH_MOD_ORDER[row["mod_order"]]
        if version == 26:
            e = struct.unpack_from("<I", body, off + 48)[0]
            row["num_repetition"] = e & 0xFFF
            row["rb_nb_start_index"] = (e >> 12) & 0xFF
        for key, low, high in (("subframe", 0, 9), ("sfn", 0, 1023), ("num_rbs", 0, 110), ("coding_rate", 0.0, 2.0),
                               ("tx_power_dbm", -60, 33)):
            if not low <= row[key] <= high:
                bad.append("grant%d.%s=%s" % (i, key, row[key]))
                row[key] = None
        grants.append(row)
        off += rec_len
    if grants:
        first = grants[0]
        fields.update({"sfn": first["sfn"], "subframe": first["subframe"],
                       "tbs_bytes": sum(g["tb_size"] for g in grants), "tx_power_dbm": first["tx_power_dbm"],
                       "modulation": first["modulation"], "mod_order": first["mod_order"],
                       "coding_rate": first["coding_rate"], "num_rbs": first["num_rbs"]})
    decoded = "fields"
    if bad:
        notes.append("implausible: " + ", ".join(bad))
        decoded = "partial"
    return _record(rec, info, version, fields, [("grants", grants)], decoded, notes, "LTE PHY PUSCH Tx Report")


def _decode_pusch_tx_v162(rec: LogRecord, info, fields: dict) -> Optional[DiagRecord]:
    """v162: 100-byte records with TTI, RB allocation, TBS, code rate, modulation and the
    required PUSCH power (web/engine/src/phy/decoders/b139.ts)."""
    body = rec.body
    if len(body) < 8 + fields["num_records"] * _PUSCH_V162_RECORD:
        return None
    notes = [HW_NOTE]
    bad = []
    grants = []
    for i in range(fields["num_records"]):
        r = 8 + _PUSCH_V162_RECORD * i
        w0, w1, tb_size, code_raw = struct.unpack_from("<IIHH", body, r)
        flags = w0 >> 16
        tti = w0 & 0xFFFF
        code = (body[r + 36] >> 2) & 7
        power_raw = body[r + 46]
        row = {"grant": i, "tti": tti, "sfn": tti // 10, "subframe": tti % 10, "carrier": flags & 3,
               "retx_index": (flags >> 7) & 0x1F, "start_rb": (w1 >> 1) & 0x7F, "num_rbs": (w1 >> 15) & 0x7F,
               "tb_size": tb_size, "coding_rate": code_raw / 1024.0, "modulation_code": code,
               "modulation": PUSCH_MOD_V162.get(code), "mod_order": PUSCH_QM_V162.get(code),
               "power_raw": power_raw, "required_power_dbm": power_raw / 4.0 - 1.5}
        for key, low, high in (("sfn", 0, 1023), ("num_rbs", 0, 110), ("coding_rate", 0.0, 2.0)):
            if not low <= row[key] <= high:
                bad.append("grant%d.%s=%s" % (i, key, row[key]))
                row[key] = None
        if row["sfn"] is None:
            row["subframe"] = None
        grants.append(row)
    if grants:
        first = grants[0]
        fields.update({"tti": first["tti"], "sfn": first["sfn"], "subframe": first["subframe"],
                       "tbs_bytes": sum(g["tb_size"] for g in grants), "required_power_dbm": first["required_power_dbm"],
                       "modulation": first["modulation"], "mod_order": first["mod_order"],
                       "coding_rate": first["coding_rate"], "num_rbs": first["num_rbs"]})
    decoded = "fields"
    if bad:
        notes.append("implausible: " + ", ".join(bad))
        decoded = "partial"
    return _record(rec, info, _PUSCH_V162_VERSION, fields, [("grants", grants)], decoded, notes, "LTE PHY PUSCH Tx Report")


def pusch_tx_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "tbs_bytes" not in fields:
        return "v%d, %d records (partial)" % (fields.get("version", 0), fields.get("num_records", 0))
    if fields.get("required_power_dbm") is not None:
        power = "%.2f dBm" % fields["required_power_dbm"]
    elif fields.get("tx_power_dbm") is not None:
        power = "%d dBm" % fields["tx_power_dbm"]
    else:
        power = "n/a"
    return "%d grants %d bytes %s Tx %s" % (fields["num_records"], fields["tbs_bytes"], fields["modulation"] or "n/a",
                                           power)


DECODERS = {"lte_pdsch_stat": decode_pdsch_stat, "lte_pusch_tx": decode_pusch_tx}
