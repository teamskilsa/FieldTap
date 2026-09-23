"""LTE MAC records: 0xB063 (DL transport blocks), 0xB064 (UL transport blocks), 0xB062 (RACH attempt).

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
    UL v7 (13):          Cell id u8, then as v1 (iPhone 17, packet v1 / subpacket 0x08 v7)
Sub-FN: low 4 bits subframe, upper 12 bits SFN.

The iPhone 17 (Qualcomm M25) layouts were derived and validated on the captures of
2026-09-21/22 by this repository's TypeScript engine (web/engine/src/phy/decoders/
lteMac.ts) and are ported here field for field:

0xB064 v1 / subpacket 0x08 v7: the sample layout above; the header bytes that follow
are a MAC PDU header (sub-headers, then the control elements in sub-header order),
so the PHR control element (LCID 26) gives power_headroom_db = (byte & 63) - 23.

0xB063 v50 (0x32) is not a subpacket container: u8 version, 3 reserved, u32 transport
block count @4; per transport block a 16-byte header (u32 size bytes @0, u32 padding
@4, u32 @8 = SFN bits 0-9 | subframe bits 10-13, u8 @12 = carrier bits 0-3 | HARQ
bits 4-7, u8 SDU count @13, u16 MAC header length @14), then per SDU a 12-byte
descriptor whose first 3 bytes are a little-endian 24-bit word (bit 0 control
element, bits 1-6 LCID, bits 7-22 length in bytes) followed, for each SDU, by a tail
of 8 x descriptor byte 9 bytes. A header must be self-consistent (1..8 SDUs, header
length <= 4 * SDUs + 4, 0 < size <= 9422, padding <= size); when the tail rule misses,
the walk scans forward 4 bytes at a time for the next self-consistent header within
two frames of the last one. No MAC PDU bytes exist in this version (nothing goes to
mac-lte). Validated: 99.0% / 99.9% of the blocks found match an 0xB173 transport
block on (SFN, subframe, carrier, HARQ, size); the walk reaches about 80% of the
declared blocks, which the note reports.

0xB062 v1 / subpacket 0x06 v50: the subpacket size EXCLUDES the 4-byte subpacket
header in this record. Body: u8 @1 cell, @2 attempts, @3 result, @4 contention, @5
message bitmask; Msg1 @6 preamble, s16 target power @8; Msg2 u16 TA @18 when mask & 2;
u32 UL EARFCN @37. Validated by the UL EARFCNs of the target cells and the preamble
target power (SIB2's).
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from ..output.fieldtap_diag import QC_RNTI_TO_WIRESHARK
from .records import DiagRecord

DOC_NOTE = "layout from documentation; confirm on a hardware capture"
HW_NOTE = "layout validated on the iPhone 17 (M25) captures of 2026-09-21/22"

RNTI_NAMES = {0: "C-RNTI", 1: "SPS C-RNTI", 2: "P-RNTI", 3: "RA-RNTI", 4: "Temp C-RNTI", 5: "SI-RNTI"}
BSR_EVENT = {0: "none", 1: "periodic", 2: "high data arrival"}
BSR_TRIGGER = {0: "no BSR", 3: "S-BSR", 4: "Pad L-BSR"}

# LCID names, TS 36.321 tables 6.2.1-1 (DL-SCH) and 6.2.1-2 (UL-SCH)
DL_LCID = {0: "CCCH", 24: "Activation/Deactivation (4 octet)", 26: "Long DRX Command",
           27: "Activation/Deactivation (1 octet)", 28: "UE Contention Resolution Identity",
           29: "Timing Advance Command", 30: "DRX Command", 31: "Padding"}
UL_LCID = {0: "CCCH", 24: "Dual Connectivity PHR", 25: "Extended PHR", 26: "PHR", 27: "C-RNTI", 28: "Truncated BSR",
           29: "Short BSR", 30: "Long BSR", 31: "Padding"}

_DL_SAMPLE = {2: ("<HBBHHBHB", ("subfn_raw", "rnti_type", "harq_id", "pmch_id", "tbs_bytes", "rlc_pdus",
                                 "padding_bytes", "hdr_len")),
              4: ("<BBHBBHHBHB", ("sub_id", "cell_id", "subfn_raw", "rnti_type", "harq_id", "pmch_id", "tbs_bytes",
                                   "rlc_pdus", "padding_bytes", "hdr_len"))}
_UL_V1 = ("<BBHHBHBBB", ("harq_id", "rnti_type", "subfn_raw", "grant_bytes", "rlc_pdus", "padding_bytes",
                         "bsr_event", "bsr_trigger", "hdr_len"))
_UL_V2 = ("<BBBBHHBHBBB", ("sub_id", "cell_id") + _UL_V1[1])
_UL_V7 = ("<BBBHHBHBBB", ("cell_id",) + _UL_V1[1])
_UL_SAMPLE = {1: _UL_V1, 2: _UL_V2, 3: _UL_V2, 5: _UL_V2, 7: _UL_V7, 8: _UL_V2}
# subpacket versions whose layout was validated on hardware
_HW_SAMPLE_VERSIONS = {"ul": {7}, "dl": set()}

# Fixed-size UL MAC control elements by LCID (TS 36.321 6.1.3): PHR, C-RNTI, truncated,
# short and long BSR. LCIDs 24 and 25 (extended PHR family) carry an L field instead.
UL_CE_SIZE = {26: 1, 27: 2, 28: 1, 29: 1, 30: 3}
PHR_LCID = 26


def lcid_name(lcid: int, downlink: bool) -> str:
    table = DL_LCID if downlink else UL_LCID
    if lcid in table:
        return table[lcid]
    if 1 <= lcid <= 10:
        return "DTCH/DCCH %d" % lcid
    return "reserved %d" % lcid


def _has_length_field(lcid: int, downlink: bool) -> bool:
    """SDUs carry F/L; so do the uplink's variable-size CEs (LCID 24, 25)."""
    return lcid <= 10 or (not downlink and lcid in (24, 25))


