// The journey strip's layout decisions, kept out of the view so they are tested: which markers share a glyph
// at the current zoom, which label a segment has room for, and how pinch and pan move the visible window.

import FTModel

/// Markers drawn as one glyph because they are closer than a finger on screen. The lead marker (the most
/// severe, then the most telling kind) gives the glyph; the count badge says how many there are.
public struct MarkerCluster: Identifiable, Hashable, Sendable {
    public var markers: [Marker]
    public var lead: Marker
    /// Where the glyph sits: midway between the first and last marker.
    public var tMs: Double

    public var id: String { markers.first?.id ?? lead.id }
    public var count: Int { markers.count }
}

public enum JourneyLayout {
    /// At the default 27 s window on a 402 pt iPhone (about 80 ms per point), 4 markers fall within 67 ms at
    /// 2.59-2.66 s. A glyph with its count badge is about 20 pt wide, so neighbours closer than that share one.
    public static let clusterSpacingPt = 20.0

    /// The markers inside `window`, grouped when a marker is closer than `spacing` points to the previous one on
    /// a plot `width` points wide, and a group spans less than three spacings (so a long chain still splits).
    /// Glyphs sit at the group's midpoint, so neighbouring glyphs are at least `spacing` apart. Markers are in
    /// time order (JourneyBuilder sorts them).
    public static func clusters(_ markers: [Marker], window: ClosedRange<Double>, width: Double,
                                spacing: Double = clusterSpacingPt) -> [MarkerCluster] {
        let span = max(window.upperBound - window.lowerBound, 1)
        let perPt = span / max(width, 1)
        var out: [MarkerCluster] = []
        var group: [Marker] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let lead = group.max { importance($0) < importance($1) } ?? first
            out.append(MarkerCluster(markers: group, lead: lead, tMs: (first.tMs + last.tMs) / 2))
            group = []
        }
        for m in markers where window.contains(m.tMs) {
            if let first = group.first, let last = group.last,
               (m.tMs - last.tMs) / perPt >= spacing || (m.tMs - first.tMs) / perPt >= 3 * spacing {
                flush()
            }
            group.append(m)
        }
        flush()
        return out
    }

    /// Failures first, then warnings, then moves, the NR leg, attach/detach, and last the RRC ticks and RACH.
    public static func importance(_ m: Marker) -> Int {
        let base: Int = switch m.kind {
        case .handover, .reselection, .reattach, .redirect, .reestablishment, .cellChange: 50
        case .scgAdd, .scgModify, .scgRelease, .scgFailure: 40
        case .attach, .detachSwitchOff, .detach: 30
        case .rrcSetup, .rrcRelease, .rrcReject: 10
        case .rach: 5
        case .procedureFailed, .procedureUnanswered, .connectionLost, .noAnswer, .registrationReject: 20
        }
        let severity: Int = switch m.severity {
        case .failure: 200
        case .warning: 100
        case .info: 0
        }
        return base + severity
    }

    /// The longest of `candidates` that fits `width` points, estimating 6.4 pt per character of the strip's
    /// 11 pt semibold digits plus 6 pt of padding; nil when not even the shortest fits.
    public static func label(_ candidates: [String], width: Double, perCharPt: Double = 6.4, paddingPt: Double = 6) -> String? {
        candidates.first { Double($0.count) * perCharPt + paddingPt <= width }
    }

    /// The label candidates for a segment, longest first: "B66 67086/80", "B66".
    public static func labels(for s: CellSegment) -> [String] {
        switch s.lane {
        case .pcell: [JourneyText.cell(s), JourneyText.band(s)]
        case .pscell: ["\(JourneyText.cell(s)), \(JourneyText.band(s))", JourneyText.cell(s), "NR"]
        case .scell: ["SCell\(s.index) \(JourneyText.band(s)) \(s.cell.earfcn)/\(s.cell.pci)", "\(JourneyText.band(s)) \(s.cell.earfcn)", JourneyText.band(s)]
        }
    }

    /// The window after pinching by `scale` (> 1 zooms in) around `anchorMs`, keeping the anchor under the
    /// fingers, between `minSpanMs` and the whole trace.
    public static func zoom(_ window: ClosedRange<Double>, scale: Double, anchorMs: Double, durationMs: Double,
                            minSpanMs: Double = 500) -> ClosedRange<Double> {
        let total = max(durationMs, 1)
        let span = window.upperBound - window.lowerBound
        let newSpan = min(max(span / max(scale, 0.01), min(minSpanMs, total)), total)
        let f = span > 0 ? (anchorMs - window.lowerBound) / span : 0.5
        return clamp(start: anchorMs - f * newSpan, span: newSpan, durationMs: total)
    }

    /// The window moved so that its start is `start`, kept inside the trace.
    public static func clamp(start: Double, span: Double, durationMs: Double) -> ClosedRange<Double> {
        let total = max(durationMs, 1)
        let s = min(max(start, 0), max(total - span, 0))
        return s...min(s + span, total)
    }

    /// The window recentred on `tMs` when `tMs` is outside it (or within 4 % of an edge); otherwise unchanged.
    public static func follow(_ window: ClosedRange<Double>, cursorMs: Double, durationMs: Double) -> ClosedRange<Double> {
        let span = window.upperBound - window.lowerBound
        let margin = span * 0.04
        if cursorMs >= window.lowerBound + margin && cursorMs <= window.upperBound - margin { return window }
        if span >= durationMs - 0.5 { return window }
        return clamp(start: cursorMs - span / 2, span: span, durationMs: durationMs)
    }

    /// Axis ticks for a window: the smallest round step giving fewer than `count` of them.
    public static func ticks(_ window: ClosedRange<Double>, count: Int = 5) -> [Double] {
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return [] }
        let steps: [Double] = [50, 100, 200, 250, 500, 1_000, 2_000, 5_000, 10_000, 15_000, 30_000, 60_000, 120_000, 300_000]
        let step = steps.first { span / $0 < Double(count) } ?? 600_000
        var t = (window.lowerBound / step).rounded(.up) * step
        var out: [Double] = []
        while t <= window.upperBound + 0.000_1 {
            out.append(t)
            t += step
        }
        return out
    }

    /// "0:05" for whole seconds; "15.1" or "15.25" when the step is below a second.
    public static func tickLabel(_ ms: Double, step: Double) -> String {
        if step >= 1_000 { return JourneyText.shortClock(ms) }
        let digits = step.truncatingRemainder(dividingBy: 100) == 0 ? 1 : 2
        let seconds = ms / 1_000
        var s = String(Int(seconds.rounded(.down)))
        let frac = seconds - seconds.rounded(.down)
        let scaled = Int((frac * pow10(digits)).rounded())
        s += "." + String(repeating: "0", count: max(0, digits - String(scaled).count)) + String(scaled)
        return s
    }

    private static func pow10(_ n: Int) -> Double { n == 1 ? 10 : 100 }
}
