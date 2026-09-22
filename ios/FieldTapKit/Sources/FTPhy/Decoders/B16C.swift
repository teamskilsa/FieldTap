// 0xB16C LTE ML1 DCI Information Report, v50 (0x32) on this modem. A flag-driven element chain whose element size
// comes out of the element's own first word, which is why the record has 40-odd distinct lengths. The chain
// consumes 495 of 495 bodies exactly across both captures.
//
// The two record kinds were identified by *when* they land, not by their contents:
//   * the 8-byte records fall on a subframe where 0xB173 logged a PDSCH in 99.4% / 99.6% — downlink assignments;
//   * the 16-byte records fall exactly four subframes before an 0xB139 PUSCH report in 97.7% / 99.6% — uplink
//     grants, at FDD's textbook n+4 timing. Every other shift from 0 to 8 scores at the base rate.
// The uplink grant's own fields then agree with 0xB139's for the same subframe in 99.96% / 99.98%.
//
// The 8-byte downlink assignment's contents are REJECTED and not read: the best bit field anywhere in it matches
// 0xB173's MCS in 31%/16%, N_RB at chance level, TBS in 1%/5% and HARQ in 14%, in both bit orders. Only how many
// there were per subframe is reported.

/// What the scheduler told this phone to do, per subframe: the uplink grant, and how many downlink assignments.
enum B16C {
    struct UlGrant: Hashable {
        var startRb: Int
        var nRb: Int
        /// 1 QPSK, 2 16QAM, 3 64QAM, 4 256QAM — the same code 0xB139 uses.
        var modulation: Int
        /// Modulation order Qm, or nil for a code outside 1-4.
        var qm: Int? { [1: 2, 2: 4, 3: 6, 4: 8][modulation] }
    }

    struct Element: Hashable {
        var sfn: Int
        var subframe: Int
        var ulGrants: [UlGrant]
        /// Downlink assignments in this subframe; their contents are not decoded.
        var dlAssignments: Int
        var tti: Int { sfn * 10 + subframe }
    }

    struct Record: Hashable {
        /// The element count the header states.
        var declared: Int
        /// True when the chain ended exactly on the body's last byte after `declared` elements.
        var exact: Bool
        var elements: [Element]
    }

    static let version = 50
    static let headerBytes = 4
    static let ulGrantBytes = 16
    static let dlAssignmentBytes = 8

    /// Header: u8 version, then the element count in bits 6-11 of the u16 at +1. Element: u32 with SFN bits 0-9,
    /// subframe bits 10-13, uplink grants bits 14-15 and downlink assignments bits 17-19, then the 16-byte grants
    /// and then the 8-byte assignments. Grant: start RB = u32 @5 bits 3-9, number of RBs = u32 @6 bits 2-8,
    /// modulation = byte +4 bits 0-2.
    static func decode(_ b: [UInt8]) -> Decoded<Record> {
        guard b.has(0, 1) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB16C v\(b[0])") }
        guard b.has(0, headerBytes) else { return .malformed }
        let declared = ((b.u8(1) >> 6) | (b.u8(2) << 2)) & 0x3F
        var elements: [Element] = []
        var pos = headerBytes
        while elements.count < declared, b.has(pos, 4) {
            let w = b.u32(pos)
            let grants = w.bits(14, 2), assignments = w.bits(17, 3)
            var q = pos + 4
            var out: [UlGrant] = []
            for i in 0..<grants {
                let g = q + ulGrantBytes * i
                guard b.has(g, ulGrantBytes) else { break }
                out.append(UlGrant(startRb: b.u32(g + 5).bits(3, 7), nRb: b.u32(g + 6).bits(2, 7),
                                   modulation: b.u8(g + 4) & 7))
            }
            q += ulGrantBytes * grants
            elements.append(Element(sfn: w.bits(0, 10), subframe: w.bits(10, 4), ulGrants: out,
                                   dlAssignments: assignments))
            pos = q + dlAssignmentBytes * assignments
        }
        return .value(Record(declared: declared, exact: pos == b.count && elements.count == declared,
                             elements: elements))
    }
}