def parse_subheaders(hdr: bytes, downlink: bool) -> tuple:
    """TS 36.321 6.1.2: R/R/E/LCID, then for a variable-size SDU F/L (7 or 15 bits).
    Fixed-size control elements and padding have no length field. Returns (rows, note)."""
    rows = []
    i = 0
    note = ""
    while i < len(hdr):
        octet = hdr[i]
        i += 1
        ext = (octet >> 5) & 1
        lcid = octet & 0x1F
        row = {"lcid": lcid, "lcid_name": lcid_name(lcid, downlink), "extension": ext, "length": None}
        if ext and _has_length_field(lcid, downlink):
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


def ul_control_elements(hdr: bytes) -> tuple:
    """The uplink control elements that follow the sub-headers, in sub-header order:
    [(lcid, payload bytes), ...] and the header bytes used in all (the port of lteMac.ts
    controlElements: the sub-headers are walked again so the count is exact)."""
    subheaders = []
    i = 0
    while i < len(hdr):
        octet = hdr[i]
        ext, lcid = (octet >> 5) & 1, octet & 0x1F
        i += 1
        length = None
        if ext and _has_length_field(lcid, False):
            if i >= len(hdr):
                break
            if hdr[i] & 0x80:
                if i + 1 >= len(hdr):
                    break
                length = ((hdr[i] & 0x7F) << 8) | hdr[i + 1]
                i += 2
            else:
                length = hdr[i] & 0x7F
                i += 1
        subheaders.append((lcid, length))
        if not ext:
            break
    ces = []
    for lcid, length in subheaders:
        n = UL_CE_SIZE.get(lcid)
        if n is None and lcid in (24, 25):
            n = length
        if n is None:
            continue
        ces.append((lcid, bytes(hdr[min(i, len(hdr)):min(i + n, len(hdr))])))
        i += n
    return ces, i


