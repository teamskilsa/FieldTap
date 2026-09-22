// One synthetic bit-packing test per decoder: every field at the position and width the layout comment names.

import Testing
import FTModel
@testable import FTPhy

@Suite struct DecoderTests {
    @Test func b0c1MibV2() throws {
        var p = Packing(11)
        p.u8(0, 2); p.u16(1, 80); p.u32(3, 67_086); p.u16(7, 1_023); p.u8(9, 4); p.u8(10, 50)
        let m = try #require(B0C1.decode(p.bytes).value)
        #expect(m == B0C1.Mib(pci: 80, earfcn: 67_086, sfn: 1_023, txAntennas: 4, dlBandwidthPrb: 50))
        #expect(B0C1.decode(Array(p.bytes.prefix(10))).value == nil)
    }

    @Test func b0c2ServingCellV3() throws {
        var p = Packing(29)
        p.u8(0, 3); p.u16(1, 235); p.u32(3, 5_110); p.u32(7, 23_110); p.u8(11, 50); p.u8(12, 50); p.u32(19, 12)
        let c = try #require(B0C2.decode(p.bytes).value)
        #expect(c == B0C2.ServingCell(pci: 235, dlEarfcn: 5_110, ulEarfcn: 23_110, dlBandwidthPrb: 50, ulBandwidthPrb: 50,
                                      band: 12))
    }

    /// Raw measurement units: RSRP x/16 - 180, RSRQ x/16 - 30, RSSI x/16 - 110.
    static func b193Cell(_ p: inout Packing, at c: Int, pci: Int, serving: Bool, carrier: Int, rxMap: UInt32) {
        p.u32(c, rxMap)
        p.u16(c + 8, pci | carrier << 9 | (serving ? 0x8000 : 0))
        let rsrp = { (dBm: Double) in Int((dBm + 180) * 16) }, rsrq = { (dB: Double) in Int((dB + 30) * 16) }
        let rssi = { (dBm: Double) in Int((dBm + 110) * 16) }
        p.u32(c + 24, field(rsrp(-100), 10, 12))                                  // Rx0
        p.u32(c + 28, field(rsrp(-101), 12, 12))                                  // Rx1
        p.u32(c + 32, field(rsrp(-102), 12, 12))                                  // Rx2
        p.u32(c + 40, field(rsrp(-103), 0, 12) | field(rsrp(-100) - 640, 12, 12))   // Rx3, combined (+640)
        p.u32(c + 44, field(rsrp(-99.5), 12, 12))                                 // filtered
        p.u32(c + 48, field(rsrq(-10), 0, 10) | field(rsrq(-11), 20, 10))           // RSRQ Rx0 / Rx1
        p.u32(c + 52, field(rsrq(-12), 10, 10) | field(rsrq(-13), 20, 10))          // RSRQ Rx2 / Rx3
        p.u32(c + 56, field(rsrq(-10.5), 0, 10) | field(rsrq(-10.25), 20, 10))      // RSRQ combined / filtered
        p.u32(c + 60, field(rssi(-70), 0, 11) | field(rssi(-71), 11, 11))           // RSSI Rx0 / Rx1
        p.u32(c + 64, field(rssi(-72), 0, 11) | field(rssi(-73), 11, 11))           // RSSI Rx2 / Rx3
        p.u32(c + 68, field(rssi(-69), 0, 11))                                    // RSSI combined
    }

    @Test func b193ServingAndNeighbourCellsV66() throws {
        var p = Packing(4 + 4 + 8 + 144 * 2)
        p.u8(0, 1); p.u8(1, 1)
        p.u8(4, 0x19); p.u8(5, 66); p.u16(6, 4 + 8 + 144 * 2)
        p.u32(8, 975); p.u16(12, 2)
        Self.b193Cell(&p, at: 16, pci: 235, serving: true, carrier: 2, rxMap: 0b0011)
        Self.b193Cell(&p, at: 16 + 144, pci: 233, serving: false, carrier: 0, rxMap: 0b1111)
        let cells = try #require(B193.decode(p.bytes).value)
        #expect(cells.count == 2)
        let s = cells[0]
        #expect(s.earfcn == 975 && s.pci == 235 && s.serving && s.carrier == 2 && s.rxCount == 2)
        #expect(s.rsrpRx == [-100, -101, -102, -103] && s.rsrp == -100 && s.rsrpFiltered == -99.5)
        #expect(s.rsrqRx == [-10, -11, -12, -13] && s.rsrq == -10.5 && s.rsrqFiltered == -10.25)
        #expect(s.rssiRx == [-70, -71, -72, -73] && s.rssi == -69)
        #expect(!cells[1].serving && cells[1].pci == 233 && cells[1].rxCount == 4)
        // Another subpacket id is skipped; 0x19 in another version is a miss.
        p.u8(4, 0x1A)
        #expect(B193.decode(p.bytes).value == [])
        p.u8(4, 0x19); p.u8(5, 48)
        #expect(B193.decode(p.bytes).miss == "0xB193 v1/0x19 v48")
    }

    @Test func b173PdschStatV50() throws {
        var p = Packing(4 + 40)
        p.u8(0, 50); p.u8(1, 1)
        let r = 4
        p.u16(r, 700 << 4 | 3); p.u8(r + 2, 2); p.u8(r + 3, 2); p.u8(r + 4, 0xF8 | 1)
        p.u8(r + 12, 5 | 2 << 4 | 1 << 6 | 1 << 7); p.u16(r + 13, 0 | 0 << 4)
        p.u16(r + 16, 1_800); p.u8(r + 18, 19); p.u8(r + 19, 48); p.u8(r + 20, 6)
        p.u8(r + 24, 6 | 0 << 4 | 0 << 6 | 0 << 7); p.u16(r + 25, 0 | 1 << 4)
        p.u16(r + 28, 900); p.u8(r + 30, 30); p.u8(r + 31, 48); p.u8(r + 32, 4)
        let recs = try #require(B173.decode(p.bytes).value)
        let rec = try #require(recs.first)
        #expect(rec.sfn == 700 && rec.subframe == 3 && rec.layers == 2 && rec.transportBlocks == 2 && rec.carrier == 1)
        #expect(rec.blocks[0] == B173.TransportBlock(harq: 5, rv: 2, ndi: 1, crcOk: true, rntiType: 0, tbIndex: 0,
                                                    tbsBytes: 1_800, mcs: 19, nRb: 48, qm: 6))
        #expect(rec.blocks[1].crcOk == false && rec.blocks[1].tbIndex == 1 && rec.blocks[1].mcs == 30
                && rec.blocks[1].qm == 4 && rec.blocks[1].harq == 6)
    }

    @Test func b139PuschTxReportV162() throws {
        var p = Packing(8 + 100)
        p.u8(0, 162); p.u16(1, 80 | 1 << 9)
        let flags = 1 | 3 << 7                                   // carrier 1, retx index 3
        p.u32(8, UInt32(4_567) | UInt32(flags) << 16)
        p.u32(12, field(1, 0, 1) | field(4, 1, 7) | field(40, 15, 7))
        p.u16(16, 1_479); p.u16(18, 512); p.u8(8 + 36, 3 << 2 | 1); p.u8(8 + 46, 140)
        let tx = try #require(B139.decode(p.bytes).value?.first)
        #expect(tx.pci == 80 && tx.tti == 4_567 && tx.carrier == 1 && tx.retxIndex == 3)
        #expect(tx.startRb == 4 && tx.nRb == 40 && tx.tbsBytes == 1_479 && tx.codeRate == 0.5)
        #expect(tx.modulation == 3 && tx.qm == 6 && tx.requiredPowerDbm == 33.5)
    }

    @Test func b14ePuschCsfV164() throws {
        var p = Packing(10)
        p.u8(0, 164)
        p.u32(1, field(7, 0, 4) | field(512, 4, 10) | field(1, 14, 4) | field(1, 28, 2))
        p.u32(5, field(9, 2, 5) | field(11, 7, 4) | field(9, 11, 4) | field(14, 24, 4))
        p.u8(9, 0x40 | 4)
        let r = try #require(B14E.decode(p.bytes).value)
        #expect(r == B14E.Report(sfn: 512, subframe: 7, carrier: 1, ri: 2, cqiCw0: 11, cqiCw1: 9, widebandPmi: 14, txMode: 4))
    }

    @Test func b14dPucchCsfV164() throws {
        var p = Packing(14)
        p.u8(0, 164)
        p.u32(1, field(3, 0, 4) | field(100, 4, 10) | field(2, 14, 4) | field(2, 26, 4))
        p.u16(6, 10 << 4 | 8 << 8 | 6 << 12); p.u16(8, 4); p.u16(10, 1 << 8)
        let cqi = try #require(B14D.decode(p.bytes).value)
        #expect(cqi.reportType == 2 && cqi.carrier == 2 && cqi.cqiCw0 == 10 && cqi.cqiCw1 == 8 && cqi.widebandPmi == 6
                && cqi.ri == nil && cqi.txMode == 4)
        p.u32(1, field(3, 26, 4))
        let ri = try #require(B14D.decode(p.bytes).value)
        #expect(ri.reportType == 3 && ri.ri == 2 && ri.cqiCw0 == nil)
    }

    @Test func b064MacUlTransportBlockV7() throws {
        // PHR subheader (E=1, LCID 26), a last SDU subheader (LCID 3), then the 1-byte PHR CE: PH index 30.
        let header: [UInt8] = [0x20 | 26, 3, 30]
        var p = Packing(4 + 4 + 1 + 13 + header.count)
        p.u8(0, 1); p.u8(1, 1)
        p.u8(4, 0x08); p.u8(5, 7); p.u16(6, 4 + 1 + 13 + header.count)
        p.u8(8, 1)
        let s = 9
        p.u8(s, 1); p.u8(s + 1, 5); p.u8(s + 2, 0); p.u16(s + 3, 300 << 4 | 2); p.u16(s + 5, 125); p.u8(s + 7, 1)
        p.u16(s + 8, 4); p.u8(s + 12, header.count)
        for (i, b) in header.enumerated() { p.u8(s + 13 + i, Int(b)) }
        let sample = try #require(B064.decode(p.bytes).value?.first)
        #expect(sample.carrier == 1 && sample.harq == 5 && sample.sfn == 300 && sample.subframe == 2)
        #expect(sample.grantBytes == 125 && sample.paddingBytes == 4 && sample.headerLength == 3)
        #expect(sample.headerConsistent && sample.powerHeadroomDb == 7)
        #expect(sample.controlElements == [B064.ControlElement(lcid: 26, payload: [30])])
        p.u8(5, 6)
        #expect(B064.decode(p.bytes).miss == "0xB064 v1/0x08 v6")
    }

    @Test func b064LongBsrAndLengthFields() {
        // Long BSR (LCID 30, 3 bytes) then an SDU with a 15-bit length field, then the last subheader (LCID 1).
        let (ces, used) = B064.controlElements([0x20 | 30, 0x20 | 2, 0x80 | 0x01, 0x02, 1, 0xAA, 0xBB, 0xCC])
        #expect(ces == [B064.ControlElement(lcid: 30, payload: [0xAA, 0xBB, 0xCC])])
        #expect(used == 8)
    }

    @Test func b062RachAttemptV50() throws {
        var p = Packing(4 + 4 + 41)
        p.u8(0, 1); p.u8(1, 1)
        p.u8(4, 6); p.u8(5, 50); p.u16(6, 41)
        let b = 8
        p.u8(b + 1, 0); p.u8(b + 2, 1); p.u8(b + 3, 1); p.u8(b + 4, 1); p.u8(b + 5, 0b111)
        p.u8(b + 6, 17); p.i16(b + 8, -110); p.u16(b + 18, 18); p.u32(b + 37, 132_622)
        let a = try #require(B062.decode(p.bytes).value?.first)
        #expect(a.preamble == 17 && a.preambleTargetDbm == -110 && a.taRar == 18 && a.ulEarfcn == 132_622 && a.attempts == 1)
        p.u8(b + 5, 0b101)
        #expect(B062.decode(p.bytes).value?.first?.taRar == nil, "no Msg2 in the bitmask: no TA")
    }

    /// Q7: the integer part's bits are stored so that -((i ^ 0xFF) + 1) is the value; 7 fraction bits.
    static func q7(integer: Int, eighths128: Int) -> UInt32 { UInt32((-integer - 1) ^ 0xFF) << 7 | UInt32(eighths128) }

    @Test func b97fNrSearcherV3() throws {
        var p = Packing(20 + 40 + 16 + 84 + 16)
        p.u16(0, 0); p.u16(2, 3); p.u8(8, 1)
        p.u32(20, 174_770); p.u8(24, 0); p.u8(25, 2); p.u16(26, 80); p.u8(28, 0)
        p.u16(60, 80); p.u8(64, 1); p.u32(68, Self.q7(integer: -107, eighths128: 64)); p.u32(72, Self.q7(integer: -12, eighths128: 0))
        p.u16(160, 233); p.u8(164, 0); p.u32(168, Self.q7(integer: -111, eighths128: 32)); p.u32(172, 0)
        let carrier = try #require(B97F.decode(p.bytes).value?.first)
        #expect(carrier.arfcn == 174_770 && carrier.ccId == 0 && carrier.servingPci == 80)
        #expect(carrier.cells == [B97F.Cell(pci: 80, rsrp: -106.5, rsrq: -12, beams: 1),
                                  B97F.Cell(pci: 233, rsrp: -110.75, rsrq: nil, beams: 0)])
    }

    @Test func b887NrPdschStatusV313() throws {
        var p = Packing(8 + 44)
        p.u16(0, 13); p.u16(2, 3); p.u8(7, 1)
        p.u32(16, field(571, 5, 10) | field(5, 15, 4)); p.u16(20, 80)
        p.u32(24, field(3_585, 5, 21) | field(27, 26, 5)); p.u32(28, field(52, 0, 7) | field(9, 11, 4) | field(1, 29, 1))
        p.u8(32, 1)
        let s = try #require(B887.decode(p.bytes).value?.first)
        #expect(s == B887.Slot(frame: 571, slot: 5, pci: 80, tbsBytes: 3_585, mcs: 27, nRb: 52, harq: 9, layers: 2, crcOk: true))
    }

    @Test func b888NrPdschStatsV31() throws {
        var p = Packing(92)
        p.u16(0, 1); p.u16(2, 3)
        let u: [UInt32] = [0, 7, 1_000, 500, 480, 20, 25, 1, 0]
        for (i, v) in u.enumerated() { p.u32(16 + 4 * i, v) }
        let q: [UInt64] = [600_000, 25_000, 625_000, 0, 30_000]
        for (i, v) in q.enumerated() { p.u64(52 + 8 * i, v) }
        let c = try #require(B888.decode(p.bytes).value)
        #expect(c == B888.Counters(carrier: 0, slots: 1_000, decodes: 500, crcPass: 480, crcFail: 20, retx: 25,
                                   passBytes: 600_000, failBytes: 25_000, tbBytes: 625_000))
        #expect(B888.decode(Array(p.bytes.prefix(91))).value == nil)
    }
}
