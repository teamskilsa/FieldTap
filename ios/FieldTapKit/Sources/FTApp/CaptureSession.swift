import Foundation
import FTModel
import FTPresentation

/// The one time cursor of an open capture. The ladder, the journey strip, the serving header and every chart
/// read and write it, so they always show the same moment.
@Observable @MainActor
public final class TimeCursor {
    private var value: Double
    /// The trace length the cursor is clamped to.
    public private(set) var durationMs: Double

    public init(durationMs: Double, ms: Double = 0) {
        self.durationMs = max(0, durationMs)
        value = Self.clamp(ms, max(0, durationMs))
    }

    /// Milliseconds since the capture's time base (D1), always within 0...durationMs.
    public var ms: Double {
        get { value }
        set { value = Self.clamp(newValue, durationMs) }
    }

    public func set(_ ms: Double) { self.ms = ms }

    /// Moves by `deltaMs` (the cursor bar's -100 ms / +100 ms, 1 s on long press).
    public func step(_ deltaMs: Double) { ms = value + deltaMs }

    static func clamp(_ v: Double, _ duration: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), duration)
    }
}

/// One open capture: its analysis and everything the detail pages share (cursor, filter, selection, page,
/// visible window). Created by `AppModel.open`; lives as long as the detail screen.
@Observable @MainActor
public final class CaptureSession: Identifiable, Hashable {
    public nonisolated let id: UUID
    public let analysis: CaptureAnalysis
    public let cursor: TimeCursor
    public var filter: FlowFilter = .ALL
    /// The event whose message sheet is open.
    public var selectedEvent: Int?
    public var page: DetailPage = .overview
    /// The time span the strip and every Radio chart show; the whole trace by default.
    public var visibleWindow: ClosedRange<Double>
    /// The Radio page's section chip ("signal", "dl", ...), owned by WP4's RadioPage.
    public var radioSection: String?
    /// Identifiers shown for this session (only after the Settings confirmation).
    public var reveal: Bool

    public init(analysis: CaptureAnalysis, reveal: Bool = false) {
        id = analysis.summary.id
        self.analysis = analysis
        let duration = analysis.durationMs
        cursor = TimeCursor(durationMs: duration)
        visibleWindow = 0...max(duration, 1)
        self.reveal = reveal
    }

    public var durationMs: Double { analysis.durationMs }

    /// Opens an event's sheet and moves the cursor to it. Out-of-range indexes are ignored.
    public func select(event index: Int) {
        guard analysis.flow.events.indices.contains(index) else { return }
        selectedEvent = index
        cursor.set(analysis.flow.events[index].sinceStartMs)
    }

    /// The whole trace in view again (double-tap on the strip).
    public func zoomToFit() { visibleWindow = 0...max(durationMs, 1) }

    public nonisolated static func == (a: CaptureSession, b: CaptureSession) -> Bool { a === b }

    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
