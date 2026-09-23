"""NR NAS state records: 0xB80C 5GMM state.

Not an OTA message: a snapshot of where the 5GMM state machine is, with the
registered PLMN, the 5G-GUTI and the TAC. Two independent decoders agree on the
version-1 layout, and one of them documents packet version 3.0 (the NR minor/major
pair 0x00030000) with the identical body (docs/research/qualcomm-measurement-log-layouts.md,
"0xB80C"). The iPhone 17 (M25) writes 3.0: the one record in the 2026-09-21 capture
is 27 bytes, the version-1 body plus one trailing byte, and read that way its PLMN
is the operator whose n5 / n77 carriers the same capture measures and its GUTI is
all 0xFF (none assigned yet), which is what pins the layout down. The trailing
byte(s) are not read.

The 5G-TMSI is a subscriber identifier. The 3.0 decode never reports it: only
whether a GUTI is assigned and, when it is, the network part (PLMN, AMF region,
set and pointer). The version-1 decode is left as it was.

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
from .nr_common import DOC_NOTE, IPHONE_NOTE, read_version, version_label
from .records import DiagRecord

STATE_LAYOUT_LEN = 26        # u32 version + 22 bytes of body
STATE_VERSION_30 = (3, 0)
GUTI_NONE = b"\xff" * 12     # the 12 GUTI bytes before any registration
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


def _state_fields(body: bytes) -> dict:
    """The version-1 body at offsets 4..25, without the 5G-TMSI."""
    state = body[4]
    substate = struct.unpack_from("<H", body, 5)[0]
    ue_id_type = body[10]
    update_status = body[22]
    return {
        "state": MM5G_STATE[state], "state_code": state,
        "substate": DEREGISTERED_SUBSTATE.get(substate, "substate_%d" % substate), "substate_code": substate,
        "plmn": decode_plmn(body[7:10]),
        "guti_ue_id_type": UE_ID_TYPE.get(ue_id_type, "type_%d" % ue_id_type),
        "guti_plmn": decode_plmn(body[11:14]), "amf_region_id": body[14],
        "amf_set_id": struct.unpack_from(">H", body, 15)[0], "amf_pointer": body[17],
        "update_status": UPDATE_STATUS.get(update_status, "status_%d" % update_status),
        "tac": (body[23] << 16) | (body[24] << 8) | body[25],
    }


def decode_mm5g_state(rec: LogRecord, info=None) -> Optional[DiagRecord]:
    """0xB80C NR NAS MM5G State: version 1 (documented) and 3.0 (iPhone 17)."""
    body = rec.body
    if len(body) >= STATE_LAYOUT_LEN:
        version = struct.unpack_from("<I", body, 0)[0]
        major, minor, _raw = read_version(body)
        state = body[4]
        if version == 1 and state in MM5G_STATE:
            fields = _state_fields(body)
            fields["tmsi_5g"] = "0x%08X" % struct.unpack_from(">I", body, 18)[0]
            return DiagRecord(rec.code, info.name if info else "NR NAS MM5G State", version, rec.timestamp,
                              rec.timestamp_raw, body, fields=fields, decoded="fields",
                              confidence=info.confidence if info else "medium", note=DOC_NOTE)
        if (major, minor) == STATE_VERSION_30 and state in MM5G_STATE:
            fields = {"version": version_label(major, minor)}
            fields.update(_state_fields(body))
            assigned = body[10:22] != GUTI_NONE
            fields["guti_assigned"] = assigned
            if not assigned:
                for name in ("guti_ue_id_type", "guti_plmn", "amf_region_id", "amf_set_id", "amf_pointer"):
                    del fields[name]
            notes = ["5G-TMSI not reported"]
            if len(body) > STATE_LAYOUT_LEN:
                notes.append("%d trailing byte(s) not read" % (len(body) - STATE_LAYOUT_LEN))
            notes.append(IPHONE_NOTE)
            return DiagRecord(rec.code, info.name if info else "NR NAS MM5G State", version, rec.timestamp,
                              rec.timestamp_raw, body, fields=fields, decoded="fields",
                              confidence=info.confidence if info else "medium", note="; ".join(notes))
    # Not the state layout: the NAS locator, as this code was decoded before.
    from . import nas
    return nas.decode(rec, info)


def summary_mm5g_state(fields: dict) -> str:
    """The Info-column line; wireshark/fieldtap_nr.lua prints the same."""
    return "%s PLMN %s TAC %d" % (fields["state"], fields["plmn"], fields["tac"])


DECODERS = {"nr_mm5g_state": decode_mm5g_state}
SUMMARIES = {0xB80C: summary_mm5g_state}
