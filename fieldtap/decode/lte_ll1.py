"""LTE LL1/ML1 per-subframe reports of the iPhone 17 (Qualcomm M25) modem: 0xB14E, 0xB14D,
0xB126, 0xB12A and 0xB16C.

None of these has a published layout for the versions this modem logs. Every layout here
was derived and validated on the captures of 2026-09-21/22 by this repository's TypeScript
engine (web/engine/src/phy/decoders/csf.ts, b126.ts, b12a.ts, b16c.ts; the evidence is in
docs/research/iphone-named-log-codes.md) and is ported field for field. Each decoder reads
one version and refuses the others (a "partial" record with the version in the note), never
guessing at a layout.

0xB14E LL1 PUSCH CSF v164 (aperiodic CSI): u32 @1 = subframe 4b, SFN 10b @4, carrier 4b
@14, RI-1 2b @28; u32 @5 = wideband CQI CW0 4b @7, CW1 4b @11, wideband PMI 4b @24; byte
@9 low nibble = transmission mode. Validated: Tx mode = the RRC's tm4, RI against 0xB173.

0xB14D LL1 PUCCH CSF v164 (periodic CSI): u32 @1 as above with the report type in bits
26-29; u16 @6 = CQI CW0 bits 4-7, CW1 bits 8-11, wideband PMI bits 12-15; u16 @8 low nibble
= Tx mode; u16 @10 bits 8-9 = RI-1. Report type 3 carries RI; types 2 and 4 carry CQI/PMI.
The CQI/PMI/RI positions were re-derived (they agree with 0xB14E at the same moments).

0xB126 LL1 PDSCH Demapper Configuration v163: a fixed 968-byte body, 8-byte header and 20
48-byte sub-records, one per subframe, oldest first; only the last one is "now". Sub-record:
u16 @0 = SFN bits 4-13 | subframe bits 0-3; byte @2 bits 1-3 transmit antenna ports, bits
4-5 receive antennas - 1; byte @4 bits 0-1 rank - 1; 7 bytes @8 the PRB allocation bitmap
(bit k = PRB k). Validated: popcount(bitmap) is an N_RB 0xB173 reports for the subframe in
99.5% / 99.7%, rank equals 0xB173's layers (transmit diversity excepted) in 99.9% / 100%,
transmit antenna ports equal the MIB's count for every cell with a MIB; receive antennas
agree with 0xB193's Rx map in 88% / 93% only (medium).

0xB12A LL1 PCFICH Decoding Results v161: a fixed 176-byte body, 16-byte header (u16 @4
bits 0-9 = SFN) and 20 8-byte elements, one per subframe: u16 @0 rolling index, u8 @2
decoded flag, u8 @3 = 4 x CFI (only 0, 4, 8, 12 occur, and 0 exactly when the flag is 0),
u16 @4 bits 8-11 = subframe. Which of the two radio frames the header SFN names is not
settled.

0xB16C ML1 DCI Information Report v50: 4-byte header whose element count is bits 6-11 of
the u16 at +1; then elements: u32 = SFN bits 0-9 | subframe bits 10-13 | uplink grants
bits 14-15 | downlink assignments bits 17-19, followed by the grants (16 bytes: start RB =
(u32 @5 >> 3) & 0x7F, nRB = (u32 @6 >> 2) & 0x7F, modulation = byte @4 & 7) and the
assignments (8 bytes each; contents deliberately not read, only counted). Validated: the
grant's start RB, nRB and modulation agree with 0xB139's for the same subframe in 99.96% /
99.98%; the assignments fall on 0xB173's PDSCH subframes in 99.4% / 99.6%. The modulation
code is 0xB139 v162's own (1 QPSK, 2 16QAM, 3 64QAM): on 4,212 grants matched to the PUSCH
report four subframes later the two codes are equal, so the names follow 0xB139's table
(b16c.ts's comment numbers them from 0, which the matched pairs do not support).
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from .records import DiagRecord

HW_NOTE = "layout validated on the iPhone 17 (M25) captures of 2026-09-21/22"

CSF_VERSION = 164
DEMAPPER_VERSION = 163
DEMAPPER_BODY = 968
DEMAPPER_HEADER = 8
DEMAPPER_SUB = 48
DEMAPPER_SUBFRAMES = 20
PCFICH_VERSION = 161
PCFICH_BODY = 176
PCFICH_HEADER = 16
PCFICH_ELEMENT = 8
PCFICH_SUBFRAMES = 20
DCI_VERSION = 50
DCI_GRANT_BYTES = 16
DCI_ASSIGNMENT_BYTES = 8
# 0xB16C grant modulation: the same codes as 0xB139 v162 (equal on every matched grant)
DCI_MODULATION = {1: "QPSK", 2: "16QAM", 3: "64QAM", 4: "256QAM"}
# 0xB126 receive antennas: field value -> count
_RX_ANTENNAS = (1, 2, 3, 4)


def _bits(word: int, shift: int, width: int) -> int:
    return (word >> shift) & ((1 << width) - 1)


def _record(rec: LogRecord, info, default_name: str, version: int, fields: dict, sections: list, decoded: str,
            notes: list) -> DiagRecord:
    return DiagRecord(rec.code, info.name if info else default_name, version, rec.timestamp, rec.timestamp_raw,
                      rec.body, fields=fields, sections=sections, decoded=decoded,
                      confidence=info.confidence if info else "low", note="; ".join(notes))


def _wrong_version(rec, info, default_name, version, wanted):
    fields = {"version": version}
    return _record(rec, info, default_name, version, fields, [], "partial",
                   [HW_NOTE, "version %d not implemented (only v%d)" % (version, wanted)])


# --- 0xB14E LTE LL1 PUSCH CSF -----------------------------------------------------------------

def decode_pusch_csf(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB14E v164: one aperiodic CSI report (csf.ts decodeB14E)."""
    body = rec.body
    if len(body) < 1:
        return None
    version = body[0]
    if version != CSF_VERSION:
        return _wrong_version(rec, info, "LTE PHY PUSCH CSF", version, CSF_VERSION)
    if len(body) < 10:
        return None
    a, c = struct.unpack_from("<II", body, 1)
    fields = {"version": version, "sfn": _bits(a, 4, 10), "subframe": _bits(a, 0, 4), "carrier": _bits(a, 14, 4),
              "ri": _bits(a, 28, 2) + 1, "cqi_cw0": _bits(c, 7, 4), "cqi_cw1": _bits(c, 11, 4),
              "wideband_pmi": _bits(c, 24, 4), "tx_mode": body[9] & 0xF}
    notes = [HW_NOTE]
    decoded = "fields"
    if fields["subframe"] > 9:
        notes.append("implausible: subframe=%d" % fields["subframe"])
        fields["subframe"] = None
        decoded = "partial"
    return _record(rec, info, "LTE PHY PUSCH CSF", version, fields, [], decoded, notes)


