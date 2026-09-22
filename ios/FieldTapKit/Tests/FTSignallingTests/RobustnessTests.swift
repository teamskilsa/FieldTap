// Not in the Kotlin suite: where Kotlin throws and catches IndexOutOfBoundsException, Swift would trap on a bad
// index instead. These feed every decoder cut-short and random bodies, so a malformed capture can only ever give
// fewer rows, never a crash.

import Testing
import FTCore
import FTModel
import FTTestSupport
@testable import FTSignalling

@Suite struct RobustnessTests {
    /// Every signalling record of the OnePlus captures and of the iPhone attach window, cut at every length.
    @Test(.fixture("qdss-attach4/expected/attach4.qmdl"))
    func everyTruncationOfRealRecordsDecodesWithoutTrapping() throws {
        guard Fixtures.require("qdss-attach4/expected/attach4.qmdl") != nil else { return }
        let fixtures = [QmdlFixture.attach4, QmdlFixture.onePlus5g, QmdlFixture.onePlusCallbox].compactMap { $0 }
        #expect(fixtures.count == 3)
        var decoded = 0
        var records: [LogRecord] = []
        for record in fixtures.flatMap(\.read.records) {
            guard let info = LogCodes.of(record.code) else { continue }
            for length in 0...record.body.count {
                let body = Array(record.body.prefix(length))
                switch info.category {
                case .rrc:
                    if (info.isNr ? NrRrc.decode(body)?.asn1Name : LteRrc.decode(body)?.asn1Name) != nil { decoded += 1 }
                case .nas:
                    if let m = Nas.decode(body, nr: info.isNr) {
                        let pdu = Array(body[m.offset...])
                        _ = info.isNr
                            ? NasFields.fiveGs(sublayer: m.sublayer, securityHeader: m.securityHeader,
                                               messageType: m.messageType, pdu: pdu, uplink: true)
                            : NasFields.eps(sublayer: m.sublayer, securityHeader: m.securityHeader,
                                            messageType: m.messageType, pdu: pdu, uplink: true)
                        decoded += 1
                    }
                case .cell:
                    if CellInfo.serving(body) != nil { decoded += 1 }
                }
                if length < record.body.count && length % 7 == 0 {
                    records.append(LogRecord(code: record.code, timestampRaw: record.timestampRaw, body: body))
                }
            }
        }
        #expect(decoded > 1_000)
        // And the reader over a capture made of those cut-short records.
        let flow = CallFlowReader.read(records: records, crcErrors: 0)
        #expect(flow.records == records.count)
    }

    /// Seeded random bodies behind each header layout the decoders know, and bare random NAS PDUs.
    @Test func randomBytesDecodeWithoutTrapping() {
        var rng = SplitMix(seed: 0x5EED)
        var records: [LogRecord] = []
        for i in 0..<20_000 {
            let length = Int(rng.next() % 96)
            var body = (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            if !body.isEmpty { body[0] = [2, 9, 14, 19, 27, 30, 17, 26][i % 8] }
            _ = LteRrc.decode(body)
            _ = NrRrc.decode(body)
            _ = CellInfo.serving(body)
            for nr in [false, true] {
                if let m = Nas.decodePdu(body, nr: nr) ?? Nas.decode(body, nr: nr) {
                    _ = NasFields.eps(sublayer: m.sublayer, securityHeader: m.securityHeader, messageType: m.messageType,
                                      pdu: body, uplink: i % 2 == 0)
                    _ = NasFields.fiveGs(sublayer: m.sublayer, securityHeader: m.securityHeader,
                                         messageType: m.messageType, pdu: body, uplink: i % 2 == 0)
                }
            }
            let codes: [UInt16] = [0xB0C0, 0xB821, 0xB0C2, 0xB0EC, 0xB0EB, 0xB80A, 0xB80C]
            records.append(LogRecord(code: codes[i % codes.count], timestampRaw: rng.next() >> 1, body: body))
        }
        let flow = CallFlowReader.read(records: records, crcErrors: 0)
        #expect(flow.records == records.count)
    }
}

/// A tiny deterministic generator, so a failure here reproduces.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
