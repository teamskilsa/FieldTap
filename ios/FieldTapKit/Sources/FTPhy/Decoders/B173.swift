// 0xB173 LTE PDSCH Stat Indication, v50 (this modem). 4-byte header (version, record count, 2 reserved), then
// fixed 40-byte records: a 12-byte part, two 12-byte transport-block slots in the MobileInsight v40 slot order,
// and a 4-byte tail. The meaning of bytes 2-4 was re-derived on the iPhone 17 capture and validated by the TS
// 36.213 TBS matches and the SCell carriers.

/// One PDSCH scheduling decision per record: layers, transport blocks and the carrier they were on.
enum B173 {
    struct TransportBlock: Hashable {
        var harq: Int
        var rv: Int
        var ndi: Int
        var crcOk: Bool
        /// 0 = C-RNTI (user data); the others are SI/P/RA-RNTI broadcasts.
        var rntiType: Int
        var tbIndex: Int
        var tbsBytes: Int
        var mcs: Int
        var nRb: Int
        /// Modulation order Qm (2, 4, 6, 8); 0 when the slot is unused.
        var qm: Int
    }

    struct Record: Hashable {
        var sfn: Int
        var subframe: Int
        /// Spatial layers; 4 with one transport block is transmit diversity, not 4-layer MIMO.
        var layers: Int
        var transportBlocks: Int
        /// Serving-cell index: 0 = PCell, 1-3 = SCell.
        var carrier: Int
        var blocks: [TransportBlock]
    }

    static let version = 50
    static let recordBytes = 40

    /// u16 SFN<<4|SF @0, u8 layers @2, u8 TB count @3, u8 carrier&7 @4; TB slots @12 and @24: u8 HARQ 4b | RV 2b
    /// | NDI 1b | CRC 1b, u16 RNTI type 4b | TB index bit 4, u16 TBS bytes @+4, u8 MCS @+6, u8 nRB @+7, u8 Qm @+8.
    static func decode(_ b: [UInt8]) -> Decoded<[Record]> {
        guard b.has(0, 2) else { return .malformed }
        guard b[0] == version else { return .versionMiss("0xB173 v\(b[0])") }
        var out: [Record] = []
        for k in 0..<Int(b[1]) {
            let r = 4 + recordBytes * k
            guard b.has(r, recordBytes) else { break }
            let w = b.u16(r), ntb = b.u8(r + 3)
            var blocks: [TransportBlock] = []
            for j in 0..<min(ntb, 2) {
                let t = r + 12 + 12 * j
                let hb = b.u8(t), rw = b.u16(t + 1)
                blocks.append(TransportBlock(harq: hb & 15, rv: (hb >> 4) & 3, ndi: (hb >> 6) & 1, crcOk: hb >> 7 & 1 == 1,
                                             rntiType: rw & 15, tbIndex: (rw >> 4) & 1, tbsBytes: b.u16(t + 4),
                                             mcs: b.u8(t + 6), nRb: b.u8(t + 7), qm: b.u8(t + 8)))
            }
            out.append(Record(sfn: (w >> 4) & 4095, subframe: w & 15, layers: b.u8(r + 2), transportBlocks: ntb,
                              carrier: b.u8(r + 4) & 7, blocks: blocks))
        }
        return .value(out)
    }
}
