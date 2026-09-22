// Port of android/diag/src/test/kotlin/com/fieldtap/diag/HdlcTest.kt (8 tests).

import Testing
@testable import FTCore

@Suite struct HdlcTests {
    @Test func crc16MatchesThePublishedX25CheckValue() {
        // The one number that pins the whole table: CRC-16/X-25 over "123456789".
        #expect(Hdlc.crc16(Array("123456789".utf8)) == 0x906E)
    }

    @Test func aFrameIncludingItsOwnCrcChecksToTheResidue() {
        for payload in [[UInt8](), [0x10], (0..<40).map { UInt8($0) }] {
            let crc = Hdlc.crc16(payload)
            let withCrc = payload + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
            #expect(Hdlc.crc16(withCrc) == Hdlc.goodCrc, "residue for \(payload.count) bytes")
        }
    }

    @Test func encodeThenUnframeReturnsThePayload() {
        let payload: [UInt8] = [0x10, 0x00, 0x7E, 0x7D, 0x42]
        var u = Unframer()
        let frames = u.feed(Hdlc.encode(payload))
        #expect(frames == [payload])
    }

    @Test func flagAndEscapeBytesSurviveTheRoundTrip() {
        // 0x7E and 0x7D are the two bytes that cannot appear raw inside a frame.
        let payload: [UInt8] = [0x7E, 0x7D, 0x7E, 0x7D, 0x7D, 0x7E]
        let encoded = Hdlc.encode(payload)
        #expect(!encoded.dropLast().contains(Hdlc.flag), "no raw flag inside the frame")
        var u = Unframer()
        #expect(u.feed(encoded).first == payload)
    }

    @Test func aStreamSplitAnywhereYieldsTheSameFrames() {
        let stream = Hdlc.encode([0x10, 0x01]) + Hdlc.encode([0x10, 0x02, 0x7E])
        var a = Unframer(), b = Unframer()
        let whole = a.feed(stream)
        let oneByteAtATime = stream.flatMap { b.feed([$0]) }
        #expect(whole.count == 2)
        #expect(whole == oneByteAtATime)
        // And at every two-piece split, through the contiguous fast path.
        for cut in 0...stream.count {
            var c = Unframer()
            #expect(c.feed(stream[..<cut]) + c.feed(stream[cut...]) == whole, "split at \(cut)")
        }
    }

    @Test func aCorruptFrameIsCountedAndDroppedRatherThanThrown() {
        let good = Hdlc.encode([0x10, 0x01])
        var bad = Hdlc.encode([0x10, 0x02])
        bad[0] &+= 1   // break the payload, leaving the CRC stale
        var u = Unframer()
        let frames = u.feed(bad + good)
        #expect(frames.count == 1, "the good frame still arrives")
        #expect(u.crcErrors == 1)
    }

    @Test func anUnfinishedFrameIsHeldUntilItEnds() {
        let encoded = Hdlc.encode([0x10, 0x05, 0x06])
        var u = Unframer()
        #expect(u.feed(encoded.dropLast()).isEmpty)
        #expect(u.pending > 0, "bytes are held, not lost")
        #expect(u.feed([Hdlc.flag]).count == 1)
    }

    @Test func repeatedFlagsAreNotEmptyFrames() {
        var u = Unframer()
        #expect(u.feed([Hdlc.flag, Hdlc.flag, Hdlc.flag]).isEmpty)
        #expect(u.crcErrors == 0)
    }
}
