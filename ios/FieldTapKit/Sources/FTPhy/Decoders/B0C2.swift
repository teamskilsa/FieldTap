// 0xB0C2 LTE RRC Serving Cell Info, packet v3 (the MobileInsight/SCAT v3 field order, facts only).

/// The serving cell's channel and band. The cell identity, TAC and PLMN in the same record are deliberately not
/// read: with the PLMN they locate the phone, and nothing on the Radio page needs them.
enum B0C2 {
    struct ServingCell: Hashable {
        var pci: Int
        var dlEarfcn: Int64
        var ulEarfcn: Int64
        var dlBandwidthPrb: Int
        var ulBandwidthPrb: Int
        var band: Int
    }

    static let version = 3

    /// u16 PCI @1, u32 DL/UL EARFCN @3/@7, u8 DL/UL bandwidth @11/@12, u32 band @19.
    static func decode(_ b: [UInt8]) -> Decoded<ServingCell> {
        guard b.has(0, 1) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB0C2 v\(b[0])") }
        guard b.has(0, 29) else { return .malformed }
        return .value(ServingCell(pci: b.u16(1), dlEarfcn: Int64(b.u32(3)), ulEarfcn: Int64(b.u32(7)),
                                  dlBandwidthPrb: b.u8(11), ulBandwidthPrb: b.u8(12), band: Int(b.u32(19))))
    }
}
