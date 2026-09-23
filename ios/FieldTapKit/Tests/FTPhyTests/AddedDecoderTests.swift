// The decoders added after the reference extractor, twice over: a synthetic body per decoder that states its
// layout field by field, and then the two real captures, where every number asserted is the one
// docs/research/iphone-named-log-codes.md and iphone-unknown-log-codes.md claim.

import Testing
import FTModel
@testable import FTPhy

@Suite struct AddedLayoutTests {
    /// 0xB126: 20 fixed 48-byte sub-records in a fixed 968-byte body, oldest first.
    @Test func b126DemapperV163() throws {
        var p = Packing(B126.bodyBytes)
        p.u8(0, 163)
        for k in 0..<20 {
            let o = B126.headerBytes + B126.subRecordBytes * k
            p.u16(o, (700 + k) << 4 | (k % 10))
            p.u8(o + 2, 4 << 1 | 3 << 4)          // 4 transmit antenna ports, receive antennas 3 + 1 = 4
            p.u8(o + 4, 1)                         // rank 2
            p.u8(o + 8, 0b0000_0111)               // PRB 0, 1, 2
            p.u8(o + 14, 3)                        // PRB 48 and 49: the top of a 50-PRB cell
        }
        let subs = try #require(B126.decode(p.bytes).value)
        #expect(subs.count == 20)
        let first = subs[0], last = subs[19]
        #expect(first.sfn == 700 && first.subframe == 0 && last.sfn == 719 && last.subframe == 9)
        #expect(first.txAntennaPorts == 4 && first.rxAntennas == 4 && first.rank == 2)
        #expect(first.nPrb == 5 && first.prbMask == 0b111 | 3 << 48)
        #expect(first.tti == 7_000 && last.tti == 7_199)
        // Strict version dispatch, and a body that is not 968 bytes is malformed rather than guessed at.
        p.u8(0, 162)
        #expect(B126.decode(p.bytes).miss == "0xB126 v162")
        p.u8(0, 163)
        #expect(B126.decode(Array(p.bytes.prefix(900))).value == nil)
    }

    /// 0xB179: a fixed 28-byte header and 12-byte neighbours, and the length identity the check counts.
    @Test func b179IntraFrequencyV56() throws {
        var p = Packing(28 + 12 * 2)
        p.u8(0, 56)
        p.u32(8, 5_110)
        p.u16(12, 80)
        p.u16(14, 1_234)                                  // TTI = SFN 123, subframe 4
        let rsrp = { (dBm: Double) in Int((dBm + 180) * 16) }, rsrq = { (dB: Double) in Int((dB + 30) * 16) }
        p.u16(16, rsrp(-95)); p.u16(18, rsrp(-95))
        p.u16(20, rsrq(-11)); p.u16(22, rsrq(-11))
        p.u32(24, 2)
        p.u16(28, 295); p.u16(30, rsrp(-101)); p.u16(32, rsrp(-101)); p.u16(34, rsrq(-14)); p.u16(36, rsrq(-14))
        p.u16(40, 388); p.u16(42, rsrp(-88)); p.u16(44, rsrp(-88)); p.u16(46, rsrq(-9)); p.u16(48, rsrq(-9))
        let m = try #require(B179.decode(p.bytes).value)
        #expect(m.earfcn == 5_110 && m.pci == 80 && m.sfn == 123 && m.subframe == 4 && m.tti == 1_234)
        #expect(m.rsrp == -95 && m.rsrq == -11)
        #expect(m.neighbours.map(\.pci) == [295, 388])
        #expect(m.neighbours.map(\.rsrp) == [-101, -88])
        #expect(m.neighbours.map(\.rsrq) == [-14, -9])
        #expect(m.lengthExact && m.declaredNeighbours == 2)
        // A count the length does not explain reads what fits and says so, instead of reading past the body.
        p.u32(24, 5)
        let short = try #require(B179.decode(p.bytes).value)
        #expect(!short.lengthExact && short.neighbours.count == 2 && short.declaredNeighbours == 5)
        p.u8(0, 55)
        #expect(B179.decode(p.bytes).miss == "0xB179 v55")
    }

