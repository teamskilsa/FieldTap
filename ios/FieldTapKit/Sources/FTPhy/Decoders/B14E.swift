// 0xB14E LTE LL1 PUSCH CSF (aperiodic CSI), v164: the MobileInsight v142 bit order for the first two words,
// validated on the iPhone 17 capture (Tx mode = RRC tm4; 9 subbands of 6 PRB for 50 PRB; RI against 0xB173).

/// One aperiodic CSI report: wideband CQI per codeword, rank and PMI, and the transmission mode.
enum B14E {
    struct Report: Hashable {
        var sfn: Int
        var subframe: Int
        var carrier: Int
        var ri: Int
        var cqiCw0: Int
        var cqiCw1: Int
        var widebandPmi: Int
        var txMode: Int
    }

    static let version = 164

    /// u32 @1: SF 4b, SFN 10b @4, carrier 4b @14, SCell 5b @18, mode 3b @24, RI-1 2b @28; u32 @5: WB CQI CW0 4b
    /// @7, CW1 4b @11, WB PMI 4b @24; byte 9 low nibble = transmission mode.
    static func decode(_ b: [UInt8]) -> Decoded<Report> {
        guard b.has(0, 1) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB14E v\(b[0])") }
        guard b.has(0, 10) else { return .malformed }
        let a = b.u32(1), c = b.u32(5)
        return .value(Report(sfn: a.bits(4, 10), subframe: a.bits(0, 4), carrier: a.bits(14, 4), ri: a.bits(28, 2) + 1,
                             cqiCw0: c.bits(7, 4), cqiCw1: c.bits(11, 4), widebandPmi: c.bits(24, 4),
                             txMode: b.u8(9) & 15))
    }
}
