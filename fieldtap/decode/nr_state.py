"""NR NAS state records: 0xB80C 5GMM state.

Not an OTA message: a snapshot of where the 5GMM state machine is, with the
registered PLMN, the 5G-GUTI and the TAC. Two independent decoders agree on the
version-1 layout (docs/research/qualcomm-measurement-log-layouts.md, "0xB80C").

The register once routed this code to the NAS locator, and the synthetic corpus
still carries a 0xB80C record that holds a NAS message. So: a record that fits
the state layout is a state record; anything else is offered to the NAS locator
as before, and a real capture's state records are never mistaken for messages
(they hold no NAS PDU, so the locator finds nothing in them).
"""

from __future__ import annotations

import struct
from typing import Optional

from ..diag.protocol import LogRecord
from .nr_common import DOC_NOTE
from .records import DiagRecord

STATE_LAYOUT_LEN = 26        # u32 version + 22 bytes of body
MM5G_STATE = {1: "deregistered", 2: "registered_initiated", 3: "registered", 4: "service_request_initiated"}
DEREGISTERED_SUBSTATE = {0: "normal_service", 1: "plmn_search", 2: "no_cell_available", 5: "limited_service"}
UPDATE_STATUS = {0: "updated", 1: "not_updated"}
UE_ID_TYPE = {2: "5g_guti"}


def decode_plmn(octets: bytes) -> str:
    """3GPP TS 24.501 / 24.008 PLMN encoding -> "mccmnc" (2- or 3-digit MNC)."""
    if len(octets) < 3:
        return ""
    d = [octets[0] & 0xF, octets[0] >> 4, octets[1] & 0xF, octets[1] >> 4, octets[2] & 0xF, octets[2] >> 4]
    mcc = "%d%d%d" % (d[0], d[1], d[2])
    mnc3 = d[3]
    mnc = "%d%d" % (d[4], d[5]) + ("" if mnc3 == 0xF else "%d" % mnc3)
    return mcc + mnc


def decode_mm5g_state(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB80C NR NAS MM5G State (version 1)."""
    body = rec.body
    if len(body) >= STATE_LAYOUT_LEN:
        version = struct.unpack_from("<I", body, 0)[0]
        state = body[4]
        if version == 1 and state in MM5G_STATE:
            substate = struct.unpack_from("<H", body, 5)[0]
            plmn = decode_plmn(body[7:10])
            ue_id_type = body[10]
            guti_plmn = decode_plmn(body[11:14])
            amf_region = body[14]
            amf_set_raw = struct.unpack_from(">H", body, 15)[0]
            amf_pointer = body[17]
            tmsi = struct.unpack_from(">I", body, 18)[0]
            update_status = body[22]
            tac = (body[23] << 16) | (body[24] << 8) | body[25]
            fields = {
                "state": MM5G_STATE[state], "state_code": state,
                "substate": DEREGISTERED_SUBSTATE.get(substate, "substate_%d" % substate), "substate_code": substate,
                "plmn": plmn,
                "guti_ue_id_type": UE_ID_TYPE.get(ue_id_type, "type_%d" % ue_id_type),
                "guti_plmn": guti_plmn, "amf_region_id": amf_region, "amf_set_id": amf_set_raw,
                "amf_pointer": amf_pointer, "tmsi_5g": "0x%08X" % tmsi,
                "update_status": UPDATE_STATUS.get(update_status, "status_%d" % update_status),
                "tac": tac,
            }
            return DiagRecord(rec.code, info.name if info else "NR NAS MM5G State", version, rec.timestamp,
                              rec.timestamp_raw, body, fields=fields, decoded="fields",
                              confidence=info.confidence if info else "medium", note=DOC_NOTE)
    # Not the state layout: the NAS locator, as this code was decoded before.
    from . import nas
    return nas.decode(rec, info)


DECODERS = {"nr_mm5g_state": decode_mm5g_state}
