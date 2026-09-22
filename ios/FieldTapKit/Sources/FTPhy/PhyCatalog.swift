// What cannot be plotted from this iPhone, and why: the "not possible" and "not decoded yet" lists of the
// design's PHY dashboard, so an empty chart is never a mystery.

import FTCore
import FTModel

public enum PhyCatalog {
    /// What this iPhone logs in plain form, what is encrypted, and what is not decoded yet.
    public static let entries: [Availability] = notPossible + notDecodedYet

    /// The entries of the "not possible on this iPhone" list; the rest are "not decoded yet".
    public static let notPossibleIds: Set<String> = Set(notPossible.map(\.id))

    static let notPossible: [Availability] = [
        Availability(id: "nrSinr", title: "NR SINR / SNR", status: .encryptedByModem, codes: [0xB8DD],
                     reason: "0xB8DD (NR5G LL1 FW Serving FTL) is a secure record: the modem encrypts its body and only "
                         + "the header is readable. NR SINR appears only when an RRC measurement report carries it."),
        Availability(id: "nrFirmwareCsi", title: "NR CSI from the firmware", status: .encryptedByModem, codes: [0xB8E2],
                     reason: "0xB8E2 (NR5G LL1 FW CSF Reports) is encrypted by the modem."),
        Availability(id: "nrPhyEncrypted", title: "NR ML1 / LL1 records", status: .encryptedByModem,
                     codes: [0xB8C5, 0xB8CB, 0xB9A9, 0xB8C8, 0xB8CD, 0xB8C0, 0xB8CF, 0xB8A3, 0xB881, 0xB8C4],
                     reason: "Most NR physical-layer records (for example 0xB881 NR MAC UL TB stats) arrive encrypted. "
                         + "FieldTap counts them and never guesses at their contents."),
        Availability(id: "lteSinr", title: "LTE SINR / SNR", status: .notFoundInPlainLogs,
                     codes: [0xB193, 0xB134, 0xB11B, 0xB15B, 0xB122, 0xB123],
                     reason: "Not in any plain record decoded so far. The old 'projected SIR' slot of 0xB193 is not SIR on "
                         + "v66 (it reads 0 in about half the records and up to 220 dB). The candidates 0xB134, 0xB11B, "
                         + "0xB15B and 0xB122/0xB123 are unverified."),
        Availability(id: "nrPerAntennaRsrp", title: "NR RSRP per antenna", status: .notOnIPhone, codes: [0xB97F],
                     reason: "The per-Rx fields of 0xB97F are zero on this modem, and beam-level RSRP is not validated, so "
                         + "NR RSRP is shown per cell only."),
        Availability(id: "liveValues", title: "Live values, and more than about 27 s of history", status: .notOnIPhone,
                     codes: [],
                     reason: "iOS gives apps no modem data. The trace arrives only in a sysdiagnose you trigger, and the "
                         + "modem's 128 MiB ring keeps roughly the last half minute."),
        Availability(id: "actualTxPower", title: "Actual LTE Tx power", status: .notFoundInPlainLogs, codes: [0xB139],
                     reason: "The log carries the required PUSCH power before Pcmax capping. The Tx power is then "
                         + "min(Pcmax, about 23 dBm, required), which the Uplink chart marks as derived."),
        Availability(id: "continuousTa", title: "Continuous timing advance", status: .notDecodedYet,
                     codes: [0xB062, 0xB063, 0xB114],
                     reason: "Only the timing advance of each random-access response (0xB062). 0xB063 decodes now, but it "
                         + "logs a timing-advance command's LCID and length, not its 6-bit value, and the network sent "
                         + "two in 22 s. 0xB114 (serving-cell frame timing, 78 records a second) is the right record and "
                         + "its framing is validated, but its scale is about five times 0xB062's at the same moment, so "
                         + "nothing is shown: it needs a drive with several random-access events to calibrate."),
    ]

