// Port of android/diag/src/main/kotlin/com/fieldtap/diag/CellInfo.kt (contract v1: unchanged from repo main).
// Kotlin's CellInfo.Serving is FTModel's ServingCellInfo, so goldens and screens share one type.

import FTModel

/// 0xB0C2 LTE RRC Serving Cell Info: who the cell the phone is camped on actually is.
///
/// The RRC OTA header names a cell by PCI and EARFCN, which tells two cells apart but does not look one up: the
/// PLMN, the tracking area and the cell identity are in this record instead. A record whose fields are out of
/// range is rejected rather than shown, because a layout that does not fit this modem would otherwise produce a
/// confident-looking PLMN that is noise.
public enum CellInfo {
    /// Older records index a table of bandwidths; newer ones count resource blocks. Both are unambiguous.
    private static let BANDWIDTH_INDEX: [Int: Double] = [0: 1.4, 1: 3.0, 2: 5.0, 3: 10.0, 4: 15.0, 5: 20.0]
    private static let BANDWIDTH_PRBS: [Int: Double] = [6: 1.4, 15: 3.0, 25: 5.0, 50: 10.0, 75: 15.0, 100: 20.0]

    private static func bandwidth(_ raw: Int) -> Double? { BANDWIDTH_PRBS[raw] ?? BANDWIDTH_INDEX[raw] }

    public static func serving(_ body: [UInt8]) -> ServingCellInfo? {
        if body.isEmpty { return nil }
        // Version 2 keeps the EARFCNs in 16 bits; every modern modem uses the 32-bit layout.
        let wide = body[0] != 2
        let size = wide ? 27 : 23
        if body.count < 1 + size { return nil }
        var at = 1
        func u8() -> Int { defer { at += 1 }; return Int(body[at]) }
        func u16() -> Int { defer { at += 2 }; return Bytes.le16(body, at) }
        func u32() -> Int64 { defer { at += 4 }; return Bytes.le32(body, at) }
        func earfcn() -> Int64 { wide ? u32() : Int64(u16()) }
        let pci = u16()
        let downlink = earfcn()
        let uplink = earfcn()
        let downlinkBandwidth = u8()
        at += 1 // uplink bandwidth, always the same as the downlink on FDD
        let cellIdentity = u32()
        let tac = u16()
        let band = u32()
        let mcc = u16()
        let mncDigits = u8()
        let mnc = u16()
        if pci > 1007 || !(1...256).contains(band) || mcc > 999 { return nil }
        return ServingCellInfo(
            pci: pci, downlinkEarfcn: downlink, uplinkEarfcn: uplink, band: Int(band),
            plmn: padded(mcc, 3) + "-" + padded(mnc, mncDigits == 3 ? 3 : 2), tac: tac,
            cellIdentity: cellIdentity, bandwidthMhz: bandwidth(downlinkBandwidth))
    }

    /// Kotlin's `toString().padStart(width, '0')`.
    private static func padded(_ v: Int, _ width: Int) -> String {
        let s = "\(v)"
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}

extension ServingCellInfo {
    /// The eNB of the cell identity (its top 20 bits); nil when the identity came masked from a golden.
    public var enb: Int64? { cellIdentity.map { $0 >> 8 } }

    /// The sector within the eNB (the low 8 bits).
    public var sector: Int? { cellIdentity.map { Int($0 & 0xFF) } }
}
