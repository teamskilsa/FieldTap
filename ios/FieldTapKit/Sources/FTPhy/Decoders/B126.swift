// 0xB126 LTE LL1 PDSCH Demapper Configuration, v163 (this modem). No published layout; derived and validated on
// the two iPhone 17 captures (docs/research/iphone-named-log-codes.md). The body is always exactly 968 bytes: an
// 8-byte header (version, then 7 bytes that never change) and 20 fixed 48-byte sub-records, one per logged
// subframe, OLDEST FIRST. Only the last sub-record is "now": its (SFN, subframe) matches the record's own DIAG
// timestamp with circular R = 1.00000 and a standard deviation of 0.12 ms, which is what fixed the sub-record
// size, the count and the order.
//
// Validated: popcount(the PRB bitmap) is an N_RB that 0xB173 reports for the same subframe in 99.5% / 99.7% of
// the sub-records 0xB173 also covers; the rank equals 0xB173's layer count (transmit diversity excepted) in
// 99.9% / 100.0%; the transmit antenna ports equal the 0xB0C1 MIB's antenna count for every cell whose MIB was
// captured, and follow the serving cell rather than the scheduling, which is why they are an antenna-port count
// and not the transmission mode. The receive-antenna field agrees with the Rx antennas 0xB193 measured in
// 88% / 93%, which is not decisive, so it is medium confidence.

/// The last 20 subframes' PDSCH demapper configuration: the cell's transmit antenna ports, the receive antennas
/// in use, the MIMO rank and exactly which resource blocks the PDSCH used.
enum B126 {
    struct SubRecord: Hashable {
        var sfn: Int
        var subframe: Int
        /// Transmit antenna ports of the serving cell (1, 2 or 4).
        var txAntennaPorts: Int
        /// Receive antennas in use (1-4); medium confidence.
        var rxAntennas: Int
        /// Spatial layers of this PDSCH.
        var rank: Int
        /// Bit k = PRB k of the allocation (up to 56 bits; 50 are used on a 50-PRB cell).
        var prbMask: UInt64
        var nPrb: Int { prbMask.nonzeroBitCount }
        /// SFN x 10 + subframe, the record's own place in the 10.24 s frame cycle.
        var tti: Int { sfn * 10 + subframe }
    }

    static let version = 163
    static let bodyBytes = 968
    static let headerBytes = 8
    static let subRecordBytes = 48
    static let subRecordCount = 20

    /// Sub-record: u16 SFN<<4 | subframe @0; u8 @2 bits 1-3 transmit antenna ports, bits 4-5 receive antennas - 1;
    /// u8 @4 bits 0-1 rank - 1; 7 bytes @8 the PRB bitmap (repeated at @24). Bytes +5, +7, +40 and +41 are not
    /// identified and are not read.
    static func decode(_ b: [UInt8]) -> Decoded<[SubRecord]> {
        guard b.has(0, 1) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB126 v\(b[0])") }
        guard b.count == bodyBytes else { return .malformed }
        var out: [SubRecord] = []
        out.reserveCapacity(subRecordCount)
        for k in 0..<subRecordCount {
            let o = headerBytes + subRecordBytes * k
            let w = b.u16(o)
            var mask: UInt64 = 0
            for i in 0..<7 { mask |= UInt64(b[o + 8 + i]) << (8 * UInt64(i)) }
            out.append(SubRecord(sfn: (w >> 4) & 1_023, subframe: w & 15,
                                 txAntennaPorts: (b.u8(o + 2) >> 1) & 7,
                                 rxAntennas: ((b.u8(o + 2) >> 4) & 3) + 1,
                                 rank: (b.u8(o + 4) & 3) + 1,
                                 prbMask: mask))
        }
        return .value(out)
    }
}
