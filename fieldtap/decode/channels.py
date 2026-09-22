"""Logical channels and how each one reaches a Wireshark dissector.

`dissector` is the registered dissector name used on the exported-PDU link
type (stock Wireshark, no plugin). `gsmtap_subtype` is the GSMTAP LTE RRC
sub-type, which only exists for LTE: Wireshark 4.0 has no GSMTAP payload type
for NR RRC, which is why the exported-PDU path is the primary output.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Channel:
    key: str
    label: str
    direction: str            # "ul" | "dl" | "unknown"
    dissector: str            # exported-PDU dissector name ("data" = undecoded)
    gsmtap_subtype: Optional[int] = None


def _lte(key, label, direction, dissector, subtype):
    return Channel(key, label, direction, dissector, subtype)


# GSMTAP_LTE_RRC_SUB_* numbering from osmocom gsmtap.h
LTE_CHANNELS = {c.key: c for c in (
    _lte("DL_CCCH", "DL-CCCH", "dl", "lte-rrc.dl.ccch", 0),
    _lte("DL_DCCH", "DL-DCCH", "dl", "lte-rrc.dl.dcch", 1),
    _lte("UL_CCCH", "UL-CCCH", "ul", "lte-rrc.ul.ccch", 2),
    _lte("UL_DCCH", "UL-DCCH", "ul", "lte-rrc.ul.dcch", 3),
    _lte("BCCH_BCH", "BCCH-BCH", "dl", "lte-rrc.bcch.bch", 4),
    _lte("BCCH_DL_SCH", "BCCH-DL-SCH", "dl", "lte-rrc.bcch.dl.sch", 5),
    _lte("PCCH", "PCCH", "dl", "lte-rrc.pcch", 6),
    _lte("MCCH", "MCCH", "dl", "lte-rrc.mcch", 7),
    _lte("BCCH_BCH_MBMS", "BCCH-BCH-MBMS", "dl", "lte-rrc.bcch.bch.mbms", 8),
    _lte("BCCH_DL_SCH_BR", "BCCH-DL-SCH-BR", "dl", "lte-rrc.bcch.dl.sch.br", 9),
    _lte("BCCH_DL_SCH_MBMS", "BCCH-DL-SCH-MBMS", "dl", "lte-rrc.bcch.dl.sch.mbms", 10),
    _lte("SC_MCCH", "SC-MCCH", "dl", "lte-rrc.sc.mcch", 11),
    _lte("SBCCH_SL_BCH", "SBCCH-SL-BCH", "dl", "lte-rrc.sbcch.sl.bch", 12),
    _lte("SBCCH_SL_BCH_V2X", "SBCCH-SL-BCH-V2X", "dl", "lte-rrc.sbcch.sl.bch.v2x", 13),
    _lte("DL_CCCH_NB", "DL-CCCH-NB", "dl", "lte-rrc.dl.ccch.nb", 14),
    _lte("DL_DCCH_NB", "DL-DCCH-NB", "dl", "lte-rrc.dl.dcch.nb", 15),
    _lte("UL_CCCH_NB", "UL-CCCH-NB", "ul", "lte-rrc.ul.ccch.nb", 16),
    _lte("UL_DCCH_NB", "UL-DCCH-NB", "ul", "lte-rrc.ul.dcch.nb", 17),
    _lte("BCCH_BCH_NB", "BCCH-BCH-NB", "dl", "lte-rrc.bcch.bch.nb", 18),
    _lte("BCCH_BCH_TDD_NB", "BCCH-BCH-TDD-NB", "dl", "lte-rrc.bcch.bch.nb.tdd", 19),
    _lte("BCCH_DL_SCH_NB", "BCCH-DL-SCH-NB", "dl", "lte-rrc.bcch.dl.sch.nb", 20),
    _lte("PCCH_NB", "PCCH-NB", "dl", "lte-rrc.pcch.nb", 21),
    _lte("SC_MCCH_NB", "SC-MCCH-NB", "dl", "lte-rrc.sc.mcch.nb", 22),
)}


def _nr(key, label, direction, dissector):
    return Channel(key, label, direction, dissector, None)


NR_CHANNELS = {c.key: c for c in (
    _nr("BCCH_BCH", "BCCH-BCH", "dl", "nr-rrc.bcch.bch"),
    _nr("BCCH_DL_SCH", "BCCH-DL-SCH", "dl", "nr-rrc.bcch.dl.sch"),
    _nr("DL_CCCH", "DL-CCCH", "dl", "nr-rrc.dl.ccch"),
    _nr("DL_DCCH", "DL-DCCH", "dl", "nr-rrc.dl.dcch"),
    _nr("PCCH", "PCCH", "dl", "nr-rrc.pcch"),
    _nr("UL_CCCH", "UL-CCCH", "ul", "nr-rrc.ul.ccch"),
    _nr("UL_CCCH1", "UL-CCCH1", "ul", "nr-rrc.ul.ccch1"),
    _nr("UL_DCCH", "UL-DCCH", "ul", "nr-rrc.ul.dcch"),
    # Standalone containers, mostly seen in EN-DC where the NR RRC message is
    # carried inside an LTE RRC message and the modem logs it separately.
    _nr("RRC_RECONFIGURATION", "RRCReconfiguration (container)", "dl", "nr-rrc.rrc_reconf"),
    # Wireshark 4.0 has no standalone dissector for RRCReconfigurationComplete.
    _nr("RRC_RECONFIGURATION_COMPLETE", "RRCReconfigurationComplete (container)", "ul", "data"),
    # EN-DC SCG addition: the RadioBearerConfig inside the LTE reconfiguration's
    # nr-RadioBearerConfig1, logged on its own (iPhone 17, NR RRC version 26).
    _nr("RADIO_BEARER_CONFIG", "RadioBearerConfig (container)", "dl", "nr-rrc.radiobearerconfig"),
    _nr("UE_MRDC_CAPABILITY", "UE-MRDC-Capability", "ul", "nr-rrc.ue_mrdc_cap"),
    _nr("UE_NR_CAPABILITY", "UE-NR-Capability", "ul", "nr-rrc.ue_nr_cap"),
    _nr("UE_RADIO_ACCESS_CAP_INFO", "UERadioAccessCapabilityInformation", "ul", "nr-rrc.ue_radio_access_cap_info"),
    _nr("UE_RADIO_PAGING_INFO", "UERadioPagingInformation", "ul", "nr-rrc.ue_radio_paging_info"),
)}

UNKNOWN_CHANNEL = Channel("UNKNOWN", "unknown channel", "unknown", "data", None)


def unknown_channel(pdu_num: int) -> Channel:
    return Channel("UNKNOWN_%d" % pdu_num, "unmapped PDU type %d" % pdu_num, "unknown", "data", None)
