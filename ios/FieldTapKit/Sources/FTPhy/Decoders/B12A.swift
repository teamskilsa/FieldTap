// 0xB12A LTE LL1 PCFICH Decoding Results, v161 (0xA1) on this modem. Fixed 176-byte body: a 16-byte header and 20
// 8-byte elements, one per subframe, so each record covers two radio frames.
//
// Validated: element byte +3 takes only 0x04, 0x08, 0x0C and 0x00 across all 32,140 and 26,680 elements of the two
// captures, i.e. 4 x CFI with CFI in {1, 2, 3} — exactly the legal set for a 50-PRB cell and never the 4 that only
// 1.4 MHz cells use — and it is 0 in precisely the elements where the decode flag at +2 is 0, with no exceptions.
// The header SFN fits the timestamp with R = 0.99854 / 0.99985.
//
// Not established: which of the two radio frames the header SFN names (10 ms is below the timestamp's
// discriminating power), so the app places the elements by the record's own time and says the subframe is only
// good to a frame. The CFI value itself could not be cross-checked against 0xB16C's DCI count (r ~ 0.00), which
// is expected — the control region is sized for the whole cell, not for this phone — so it is corroborated
// structurally.

/// The size of the cell's control region per subframe: the PDCCH load, which does not depend on this phone's own
/// traffic.
enum B12A {
    struct Element: Hashable {
        /// Rolling element index 0-19 inside the record.
        var index: Int
        /// True when the modem logged a PCFICH decode for this subframe.
        var decoded: Bool
        /// OFDM symbols the cell spends on control (1-3), or nil when nothing was decoded.
        var cfi: Int?
        var subframe: Int
        /// True when byte +3 is 4 x a legal CFI (or 0 exactly when nothing was decoded): the runtime check.
        var consistent: Bool
    }

    struct Record: Hashable {
        var sfn: Int
        var elements: [Element]
    }

    static let version = 161
    static let bodyBytes = 176
    static let headerBytes = 16
    static let elementBytes = 8
    static let elementCount = 20

    /// u16 @4 bits 0-9 SFN; then 20 elements: u16 index @0, u8 decode flag @2, u8 4 x CFI @3, u16 @4 bits 8-11
    /// subframe.
    static func decode(_ b: [UInt8]) -> Decoded<Record> {
        guard b.has(0, 1) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB12A v\(b[0])") }
        guard b.count == bodyBytes else { return .malformed }
        var elements: [Element] = []
        elements.reserveCapacity(elementCount)
        for k in 0..<elementCount {
            let p = headerBytes + elementBytes * k
            let raw = b.u8(p + 3), decoded = b.u8(p + 2) == 1
            let cfi = raw >> 2
            elements.append(Element(index: b.u16(p), decoded: decoded, cfi: raw == 0 ? nil : cfi,
                                    subframe: (b.u16(p + 4) >> 8) & 15,
                                    consistent: raw & 3 == 0 && (raw == 0) == !decoded && (raw == 0 || (1...3).contains(cfi))))
        }
        return .value(Record(sfn: b.u16(4) & 1_023, elements: elements))
    }
}