def power_headroom_db(ces: list):
    """PH index - 23 of the first PHR CE (LCID 26): the lower edge of its 1 dB bin (TS 36.133 9.1.8.4)."""
    for lcid, payload in ces:
        if lcid == PHR_LCID and payload:
            return (payload[0] & 63) - 23
    return None


def _decode_tb(rec: LogRecord, info, downlink: bool) -> Optional[DiagRecord]:
    body = rec.body
    if len(body) < 4:
        return None
    version, num_subpackets = body[0], body[1]
    layouts = _DL_SAMPLE if downlink else _UL_SAMPLE
    size_key = "tbs_bytes" if downlink else "grant_bytes"
    fields = {"version": version, "num_subpackets": num_subpackets, "direction": "dl" if downlink else "ul"}
    notes = []
    subpackets, samples, subheaders, mac_pdus = [], [], [], []
    hw_versions = _HW_SAMPLE_VERSIONS["dl" if downlink else "ul"]
    source_note = DOC_NOTE
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
        if sp_version in hw_versions:
            source_note = HW_NOTE
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
            if not downlink:
                ces, used = ul_control_elements(hdr)
                sample["header_consistent"] = int(used == hdr_len)
                phr = power_headroom_db(ces)
                if phr is not None:
                    sample["power_headroom_db"] = phr
            header_only = hdr_len < sample[size_key]
            note = ("only the MAC header was logged (%d of %d bytes)" % (hdr_len, sample[size_key])
                    if header_only else "%d bytes logged" % hdr_len)
            if hdr:
                mac_pdus.append({"pdu": hdr, "downlink": downlink,
                                 "rnti_type": QC_RNTI_TO_WIRESHARK.get(sample["rnti_type"], 3),
                                 "sfn": sample["sfn"], "subframe": sample["subframe"], "note": note})
            samples.append(sample)
        if p < end and not (sp_version in hw_versions and end - p < 4):
            # (v7 pads its subpacket to a multiple of 4 bytes; 1-3 trailing bytes are that padding)
            notes.append("%d bytes after the last sample" % (end - p))
        off = end
    if not subpackets:
        notes.append("no subpackets")
    notes.insert(0, source_note)
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
        if not downlink:
            phrs = [s["power_headroom_db"] for s in samples if "power_headroom_db" in s]
            if phrs:
                fields["power_headroom_db"] = phrs[0]
        decoded = "fields" if len(notes) == 1 and not bad else "partial"
    if bad:
        notes.append("implausible: " + ", ".join(bad))
    record = DiagRecord(rec.code, info.name if info else "LTE MAC", version, rec.timestamp, rec.timestamp_raw,
                        body, fields=fields, sections=sections, decoded=decoded,
                        confidence=info.confidence if info else "low", note="; ".join(notes))
    record.mac_pdus = mac_pdus
    return record


