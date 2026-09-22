// 0xB887 NR5G MAC PDSCH Status, v3.13. No public layout was found; every position was re-derived on the iPhone
// 17 capture: TBS against TS 38.214 5.1.3.2 (472 of 472 new transmissions), nRB <= 52 and layers <= 2 as RRC
// configured them, CRC against the HARQ retransmissions, and the sums against the 0xB888 counters.

/// One NR PDSCH slot per record: MCS, resource blocks, layers, TBS and CRC.
enum B887 {
    struct Slot: Hashable {
        var frame: Int
        var slot: Int
        var pci: Int
        var tbsBytes: Int
        /// Index into TS 38.214 table 5.1.3.1-2 (qam256) here; 28-31 are retransmissions.
        var mcs: Int
        var nRb: Int
        var harq: Int
        var layers: Int
        var crcOk: Bool
    }

    static let major = 3, minor = 13
    static let recordBytes = 44

    /// 8-byte header (u16 minor, u16 major, 3 reserved, u8 record count @7); 44-byte records: u32 @8 frame bits
    /// 5-14, slot bits 15-18; u16 @12 PCI 10b; u32 @16 TBS bytes bits 5-25, MCS bits 26-30; u32 @20 nRB bits 0-6,
    /// HARQ bits 11-14, layers-1 bit 29; byte @24 bit 0 CRC pass.
    static func decode(_ b: [UInt8]) -> Decoded<[Slot]> {
        guard b.has(0, 4) else { return .malformed }
        guard b.u16(2) == major, b.u16(0) == minor else { return .versionMiss("0xB887 \(b.u16(2)).\(b.u16(0))") }
        guard b.has(0, 8) else { return .malformed }
        var out: [Slot] = []
        for k in 0..<b.u8(7) {
            let r = 8 + recordBytes * k
            guard b.has(r, recordBytes) else { break }
            let w2 = b.u32(r + 8), w4 = b.u32(r + 16), w5 = b.u32(r + 20)
            out.append(Slot(frame: w2.bits(5, 10), slot: w2.bits(15, 4), pci: b.u16(r + 12) & 0x3FF,
                            tbsBytes: w4.bits(5, 21), mcs: w4.bits(26, 5), nRb: w5.bits(0, 7), harq: w5.bits(11, 4),
                            layers: w5.bits(29, 1) + 1, crcOk: b[r + 24] & 1 == 1))
        }
        return .value(out)
    }
}
