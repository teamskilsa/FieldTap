// 0xB14D LTE LL1 PUCCH CSF (periodic CSI), v164. The first word follows the MobileInsight v142 order; after
// byte 5 v164 differs from v142 and the CQI/PMI/RI positions were re-derived on the iPhone 17 capture (they agree
// with 0xB14E at the same moments), hence medium confidence.

/// One periodic CSI report. Report type 3 carries RI; types 2 and 4 carry wideband CQI and PMI.
enum B14D {
    struct Report: Hashable {
        var sfn: Int
        var subframe: Int
        var carrier: Int
        var reportType: Int
        var ri: Int?
        var cqiCw0: Int?
        var cqiCw1: Int?
        var widebandPmi: Int?
        var txMode: Int
    }

    static let version = 164

    /// u32 @1: SF, SFN, carrier 4b @14, SCell, mode 2b @24, report type 4b @26; u16 @6: CQI CW0 bits 4-7, CW1 bits
    /// 8-11, WB PMI bits 12-15; u16 @8 low nibble = Tx mode; u16 @10 bits 8-9 = RI-1.
    static func decode(_ b: [UInt8]) -> Decoded<Report> {
        guard b.has(0, 1) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB14D v\(b[0])") }
        guard b.has(0, 14) else { return .malformed }
        let a = b.u32(1), q = b.u16(6), r = b.u16(10)
        let type = a.bits(26, 4)
        var report = Report(sfn: a.bits(4, 10), subframe: a.bits(0, 4), carrier: a.bits(14, 4), reportType: type,
                            txMode: b.u16(8) & 15)
        if type == 3 {
            report.ri = ((r >> 8) & 3) + 1
        } else if type == 2 || type == 4 {
            report.cqiCw0 = (q >> 4) & 15
            report.cqiCw1 = (q >> 8) & 15
            report.widebandPmi = (q >> 12) & 15
        }
        return .value(report)
    }
}
