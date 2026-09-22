// SEED from WP0; owned by WP3-capture. The state the Modem logging guide opens in (R1), worked out from the
// newest import only: an App Store app cannot look at the installed profiles, so an archive is the evidence.

import Foundation

public enum GuideState: Hashable, Sendable {
    /// The newest archive has no Baseband profile stub (or says baseband logging is not enabled).
    case off
    /// The profile's removal date has passed.
    case expired(Date)
    /// Active, but iOS removes the profile within 1 day.
    case expiringSoon(Date)
    /// Active until the date.
    case active(Date)
    /// The profile stub is present and active but the archive has no modem trace: restart and try again.
    case installedNoTrace
    /// Nothing imported yet, or the newest file was not a readable sysdiagnose.
    case unknown

    /// Pure: the guide state for the newest import at `now`.
    public static func from(latest: CaptureSummary?, now: Date) -> GuideState {
        guard let s = latest else { return .unknown }
        if s.problems.contains(.notASysdiagnose) || s.problems.contains(.truncatedArchive) { return .unknown }
        guard let profile = s.profile, profile.identifier == nil || profile.identifier == "com.apple.basebandlogging",
              profile.status != .missing else {
            return .off
        }
        if let removal = profile.removalDate, removal <= now { return .expired(removal) }
        for p in s.problems {
            if case .profileExpired(let d) = p { return .expired(d) }
        }
        if !s.hasTrace || s.basebandLoggingEnabled == false { return .installedNoTrace }
        guard let removal = profile.removalDate else { return .unknown }
        if removal.timeIntervalSince(now) <= ProfileState.expiringSoonInterval { return .expiringSoon(removal) }
        return .active(removal)
    }

    /// True when the guide should open by itself (R1 b-d): logging off, expired, expiring within a day, or a
    /// profile without a trace.
    public var needsAttention: Bool {
        switch self {
        case .off, .expired, .expiringSoon, .installedNoTrace: true
        case .active, .unknown: false
        }
    }

    /// A stable token for launch arguments and screen reports ("expiringSoon").
    public var token: String {
        switch self {
        case .off: "off"
        case .expired: "expired"
        case .expiringSoon: "expiringSoon"
        case .active: "active"
        case .installedNoTrace: "installedNoTrace"
        case .unknown: "unknown"
        }
    }

    /// The state a token names, with a date relative to `now` for the dated states (for previews and the
    /// -FTGuideState launch argument): expired 1 day ago, expiring in 12 hours, active for 5 more days.
    public init?(token: String, now: Date) {
        switch token {
        case "off": self = .off
        case "expired": self = .expired(now.addingTimeInterval(-86_400))
        case "expiringSoon": self = .expiringSoon(now.addingTimeInterval(12 * 3_600))
        case "active": self = .active(now.addingTimeInterval(5 * 86_400 + 3_600))
        case "installedNoTrace": self = .installedNoTrace
        case "unknown": self = .unknown
        default: return nil
        }
    }

    /// The status line R1 specifies, word for word. `date` formats a removal date for the reader's locale.
    public func headline(now: Date, date: (Date) -> String) -> String {
        switch self {
        case .off:
            return "Modem logging is off"
        case .expired(let d):
            return "Your logging profile expired on \(date(d))"
        case .expiringSoon(let d), .active(let d):
            let days = max(0, Int((d.timeIntervalSince(now) / 86_400).rounded(.down)))
            let left = days == 0 ? "less than 1 day" : "\(days) \(days == 1 ? "day" : "days")"
            return "Logging is on until \(date(d)) (\(left) left)"
        case .installedNoTrace:
            return "Profile installed but no modem trace — restart your iPhone and try again"
        case .unknown:
            return "Modem logging status not known yet"
        }
    }
}
