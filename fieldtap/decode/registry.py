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


# The provenance the iPhone 17 layouts share (docs/research/iphone-named-log-codes.md).
IPHONE = "validated on the iPhone 17 (M25) captures of 2026-09-21/22"


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
    _c(0xB062, "LTE MAC RACH Attempt", "lte", "mac", "lte_mac_rach", "high",
       note="Packet v1 / subpacket 0x06 v50 (the subpacket size excludes its 4-byte header) " + IPHONE
            + ": UL EARFCN of the target cell, preamble target power = SIB2's"),
    _c(0xB063, "LTE MAC DL Transport Block", "lte", "mac", "lte_mac_dl_tb", "high",
       note="v1 subpacket container (each sample carries the MAC sub-headers, written as mac-lte-framed); "
            "v50 (0x32) is a walk over self-consistent transport-block headers with per-SDU LCID/length, no "
            "MAC PDU bytes, " + IPHONE + " (99.0% / 99.9% of the blocks found match an 0xB173 transport block; "
            "the walk reaches about 80% of the declared blocks, which the note reports)"),
    _c(0xB064, "LTE MAC UL Transport Block", "lte", "mac", "lte_mac_ul_tb", "high",
       note="Subpacket container; each sample carries the MAC sub-headers, written as mac-lte-framed. "
            "Subpacket 0x08 v7 (cell id, then the v1 order; PHR control element -> power_headroom_db) " + IPHONE),
    _c(0xB139, "LTE PHY PUSCH Tx Report", "lte", "meas", "lte_pusch_tx", "medium",
       note="v23/24/26 single-sourced from documentation. v162 " + IPHONE + ": TTI, RB allocation, TBS, code "
            "rate, modulation and the required PUSCH power (raw/4 - 1.5 dBm, calibrated against 442 TTI-matched "
            "power headroom reports; absolute value good to about 1.5 dB)"),
    _c(0xB14D, "LTE PHY PUCCH CSF", "lte", "meas", "lte_pucch_csf", "medium",
       note="v164 " + IPHONE + "; the CQI/PMI/RI positions after byte 5 were re-derived and agree with 0xB14E "
            "at the same moments, hence medium"),
    _c(0xB14E, "LTE PHY PUSCH CSF", "lte", "meas", "lte_pusch_csf", "high",
       note="v164 " + IPHONE + ": Tx mode = the RRC's tm4, 9 subbands of 6 PRB for 50 PRB, RI against 0xB173"),
    _c(0xB16B, "LTE PHY PDCCH-PHICH Indication Report", "lte", "meas"),
    _c(0xB173, "LTE PDSCH Stat Indication", "lte", "meas", "lte_pdsch_stat", "high",
       note="v5/16/24/32/36 single-sourced from documentation. v50 " + IPHONE + ": fixed 40-byte records, TBS "
            "sizes match TS 36.213 and 99.0% / 99.9% of 0xB063's transport blocks"),
    _c(0xB179, "LTE ML1 Connected Mode LTE Intra-Freq Meas Results", "lte", "meas", "lte_ml1_intra_meas", "high",
       note="Serving and intra-frequency neighbour RSRP/RSRQ; versions 3 and 4 from documentation. v56 (flat, not "
            "bit packed; no DIAG timestamp, the in-record TTI is the clock) " + IPHONE + ": body length = 28 + "
            "12 x count in 98.7% / 98.9%, serving RSRP within 1 dB of 0xB193's in 93%"),
    _c(0xB17F, "LTE ML1 Serving Cell Meas and Eval", "lte", "meas", "lte_ml1_scell_eval", "low",
       note="Layout from one source only; header decoded, fields need a hardware capture"),
    _c(0xB180, "LTE ML1 Idle Neighbor Meas Results", "lte", "meas", "lte_ml1_ncell_meas", "low",
       note="Layout from one source only; header decoded, fields need a hardware capture"),
    _c(0xB193, "LTE ML1 Serving Cell Measurement Result", "lte", "meas", "lte_ml1_scell_meas", "high",
       note="Per-antenna and combined RSRP/RSRQ/RSSI/SNR from subpacket 0x19. Versions 4-40 from documentation "
            "(each measurement in its own 32-bit word at a documented bit offset; those numbers still want a "
            "hardware capture - docs/research/qualcomm-measurement-log-layouts.md). Subpacket v66 (144-byte "
            "cells with an Rx map, no SNR) " + IPHONE + ": 0xB179's serving RSRP agrees to within 1 dB"),
    _c(0xB195, "LTE ML1 Connected Neighbor Meas Request/Response", "lte", "meas"),
    # LL1/ML1 per-subframe reports of the iPhone 17; kept out of the phone-side capture profiles
    # (category "other") so the committed mask files stay what the Android app builds.
    _c(0xB126, "LTE LL1 PDSCH Demapper Configuration", "lte", "other", "lte_pdsch_demapper", "high",
       note="v163 (968-byte body, 20 x 48-byte subframes) " + IPHONE + ": PRB bitmap popcount = 0xB173's N_RB in "
            "99.5% / 99.7%, rank = 0xB173's layers in 99.9% / 100%, Tx antenna ports = the MIB's; Rx antennas "
            "agree with 0xB193 in 88% / 93% only"),
    _c(0xB12A, "LTE LL1 PCFICH Decoding Results", "lte", "other", "lte_pcfich", "high",
       note="v161 (176-byte body, 20 x 8-byte subframes) " + IPHONE + ": the CFI field is 4 x {1,2,3} or 0 exactly "
            "when the decode flag is 0 in all 58,820 elements; which of the two frames the header SFN names is open"),
    _c(0xB16C, "LTE ML1 DCI Information Report", "lte", "other", "lte_dci_info", "high",
       note="v50 " + IPHONE + ": uplink grants (start RB, nRB, modulation agree with 0xB139 in 99.96% / 99.98%, "
            "four subframes before the PUSCH) and a count of downlink assignments, whose contents are not read"),
    # --- Modem front end and clocks (iPhone 17) ------------------------------------------------
    _c(0x184C, "LTE RF FED Tx AGC", "lte", "other", "lte_fed_tx_agc", "high",
       note="v0x11 " + IPHONE + ": per-chain front-end Tx power, PA gain state and power limits; block walk closes "
            "on 99.92% / 99.98% of records. The block counter is the front end's own, not the cell's SFN"),
    _c(0x1D0B, "Modem 100 Hz sampler", "modem", "other", "modem_clock", "medium",
       note="v7 " + IPHONE + ": only the 1024 Hz sleep-clock counter, the 19.2 MHz counter and the sequence "
            "number are read (a trace-gap meter); what the five 2 ms entries sample is not identified"),
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
       note="A 5GMM state record, not a message: MobileInsight, SCAT and DiagNG agree. Version 1 "
            "and 3.0 (the version-1 body, documented as identical; validated on the iPhone 17 (M25) "
            "captures of 2026-09-21/22 by its PLMN, one record). The 5G-TMSI is never reported for "
            "3.0. Still offered to the NAS locator, which finds no NAS in a real one (counted "
            "unparsed, no frame), so the synthetic corpus's 0xB80C message decodes as before"),
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
    _c(0xB97F, "NR ML1 Searcher Measurement DB Update Ext", "nr", "meas", "nr_ml1_search_meas", "high",
       note="Per-carrier/cell SS-RSRP/RSRQ; the NR counterpart to 0xB193. Major.minor 3.0 is the "
            "nr.ts layout, validated on the iPhone 17 (M25) captures of 2026-09-21/22 (every record "
            "consumed exactly, cell RSRP within 0.2 dB of the measurement reports; beams counted, "
            "not read). 2.6 and 2.7 from documentation; 2.9 and 2.10 header/cells only"),
    # 0xB887 and 0xB888 both exist on the iPhone 17: per-slot PDSCH info and the cumulative
    # counters. 0xB883 and 0xB872 keep names from docs/research/qualcomm-measurement-log-layouts.md;
    # the versions the iPhone 17 logs (3.26, 3.17) have no implemented layout.
    _c(0xB887, "NR MAC PDSCH Info", "nr", "mac", "nr_mac_pdsch_info", "high",
       note="Per-slot frame/slot, PCI, TBS, MCS, PRBs, HARQ id, layers and CRC; major.minor 3.13. No "
            "public layout: the nr.ts positions, validated on the iPhone 17 (M25) captures of "
            "2026-09-21/22 (TBS against TS 38.214 on every new transmission, sums against 0xB888)"),
    _c(0xB888, "NR MAC PDSCH Stats", "nr", "mac", "nr_mac_pdsch_stats", "high",
       note="Cumulative per-carrier DL counters (decodes, CRC pass/fail, bytes) and the derived BLER. "
            "3.1 is the nr.ts layout, validated on the iPhone 17 (M25) captures of 2026-09-21/22 "
            "(pass + fail = decodes and pass + fail bytes = TB bytes in 602 of 602 records); 2.2 "
            "from documentation"),
    _c(0xB88A, "NR MAC RACH Attempt", "nr", "mac",
       note="Documented as RACH Attempt, not the UL schedule report; that is 0xB883"),
    _c(0xB883, "NR MAC UL Physical Channel Schedule Report", "nr", "mac", "nr_mac_ul_sched", "low",
       note="2.11 layout single-sourced and heavily packed; header decoded, the rest needs a hardware "
            "capture. The iPhone 17 logs 3.26, which has no implemented layout (its payload failed "
            "every identity check, docs/research/iphone-named-log-codes.md): returned partial, "
            "version noted"),
    _c(0xB872, "NR L2 UL Transport Block", "nr", "mac", "nr_l2_ul_tb", "low",
       note="UL throughput source; 0xB8D8 was checked and is not this record. Version-4 layout "
            "single-sourced. The iPhone 17 logs 3.17, which has no implemented layout: returned "
            "partial, version noted"),
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