    /// 0xB063: the 16-byte transport-block header, the 12-byte SDU descriptors and the PDCP tail rule.
    @Test func b063MacDlV50() throws {
        // One transport block: 200 bytes, 8 padding, SFN 300 subframe 7, HARQ 5 carrier 1, two SDUs.
        let body = 8 + 16 + 12 * 2 + 8 * 4
        var p = Packing(body)
        p.u8(0, 0x32)
        p.u32(4, 1)
        p.u32(8, 200)
        p.u32(12, 8)
        p.u32(16, UInt32(300 | 7 << 10))
        p.u8(20, 1 | 5 << 4)
        p.u8(21, 2)
        p.u16(22, 6)
        // Descriptor 1: a data SDU on LCID 3, 150 bytes, with a PDCP tail of 8 x 4 bytes.
        let d1 = 24
        let w1 = (0) | (3 << 1) | (150 << 7)
        p.u8(d1, w1 & 0xFF); p.u8(d1 + 1, (w1 >> 8) & 0xFF); p.u8(d1 + 2, (w1 >> 16) & 0xFF)
        p.u8(d1 + 9, 4)
        // Descriptor 2: a timing-advance command (control, LCID 29), length 1, no tail.
        let d2 = 36
        let w2 = 1 | (29 << 1) | (1 << 7)
        p.u8(d2, w2 & 0xFF); p.u8(d2 + 1, (w2 >> 8) & 0xFF); p.u8(d2 + 2, (w2 >> 16) & 0xFF)
        let decoded = try #require(B063.decode(p.bytes).value)
        let tb = try #require(decoded.blocks.first)
        #expect(tb.sizeBytes == 200 && tb.paddingBytes == 8 && tb.sfn == 300 && tb.subframe == 7)
        #expect(tb.harq == 5 && tb.carrier == 1 && tb.headerBytes == 6 && tb.tti == 3_007)
        #expect(tb.sdus == [B063.Sdu(control: false, lcid: 3, lengthBytes: 150),
                            B063.Sdu(control: true, lcid: 29, lengthBytes: 1)])
        #expect(tb.dataBytes == 150 && tb.signallingBytes == 0)
        #expect(tb.hasTimingAdvanceCommand, "the command is logged; its 6-bit value is not in the record")
        #expect(decoded.walk.declared == 1 && decoded.walk.found == 1 && decoded.walk.exact)
        p.u8(0, 0x31)
        #expect(B063.decode(p.bytes).miss == "0xB063 v49")
    }

    /// 0xB12A: a fixed 176-byte body, 20 8-byte elements, the CFI in byte +3 as 4 x {1, 2, 3}.
    @Test func b12aPcfichV161() throws {
        var p = Packing(176)
        p.u8(0, 161)
        p.u16(4, 900)
        for k in 0..<20 {
            let o = 16 + 8 * k
            p.u16(o, k)
            p.u8(o + 2, k == 5 ? 0 : 1)                 // element 5: nothing decoded
            p.u8(o + 3, k == 5 ? 0 : (k % 3 + 1) << 2)  // 4 x CFI
            p.u16(o + 4, 0xD0 | (k % 10) << 8)
        }
        let r = try #require(B12A.decode(p.bytes).value)
        #expect(r.sfn == 900 && r.elements.count == 20)
        #expect(r.elements[0].cfi == 1 && r.elements[1].cfi == 2 && r.elements[2].cfi == 3)
        #expect(r.elements[0].subframe == 0 && r.elements[9].subframe == 9)
        #expect(r.elements[5].cfi == nil && !r.elements[5].decoded)
        #expect(r.elements.allSatisfy { $0.consistent })
        // A CFI of 4 (or a flag that disagrees with it) is not consistent, and the check counts it.
        p.u8(16 + 3, 4 << 2)
        #expect(B12A.decode(p.bytes).value?.elements.first?.consistent == false)
        p.u8(0, 160)
        #expect(B12A.decode(p.bytes).miss == "0xB12A v160")
    }

    /// 0xB16C: the flag-driven element chain, the 16-byte uplink grant, and the 8-byte assignments counted only.
    @Test func b16cDciV50() throws {
        var p = Packing(4 + 4 + 16 + 8)
        p.u8(0, 50)
        p.u16(1, 1 << 6)                         // one element (bits 6-11 of the u16 at +1)
        // Element: SFN 512, subframe 3, one 16-byte uplink grant, one 8-byte downlink assignment.
        p.u32(4, UInt32(512 | 3 << 10 | 1 << 14 | 1 << 17))
        let g = 8
        p.u8(g + 4, 2)                           // modulation 2 = 16QAM
        // start RB 7 at record bits 43-49, number of RBs 12 at bits 50-56.
        p.u32(g + 5, UInt32(7 << 3 | 12 << 10))
        let r = try #require(B16C.decode(p.bytes).value)
        #expect(r.declared == 1 && r.exact && r.elements.count == 1)
        let e = try #require(r.elements.first)
        #expect(e.sfn == 512 && e.subframe == 3 && e.tti == 5_123 && e.dlAssignments == 1)
        #expect(e.ulGrants == [B16C.UlGrant(startRb: 7, nRb: 12, modulation: 2)])
        #expect(e.ulGrants.first?.qm == 4)
        p.u8(0, 49)
        #expect(B16C.decode(p.bytes).miss == "0xB16C v49")
    }

    /// 0x184C: the block walk, the chain-off sentinel and the binding limit.
    @Test func d184cTxAgcV17() throws {
        let body = 16 + 120 * 2 + 16 + 120
        var p = Packing(body)
        func blockHeader(_ o: Int, subframe: Int) {
            p.u8(o, 0x11)
            p.u16(o + 7, subframe << 4)
        }
        blockHeader(0, subframe: 40)
        // Chain 0x20: 21.3 dBm against a 24.5 dBm limit. Chain 0x21: off (-70.0 dBm).
        var o = 16
        p.u8(o, 0x20); p.u8(o + 1, 0x24); p.i16(o + 4, 213); p.i16(o + 6, 230)
        p.u16(o + 66, 245); p.u16(o + 68, 245); p.u16(o + 70, 250)
        o = 136
        p.u8(o, 0x21); p.i16(o + 4, -700)
        p.u16(o + 66, 245); p.u16(o + 68, 245); p.u16(o + 70, 245)
        blockHeader(256, subframe: 41)
        o = 272
        p.u8(o, 0x20); p.u8(o + 1, 0x10); p.i16(o + 4, 249)
        p.u16(o + 66, 249); p.u16(o + 68, 249); p.u16(o + 70, 249)
        let decoded = try #require(D184C.decode(p.bytes).value)
        #expect(decoded.exact)
        #expect(decoded.blocks.map(\.subframe) == [40, 41])
        let live = try #require(decoded.blocks.first?.subRecords.first)
        #expect(live.chain == 0x20 && live.gainState == 0x24)
        #expect(live.txPowerDbm == 21.3 && live.secondPowerDbm == 23.0)
        #expect(live.limitDbm == 24.5, "the binding limit is the smallest of the three")
        #expect(D184C.subRecord(Packing(120).bytes, 0).limitDbm == nil, "a zero limit is unset, not 0 dBm")
        #expect(abs((live.headroomDb ?? 0) - 3.2) < 0.001)
        let off = try #require(decoded.blocks.first?.subRecords.last)
        #expect(off.txPowerDbm == nil && off.headroomDb == nil, "-70.0 dBm means the chain was off")
        let limited = try #require(decoded.blocks.last?.subRecords.first)
        #expect(limited.headroomDb == 0, "24.9 of 24.9 dBm: transmit-limited")
        p.u8(0, 0x12)
        #expect(D184C.decode(p.bytes).miss == "0x184C v18")
    }

    /// 0x1D0B: the two clocks and the sequence number, and nothing from the entries.
    @Test func d1d0bClocksV7() throws {
        var p = Packing(370)
        p.u32(0, 7)
        p.u32(4, 1_000_000)
        p.u32(8, 0x01FF_FFFF)          // 24 bits, so the top byte is not part of the tick
        p.u32(84, 4_242)
        let s = try #require(D1D0B.decode(p.bytes).value)
        #expect(s.sleepCounts == 1_000_000 && s.tcxoTicks == 0xFF_FFFF && s.sequence == 4_242)
        p.u32(0, 6)
        #expect(D1D0B.decode(p.bytes).miss == "0x1D0B v6")
        p.u32(0, 7)
        #expect(D1D0B.decode(Array(p.bytes.prefix(80))).value == nil)
    }

    /// The absolute-TTI axis: the frame phase as a circular mean, and a TTI placed against an anchor.
    @Test func ttiAxisPlacesARecordWithoutATimestamp() {
        var axis = PhyTtiAxis()
        // A capture whose records are logged 1,440 ms after the frame they name, two whole cycles in.
        for k in 0..<50 {
            let tti = (k * 37) % 10_240
            axis.add(tMs: 2 * PhyTtiAxis.cycleMs + Double(tti) + 1_440, tti: tti)
        }
        #expect(axis.concentration > 0.9999)
        #expect(abs(axis.phaseMs - 1_440) < 0.01)
        // A record that names TTI 5,000, anchored by a neighbour stamped 23,000 ms: 5,000 + 1,440 + 2 x 10,240.
        #expect(abs(axis.timeMs(tti: 5_000, near: 23_000) - 26_920) < 0.01)
        #expect(axis.absoluteTti(tti: 5_000, tMs: 23_000) == 25_480)
        // Its wrap is exact at the cycle boundary.
        #expect(PhyTtiAxis.wrap(-1) == 10_239)
        #expect(PhyTtiAxis.wrap(10_240) == 0)
    }

    /// Strict version dispatch reaches the new codes through the extractor too.
    @Test func versionMissesAreCountedForTheAddedCodes() {
        func body(_ first: Int, _ count: Int = 400) -> [UInt8] {
            var p = Packing(count)
            p.u8(0, first)
            return p.bytes
        }
        let wrong: [(UInt16, [UInt8], String)] = [
            (0xB126, body(162, 968), "0xB126 v162"),
            (0xB12A, body(160, 176), "0xB12A v160"),
            (0xB16C, body(49), "0xB16C v49"),
            (0xB179, body(55), "0xB179 v55"),
            (0xB063, body(0x31), "0xB063 v49"),
            (0x184C, body(0x12), "0x184C v18"),
            (0x1D0B, body(6, 370), "0x1D0B v6"),
        ]
        let records = wrong.enumerated().map { i, w in LogRecord(code: w.0, timestampRaw: stamp(Double(i) * 10), body: w.1) }
        let capture = PhyExtractor.extract(records: records, timeBase: TimeBase.of(records), secure: .empty)
        #expect(capture.versionMisses == Dictionary(uniqueKeysWithValues: wrong.map { ($0.2, 1) }))
        for m in PhyMetric.addedAfterReference { #expect(capture.series[m]?.samples.isEmpty == true, "\(m.rawValue)") }
    }

    /// Every added metric names the record version its decoder accepts, and the dispatch table lists its code.
    @Test func addedMetricsNameTheirVersion() {
        for m in PhyMetric.addedAfterReference {
            let info = m.info
            #expect(!info.version.isEmpty, "\(m.rawValue)")
            #expect(PhyDispatch.codes.contains(info.code), "\(m.rawValue)")
        }
        #expect(PhyDispatch.validated[0xB126] == "v163" && PhyDispatch.validated[0xB179] == "v56")
        #expect(PhyDispatch.validated[0xB063] == "v50" && PhyDispatch.validated[0xB12A] == "v161")
        #expect(PhyDispatch.validated[0xB16C] == "v50" && PhyDispatch.validated[0x184C] == "v17")
        #expect(PhyDispatch.validated[0x1D0B] == "v7")
        // 0xB173 and 0xB139 are decoded before the codes that are checked against them.
        let order = PhyDispatch.codes
        for code in [0xB126, 0xB12A, 0xB16C, 0xB179, 0xB063] as [UInt16] {
            #expect(order.firstIndex(of: 0xB173)! < order.firstIndex(of: code)!, "\(code) before 0xB173")
            #expect(order.firstIndex(of: 0xB193)! < order.firstIndex(of: code)!, "\(code) before 0xB193")
        }
        #expect(PhyDispatch.unstampedCodes == [0xB179])
    }
}
