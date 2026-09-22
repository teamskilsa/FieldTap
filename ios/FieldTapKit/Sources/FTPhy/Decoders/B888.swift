// 0xB888 NR5G MAC PDSCH Stats, v3.1: a 16-byte header, then 9 x u32 + 5 x u64 per record, the MobileInsight
// v2.2 field order (Apache-2.0) with one extra u32 after the carrier id. The counters are cumulative; the
// identities pass + fail = decodes and pass bytes + fail bytes = TB bytes hold in 602 of 602 records.

/// Cumulative NR DL MAC counters of one carrier.
enum B888 {
    struct Counters: Hashable {
        var carrier: Int
        var slots: UInt64
        var decodes: UInt64
        var crcPass: UInt64
        var crcFail: UInt64
        var retx: UInt64
        var passBytes: UInt64
        var failBytes: UInt64
        var tbBytes: UInt64
    }

    static let major = 3, minor = 1
    static let minBytes = 92

    /// u16 minor, u16 major, ..., the first record @16: u32 carrier, u32, u32 slots, decodes, CRC pass, CRC fail,
    /// retx, ACK-as-NACK, HARQ fail; u64 pass bytes, fail bytes, TB bytes, padding bytes, retx bytes.
    static func decode(_ b: [UInt8]) -> Decoded<Counters> {
        guard b.has(0, 4) else { return .malformed }
        guard b.u16(2) == major, b.u16(0) == minor else { return .versionMiss("0xB888 \(b.u16(2)).\(b.u16(0))") }
        guard b.has(0, minBytes) else { return .malformed }
        func u(_ i: Int) -> UInt64 { UInt64(b.u32(16 + 4 * i)) }
        func q(_ i: Int) -> UInt64 { b.u64(16 + 36 + 8 * i) }
        return .value(Counters(carrier: Int(u(0)), slots: u(2), decodes: u(3), crcPass: u(4), crcFail: u(5), retx: u(6),
                               passBytes: q(0), failBytes: q(1), tbBytes: q(2)))
    }
}
