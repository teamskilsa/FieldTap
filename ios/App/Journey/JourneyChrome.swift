import SwiftUI
import FTApp
import FTJourney
import FTModel

/// What the marker sheet shows: one marker, or every marker of a cluster the user tapped.
enum MarkerSheetItem: Identifiable, Hashable {
    case marker(Marker)
    case cluster([Marker])

    var id: String {
        switch self {
        case .marker(let m): "marker-\(m.id)"
        case .cluster(let ms): "cluster-\(ms.first?.id ?? "")-\(ms.count)"
        }
    }
}

/// The journey views' own state for one open capture: whether the strip is collapsed to its mini lane, the
/// open marker sheet, and whether the DEBUG launch arguments have been applied. CaptureSession belongs to
/// WP0, so this lives next to it, keyed by the session's id, for as long as the app runs (a few bytes each).
@Observable @MainActor
final class JourneyChrome {
    var collapsed = false
    /// Collapsed by scrolling rather than by the chevron, so scrolling back to the top opens it again.
    private var collapsedByScroll = false
    var markerSheet: MarkerSheetItem?
    /// True while a finger scrubs the strip: the cursor shows its time bubble.
    var scrubbing = false
    var launchApplied = false

    private static var bySession: [UUID: JourneyChrome] = [:]

    static func of(_ session: CaptureSession) -> JourneyChrome {
        if let c = bySession[session.id] { return c }
        let c = JourneyChrome()
        bySession[session.id] = c
        return c
    }

    func toggle() {
        collapsedByScroll = false
        withAnimation(.snappy(duration: 0.25)) { collapsed.toggle() }
    }

    /// The page's scroll distance from the top. Collapses past 72 pt, reopens near the top; the gap between the
    /// two keeps the strip from flapping while the inset change settles.
    func scrolled(to y: Double) {
        if y > 72, !collapsed {
            collapsedByScroll = true
            withAnimation(.snappy(duration: 0.25)) { collapsed = true }
        } else if y < 8, collapsed, collapsedByScroll {
            collapsedByScroll = false
            withAnimation(.snappy(duration: 0.25)) { collapsed = false }
        }
    }

    /// Opens the marker sheet for `m` and moves the cursor to it.
    func show(_ item: MarkerSheetItem, session: CaptureSession) {
        switch item {
        case .marker(let m): session.cursor.set(m.tMs)
        case .cluster(let ms): if let first = ms.first { session.cursor.set(first.tMs) }
        }
        markerSheet = item
    }
}

extension View {
    /// Collapses the journey strip to its 28 pt mini lane while this scroll view is scrolled down, so the
    /// page gets the height. Call-flow and Radio pages can attach it to their scroll views too.
    func journeyStripCollapses(with session: CaptureSession) -> some View {
        modifier(StripCollapsesOnScroll(chrome: JourneyChrome.of(session)))
    }
}

private struct StripCollapsesOnScroll: ViewModifier {
    let chrome: JourneyChrome

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Double.self) { g in
            Double(g.contentOffset.y + g.contentInsets.top)
        } action: { _, y in
            chrome.scrolled(to: y)
        }
    }
}

/// "Show in call flow": the ladder at this moment, with no message sheet open.
@MainActor
func showInCallFlow(_ session: CaptureSession, event: Int?, tMs: Double?) {
    if let event, session.analysis.flow.events.indices.contains(event) {
        session.cursor.set(session.analysis.flow.events[event].sinceStartMs)
    } else if let tMs {
        session.cursor.set(tMs)
    }
    session.selectedEvent = nil
    session.page = .callflow
}

#if DEBUG || FT_HARNESS
/// DEBUG/Harness launch arguments for the journey screenshots (LaunchPlan ignores arguments it does not know):
///
///     -FTJourneyWindow 14950:15250     the strip's visible window, in ms
///     -FTJourneyMarker handover-82     open the marker sheet (a marker id, or a time in ms for its cluster)
///     -FTJourneySegment pcell:1        open a segment's popover (lane:index, index within the lane)
///     -FTJourneyCollapsed              start with the strip collapsed
///     -FTJourneyScroll tiles           scroll the Overview to a section (findings, tiles, procedures, cells, facts)
struct JourneyLaunchArguments {
    var window: ClosedRange<Double>?
    var marker: String?
    var segment: String?
    var collapsed = false
    var scroll: String?

    static let current = parse(Array(ProcessInfo.processInfo.arguments.dropFirst()))

    static func parse(_ args: [String]) -> JourneyLaunchArguments {
        var out = JourneyLaunchArguments()
        func value(after i: Int) -> String? { i + 1 < args.count && !args[i + 1].hasPrefix("-FT") ? args[i + 1] : nil }
        for (i, a) in args.enumerated() {
            switch a {
            case "-FTJourneyWindow":
                let parts = value(after: i)?.split(separator: ":").compactMap { Double($0) } ?? []
                if parts.count == 2, parts[0] < parts[1] { out.window = parts[0]...parts[1] }
            case "-FTJourneyMarker": out.marker = value(after: i)
            case "-FTJourneySegment": out.segment = value(after: i)
            case "-FTJourneyCollapsed": out.collapsed = true
            case "-FTJourneyScroll": out.scroll = value(after: i)
            default: break
            }
        }
        return out
    }
}
#endif