def decode_dl_tb(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB063 LTE MAC DL Transport Block: the subpacket container (v1), or the iPhone 17's v50."""
    if rec.body and rec.body[0] == DL_TB_V50_VERSION:
        return _decode_dl_tb_v50(rec, info)
    return _decode_tb(rec, info, True)


# --- 0xB063 v50 (0x32): a walk over self-consistent transport-block headers -----------------

DL_TB_V50_VERSION = 0x32
_TB_HEADER_BYTES = 16
_SDU_DESCRIPTOR_BYTES = 12
MAX_TB_BYTES = 9422          # the largest LTE transport block, 75,376 bits (TS 36.213)


def _tb_header_v50(body: bytes, o: int):
    """A candidate transport-block header at `o`, or None when it fails the self-consistency
    test the walk resynchronises on (lteMac.ts transportBlockHeader)."""
    if o < 0 or o + _TB_HEADER_BYTES > len(body):
        return None
    size, padding, word = struct.unpack_from("<III", body, o)
    carrier_harq, n_sdu = body[o + 12], body[o + 13]
    header_length = struct.unpack_from("<H", body, o + 14)[0]
    if n_sdu < 1 or n_sdu > 8:
        return None
    if header_length > 4 * n_sdu + 4:
        return None
    if size == 0 or size > MAX_TB_BYTES or padding > size:
        return None
    return {"size_bytes": size, "padding_bytes": padding, "sfn": word & 0x3FF, "subframe": (word >> 10) & 0xF,
            "carrier": carrier_harq & 0xF, "harq_id": (carrier_harq >> 4) & 0xF, "header_length": header_length,
            "num_sdus": n_sdu}


def _decode_dl_tb_v50(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    body = rec.body
    if len(body) < 8:
        return None
    declared = struct.unpack_from("<I", body, 4)[0]
    fields = {"version": DL_TB_V50_VERSION, "direction": "dl", "num_transport_blocks": declared}
    notes = [HW_NOTE]
    blocks, sdus = [], []
    pos, resynced = 8, 0
    while len(blocks) < declared:
        tb = _tb_header_v50(body, pos)
        if tb is None:
            # The tail rule missed: the next self-consistent header that is also near in time.
            last = blocks[-1] if blocks else None
            nxt = -1
            q = pos
            while q + _TB_HEADER_BYTES <= len(body):
                cand = _tb_header_v50(body, q)
                if cand is not None and (last is None or (cand["sfn"] - last["sfn"] + 1024) % 1024 <= 2):
                    nxt = q
                    break
                q += 4
            if nxt < 0:
                break
            resynced += 1
            pos = nxt
            continue
        start = pos + _TB_HEADER_BYTES
        tb["tb"] = len(blocks)
        tail = 0
        lcids = []
        for i in range(tb["num_sdus"]):
            p = start + _SDU_DESCRIPTOR_BYTES * i
            if p + 3 > len(body):
                break
            word = body[p] | (body[p + 1] << 8) | (body[p + 2] << 16)
            lcid = (word >> 1) & 0x3F
            sdus.append({"tb": tb["tb"], "control": word & 1, "lcid": lcid, "lcid_name": lcid_name(lcid, True),
                         "length_bytes": (word >> 7) & 0xFFFF})
            lcids.append(str(lcid))
            # A data SDU is followed by a PDCP tail of 8 x descriptor byte 9 bytes (measured, not guessed).
            if p + _SDU_DESCRIPTOR_BYTES <= len(body):
                tail += 8 * body[p + 9]
        tb["lcids"] = ",".join(lcids)
        blocks.append(tb)
        pos = start + _SDU_DESCRIPTOR_BYTES * tb["num_sdus"] + tail
    exact = pos == len(body) and len(blocks) == declared
    fields.update({"num_found": len(blocks), "walk_exact": int(exact), "resynced": resynced})
    if blocks:
        first = blocks[0]
        fields.update({"tbs_bytes": sum(b["size_bytes"] for b in blocks),
                       "padding_bytes": sum(b["padding_bytes"] for b in blocks),
                       "sfn": first["sfn"], "subframe": first["subframe"], "harq_id": first["harq_id"],
                       "cell_id": first["carrier"], "lcids": first["lcids"]})
    if not exact:
        if len(blocks) == declared:
            notes.append("walk found all %d transport blocks but ended %d bytes before the end of the body (%d resyncs)"
                         % (declared, len(body) - pos, resynced))
        else:
            notes.append("walk found %d of %d declared transport blocks (%d resyncs); the rest is not read"
                         % (len(blocks), declared, resynced))
    notes.append("no MAC PDU bytes in this version")
    return DiagRecord(rec.code, info.name if info else "LTE MAC", DL_TB_V50_VERSION, rec.timestamp, rec.timestamp_raw,
                      body, fields=fields, sections=[("transport_blocks", blocks), ("sdus", sdus)],
                      decoded="fields" if blocks else "partial",
                      confidence=info.confidence if info else "low", note="; ".join(notes))


def decode_ul_tb(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB064 LTE MAC UL Transport Block."""
    return _decode_tb(rec, info, False)


def tb_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "num_transport_blocks" in fields:
        if "tbs_bytes" not in fields:
            return "v%d, %d TB declared, none found (partial)" % (fields["version"], fields["num_transport_blocks"])
        return "%d of %d TB TBS %d bytes LCID %s" % (fields["num_found"], fields["num_transport_blocks"],
                                                    fields["tbs_bytes"], fields["lcids"])
    if "num_samples" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    size_key = "tbs_bytes" if fields["direction"] == "dl" else "grant_bytes"
    return "%d samples %s %d bytes %s LCID %s" % (fields["num_samples"], "TBS" if size_key == "tbs_bytes" else "grant",
                                                  fields[size_key], fields["rnti_type_name"], fields["lcids"])


# --- 0xB062 LTE MAC RACH Attempt ---------------------------------------------------------------

RACH_SUBPACKET = 0x06
RACH_SUBPACKET_VERSION = 50
_RACH_MIN_BODY = 41


def decode_rach_attempt(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB062 v1 / subpacket 0x06 v50: one row per attempt with the preamble, its target
    power, the RAR's timing advance and the UL EARFCN (lteMac.ts decodeB062). The
    subpacket size excludes the 4-byte subpacket header in this record."""
    body = rec.body
    if len(body) < 4:
        return None
    version, num_subpackets = body[0], body[1]
    fields = {"version": version, "num_subpackets": num_subpackets}
    notes = [HW_NOTE]
    subpackets, attempts = [], []
    off = 4
    for _ in range(num_subpackets):
        if off + 4 > len(body):
            if not subpackets:
                return None
            notes.append("subpacket header beyond the body")
            break
        sp_id, sp_version, sp_size = struct.unpack_from("<BBH", body, off)
        start = off + 4
        off = start + sp_size
        subpackets.append({"subpacket_id": sp_id, "subpacket_version": sp_version, "subpacket_size": sp_size})
        if sp_id != RACH_SUBPACKET:
            continue
        if sp_version != RACH_SUBPACKET_VERSION:
            notes.append("subpacket version %d not implemented" % sp_version)
            continue
        if sp_size < _RACH_MIN_BODY or start + _RACH_MIN_BODY > len(body):
            if not attempts:
                return None
            notes.append("subpacket shorter than %d bytes" % _RACH_MIN_BODY)
            break
        mask = body[start + 5]
        row = {"attempt": len(attempts), "cell_id": body[start + 1], "num_attempts": body[start + 2],
               "result": body[start + 3], "contention": body[start + 4], "msg_mask": mask, "preamble": body[start + 6],
               "preamble_target_dbm": struct.unpack_from("<h", body, start + 8)[0],
               "ta_rar": struct.unpack_from("<H", body, start + 18)[0] if mask & 2 else None,
               "ul_earfcn": struct.unpack_from("<I", body, start + 37)[0]}
        attempts.append(row)
    if not subpackets:
        notes.append("no subpackets")
    if attempts:
        first = dict(attempts[0])
        first.pop("attempt")
        fields.update(first)
        fields["num_rach_attempts"] = len(attempts)
    return DiagRecord(rec.code, info.name if info else "LTE MAC RACH Attempt", version, rec.timestamp,
                      rec.timestamp_raw, body, fields=fields,
                      sections=[("attempts", attempts), ("subpackets", subpackets)],
                      decoded="fields" if attempts else "partial",
                      confidence=info.confidence if info else "low", note="; ".join(notes))


def rach_attempt_summary(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_lte.lua prints the same."""
    if "preamble" not in fields:
        return "v%d (partial)" % fields.get("version", 0)
    ta = "n/a" if fields.get("ta_rar") is None else str(fields["ta_rar"])
    return "cell %d attempt %d result %d preamble %d target %d dBm TA %s UL EARFCN %d" % (
        fields["cell_id"], fields["num_attempts"], fields["result"], fields["preamble"], fields["preamble_target_dbm"],
        ta, fields["ul_earfcn"])


DECODERS = {"lte_mac_dl_tb": decode_dl_tb, "lte_mac_ul_tb": decode_ul_tb, "lte_mac_rach": decode_rach_attempt}
