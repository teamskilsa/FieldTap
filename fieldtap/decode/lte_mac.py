"""LTE MAC transport-block records: 0xB063 (DL) and 0xB064 (UL).

Each record is a subpacket container; each subpacket holds samples, one per transport
block, with the TB size (the throughput number) and HDR LEN bytes of the MAC PDU. The
modem logs the MAC sub-headers (and any control elements), usually not the SDUs, so a
sample is a MAC PDU with its payload missing. Each one is handed to the pcap sink as
`mac_pdus` for a mac-lte-framed frame, and the sub-headers are decoded here too so
the LCIDs are readable without Wireshark.

Layouts: MobileInsight log_packet.h (Apache-2.0), restated in
docs/research/qualcomm-measurement-log-layouts.md; the sub-header format is
3GPP TS 36.321 6.1.2. Written from those facts, not from any other decoder's code.
Layout from documentation; confirm on a hardware capture.

Sample layouts (little-endian):
    DL v2 (12): Sub-FN u16, RNTI type u8, HARQ id u8, PMCH id u16, TBS u16, RLC PDUs u8,
                padding u16, HDR LEN u8
    DL v4 (14): Sub id u8, Cell id u8, then as v2
    UL v1 (12): HARQ id u8, RNTI type u8, Sub-FN u16, grant u16, RLC PDUs u8, padding u16,
                BSR event u8, BSR trigger u8, HDR LEN u8
    UL v2/v3/v5/v8 (14): Sub id u8, Cell id u8, then as v1
Sub-FN: low 4 bits subframe, upper 12 bits SFN.
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from ..output.fieldtap_diag import QC_RNTI_TO_WIRESHARK
from .records import DiagRecord

DOC_NOTE = "layout from documentation; confirm on a hardware capture"

RNTI_NAMES = {0: "C-RNTI", 1: "SPS C-RNTI", 2: "P-RNTI", 3: "RA-RNTI", 4: "Temp C-RNTI", 5: "SI-RNTI"}
BSR_EVENT = {0: "none", 1: "periodic", 2: "high data arrival"}
BSR_TRIGGER = {0: "no BSR", 3: "S-BSR", 4: "Pad L-BSR"}

# LCID names, TS 36.321 tables 6.2.1-1 (DL-SCH) and 6.2.1-2 (UL-SCH)
DL_LCID = {0: "CCCH", 24: "Activation/Deactivation (4 octet)", 26: "Long DRX Command",
           27: "Activation/Deactivation (1 octet)", 28: "UE Contention Resolution Identity",
           29: "Timing Advance Command", 30: "DRX Command", 31: "Padding"}
UL_LCID = {0: "CCCH", 25: "Extended PHR", 26: "PHR", 27: "C-RNTI", 28: "Truncated BSR",
           29: "Short BSR", 30: "Long BSR", 31: "Padding"}

_DL_SAMPLE = {2: ("<HBBHHBHB", ("subfn_raw", "rnti_type", "harq_id", "pmch_id", "tbs_bytes", "rlc_pdus",
                                 "padding_bytes", "hdr_len")),
              4: ("<BBHBBHHBHB", ("sub_id", "cell_id", "subfn_raw", "rnti_type", "harq_id", "pmch_id", "tbs_bytes",
                                   "rlc_pdus", "padding_bytes", "hdr_len"))}
_UL_V1 = ("<BBHHBHBBB", ("harq_id", "rnti_type", "subfn_raw", "grant_bytes", "rlc_pdus", "padding_bytes",
                         "bsr_event", "bsr_trigger", "hdr_len"))
_UL_V2 = ("<BBBBHHBHBBB", ("sub_id", "cell_id") + _UL_V1[1])
_UL_SAMPLE = {1: _UL_V1, 2: _UL_V2, 3: _UL_V2, 5: _UL_V2, 8: _UL_V2}


def lcid_name(lcid: int, downlink: bool) -> str:
    table = DL_LCID if downlink else UL_LCID
    if lcid in table:
        return table[lcid]
    if 1 <= lcid <= 10:
        return "DTCH/DCCH %d" % lcid
    return "reserved %d" % lcid


def parse_subheaders(hdr: bytes, downlink: bool) -> tuple:
    """TS 36.321 6.1.2: R/R/E/LCID, then for a variable-size SDU F/L (7 or 15 bits).
    Control elements and padding have no length field. Returns (rows, note)."""
    rows = []
    i = 0
    note = ""
    while i < len(hdr):
        octet = hdr[i]
        i += 1
        ext = (octet >> 5) & 1
        lcid = octet & 0x1F
        row = {"lcid": lcid, "lcid_name": lcid_name(lcid, downlink), "extension": ext, "length": None}
        if ext and lcid <= 10:
            if i >= len(hdr):
                note = "sub-header truncated"
                rows.append(row)
                break
            if hdr[i] & 0x80:
                if i + 1 >= len(hdr):
                    note = "sub-header truncated"
                    rows.append(row)
                    break
                row["length"] = ((hdr[i] & 0x7F) << 8) | hdr[i + 1]
                i += 2
            else:
                row["length"] = hdr[i] & 0x7F
                i += 1
        rows.append(row)
        if not ext:
            break
    if not note and i < len(hdr):
        note = "%d control-element bytes after the sub-headers" % (len(hdr) - i)
    return rows, note


def _decode_tb(rec: LogRecord, info, downlink: bool) -> Optional[DiagRecord]:
    body = rec.body
    if len(body) < 4:
        return None
    version, num_subpackets = body[0], body[1]
    layouts = _DL_SAMPLE if downlink else _UL_SAMPLE
    size_key = "tbs_bytes" if downlink else "grant_bytes"
    fields = {"version": version, "num_subpackets": num_subpackets, "direction": "dl" if downlink else "ul"}
    notes = [DOC_NOTE]
    subpackets, samples, subheaders, mac_pdus = [], [], [], []
    bad = []
    off = 4
    for _ in range(num_subpackets):
        if off + 5 > len(body):
            if not subpackets:
                return None
            notes.append("subpacket header beyond the body")
            break
        sp_id, sp_version, sp_size, num_samples = struct.unpack_from("<BBHB", body, off)
        end = off + sp_size
        if sp_size < 5 or end > len(body):
            if not subpackets:
                return None
            notes.append("subpacket %d size %d does not fit" % (sp_id, sp_size))
            break
        subpackets.append({"subpacket_id": sp_id, "subpacket_version": sp_version, "subpacket_size": sp_size,
                           "num_samples": num_samples})
        layout = layouts.get(sp_version)
        if layout is None:
            notes.append("subpacket version %d not documented" % sp_version)
            off = end
            continue
        fmt, names = layout
        fixed = struct.calcsize(fmt)
        p = off + 5
        for k in range(num_samples):
            if p + fixed > end:
                notes.append("sample %d does not fit the subpacket" % k)
                break
            sample = dict(zip(names, struct.unpack_from(fmt, body, p)))
            p += fixed
            hdr_len = sample["hdr_len"]
            if p + hdr_len > end:
                notes.append("sample %d: %d header bytes beyond the subpacket" % (k, hdr_len))
                break
            hdr = bytes(body[p:p + hdr_len])
            p += hdr_len
            subfn = sample.pop("subfn_raw")
            sample["subframe"] = subfn & 0xF
            sample["sfn"] = subfn >> 4
            sample["sample"] = len(samples)
            if sample["subframe"] > 9:
                bad.append("sample%d.subframe=%d" % (k, sample["subframe"]))
                sample["subframe"] = None
            if sample["sfn"] > 1023:
                bad.append("sample%d.sfn=%d" % (k, sample["sfn"]))
                sample["sfn"] = None
            if sample["rnti_type"] not in RNTI_NAMES:
                bad.append("sample%d.rnti_type=%d" % (k, sample["rnti_type"]))
            sample["rnti_type_name"] = RNTI_NAMES.get(sample["rnti_type"], "unknown")
            if not downlink:
                sample["bsr_event_name"] = BSR_EVENT.get(sample["bsr_event"], "unknown")
                sample["bsr_trigger_name"] = BSR_TRIGGER.get(sample["bsr_trigger"], "unknown")
            rows, hdr_note = parse_subheaders(hdr, downlink)
            for row in rows:
                row = dict(row)
                row["sample"] = sample["sample"]
                subheaders.append(row)
            sample["lcids"] = ",".join(str(r["lcid"]) for r in rows)
            if hdr_note:
                sample["header_note"] = hdr_note
            header_only = hdr_len < sample[size_key]
            note = ("only the MAC header was logged (%d of %d bytes)" % (hdr_len, sample[size_key])
                    if header_only else "%d bytes logged" % hdr_len)
            if hdr:
                mac_pdus.append({"pdu": hdr, "downlink": downlink,
                                 "rnti_type": QC_RNTI_TO_WIRESHARK.get(sample["rnti_type"], 3),
                                 "sfn": sample["sfn"], "subframe": sample["subframe"], "note": note})
            samples.append(sample)
        if p < end:
            notes.append("%d bytes after the last sample" % (end - p))
        off = end
    if not subpackets:
        notes.append("no subpackets")
    sections = [("samples", samples), ("subheaders", subheaders), ("subpackets", subpackets)]
    decoded = "partial"
    if samples:
        first = samples[0]
        fields["num_samples"] = len(samples)
        fields[size_key] = sum(s[size_key] for s in samples)
        for key in ("sfn", "subframe", "harq_id", "rnti_type", "rnti_type_name", "cell_id"):
            if key in first:
                fields[key] = first[key]
        fields["lcids"] = first["lcids"]
        decoded = "fields" if len(notes) == 1 and not bad else "partial"
    if bad:
        notes.append("implausible: " + ", ".join(bad))
    record = DiagRecord(rec.code, info.name if info else "LTE MAC", version, rec.timestamp, rec.timestamp_raw,
                        body, fields=fields, sections=sections, decoded=decoded,
                        confidence=info.confidence if info else "low", note="; ".join(notes))
    record.mac_pdus = mac_pdus
    return record


def decode_dl_tb(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB063 LTE MAC DL Transport Block."""
    return _decode_tb(rec, info, True)


def decode_ul_tb(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB064 LTE MAC UL Transport Block."""
    return _decode_tb(rec, info, False)


def tb_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "num_samples" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    size_key = "tbs_bytes" if fields["direction"] == "dl" else "grant_bytes"
    return "%d samples %s %d bytes %s LCID %s" % (fields["num_samples"], "TBS" if size_key == "tbs_bytes" else "grant",
                                                  fields[size_key], fields["rnti_type_name"], fields["lcids"])


DECODERS = {"lte_mac_dl_tb": decode_dl_tb, "lte_mac_ul_tb": decode_ul_tb}
