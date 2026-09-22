// 0xB193 LTE ML1 Serving Cell Meas Response, packet v1 with subpacket 0x19 v66 (this modem). The field order is
// the v40 (MobileInsight) / v48 (SCAT) one with each cell record shifted by 8 bytes (a u32 Rx map plus 4 bytes
// before the PCI word) and grown to 144 bytes, re-derived and validated on the iPhone 17 capture (facts only).

/// Per-cell RSRP/RSRQ/RSSI, per Rx antenna and combined, for the serving cells (PCell and SCells) and the
/// neighbours the modem measured on the same carriers.
enum B193 {
    struct CellMeasurement: Hashable {
        var earfcn: Int64
        var pci: Int
        /// Bit 15 of the PCI word: a serving cell (PCell or SCell), not a neighbour.
        var serving: Bool
        /// Bits 9-11 of the PCI word: 0 = PCell, 1-3 = SCell index (serving cells only).
        var carrier: Int
        /// Which of Rx0-Rx3 were measured (bit k = Rx k).
        var rxMap: UInt32
        var rsrpRx: [Double]
        var rsrqRx: [Double]
        var rssiRx: [Double]
        var rsrp: Double
        var rsrpFiltered: Double
        var rsrq: Double
        var rsrqFiltered: Double
        var rssi: Double

        func measured(_ rx: Int) -> Bool { rxMap >> UInt32(rx) & 1 == 1 }
        var rxCount: Int { (0..<4).filter(measured).count }
    }

    static let version = 1
    static let subpacketId = 0x19
    static let subpacketVersion = 66
    static let cellRecordBytes = 144

    static func rsrp(_ x: Int) -> Double { Double(x) * 0.0625 - 180 }
    static func rsrq(_ x: Int) -> Double { Double(x) * 0.0625 - 30 }
    static func rssi(_ x: Int) -> Double { Double(x) * 0.0625 - 110 }

    /// 4-byte packet header (version, subpacket count); subpackets of (id, version, u16 size including this
    /// header); body: u32 EARFCN, u16 cell count, u16 valid-Rx flags, then 144-byte cell records. Other
    /// subpacket ids are skipped; subpacket 0x19 in any version but 66 makes the whole record a version miss.
    static func decode(_ b: [UInt8]) -> Decoded<[CellMeasurement]> {
        guard b.has(0, 4) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB193 v\(b[0])") }
        var out: [CellMeasurement] = []
        var pos = 4
        for _ in 0..<Int(b[1]) {
            guard b.has(pos, 4) else { return .malformed }
            let id = b.u8(pos), ver = b.u8(pos + 1), size = b.u16(pos + 2)
            guard size >= 4, b.has(pos, size) else { return .malformed }
            let body = pos + 4, end = pos + size
            pos = end
            guard id == subpacketId else { continue }
            guard ver == subpacketVersion else { return .versionMiss("0xB193 v1/0x19 v\(ver)") }
            guard end - body >= 8 else { return .malformed }
            let earfcn = Int64(b.u32(body)), cells = b.u16(body + 4)
            for k in 0..<cells {
                let c = body + 8 + cellRecordBytes * k
                guard c + cellRecordBytes <= end else { break }
                out.append(cell(b, c, earfcn: earfcn))
            }
        }
        return .value(out)
    }

    /// One 144-byte cell record at `c`: u32 Rx map @0, u16 PCI word @8, measurement words u32 @24...@68.
    static func cell(_ b: [UInt8], _ c: Int, earfcn: Int64) -> CellMeasurement {
        let pciWord = b.u16(c + 8)
        func w(_ i: Int) -> UInt32 { b.u32(c + 24 + 4 * i) }
        let w0 = w(0), w1 = w(1), w2 = w(2), w4 = w(4), w5 = w(5), w6 = w(6), w7 = w(7), w8 = w(8), w9 = w(9),
            w10 = w(10), w11 = w(11)
        return CellMeasurement(
            earfcn: earfcn, pci: pciWord & 511, serving: pciWord >> 15 & 1 == 1, carrier: (pciWord >> 9) & 7,
            rxMap: b.u32(c),
            rsrpRx: [rsrp(w0.bits(10, 12)), rsrp(w1.bits(12, 12)), rsrp(w2.bits(12, 12)), rsrp(w4.bits(0, 12))],
            rsrqRx: [rsrq(w6.bits(0, 10)), rsrq(w6.bits(20, 10)), rsrq(w7.bits(10, 10)), rsrq(w7.bits(20, 10))],
            rssiRx: [rssi(w9.bits(0, 11)), rssi(w9.bits(11, 11)), rssi(w10.bits(0, 11)), rssi(w10.bits(11, 11))],
            rsrp: rsrp(w4.bits(12, 12) + 640), rsrpFiltered: rsrp(w5.bits(12, 12)),
            rsrq: rsrq(w8.bits(0, 10)), rsrqFiltered: rsrq(w8.bits(20, 10)),
            rssi: rssi(w11.bits(0, 11)))
    }
}
