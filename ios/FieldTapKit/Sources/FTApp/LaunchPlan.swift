import Foundation
import FTModel
import FTPresentation

/// What the launch arguments ask the app to show, for screenshots and the harness (read only by the DEBUG and
/// Harness hooks in App/Debug; a Release app never calls `parse`).
///
///     -FTScreen <route>          captures | guide | settings | importSheet | overview | callflow | radio | message
///     -FTFixture <dir>           load ios/Fixtures/local as a capture (FixtureLoader)
///     -FTOpenLatest              open the newest capture
///     -FTCursorMs <ms>           move the time cursor
///     -FTEvent <index>           select an event (the message sheet for -FTScreen message)
///     -FTFilter ALL|RRC|NAS      the call-flow filter
///     -FTRadioSection <name>     signal | neighbours | dl | mac | ul | csi | nr | antennas | carriers | rach | unavailable
///     -FTRadioEntry <id>         scroll the Not available list to one catalogue entry ("nrUlSchedule")
///     -FTImportState <token>     an import sheet state (ImportState.preview): done, reading..., noBasebandTrace...
///     -FTGuideState <token>      a Modem logging guide state (GuideState(token:)): off, expired, expiringSoon...
public struct LaunchPlan: Hashable, Sendable {
    public var route: Route?
    public var openLatest = false
    public var fixtureDir: URL?
    public var cursorMs: Double?
    public var event: Int?
    public var filter: FlowFilter?
    public var radioSection: String?
    /// A catalogue entry id to scroll the Not available list to (PhyCatalog ids).
    public var radioEntry: String?
    public var importState: String?
    public var guideState: String?
    /// Arguments that looked like ours but could not be read, reported rather than ignored.
    public var problems: [String] = []

    public init(route: Route? = nil, openLatest: Bool = false, fixtureDir: URL? = nil, cursorMs: Double? = nil,
                event: Int? = nil, filter: FlowFilter? = nil, radioSection: String? = nil, radioEntry: String? = nil,
                importState: String? = nil, guideState: String? = nil) {
        self.route = route
        self.openLatest = openLatest
        self.fixtureDir = fixtureDir
        self.cursorMs = cursorMs
        self.event = event
        self.filter = filter
        self.radioSection = radioSection
        self.radioEntry = radioEntry
        self.importState = importState
        self.guideState = guideState
    }

    /// True when nothing was asked for: a normal launch.
    public var isEmpty: Bool {
        route == nil && !openLatest && fixtureDir == nil && cursorMs == nil && event == nil && filter == nil
            && radioSection == nil && radioEntry == nil && importState == nil && guideState == nil
    }

    /// True when the plan needs a capture open (a detail page, or -FTOpenLatest).
    public var needsCapture: Bool { openLatest || route?.page != nil }

    public static func parse(_ info: ProcessInfo) -> LaunchPlan { parse(arguments: Array(info.arguments.dropFirst())) }

    public static func parse(arguments: [String]) -> LaunchPlan {
        var plan = LaunchPlan()
        var i = 0
        func value() -> String? {
            guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-FT") else { return nil }
            i += 1
            return arguments[i]
        }
        while i < arguments.count {
            let key = arguments[i]
            switch key {
            case "-FTScreen":
                let v = value()
                plan.route = v.flatMap(Route.init(rawValue:))
                if plan.route == nil { plan.problems.append("-FTScreen \(v ?? "")") }
            case "-FTFixture":
                if let v = value() { plan.fixtureDir = URL(fileURLWithPath: v, isDirectory: true) } else { plan.problems.append(key) }
            case "-FTOpenLatest":
                // Accepts a bare flag or "-FTOpenLatest YES" (the NSUserDefaults argument form).
                plan.openLatest = true
                if i + 1 < arguments.count, ["YES", "1", "true"].contains(arguments[i + 1]) { i += 1 }
            case "-FTCursorMs":
                let v = value()
                plan.cursorMs = v.flatMap(Double.init)
                if plan.cursorMs == nil { plan.problems.append("-FTCursorMs \(v ?? "")") }
            case "-FTEvent":
                let v = value()
                plan.event = v.flatMap { Int($0) }
                if plan.event == nil { plan.problems.append("-FTEvent \(v ?? "")") }
            case "-FTFilter":
                let v = value()
                plan.filter = v.flatMap { FlowFilter(rawValue: $0.uppercased()) }
                if plan.filter == nil { plan.problems.append("-FTFilter \(v ?? "")") }
            case "-FTRadioSection":
                plan.radioSection = value()
            case "-FTRadioEntry":
                plan.radioEntry = value()
            case "-FTImportState":
                plan.importState = value()
            case "-FTGuideState":
                plan.guideState = value()
            default:
                break
            }
            i += 1
        }
        return plan
    }
}
