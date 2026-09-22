// 0xB97F NR5G ML1 Searcher Measurement Database Update Ext, v3.0: the SCAT v3.0 field order (facts only),
// validated on the iPhone 17 capture (the parse consumes each record exactly; cell RSRP within 0.2 dB of the NR
// measurement reports).

/// NR SS-RSRP/RSRQ per cell and carrier. The per-Rx serving fields are zero on this modem, so only the cell
/// level is used.
enum B97F {
    struct Cell: Hashable {
        var pci: Int
        var rsrp: Double?
        var rsrq: Double?
        var beams: Int
    }

    struct Carrier: Hashable {
        var arfcn: Int64
        /// 255 before the SCG is added (measured as a candidate), else the component carrier id.
        var ccId: Int
        var servingPci: Int
        var cells: [Cell]
    }

    static let major = 3, minor = 0
    static let carrierBytes = 40, cellBytes = 16, beamBytes = 84

    /// Q7: 8-bit two's-complement integer part and a 7-bit fraction; 0 means not measured.
    static func q7(_ x: UInt32) -> Double? {
        guard x != 0 else { return nil }
        let integer = Int((x >> 7) & 0xFF), fraction = Int(x & 0x7F)
        return Double(-((integer ^ 0xFF) + 1)) + Double(fraction) * 0.0078125
    }

    /// u16 minor, u16 major; 20-byte header (u8 carrier count @8); per carrier 40 bytes (u32 ARFCN @0, u8 CC id
    /// @4, u8 cell count @5, u16 serving PCI @6, u8 serving index @8), then 16-byte cells (u16 PCI @0, u8 beam
    /// count @4, Q7 RSRP @8, Q7 RSRQ @12), each followed by its 84-byte beam records.
    static func decode(_ b: [UInt8]) -> Decoded<[Carrier]> {
        guard b.has(0, 4) else { return .malformed }
        guard b.u16(2) == major, b.u16(0) == minor else { return .versionMiss("0xB97F \(b.u16(2)).\(b.u16(0))") }
        guard b.has(0, 20) else { return .malformed }
        var off = 20
        var out: [Carrier] = []
        for _ in 0..<b.u8(8) {
            guard b.has(off, carrierBytes) else { return .malformed }
            let arfcn = Int64(b.u32(off)), ccId = b.u8(off + 4), count = b.u8(off + 5), servingPci = b.u16(off + 6),
                servingIndex = b.u8(off + 8)
            off += carrierBytes
            let n = (count != 0 && count != 0xFF) ? count : (servingIndex > 0 && servingIndex < 0xFF ? servingIndex : 0)
            var cells: [Cell] = []
            for _ in 0..<n {
                guard b.has(off, cellBytes) else { return .malformed }
                let beams = b.u8(off + 4)
                cells.append(Cell(pci: b.u16(off), rsrp: q7(b.u32(off + 8)), rsrq: q7(b.u32(off + 12)), beams: beams))
                off += cellBytes + beamBytes * beams
                guard off <= b.count else { return .malformed }
            }
            out.append(Carrier(arfcn: arfcn, ccId: ccId, servingPci: servingPci, cells: cells))
        }
        return .value(out)
    }
}
