"""The log-code register (roadmap 2.2): code -> what it is -> how it is decoded.

`confidence` is about the record *layout* FieldTap applies, not the log
code's existence:

  high    layout widely documented and exercised in the field by public tools
  medium  layout documented for the common versions; self-validated at runtime
  low     name known, layout not implemented; captured to .qmdl, not decoded

Anything not listed here is still captured when the mask allows it; it is
just counted as unknown by the decoder.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class LogCodeInfo:
    code: int
    name: str
    rat: str            # "lte" | "nr"
    category: str       # "rrc" | "nas" | "cell" | "meas" | "mac" | "other"
    decoder: str = ""   # key into records.DECODERS; "" = captured, not decoded
    confidence: str = "low"
    # NAS only: (sublayer, direction, security)
    nas: Optional[tuple] = None
    note: str = ""


def _c(code, name, rat, category, decoder="", confidence="low", nas=None, note=""):
    return LogCodeInfo(code, name, rat, category, decoder, confidence, nas, note)


LOG_CODES = {i.code: i for i in (
    # --- LTE RRC ---------------------------------------------------------------
    _c(0xB0C0, "LTE RRC OTA Packet", "lte", "rrc", "lte_rrc", "high"),
    _c(0xB0C1, "LTE RRC MIB Message Log Packet", "lte", "cell", "lte_mib", "high",
       note="Versions 1, 2, 3 and 17; two independent layouts agree"),
    _c(0xB0C2, "LTE RRC Serving Cell Info Log Packet", "lte", "cell", "lte_serving_cell", "medium"),
    _c(0xB0C3, "LTE RRC PLMN Search Info", "lte", "other"),
    _c(0xB0C4, "LTE RRC PLMN Search Request", "lte", "other"),
    # --- LTE NAS ---------------------------------------------------------------
    _c(0xB0E0, "LTE NAS ESM Security Protected Incoming Msg", "lte", "nas", "nas", "medium", ("esm", "dl", "sec")),
    _c(0xB0E1, "LTE NAS ESM Security Protected Outgoing Msg", "lte", "nas", "nas", "medium", ("esm", "ul", "sec")),
    _c(0xB0E2, "LTE NAS ESM Plain OTA Incoming Msg", "lte", "nas", "nas", "high", ("esm", "dl", "plain")),
    _c(0xB0E3, "LTE NAS ESM Plain OTA Outgoing Msg", "lte", "nas", "nas", "high", ("esm", "ul", "plain")),
    _c(0xB0E4, "LTE NAS ESM Bearer Context State", "lte", "other"),
    _c(0xB0E5, "LTE NAS ESM Bearer Context Info", "lte", "other"),
    _c(0xB0EA, "LTE NAS EMM Security Protected Incoming Msg", "lte", "nas", "nas", "medium", ("emm", "dl", "sec")),
    _c(0xB0EB, "LTE NAS EMM Security Protected Outgoing Msg", "lte", "nas", "nas", "medium", ("emm", "ul", "sec")),
    _c(0xB0EC, "LTE NAS EMM Plain OTA Incoming Msg", "lte", "nas", "nas", "high", ("emm", "dl", "plain")),
    _c(0xB0ED, "LTE NAS EMM Plain OTA Outgoing Msg", "lte", "nas", "nas", "high", ("emm", "ul", "plain")),
    _c(0xB0EE, "LTE NAS EMM State", "lte", "other"),
    _c(0xB0EF, "LTE NAS EMM USIM Card Mode", "lte", "other"),
    # --- LTE MAC / PHY: captured for the corpus, not decoded -------------------------------
    # Names as MobileInsight's log-code table (Apache-2.0) gives them; the iPhone 17's
    # QDSS trace carries every one of these codes.
    _c(0xB061, "LTE MAC RACH Trigger", "lte", "mac"),
    _c(0xB062, "LTE MAC RACH Attempt", "lte", "mac"),
    _c(0xB063, "LTE MAC DL Transport Block", "lte", "mac", "lte_mac_dl_tb", "high",
       note="Subpacket container; each sample carries the MAC sub-headers, written as mac-lte-framed"),
    _c(0xB064, "LTE MAC UL Transport Block", "lte", "mac", "lte_mac_ul_tb", "high",
       note="Subpacket container; each sample carries the MAC sub-headers, written as mac-lte-framed"),
    _c(0xB139, "LTE PHY PUSCH Tx Report", "lte", "meas", "lte_pusch_tx", "medium",
       note="Single-sourced layout; confirm TB size and Tx power on hardware"),
    _c(0xB14D, "LTE PHY PUCCH CSF", "lte", "meas"),
    _c(0xB14E, "LTE PHY PUSCH CSF", "lte", "meas"),
    _c(0xB16B, "LTE PHY PDCCH-PHICH Indication Report", "lte", "meas"),
    _c(0xB173, "LTE PDSCH Stat Indication", "lte", "meas", "lte_pdsch_stat", "medium",
       note="Single-sourced layout; confirm TB size, MCS and CRC result on hardware"),
    _c(0xB179, "LTE ML1 Connected Mode LTE Intra-Freq Meas Results", "lte", "meas", "lte_ml1_intra_meas", "medium",
       note="Serving and intra-frequency neighbour RSRP/RSRQ; versions 3 and 4"),
    _c(0xB17F, "LTE ML1 Serving Cell Meas and Eval", "lte", "meas", "lte_ml1_scell_eval", "low",
       note="Layout from one source only; header decoded, fields need a hardware capture"),
    _c(0xB180, "LTE ML1 Idle Neighbor Meas Results", "lte", "meas", "lte_ml1_ncell_meas", "low",
       note="Layout from one source only; header decoded, fields need a hardware capture"),
    _c(0xB193, "LTE ML1 Serving Cell Measurement Result", "lte", "meas", "lte_ml1_scell_meas", "medium",
       note="Per-antenna and combined RSRP/RSRQ/RSSI/SNR from subpacket 0x19. Each measurement "
            "sits in its own 32-bit word at a documented bit offset (Apache-licensed layouts, "
            "cross-checked against a second implementation); the numbers still want a hardware "
            "capture before a report relies on them - docs/research/qualcomm-measurement-log-layouts.md"),
    _c(0xB195, "LTE ML1 Connected Neighbor Meas Request/Response", "lte", "meas"),
    # --- NR RRC ---------------------------------------------------------------------
    _c(0xB821, "NR RRC OTA Packet", "nr", "rrc", "nr_rrc", "medium",
       note="Header layout self-validated against the record length field"),
    _c(0xB822, "NR RRC MIB Info", "nr", "cell", "nr_mib", "medium",
       note="Layout from one source only; a real record (the OnePlus fixtures) is the check"),
    _c(0xB823, "NR RRC Serving Cell Info", "nr", "cell", "nr_serving_cell", "medium",
       note="Layout from one source only; a real record (the OnePlus fixtures) is the check"),
    _c(0xB825, "NR RRC Configuration Info", "nr", "other"),
    _c(0xB826, "NR5G RRC Supported CA Combos", "nr", "other",
       note="Not a PLMN search record, as this register had it; the iPhone 17 trace holds 610 in 27 s"),
    # --- NR NAS ---------------------------------------------------------------------
    _c(0xB800, "NR NAS SM5G Plain OTA Incoming Msg", "nr", "nas", "nas", "medium", ("5gsm", "dl", "plain")),
    _c(0xB801, "NR NAS SM5G Plain OTA Outgoing Msg", "nr", "nas", "nas", "medium", ("5gsm", "ul", "plain")),
    _c(0xB808, "NR NAS SM5G Security Protected Incoming Msg", "nr", "nas", "nas", "low", ("5gsm", "dl", "sec"),
       note="code/direction pairing not confirmed on hardware"),
    _c(0xB809, "NR NAS SM5G Security Protected Outgoing Msg", "nr", "nas", "nas", "low", ("5gsm", "ul", "sec"),
       note="code/direction pairing not confirmed on hardware"),
    _c(0xB80A, "NR NAS MM5G Plain OTA Incoming Msg", "nr", "nas", "nas", "medium", ("5gmm", "dl", "plain")),
    _c(0xB80B, "NR NAS MM5G Plain OTA Outgoing Msg", "nr", "nas", "nas", "medium", ("5gmm", "ul", "plain")),
    _c(0xB80C, "NR NAS MM5G State", "nr", "nas", "nr_mm5g_state", "medium", ("5gmm", "dl", "sec"),
       note="A 5GMM state record, not a message: MobileInsight, SCAT and DiagNG agree, and the one "
            "record in the iPhone 17 trace is state-shaped. Still offered to the NAS locator, "
            "which finds no NAS in a real one (counted unparsed, no frame), so the synthetic "
            "corpus's 0xB80C message decodes as before"),
    _c(0xB80D, "NR NAS MM5G Security Protected Outgoing Msg", "nr", "nas", "nas", "low", ("5gmm", "ul", "sec"),
       note="seen in the Jul 2024 QCAT export as an MM5G log; direction unconfirmed"),
    _c(0xB80E, "NR NAS MM5G (unconfirmed)", "nr", "other",
       note="Listed here as the MM5G state record until the open decoders and an iPhone capture "
            "put that at 0xB80C; what 0xB80E carries is unconfirmed"),
    _c(0xB80F, "NR NAS MM5G Service Request", "nr", "other"),
    _c(0xB814, "NR NAS SM5G State", "nr", "other"),
    # --- NR ML1: captured for the corpus, not decoded ----------------------------------------
    _c(0xB975, "NR ML1 Serving Cell Beam Management", "nr", "meas", "nr_ml1_beam", "medium",
       note="Serving and per-beam filtered SS-RSRP/RSRQ, major.minor 2.1"),
    _c(0xB97F, "NR ML1 Searcher Measurement DB Update Ext", "nr", "meas", "nr_ml1_search_meas", "medium",
       note="Per-carrier/cell/beam SS-RSRP/RSRQ; the NR counterpart to 0xB193. Major.minor 2.6 and 2.7 "
            "layouts; the 2.7 fixed-point scaling agrees between two implementations"),
    # The four codes below were checked against two independent open decoders while writing
    # docs/research/qualcomm-measurement-log-layouts.md and none of them matched. The name is
    # kept because it is what the field asks for, but the number is suspect: enable both the
    # code here and the one in the note during a hardware capture and keep whichever appears.
    _c(0xB887, "NR MAC PDSCH Info", "nr", "mac",
       note="Number unconfirmed: documented decoders put PDSCH stats at 0xB888"),
    _c(0xB888, "NR MAC PDSCH Stats", "nr", "mac", "nr_mac_pdsch_stats", "low",
       note="Where two open decoders place NR PDSCH decode stats (BLER, MCS); layout single-sourced"),
    _c(0xB88A, "NR MAC RACH Attempt", "nr", "mac",
       note="Documented as RACH Attempt, not the UL schedule report; that is 0xB883"),
    _c(0xB883, "NR MAC UL Physical Channel Schedule Report", "nr", "mac", "nr_mac_ul_sched", "low",
       note="Layout single-sourced and heavily packed; header decoded, the rest needs a hardware capture"),
    _c(0xB872, "NR L2 UL Transport Block", "nr", "mac", "nr_l2_ul_tb", "low",
       note="UL throughput source; 0xB8D8 was checked and is not this record. Layout single-sourced"),
)}


PROFILES = {
    # The product promise: every RRC and NAS message, plus cell identity.
    "signalling": [c for c, i in LOG_CODES.items() if i.category in ("rrc", "nas", "cell")],
    "lte": [c for c, i in LOG_CODES.items() if i.rat == "lte" and i.category in ("rrc", "nas", "cell")],
    "nr": [c for c, i in LOG_CODES.items() if i.rat == "nr" and i.category in ("rrc", "nas", "cell")],
    # Signalling plus what a field engineer reads next: cell identity, serving and
    # neighbour measurements, PHY reports, MAC RACH and state logs. The capture stays
    # small (no transport blocks, no debug text).
    "engineering": sorted({c for c, i in LOG_CODES.items() if i.category in ("rrc", "nas", "cell", "meas")}
                          | {0xB061, 0xB062, 0xB0C3, 0xB0C4, 0xB0EE, 0xB0E4, 0xB0E5, 0xB80C, 0xB814, 0xB80F,
                             0xB825, 0xB826, 0xB883, 0xB888}),
    # Engineering plus every MAC transport block: per-TTI throughput and Wireshark's
    # own MAC/RLC/PDCP decode of the sub-headers. Larger files.
    "l2": sorted({c for c, i in LOG_CODES.items() if i.category in ("rrc", "nas", "cell", "meas", "mac")}
                 | {0xB0C3, 0xB0C4, 0xB0EE, 0xB0E4, 0xB0E5, 0xB80C, 0xB814, 0xB80F, 0xB825, 0xB826}),
    # Everything in the register, decoded or not: what the regression corpus needs.
    "corpus": sorted(LOG_CODES),
}


ALL_PROFILE = "all"   # every log item in every range the modem reports; resolved at capture time


def profile_codes(name: str) -> list:
    if name == ALL_PROFILE:
        return []
    if name not in PROFILES:
        raise KeyError("unknown log profile %r (choose from %s)"
                       % (name, ", ".join(sorted(list(PROFILES) + [ALL_PROFILE]))))
    return sorted(PROFILES[name])


def describe(code: int) -> str:
    info = LOG_CODES.get(code)
    return info.name if info else "unknown log 0x%04X" % code
