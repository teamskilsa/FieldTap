import Foundation
import FTModel

/// The capture coaching's timing (R2), measured on both of the user's captures: the sysdiagnose dumps the
/// modem log about 19 s after the button press (46 s when the phone had just restarted and was still busy) and
/// keeps only the last ~128 MiB of it, about 22-28 s of trace. The kept window of the second capture therefore
/// ran from 4 s *before* the press to 19 s after it. So the user presses first, does the thing a few seconds
/// later and is finished well before the dump; `CaptureWording.timing` is that advice in words.
public struct CaptureCountdown: Hashable, Codable, Sendable {
    /// "Get ready", while the user puts the phone down and gets to the button.
    public static let getReadySeconds: TimeInterval = 3
    /// "Do it now", to the end of the useful window.
    public static let doItSeconds: TimeInterval = 9
    /// Be finished by here: the dump comes about 19 s after the press and keeps what came before it.
    public static var doItBySeconds: TimeInterval { getReadySeconds + doItSeconds }
    /// Apple: a sysdiagnose can take up to 10 minutes to appear in Analytics Data.
    public static let sysdiagnoseWaitSeconds: TimeInterval = 600

    public enum Phase: Hashable, Sendable {
        /// 0-3 s after the press.
        case getReady(secondsLeft: Int)
        /// 3-12 s after the press: do the thing now.
        case doItNow(secondsLeft: Int)
        /// Until 10 minutes after the press.
        case waiting(secondsLeft: Int)
        /// The sysdiagnose should be in Analytics Data by now.
        case ready

        public var token: String {
            switch self {
            case .getReady: "getReady"
            case .doItNow: "doItNow"
            case .waiting: "waiting"
            case .ready: "ready"
            }
        }
    }

    public var pressedAt: Date

    public init(pressedAt: Date) {
        self.pressedAt = pressedAt
    }

    public var doItNowAt: Date { pressedAt.addingTimeInterval(Self.getReadySeconds) }
    public var waitAt: Date { doItNowAt.addingTimeInterval(Self.doItSeconds) }
    public var readyAt: Date { pressedAt.addingTimeInterval(Self.sysdiagnoseWaitSeconds) }

    public func phase(at now: Date) -> Phase {
        func left(_ until: Date) -> Int { max(0, Int(until.timeIntervalSince(now).rounded(.up))) }
        if now < doItNowAt { return .getReady(secondsLeft: left(doItNowAt)) }
        if now < waitAt { return .doItNow(secondsLeft: left(waitAt)) }
        if now < readyAt { return .waiting(secondsLeft: left(readyAt)) }
        return .ready
    }
}

/// Plain-words strings the capture screens share, kept here so they are tested.
public enum CaptureWording {
    /// The capture timing, in the words the guide, the countdown and every help text use. It lives here alone:
    /// no screen writes its own seconds. See `CaptureCountdown` for where the numbers come from.
    public static let timing = """
        Press the buttons first, then do the thing about 3 to 5 seconds later and be finished by about \
        12 seconds. If it has already happened, press within 2 to 3 seconds. When your iPhone has been sitting \
        idle, the trace reaches back minutes.
        """

    /// "0:19", "1:05"; whole seconds, rounded down.
    public static func minutesSeconds(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// R2: "covers 0:19–0:46 after you pressed the buttons", from the trace window relative to the press.
    public static func pressWindow(_ w: TraceWindow) -> String {
        let start = w.startMs / 1_000, end = w.endMs / 1_000
        if start >= 0 {
            return "covers \(minutesSeconds(start))–\(minutesSeconds(end)) after you pressed the buttons"
        }
        if end <= 0 {
            return "covers \(minutesSeconds(-start))–\(minutesSeconds(-end)) before you pressed the buttons"
        }
        return "covers \(minutesSeconds(-start)) before to \(minutesSeconds(end)) after you pressed the buttons"
    }

    /// "111 of 241 trace files had already been overwritten", or nil when none were.
    public static func overwritten(_ overwritten: Int?, listed: Int?) -> String? {
        guard let o = overwritten, o > 0 else { return nil }
        if let l = listed { return "\(o) of \(l) trace files had already been overwritten" }
        return o == 1 ? "1 trace file had already been overwritten" : "\(o) trace files had already been overwritten"
    }

    /// The trace-length line: "27.0 s trace".
    public static func traceLength(ms: Double?) -> String? {
        guard let ms, ms > 0 else { return nil }
        return String(format: "%.1f s trace", ms / 1_000)
    }
}

/// The capture card's journey digest and mini-strip data, from the analysis at import time.
public enum CaptureDigest {
    /// "B2 → B66 → B12 → B2, NR, 0 failures" and the PCell spans; nil when the journey has no cells yet.
    public static func of(journey: Journey) -> (digest: String, preview: JourneyPreview)? {
        let pcells = journey.cells.filter { $0.lane == .pcell }.sorted { $0.startMs < $1.startMs }
        guard !pcells.isEmpty else { return nil }
        var bands: [String] = []
        for c in pcells {
            let b = c.band ?? "NR"
            if bands.last != b { bands.append(b) }
        }
        let nr = journey.cells.contains { $0.lane == .pscell }
        let failures = journey.markers.filter { $0.severity == .failure }.count
        var parts = [bands.joined(separator: " → ")]
        if nr { parts.append("NR") }
        parts.append("\(failures) \(failures == 1 ? "failure" : "failures")")
        let preview = JourneyPreview(
            segments: pcells.map { PreviewSegment(band: $0.band ?? "NR", startMs: $0.startMs, endMs: $0.endMs) },
            nr: nr, failures: failures)
        return (parts.joined(separator: ", "), preview)
    }
}
