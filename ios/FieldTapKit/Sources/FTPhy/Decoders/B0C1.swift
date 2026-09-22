// 0xB0C1 LTE RRC MIB, packet v2 (the MobileInsight/SCAT v2 field order, facts only).

/// The MIB as the modem logged it: which cell, and the eNB's Tx antenna count and DL bandwidth it announces.
enum B0C1 {
    struct Mib: Hashable {
        var pci: Int
        var earfcn: Int64
        var sfn: Int
        var txAntennas: Int
        var dlBandwidthPrb: Int
    }

    static let version = 2

    /// u16 PCI @1, u32 EARFCN @3, u16 SFN @7, u8 Tx antennas @9, u8 DL bandwidth (PRB) @10.
    static func decode(_ b: [UInt8]) -> Decoded<Mib> {
        guard b.has(0, 1) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB0C1 v\(b[0])") }
        guard b.has(0, 11) else { return .malformed }
        return .value(Mib(pci: b.u16(1), earfcn: Int64(b.u32(3)), sfn: b.u16(7), txAntennas: b.u8(9),
                          dlBandwidthPrb: b.u8(10)))
    }
}
