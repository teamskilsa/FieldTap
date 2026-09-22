// Port of android/diag/src/test/kotlin/com/fieldtap/diag/ProtocolTest.kt (9 tests), plus the encoder.

import Testing
import FTModel
@testable import FTCore

/// A log packet as the modem emits it: header, then body.
func logPacket(_ code: UInt16, _ timestampRaw: UInt64, _ body: [UInt8]) -> [UInt8] {
    let inner = DiagProtocol.logEntryHeaderLen + body.count
    var out = [UInt8](repeating: 0, count: DiagProtocol.logHeaderLen + body.count)
    out[0] = DiagProtocol.diagLogF
    func putU16(_ at: Int, _ v: Int) {
        out[at] = UInt8(v & 0xFF)
        out[at + 1] = UInt8((v >> 8) & 0xFF)
    }
    putU16(2, inner)
    putU16(4, inner)
    putU16(6, Int(code))
    for i in 0..<8 { out[8 + i] = UInt8((timestampRaw >> (8 * UInt64(i))) & 0xFF) }
    out.replaceSubrange(DiagProtocol.logHeaderLen..., with: body)
    return out
}

func container(_ packets: [[UInt8]], count: Int = -1, version: UInt8 = 1) -> [UInt8] {
    let n = count >= 0 ? count : packets.count
    let head: [UInt8] = [DiagProtocol.diagMultiLogF, version, 0, 0,
                         UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
    return head + packets.flatMap { $0 }
}

@Suite struct ProtocolTests {
    @Test func aLogPacketYieldsItsCodeTimestampAndBody() throws {
        let rec = try #require(DiagProtocol.parseLogPacket(logPacket(0xB0C0, 0x1234_5678, [1, 2, 3, 4])))
        #expect(rec.code == 0xB0C0)
        #expect(rec.timestampRaw == 0x1234_5678)
        #expect(rec.body == [1, 2, 3, 4])
    }

    @Test func theEquipmentIdIsTheTopNibble() {
        #expect(DiagProtocol.equipId(0xB0C0) == 0xB)
        #expect(DiagProtocol.equipId(0x1C98) == 0x1)
        #expect(DiagProtocol.logItem(0xB0C0) == 0x0C0)
    }

    @Test func aTruncatedLogPacketKeepsWhatItHas() throws {
        let full = logPacket(0xB821, 9, (0..<40).map { UInt8($0) })
        let cut = Array(full.dropLast(10))
        let rec = try #require(DiagProtocol.parseLogPacket(cut))
        #expect(rec.code == 0xB821)
        #expect(rec.body.count == 30, "the body is short rather than the parse failing")
    }

    @Test func theContainerShapeTheHandsetWritesIsUnwrapped() {
        // Exactly the bytes diag_mdlog produced on the reference handset: 0x98, version 1, two pad bytes,
        // count 1, then one log packet.
        let packet = logPacket(0xB0C0, 0x41, [0x1B, 0x10])
        let frame = container([packet])
        #expect(Array(frame.prefix(8)) == [0x98, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
        let got = DiagProtocol.qmdl2LogPackets(frame)
        #expect(got == [packet])
        #expect(DiagProtocol.parseLogPacket(got[0])?.code == 0xB0C0)
    }

    @Test func aContainerHoldingSeveralPacketsYieldsThemAll() {
        let packets = [
            logPacket(0xB0C0, 1, [UInt8](repeating: 0, count: 10)),
            logPacket(0xB821, 2, [UInt8](repeating: 0, count: 3)),
            logPacket(0xB0EC, 3, []),
        ]
        let got = DiagProtocol.qmdl2LogPackets(container(packets))
        #expect(got.compactMap { DiagProtocol.parseLogPacket($0)?.code } == [0xB0C0, 0xB821, 0xB0EC])
    }

    @Test func theDeclaredCountBoundsWhatIsRead() {
        let packets = [logPacket(0xB0C0, 1, [0, 0, 0, 0]), logPacket(0xB821, 2, [0, 0, 0, 0])]
        #expect(DiagProtocol.qmdl2LogPackets(container(packets, count: 1)).count == 1)
    }

    @Test func aTruncatedContainerYieldsWhatItHolds() {
        let packet = logPacket(0xB0C0, 1, [UInt8](repeating: 0, count: 20))
        let frame = container([packet])
        let got = DiagProtocol.qmdl2LogPackets(Array(frame.dropLast(5)))
        #expect(got.count == 1)
        #expect(got[0].count < packet.count)
    }

    @Test func aFrameThatIsNotAContainerYieldsNothing() {
        #expect(DiagProtocol.qmdl2LogPackets([]).isEmpty)
        #expect(DiagProtocol.qmdl2LogPackets([0x98, 0x01]).isEmpty)
        #expect(DiagProtocol.qmdl2LogPackets(logPacket(0xB0C0, 1, [0, 0])).isEmpty)
    }

    @Test func logPacketsOfAcceptsBothShapesAndRejectsTheRest() {
        let packet = logPacket(0xB0C0, 1, [0, 0])
        #expect(DiagProtocol.logPacketsOf(packet).count == 1)
        #expect(DiagProtocol.logPacketsOf(container([packet])).count == 1)
        // A response, not a log packet.
        #expect(DiagProtocol.logPacketsOf([0x73, 0x00, 0x00, 0x00]).isEmpty)
        #expect(DiagProtocol.logPacketsOf([]).isEmpty)
    }

    @Test func encodeLogPacketIsTheInverseOfParse() throws {
        let rec = LogRecord(code: 0xB193, timestampRaw: 0x0112_3456_789A_BCDE, body: (0..<33).map { UInt8($0) }, more: 1)
        let bytes = DiagProtocol.encodeLogPacket(rec)
        #expect(bytes == logPacket(0xB193, 0x0112_3456_789A_BCDE, rec.body).enumerated().map { $0 == 1 ? 1 : $1 })
        #expect(try #require(DiagProtocol.parseLogPacket(bytes)) == rec)
    }

    @Test func aShortOrForeignPacketIsNotALogRecord() {
        #expect(DiagProtocol.parseLogPacket([0x10, 0, 0]) == nil)
        #expect(DiagProtocol.parseLogPacket([UInt8](repeating: 0x11, count: 20)) == nil)
    }
}
