import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTCore

/// The recovered iPhone capture (ios/Fixtures/local/iphone-recovered.qmdl, md5 e53a167b...) read the way
/// GoldenDump.kt reads it: the numbers must equal the golden's source block and recordsPerCode.
@Suite struct RealCaptureTests {
    @Test(.fixture("iphone-recovered.qmdl"))
    func realQmdlUnframes() throws {
        guard let url = Fixtures.require("iphone-recovered.qmdl"),
              let goldenURL = Fixtures.require("contract/callflow-golden.json") else { return }
        let read = DiagProtocol.readQmdl(try Data(contentsOf: url))
        #expect(read.frames == 92_133)
        #expect(read.crcErrors == 0)
        #expect(read.badPackets == 0)
        #expect(read.records.count == 92_133)
        let perCode = read.recordsPerCode
        #expect(perCode.count == 224)

        let golden = try GoldenCodec.decodeFlow(Data(contentsOf: goldenURL))
        #expect(golden.source.hdlcFrames == read.frames)
        #expect(golden.source.logRecords == read.records.count)
        #expect(golden.recordsPerCode == perCode)
    }

    @Test(.fixture("oneplus/oneplus-5g-registration.qmdl"))
    func onePlusQmdl2ContainersUnwrap() throws {
        guard let url = Fixtures.require("oneplus/oneplus-5g-registration.qmdl"),
              let goldenURL = Fixtures.require("contract/oneplus-5g-registration.json") else { return }
        let read = DiagProtocol.readQmdl(try Data(contentsOf: url))
        let golden = try GoldenCodec.decodeFlow(Data(contentsOf: goldenURL))
        #expect(read.frames == golden.source.hdlcFrames)
        #expect(read.records.count == golden.source.logRecords)
        #expect(read.recordsPerCode == golden.recordsPerCode)
    }

    @Test(.fixture("iphone-recovered.qmdl"))
    func unframingIsSplitInvariantOnTheRealCapture() throws {
        guard let url = Fixtures.require("iphone-recovered.qmdl") else { return }
        let bytes = [UInt8](try Data(contentsOf: url).prefix(2_000_000))
        var whole = Unframer()
        let expected = whole.feed(bytes)
        var pieces = Unframer()
        var got: [[UInt8]] = []
        var offset = 0
        var step = 1
        while offset < bytes.count {
            let end = min(offset + step, bytes.count)
            got += pieces.feed(bytes[offset..<end])
            offset = end
            step = step * 7 % 65_521 + 1          // uneven splits, from 1 byte up
        }
        #expect(got == expected)
        #expect(pieces.crcErrors == whole.crcErrors)
    }
}
