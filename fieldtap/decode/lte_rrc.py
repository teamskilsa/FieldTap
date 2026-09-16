"""0xB0C0 LTE RRC OTA Packet.

Record body:  packet_version(u8)  header(layout by version)  RRC PDU

Three header layouts are known across modem generations; they differ in the
width of the EARFCN and in whether a SIB mask is present. The PDU-number to
channel mapping also changed three times. Both tables are keyed on the
packet version and both are self-checked (see layout.py).
"""

from __future__ import annotations

from typing import Optional

from ..diag.protocol import LogRecord
from . import channels
from .layout import Layout, resolve_header, sfn_subfn_u16
from .msgnames import rrc_message_name
from .records import DecodedMessage

HDR_A = Layout("A", "<BBBHHHBH", ("rrc_rel", "rrc_ver", "rb_id", "pci", "earfcn", "sfn_subfn", "pdu_num", "length"))
HDR_B = Layout("B", "<BBBHIHBH", ("rrc_rel", "rrc_ver", "rb_id", "pci", "earfcn", "sfn_subfn", "pdu_num", "length"))
HDR_C = Layout("C", "<BBBHIHBIH", ("rrc_rel", "rrc_ver", "rb_id", "pci", "earfcn", "sfn_subfn", "pdu_num", "sib_mask", "length"))
# HDR_D: the NR-era layout, seen on a Snapdragon 8 Gen 1 (SM8450) running
# MPSS.DE.2.0 and reporting packet version 27. It is HDR_C with three extra
# bytes before the PCI. The first is a further release/version byte; the
# next two are a 16-bit field whose meaning is not established (it read 0x0060
# on every packet of the reference capture). Nothing in the decode depends on
# either, but they must be consumed or PCI, EARFCN and pdu_num all shift.
HDR_D = Layout("D", "<BBBHHIHBIH", ("rrc_rel", "rrc_ver", "nr_rrc_rel", "unknown_u16",
                                    "pci", "earfcn", "sfn_subfn", "pdu_num", "sib_mask", "length"))
CANDIDATES = (HDR_A, HDR_B, HDR_C, HDR_D)

PDU_MAP_A = {1: "BCCH_BCH", 2: "BCCH_DL_SCH", 3: "MCCH", 4: "PCCH",
             5: "DL_CCCH", 6: "DL_DCCH", 7: "UL_CCCH", 8: "UL_DCCH"}
PDU_MAP_B = {8: "BCCH_BCH", 9: "BCCH_DL_SCH", 10: "MCCH", 11: "PCCH",
             12: "DL_CCCH", 13: "DL_DCCH", 14: "UL_CCCH", 15: "UL_DCCH"}
PDU_MAP_C = {1: "BCCH_BCH", 2: "BCCH_DL_SCH", 4: "MCCH", 5: "PCCH",
             6: "DL_CCCH", 7: "DL_DCCH", 8: "UL_CCCH", 9: "UL_DCCH"}
PDU_MAP_D = {1: "BCCH_BCH", 3: "BCCH_DL_SCH", 6: "MCCH", 7: "PCCH",
             8: "DL_CCCH", 9: "DL_DCCH", 10: "UL_CCCH", 11: "UL_DCCH",
             45: "BCCH_BCH_NB", 46: "BCCH_DL_SCH_NB", 47: "PCCH_NB", 48: "DL_CCCH_NB",
             49: "DL_DCCH_NB", 50: "UL_CCCH_NB", 52: "UL_DCCH_NB"}
PDU_MAPS = {"A": PDU_MAP_A, "B": PDU_MAP_B, "C": PDU_MAP_C, "D": PDU_MAP_D}

# packet version -> (header layout, pdu map name)
VERSION_TABLE = {
    2: (HDR_A, "A"), 3: (HDR_A, "A"), 4: (HDR_A, "A"), 6: (HDR_A, "A"), 7: (HDR_A, "A"),
    8: (HDR_A, "A"), 13: (HDR_A, "A"), 22: (HDR_A, "A"),
    9: (HDR_B, "B"), 12: (HDR_B, "B"),
    14: (HDR_C, "C"), 15: (HDR_C, "C"), 16: (HDR_C, "C"),
    19: (HDR_C, "D"), 26: (HDR_C, "D"),
    # 27 verified against a live SM8450 capture (PCI 235, EARFCN 5110, band 12).
    # 26 is left on HDR_C: the only v26 evidence is the synthetic corpus, and no
    # handset has been seen emitting it. resolve_header probes anyway, so a real
    # v26 device that uses the longer header still decodes.
    27: (HDR_D, "D"),
}


def _guess_map(version: int) -> str:
    if version >= 19:
        return "D"
    if version >= 14:
        return "C"
    if version >= 9:
        return "B"
    return "A"


def decode(rec: LogRecord, info=None) -> Optional[DecodedMessage]:
    body = rec.body
    if len(body) < 1 + HDR_A.size:
        return None
    version = body[0]
    preferred, map_name = VERSION_TABLE.get(version, (None, _guess_map(version)))
    match = resolve_header(body, 1, preferred, CANDIDATES)
    if match is None:
        return None
    f = match.fields
    payload = body[match.header_end:]
    if match.source == "forced":
        # Nothing fitted; keep whatever the preferred layout says the length is,
        # but never run past the record.
        payload = payload[: f["length"]] if 0 < f["length"] <= len(payload) else payload
    pdu_map = PDU_MAPS[map_name]
    key = pdu_map.get(f["pdu_num"])
    channel = channels.LTE_CHANNELS.get(key) if key else None
    if channel is None:
        # An unknown version may use another era's numbering; accept a unique hit.
        hits = {m: pm[f["pdu_num"]] for m, pm in PDU_MAPS.items() if f["pdu_num"] in pm}
        if version not in VERSION_TABLE and len(set(hits.values())) == 1:
            key = next(iter(hits.values()))
            channel = channels.LTE_CHANNELS[key]
            map_name = "?" + next(iter(hits))
        else:
            channel = channels.unknown_channel(f["pdu_num"])
    sfn, subfn = sfn_subfn_u16(f["sfn_subfn"])
    fields = {
        "rrc_rel": f["rrc_rel"], "rrc_ver": f["rrc_ver"], "pci": f["pci"],
        "earfcn": f["earfcn"], "sfn": sfn, "subfn": subfn, "pdu_num": f["pdu_num"],
        "length": f["length"], "layout": match.layout.name, "layout_source": match.source,
        "pdu_map": map_name,
    }
    for optional in ("rb_id", "nr_rrc_rel", "sib_mask"):
        if optional in f:
            fields[optional] = f[optional]
    return DecodedMessage(
        rat="lte", layer="rrc", channel=channel, direction=channel.direction,
        payload=bytes(payload), timestamp=rec.timestamp, log_code=rec.code,
        version=version, fields=fields,
        name=rrc_message_name("lte", channel.key, payload),
    )