def pusch_csf_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "ri" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    return "SFN %s.%s CQI %d/%d RI %d PMI %d TM %d" % (fields["sfn"], _na(fields["subframe"]), fields["cqi_cw0"],
                                                       fields["cqi_cw1"], fields["ri"], fields["wideband_pmi"],
                                                       fields["tx_mode"])


def _na(value) -> str:
    return "n/a" if value is None else str(value)


# --- 0xB14D LTE LL1 PUCCH CSF -----------------------------------------------------------------

def decode_pucch_csf(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB14D v164: one periodic CSI report; type 3 carries RI, types 2 and 4 CQI/PMI (csf.ts decodeB14D)."""
    body = rec.body
    if len(body) < 1:
        return None
    version = body[0]
    if version != CSF_VERSION:
        return _wrong_version(rec, info, "LTE PHY PUCCH CSF", version, CSF_VERSION)
    if len(body) < 14:
        return None
    a = struct.unpack_from("<I", body, 1)[0]
    q, mode_word, r = struct.unpack_from("<HHH", body, 6)
    report_type = _bits(a, 26, 4)
    fields = {"version": version, "sfn": _bits(a, 4, 10), "subframe": _bits(a, 0, 4), "carrier": _bits(a, 14, 4),
              "report_type": report_type, "tx_mode": mode_word & 0xF}
    if report_type == 3:
        fields["ri"] = ((r >> 8) & 3) + 1
    elif report_type in (2, 4):
        fields["cqi_cw0"] = (q >> 4) & 0xF
        fields["cqi_cw1"] = (q >> 8) & 0xF
        fields["wideband_pmi"] = (q >> 12) & 0xF
    notes = [HW_NOTE]
    decoded = "fields"
    if fields["subframe"] > 9:
        notes.append("implausible: subframe=%d" % fields["subframe"])
        fields["subframe"] = None
        decoded = "partial"
    return _record(rec, info, "LTE PHY PUCCH CSF", version, fields, [], decoded, notes)


def pucch_csf_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "report_type" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    line = "SFN %s.%s type %d" % (fields["sfn"], _na(fields["subframe"]), fields["report_type"])
    if "ri" in fields:
        line += " RI %d" % fields["ri"]
    if "cqi_cw0" in fields:
        line += " CQI %d/%d PMI %d" % (fields["cqi_cw0"], fields["cqi_cw1"], fields["wideband_pmi"])
    return line + " TM %d" % fields["tx_mode"]


# --- 0xB126 LTE LL1 PDSCH Demapper Configuration -------------------------------------------------

def decode_pdsch_demapper(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB126 v163: the 20 logged subframes, oldest first; the headline is the last one (b126.ts)."""
    body = rec.body
    if len(body) < 1:
        return None
    version = body[0]
    if version != DEMAPPER_VERSION:
        return _wrong_version(rec, info, "LTE LL1 PDSCH Demapper Configuration", version, DEMAPPER_VERSION)
    # The body is fixed at 968 bytes on this modem: a different length is not a layout to guess at.
    if len(body) != DEMAPPER_BODY:
        return None
    rows = []
    bad = []
    for k in range(DEMAPPER_SUBFRAMES):
        o = DEMAPPER_HEADER + DEMAPPER_SUB * k
        word = struct.unpack_from("<H", body, o)[0]
        antennas = body[o + 2]
        lo = struct.unpack_from("<I", body, o + 8)[0]
        hi = body[o + 12] | (body[o + 13] << 8) | (body[o + 14] << 16)
        row = {"index": k, "sfn": _bits(word, 4, 10), "subframe": word & 0xF, "tx_antennas": _bits(antennas, 1, 3),
               "rx_antennas": _RX_ANTENNAS[_bits(antennas, 4, 2)], "rank": _bits(body[o + 4], 0, 2) + 1,
               "prb_mask_lo": lo, "prb_mask_hi": hi, "num_prb": bin(lo).count("1") + bin(hi).count("1")}
        if row["subframe"] > 9:
            bad.append("subframe%d.subframe=%d" % (k, row["subframe"]))
            row["subframe"] = None
        rows.append(row)
    now = rows[-1]
    fields = {"version": version, "num_subframes": DEMAPPER_SUBFRAMES}
    for key in ("sfn", "subframe", "tx_antennas", "rx_antennas", "rank", "num_prb"):
        fields[key] = now[key]
    notes = [HW_NOTE, "headline = the last (newest) subframe"]
    decoded = "fields"
    if bad:
        notes.append("implausible: " + ", ".join(bad))
        decoded = "partial"
    return _record(rec, info, "LTE LL1 PDSCH Demapper Configuration", version, fields, [("demapper", rows)], decoded,
                   notes)


def pdsch_demapper_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "rank" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    return "SFN %s.%s Tx ant %d Rx ant %d rank %d %d PRB" % (fields["sfn"], _na(fields["subframe"]),
                                                            fields["tx_antennas"], fields["rx_antennas"],
                                                            fields["rank"], fields["num_prb"])


# --- 0xB12A LTE LL1 PCFICH Decoding Results ---------------------------------------------------

def decode_pcfich(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB12A v161: the SFN the header names and the CFI of 20 subframes (b12a.ts)."""
    body = rec.body
    if len(body) < 1:
        return None
    version = body[0]
    if version != PCFICH_VERSION:
        return _wrong_version(rec, info, "LTE LL1 PCFICH Decoding Results", version, PCFICH_VERSION)
    if len(body) != PCFICH_BODY:
        return None
    rows = []
    counts = {1: 0, 2: 0, 3: 0}
    consistent = 0
    for k in range(PCFICH_SUBFRAMES):
        o = PCFICH_HEADER + PCFICH_ELEMENT * k
        index, flag, raw, sf_word = struct.unpack_from("<HBBH", body, o)
        decoded_flag = 1 if flag == 1 else 0
        # The field is 4 x CFI; anything that is not 4, 8 or 12 is not a CFI and is not reported as one.
        legal = raw in (4, 8, 12)
        ok = (not decoded_flag) if raw == 0 else (legal and decoded_flag == 1)
        row = {"index": index, "subframe": (sf_word >> 8) & 0xF, "decoded_flag": decoded_flag,
               "cfi": raw >> 2 if legal else None, "consistent": int(ok)}
        if legal:
            counts[raw >> 2] += 1
        consistent += int(ok)
        rows.append(row)
    fields = {"version": version, "sfn": struct.unpack_from("<H", body, 4)[0] & 0x3FF,
              "num_subframes": PCFICH_SUBFRAMES, "num_decoded": sum(r["decoded_flag"] for r in rows),
              "cfi1": counts[1], "cfi2": counts[2], "cfi3": counts[3], "num_consistent": consistent}
    notes = [HW_NOTE]
    decoded = "fields"
    if consistent < PCFICH_SUBFRAMES:
        notes.append("%d elements break the CFI/decode-flag identity" % (PCFICH_SUBFRAMES - consistent))
        decoded = "partial"
    return _record(rec, info, "LTE LL1 PCFICH Decoding Results", version, fields, [("pcfich", rows)], decoded, notes)


def pcfich_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "cfi1" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    return "SFN %d CFI 1/2/3 x%d/%d/%d decoded %d/%d" % (fields["sfn"], fields["cfi1"], fields["cfi2"], fields["cfi3"],
                                                       fields["num_decoded"], fields["num_subframes"])


# --- 0xB16C LTE ML1 DCI Information Report ------------------------------------------------------

def decode_dci_info(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB16C v50: per-subframe uplink grants (decoded) and downlink assignments (counted) (b16c.ts)."""
    body = rec.body
    if len(body) < 1:
        return None
    version = body[0]
    if version != DCI_VERSION:
        return _wrong_version(rec, info, "LTE ML1 DCI Information Report", version, DCI_VERSION)
    if len(body) < 4:
        return None
    declared = ((body[1] >> 6) | (body[2] << 2)) & 0x3F
    subframes, grants = [], []
    pos = 4
    exact = False
    while len(subframes) < declared and pos + 4 <= len(body):
        word = struct.unpack_from("<I", body, pos)[0]
        n_grants, n_assignments = (word >> 14) & 3, (word >> 17) & 7
        p = pos + 4
        rows = []
        for i in range(n_grants):
            g = p + DCI_GRANT_BYTES * i
            if g + DCI_GRANT_BYTES > len(body):
                break
            code = body[g + 4] & 7
            rows.append({"subframe_index": len(subframes),
                         "start_rb": (struct.unpack_from("<I", body, g + 5)[0] >> 3) & 0x7F,
                         "num_rbs": (struct.unpack_from("<I", body, g + 6)[0] >> 2) & 0x7F,
                         "modulation_code": code, "modulation": DCI_MODULATION.get(code)})
        if len(rows) < n_grants:
            break
        p += DCI_GRANT_BYTES * n_grants + DCI_ASSIGNMENT_BYTES * n_assignments
        if p > len(body):
            break
        sfn, subframe = word & 0x3FF, (word >> 10) & 0xF
        subframes.append({"index": len(subframes), "sfn": sfn, "subframe": subframe, "tti": sfn * 10 + subframe,
                          "num_ul_grants": n_grants, "num_dl_assignments": n_assignments})
        grants.extend(rows)
        pos = p
    else:
        exact = pos == len(body) and len(subframes) == declared
    fields = {"version": version, "num_declared": declared, "num_subframes": len(subframes),
              "num_ul_grants": len(grants), "num_dl_assignments": sum(s["num_dl_assignments"] for s in subframes),
              "walk_exact": int(exact)}
    if subframes:
        fields["sfn"], fields["subframe"] = subframes[0]["sfn"], subframes[0]["subframe"]
    if grants:
        fields["start_rb"], fields["num_rbs"] = grants[0]["start_rb"], grants[0]["num_rbs"]
        fields["modulation"] = grants[0]["modulation"]
    notes = [HW_NOTE, "downlink assignments counted, contents not read"]
    if not exact:
        notes.append("element chain did not consume the body (%d of %d elements)" % (len(subframes), declared))
    return _record(rec, info, "LTE ML1 DCI Information Report", version, fields,
                   [("dci", subframes), ("ul_grants", grants)], "fields" if subframes else "partial", notes)


def dci_info_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "num_subframes" not in fields or not fields["num_subframes"]:
        return "v%d (partial)" % fields.get("version", 0)
    return "%d subframes %d UL grants %d DL assignments" % (fields["num_subframes"], fields["num_ul_grants"],
                                                            fields["num_dl_assignments"])


DECODERS = {
    "lte_pusch_csf": decode_pusch_csf,
    "lte_pucch_csf": decode_pucch_csf,
    "lte_pdsch_demapper": decode_pdsch_demapper,
    "lte_pcfich": decode_pcfich,
    "lte_dci_info": decode_dci_info,
}
