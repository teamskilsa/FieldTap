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
        Availability(id: "continuousTa", title: "Continuous timing advance", status: .notDecodedYet, codes: [0xB062, 0xB063],
                     reason: "Only the timing advance of each random-access response (0xB062). The TA MAC commands sit in "
                         + "0xB063, which does not decode yet."),
    ]

    static let notDecodedYet: [Availability] = [
        Availability(id: "bsr", title: "Buffer status reports", status: .notDecodedYet, codes: [0xB064],
                     reason: "The MAC control elements in 0xB064 are parsed, but the BSR levels are not validated against "
                         + "another source yet, so they are not plotted."),
        Availability(id: "nrUlSchedule", title: "NR UL MCS, PRB and TBS", status: .notDecodedYet, codes: [0xB883],
                     reason: "0xB883 (NR5G MAC UL Physical Channel Schedule Report) v3.26 is plain but not decoded yet."),
        Availability(id: "nrUlPower", title: "NR UL power", status: .notDecodedYet, codes: [0xB884],
                     reason: "0xB884 (NR5G MAC UL Power Control) v3.5 is plain but not decoded yet."),
        Availability(id: "nrDci", title: "NR DCI", status: .notDecodedYet, codes: [0xB885],
                     reason: "0xB885 (NR5G MAC DCI Info) v3.20 is plain but not decoded yet."),
        Availability(id: "nrCsf", title: "NR CQI, RI and PMI", status: .notDecodedYet, codes: [0xB8A7],
                     reason: "0xB8A7 (NR5G MAC CSF Report) v3.5 is plain but not decoded yet."),
        Availability(id: "nrLl1", title: "NR Rx AGC and Tx", status: .notDecodedYet, codes: [0xB8C9, 0xB8D1],
                     reason: "0xB8C9 (LL1 Rx AGC) v3.1 and 0xB8D1 (LL1 Tx) v3.7 are plain but not decoded yet."),
        Availability(id: "lteDlMac", title: "LTE DL MAC TBs and TA commands", status: .notDecodedYet, codes: [0xB063],
                     reason: "0xB063 v50: the known framing did not validate on this modem."),
        Availability(id: "pdschDemapper", title: "PDSCH demapper (antennas, TM per TTI)", status: .notDecodedYet,
                     codes: [0xB126], reason: "0xB126 v163 is plain but not decoded yet."),
        Availability(id: "lteRxAgc", title: "LTE Rx AGC", status: .notDecodedYet, codes: [0xB111],
                     reason: "0xB111 v166 has no public layout."),
        Availability(id: "lteDciPhich", title: "LTE DCI and PHICH", status: .notDecodedYet, codes: [0xB16B, 0xB16C],
                     reason: "0xB16B and 0xB16C are plain but not decoded yet."),
        Availability(id: "intraFreqNeighbours", title: "Intra-frequency neighbour search", status: .notDecodedYet,
                     codes: [0xB179], reason: "0xB179 is plain but not decoded yet."),
        Availability(id: "b134", title: "Unnamed record 0xB134", status: .notDecodedYet, codes: [0xB134],
                     reason: "0xB134 has no public name or layout; it is a candidate for LTE SINR."),
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
