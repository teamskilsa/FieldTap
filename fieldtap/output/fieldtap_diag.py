"""The "fieldtap-diag" exported-PDU payload: any diag log record, verbatim, with a
small header Wireshark's FieldTap plugin (wireshark/fieldtap.lua) reads.

RRC and NAS messages already reach Wireshark as native PDUs. Every other
record the modem logged - cell identity, measurements, MAC and PHY reports,
state logs, and codes nobody has a layout for - used to be dropped on the
way to the pcap. This wrapper carries them all, so the capture file is
complete: the bytes are present even without the plugin, and decoded into
fields with it.

Layout (little-endian, fixed):

    'F' 'T' 'D' 'G'     magic
    u8   format         1
    u16  log_code       the diag log code (0xB193 ...)
    u8   flags          bit 0: the modem timestamp was plausible (network time)
                        bit 1: FieldTap decoded fields for this record
    u64  timestamp_raw  the log header's Qualcomm timestamp, untouched
    u16  body_len       length of the record body that follows
    body                the log record body, byte for byte
"""

from __future__ import annotations

import struct

MAGIC = b"FTDG"
FORMAT = 1
DISSECTOR = "fieldtap-diag"
HEADER = struct.Struct("<4sBHBQH")

FLAG_TIMESTAMP_PLAUSIBLE = 0x01
FLAG_DECODED = 0x02


def build(log_code: int, timestamp_raw: int, body: bytes, timestamp_plausible: bool = True,
          decoded: bool = False) -> bytes:
    flags = (FLAG_TIMESTAMP_PLAUSIBLE if timestamp_plausible else 0) | (FLAG_DECODED if decoded else 0)
    if len(body) > 0xFFFF:
        raise ValueError("record body too long for a fieldtap-diag frame: %d bytes" % len(body))
    return HEADER.pack(MAGIC, FORMAT, log_code & 0xFFFF, flags, timestamp_raw & 0xFFFFFFFFFFFFFFFF, len(body)) + body


def parse(frame: bytes) -> dict:
    """-> {"log_code", "flags", "timestamp_raw", "body"}; raises ValueError on a bad frame."""
    if len(frame) < HEADER.size:
        raise ValueError("fieldtap-diag frame shorter than its header")
    magic, fmt, code, flags, ts, length = HEADER.unpack_from(frame, 0)
    if magic != MAGIC:
        raise ValueError("not a fieldtap-diag frame")
    if fmt != FORMAT:
        raise ValueError("fieldtap-diag format %d is not supported" % fmt)
    body = frame[HEADER.size:HEADER.size + length]
    if len(body) != length:
        raise ValueError("fieldtap-diag frame truncated: %d of %d body bytes" % (len(body), length))
    return {"log_code": code, "flags": flags, "timestamp_raw": ts, "body": body,
            "timestamp_plausible": bool(flags & FLAG_TIMESTAMP_PLAUSIBLE), "decoded": bool(flags & FLAG_DECODED)}


# --- MAC-LTE framed (Wireshark's own encapsulation for a MAC PDU with context) -----------------
#
# The "mac-lte-framed" exported-PDU dissector reads a context header first, then the
# MAC PDU, and hands the PDU to mac-lte -> rlc-lte -> pdcp-lte. Verified on Wireshark 4.0.1:
# the payload starts straight at the radio-type byte (the "mac-lte" signature that the UDP
# heuristic looks for is not part of it).

MAC_LTE_DISSECTOR = "mac-lte-framed"
MAC_LTE_RADIO_FDD = 1
MAC_LTE_RADIO_TDD = 2
MAC_LTE_DIR_UL = 0
MAC_LTE_DIR_DL = 1
# Wireshark's RNTI types
MAC_LTE_RNTI_NONE, MAC_LTE_RNTI_P, MAC_LTE_RNTI_RA, MAC_LTE_RNTI_C, MAC_LTE_RNTI_SI, MAC_LTE_RNTI_SPS = 0, 1, 2, 3, 4, 5
_TAG_RNTI, _TAG_UEID, _TAG_SUBFRAME, _TAG_PAYLOAD = 0x02, 0x03, 0x04, 0x01

# Qualcomm's RNTI type in the MAC transport-block logs -> Wireshark's
QC_RNTI_TO_WIRESHARK = {0: MAC_LTE_RNTI_C, 1: MAC_LTE_RNTI_SPS, 2: MAC_LTE_RNTI_P, 3: MAC_LTE_RNTI_RA,
                        4: MAC_LTE_RNTI_C, 5: MAC_LTE_RNTI_SI}


def build_mac_lte_framed(pdu: bytes, downlink: bool, rnti_type: int = MAC_LTE_RNTI_C, rnti: int = None,
                         ueid: int = None, sfn: int = None, subframe: int = None, tdd: bool = False) -> bytes:
    out = bytearray([MAC_LTE_RADIO_TDD if tdd else MAC_LTE_RADIO_FDD,
                     MAC_LTE_DIR_DL if downlink else MAC_LTE_DIR_UL, rnti_type & 0xFF])
    if rnti is not None:
        out += bytes([_TAG_RNTI]) + struct.pack(">H", rnti & 0xFFFF)
    if ueid is not None:
        out += bytes([_TAG_UEID]) + struct.pack(">H", ueid & 0xFFFF)
    if sfn is not None and subframe is not None:
        out += bytes([_TAG_SUBFRAME]) + struct.pack(">H", ((sfn & 0xFFF) << 4) | (subframe & 0xF))
    out += bytes([_TAG_PAYLOAD]) + pdu
    return bytes(out)
