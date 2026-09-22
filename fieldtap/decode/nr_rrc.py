"""0xB821 NR RRC OTA Packet.

Record body:  packet_version(u32)  header(layout by version)  RRC PDU

The header carries, in order: RRC release, RRC version, radio bearer id,
physical cell id, NR-ARFCN, frame/subframe, PDU number, SIB mask, message
length. Newer packet versions widen the frame/subframe field. Because every
layout ends in the message length, the choice is verified against the record
rather than trusted (layout.py). Versions not in the table are probed.
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from . import channels
from .layout import Layout, resolve_header, sfn_subfn_u16
from .msgnames import rrc_message_name
from .records import DecodedMessage

HDR_A = Layout("A", "<BBBHIHBIH", ("rrc_rel", "rrc_ver", "rb_id", "pci", "arfcn", "sfn_subfn", "pdu_num", "sib_mask", "length"))
HDR_B = Layout("B", "<BBBHIIBIH", ("rrc_rel", "rrc_ver", "rb_id", "pci", "arfcn", "sfn_subfn", "pdu_num", "sib_mask", "length"))
# HDR_N26: the iPhone 17 (M25 modem), packet version 26, 35 bytes with the
# version. Between the PCI and the NR-ARFCN sit eight bytes that carry the cell
# global identity (NCGI): they are consumed, never output. A 3-byte frame/slot
# field, and four reserved bytes after the length. Verified on the recovered
# QDSS trace: the length fits in 7 of 7 records.
HDR_N26 = Layout("N26", "<BBBH8sI3sBIH4s", ("rrc_rel", "rrc_ver", "rb_id", "pci", "ncgi", "arfcn",
                                           "sfn_subfn", "pdu_num", "sib_mask", "length", "reserved4"))
CANDIDATES = (HDR_A, HDR_B, HDR_N26)

VERSION_TABLE = {
    7: HDR_A, 9: HDR_A, 12: HDR_A, 14: HDR_A,
    15: HDR_B, 17: HDR_B, 19: HDR_B, 23: HDR_B, 25: HDR_B, 27: HDR_B,
    26: HDR_N26,
}

PDU_MAP = {
    1: "BCCH_BCH", 2: "BCCH_DL_SCH", 3: "DL_CCCH", 4: "DL_DCCH", 5: "PCCH",
    6: "UL_CCCH", 7: "UL_CCCH1", 8: "UL_DCCH",
    9: "RRC_RECONFIGURATION", 10: "RRC_RECONFIGURATION_COMPLETE",
    # Version 26 numbers the EN-DC containers 11 and 12, and logs the
    # RadioBearerConfig of an SCG addition on its own as 36.
    11: "RRC_RECONFIGURATION", 12: "RRC_RECONFIGURATION_COMPLETE",
    36: "RADIO_BEARER_CONFIG",
}

VERSION_OFFSET = 4


def decode(rec: LogRecord, info=None) -> Optional[DecodedMessage]:
    body = rec.body
    if len(body) < VERSION_OFFSET + HDR_A.size:
        return None
    version = struct.unpack_from("<I", body, 0)[0]
    preferred = VERSION_TABLE.get(version)
    match = resolve_header(body, VERSION_OFFSET, preferred, CANDIDATES)
    if match is None:
        return None
    f = match.fields
    payload = body[match.header_end:]
    if match.source == "forced":
        payload = payload[: f["length"]] if 0 < f["length"] <= len(payload) else payload
    key = PDU_MAP.get(f["pdu_num"])
    channel = channels.NR_CHANNELS.get(key) if key else channels.unknown_channel(f["pdu_num"])
    fields = {
        "rrc_rel": f["rrc_rel"], "rrc_ver": f["rrc_ver"], "rb_id": f["rb_id"], "pci": f["pci"],
        "arfcn": f["arfcn"], "pdu_num": f["pdu_num"], "sib_mask": f["sib_mask"],
        "length": f["length"], "layout": match.layout.name, "layout_source": match.source,
    }
    if match.layout is HDR_A:
        fields["sfn"], fields["subfn"] = sfn_subfn_u16(f["sfn_subfn"])
    elif isinstance(f["sfn_subfn"], bytes):
        # HDR_N26's 3-byte frame/slot field: the packing is not confirmed either.
        fields["sfn_subfn_raw"] = int.from_bytes(f["sfn_subfn"], "little")
    else:
        # 32-bit frame field: the packing is not confirmed, keep it raw.
        fields["sfn_subfn_raw"] = f["sfn_subfn"]
    return DecodedMessage(
        rat="nr", layer="rrc", channel=channel, direction=channel.direction,
        payload=bytes(payload), timestamp=rec.timestamp, log_code=rec.code,
        version=version, fields=fields,
        name=rrc_message_name("nr", channel.key, payload),
    )
