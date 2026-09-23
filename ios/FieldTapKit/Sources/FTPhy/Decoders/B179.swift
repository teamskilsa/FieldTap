// 0xB179 LTE ML1 Connected Mode Intra-Frequency Measurement Results, v56 (this modem). One record per measured
// LTE frequency: the serving cell's own measurement and then the neighbours found on it. The published note that
// the layout is bit packed does not hold on v56: it is plain little-endian fields.
//
// These records carry NO DIAG timestamp — all 385 and all 373 arrive stamped 0 — which is why the in-record TTI
// at +14 matters: it places the record itself (see PhyTtiAxis), and against the surrounding timed records it
// scores circular R = 1.00000 / 0.99999 with a spread of 3.8 / 5.2 ms.
//
// The RSRP and RSRQ scales are 0xB193's own, fixed by agreement with it rather than by a published constant:
// mean +0.12 dB, sd 0.78 dB, 93% inside 1 dB on the stationary capture. Only 29 of 492 and 43 of 265 neighbour
// PCIs appear anywhere else in the capture, which is the value of the code.

/// One measured LTE frequency: the serving cell, and the ranked neighbours on it.
enum B179 {
    struct Neighbour: Hashable {
        var pci: Int
        var rsrp: Double
        var rsrq: Double
    }

    struct Measurement: Hashable {
        var earfcn: Int64
        var pci: Int
        var sfn: Int
        var subframe: Int
        var rsrp: Double
        var rsrq: Double
        var neighbours: [Neighbour]
        /// The neighbour count the record declares, which the length identity checks.
        var declaredNeighbours: Int
        /// True when `len == 28 + 12 x count` (98.7% / 98.9%; the runtime check counts this).
        var lengthExact: Bool
        /// SFN x 10 + subframe, as the record states it: this is the record's only clock.
        var tti: Int { sfn * 10 + subframe }
    }

    static let version = 56
    static let headerBytes = 28
    static let neighbourBytes = 12

    static func rsrp(_ x: Int) -> Double { Double(x) * 0.0625 - 180 }
    static func rsrq(_ x: Int) -> Double { Double(x) * 0.0625 - 30 }

    /// u32 EARFCN @8, u16 serving PCI @12, u16 TTI @14, u16 RSRP @16 and RSRQ @20 (each repeated in the next
    /// word: the instantaneous and filtered values, equal in every record of both captures), u32 neighbour count
    /// @24, then 12-byte neighbours (PCI, RSRP, RSRQ, each value repeated). The word at +4 is not identified.
    static func decode(_ b: [UInt8]) -> Decoded<Measurement> {
        guard b.has(0, 1) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB179 v\(b[0])") }
        guard b.has(0, headerBytes) else { return .malformed }
        let declared = Int(b.u32(24))
        let fits = max(0, (b.count - headerBytes) / neighbourBytes)
        var cells: [Neighbour] = []
        for j in 0..<min(declared, fits) {
            let o = headerBytes + neighbourBytes * j
            cells.append(Neighbour(pci: b.u16(o), rsrp: rsrp(b.u16(o + 2)), rsrq: rsrq(b.u16(o + 6))))
        }
        let tti = b.u16(14)
        return .value(Measurement(earfcn: Int64(b.u32(8)), pci: b.u16(12), sfn: tti / 10, subframe: tti % 10,
                                  rsrp: rsrp(b.u16(16)), rsrq: rsrq(b.u16(20)), neighbours: cells,
                                  declaredNeighbours: declared,
                                  lengthExact: b.count == headerBytes + neighbourBytes * declared))
    }
}