    static let notDecodedYet: [Availability] = [
        Availability(id: "bsr", title: "Buffer status reports", status: .notDecodedYet, codes: [0xB064],
                     reason: "The MAC control elements in 0xB064 are parsed, but the BSR levels are not validated against "
                         + "another source yet, so they are not plotted."),
        // The 5G uplink codes: their presence, rate, numerology and frame/slot timing are validated (the frame
        // field scores a circular R of 1.00000 on all four), but every payload field failed the TS 38.214
        // transport-block identity, which the shipped 0xB887 decoder passes 828 of 828 times. So the timing is
        // known and the sizes are not, and that is what these say.
        Availability(id: "nrUlSchedule", title: "NR UL MCS, PRB and TBS", status: .notDecodedYet, codes: [0xB883],
                     reason: "0xB883 (NR5G MAC UL Physical Channel Schedule Report) v3.26: the record's framing, rate "
                         + "(about 27 uplink grants a second) and frame/slot timing are validated, but no MCS, PRB or "
                         + "transport-block field satisfies TS 38.214 5.1.3.2, so none is shown. Needs a capture with a "
                         + "sustained 5G upload."),
        Availability(id: "nrUlPower", title: "NR UL power", status: .notDecodedYet, codes: [0xB884],
                     reason: "0xB884 (NR5G MAC UL Power Control) v3.5: framing and timing validated. The best power "
                         + "candidate correlates r = 0.81 with the LTE required power on one capture and r = 0.79 at a "
                         + "different bit offset on the other, so nothing is claimed. Needs a capture with a sustained "
                         + "5G upload."),
        Availability(id: "nrDci", title: "NR DCI", status: .notDecodedYet, codes: [0xB885],
                     reason: "0xB885 (NR5G MAC DCI Info) v3.20: framing and timing validated, and 75% of the slots it "
                         + "reports are slots where 0xB887 logged an NR PDSCH, which corroborates the name. The DCI "
                         + "contents are not decoded. Needs a capture with a sustained 5G upload."),
        Availability(id: "nrCsf", title: "NR CQI, RI and PMI", status: .notDecodedYet, codes: [0xB8A7],
                     reason: "0xB8A7 (NR5G MAC CSF Report) v3.5: framing and timing validated, but the record is sparse "
                         + "and the NR downlink rank is almost always 1 in these captures, so there is nothing with "
                         + "enough variance to validate a CQI or RI field against. Needs a capture with a sustained 5G "
                         + "upload."),
        Availability(id: "nrLl1", title: "NR Rx AGC and Tx", status: .notDecodedYet, codes: [0xB8C9, 0xB8D1],
                     reason: "0xB8C9 (LL1 Rx AGC) v3.1 frames exactly (its chunk chain ends on the body's last byte in "
                         + "100.0000% of records), but its gain values were rejected: the code only exists for 8 s of "
                         + "the reference drive, with 5 dB of NR dynamic range, which cannot settle a gain scale. "
                         + "0xB8D1 (LL1 Tx) v3.7 is plain and not decoded."),
        Availability(id: "lteRxAgc", title: "LTE Rx gain, and antenna imbalance", status: .notDecodedYet, codes: [0xB111],
                     reason: "0xB111 v166 frames exactly (len == 8 + 40N + 16 x popcount(mask), 100.0000%), but its gain "
                         + "values were rejected. Only a per-chain differential survived, at medium confidence, and it is "
                         + "not shown as an absolute level: a purpose-built capture, one carrier with no handover while "
                         + "RSRP swings 20 dB, would settle it."),
        Availability(id: "lteDelaySpread", title: "Delay spread", status: .notDecodedYet, codes: [0xB122],
                     reason: "0xB122 v141 frames exactly and its timing is the tightest of any code here (circular "
                         + "R = 1.00000), and the body is a clean single-peaked energy-versus-delay profile. But the "
                         + "level is not power (|r| <= 0.26 against RSRP and RSSI: it is a post-AGC channel estimate) and "
                         + "the delay axis is unanchored, so no tap spacing in Ts can be stated."),
        Availability(id: "lteDciPhich", title: "LTE PHICH and HARQ feedback", status: .notDecodedYet, codes: [0xB16B],
                     reason: "0xB16B v49's element chain frames exactly (656 of 656 records), but the record carries no "
                         + "subframe field, so its blocks cannot be lined up against 0xB173's HARQ feedback and no PHICH "
                         + "field is claimed. 0xB16C, the DCI report next to it, decodes."),
        Availability(id: "lteUlAgcPower", title: "LTE front-end UL AGC power", status: .notDecodedYet, codes: [0xB146],
                     reason: "0xB146 v165 frames exactly and its channel type is validated (every type-1 element lands "
                         + "on a TTI where 0xB139 reported a PUSCH, 100% in both captures), but no field in the 56 bytes "
                         + "reproduces the transmit power: the best candidates sit at different offsets in the two "
                         + "captures with slopes a factor of two apart. The front-end transmit power comes from 0x184C "
                         + "instead."),
        Availability(id: "b134", title: "Unnamed record 0xB134", status: .notDecodedYet, codes: [0xB134],
                     reason: "0xB134 v163 (LTE LL1 Serving Cell RS) frames exactly and its SFN is validated, but its "
                         + "measurement block is not per-antenna RSRP, RSRQ, RSSI or SNR (|r| <= 0.34 against all four, "
                         + "and the antenna-imbalance test fails outright), so nothing is plotted from it."),
        Availability(id: "gnssPosition", title: "Location (GNSS position reports)", status: .excludedForPrivacy,
                     codes: CapturePrivacy.excludedCodeList,
                     reason: CapturePrivacy.statement),
    ]

    /// Shown when this build carries no TS 36.213 table (see LteTbsTable.swift).
    static let tbsTableMissing = Availability(
        id: "lteTbsTable", title: "TBS checks and UL MCS", status: .notDecodedYet, codes: [0xB173, 0xB139],
        reason: "This build has no TS 36.213 transport block size table (it is generated from the 3GPP document), so "
            + "the TBS self-checks and the UL MCS, which is derived from the table, are not run.")

    /// The catalogue with this capture's record counts, the encrypted census, and the TBS-table entry if needed.
    static func availability(recordsPerCode: [UInt16: Int], secure: EncryptedCensus, tbsAvailable: Bool) -> [Availability] {
        var out = entries.map { e -> Availability in
            var e = e
            if e.id == "nrPhyEncrypted", secure.records > 0 {
                e.reason += " This capture: \(PhyChecks.count(secure.records)) encrypted records across \(secure.codes) codes."
            } else if e.status == .excludedForPrivacy {
                let n = e.codes.reduce(0) { $0 + (recordsPerCode[$1] ?? 0) }
                e.reason += n > 0 ? " This capture: \(PhyChecks.count(n)) such records, counted and dropped."
                    : " None are in what this capture kept."
            } else if e.status == .notDecodedYet, e.id != "continuousTa", e.id != "bsr" {
                let n = e.codes.reduce(0) { $0 + (recordsPerCode[$1] ?? 0) }
                e.reason += n > 0 ? " This capture: \(PhyChecks.count(n)) records." : " None in this capture."
            }
            return e
        }
        if !tbsAvailable { out.insert(tbsTableMissing, at: notPossible.count) }
        return out
    }
}
