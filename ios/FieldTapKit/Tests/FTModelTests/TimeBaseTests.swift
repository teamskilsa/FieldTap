import Foundation
import Testing
import FTCore
import FTTestSupport
@testable import FTModel

@Suite struct TimeBaseTests {
    /// A raw modem timestamp for `ms` after the GPS epoch (upper 48 bits in 1.25 ms units).
    static func raw(ms: Double) -> UInt64 { UInt64(ms / 1.25) << 16 }

    @Test func modemMsReadsBothHalves() {
        #expect(TimeBase.modemMs(0) == 0)
        #expect(TimeBase.modemMs(1 << 16) == 1.25)
        #expect(abs(TimeBase.modemMs(0x8000) - 32_768 / 39_321.6) < 1e-12)
    }

    @Test func utcIsNilBefore2005AndForZero() {
        #expect(TimeBase.utcMs(0) == nil)
        let y2000 = Self.raw(ms: Double(946_684_800_000 - TimeBase.gpsEpochUtcMs))
        #expect(TimeBase.utcMs(y2000) == nil)
        let y2026 = Self.raw(ms: Double(1_790_019_725_000 - TimeBase.gpsEpochUtcMs))
        #expect(TimeBase.utcMs(y2026) == 1_790_019_725_000)
    }

    @Test func d1StartsAtTheFirstPlausibleTimestamp() {
        let early = Self.raw(ms: 5_000)                         // 1980: the modem had no network time yet
        let t0 = Self.raw(ms: Double(1_790_019_725_000 - TimeBase.gpsEpochUtcMs))
        let t1 = t0 + (800 << 16)                                // + 1000 ms
        let records = [early, 0, t0, early, t1].map { LogRecord(code: 0xB0C0, timestampRaw: $0, body: []) }
        let tb = TimeBase.of(records)
        #expect(tb.firstRaw == t0 && tb.lastRaw == t1)
        #expect(tb.durationMs == 1000)
        #expect(tb.sinceStartMs(t1) == 1000)
        #expect(tb.sinceStartMs(0) == nil)
        #expect(tb.startUtcMs == 1_790_019_725_000)
    }

    @Test func withoutAnyPlausibleTimestampItFallsBackToTheFirstNonZero() {
        let a = Self.raw(ms: 5_000), b = Self.raw(ms: 7_500)
        let tb = TimeBase.of([0, a, b].map { LogRecord(code: 1, timestampRaw: $0, body: []) })
        #expect(tb.firstRaw == a && tb.lastRaw == b)
        #expect(tb.durationMs == 2_500)
        #expect(tb.startUtcMs == nil)
        #expect(TimeBase.of([LogRecord]()).durationMs == 0)
    }

    @Test func negativeKotlinLongsAreSkipped() {
        // Kotlin reads the raw stamp as a signed Long and skips values <= 0.
        let tb = TimeBase.of([LogRecord(code: 1, timestampRaw: .max, body: [])])
        #expect(tb.firstRaw == 0)
    }

    @Test(.fixture("iphone-recovered.qmdl"))
    func timeBaseOfIphoneCapture() throws {
        guard let url = Fixtures.require("iphone-recovered.qmdl") else { return }
        let tb = TimeBase.of(DiagProtocol.readQmdl(try Data(contentsOf: url)).records)
        #expect(abs(tb.durationMs - 26_959.395) <= 0.001)
        let start = try #require(tb.startUtcMs)
        #expect(abs(start - 1_790_019_725_984) <= 1)
    }
}

@Suite struct JavaDecimalTests {
    @Test func halfUpOnTheShortestDecimal() {
        #expect(JavaDecimal.fixed(0.15, 1) == "0.2")
        #expect(JavaDecimal.fixed(0.125, 2) == "0.13")
        #expect(JavaDecimal.fixed(2.675, 2) == "2.68")
        #expect(JavaDecimal.fixed(725.813, 3) == "725.813")
        #expect(JavaDecimal.fixed(1e6, 1) == "1000000.0")
        #expect(JavaDecimal.fixed(1.5e-5, 5) == "0.00002")
        #expect(JavaDecimal.fixed(.nan, 2) == "NaN")
        #expect(JavaDecimal.fixed(0.000_5, 3) == "0.001")
        #expect(JavaDecimal.fixed(0.000_49, 3) == "0.000")
    }
}
