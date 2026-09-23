import Foundation
import FTModel

// TestFlight-only live capture-status detectors (like CellGuard's ProfileTask / SysdiagTask).
//
// These read *metadata only* (existence and modification date) of system paths OUTSIDE the app sandbox with
// the public FileManager API. They never read file contents and use no private frameworks. The v1 App Store
// build forbids system-file probes (see Contract/CONTRACT.md); this is deliberately relaxed only because the
// FieldTap 1.0 distribution is TestFlight, where these public-API probes are acceptable.
//
// UNVERIFIED ON iOS 26: iOS 26 has tightened some of these paths. Whether `attributesOfItem` returns a date,
// throws permission-denied (257/EACCES), or throws not-found (260/ENOENT) on iOS 26.5.2 is NOT known until it
// runs on a real device — the simulator does not have these paths. Every probe therefore FAILS GRACEFULLY:
// on any error the caller falls back to the existing import-based detection with no error surfaced to the user.
// The Settings > Diagnostics readout exists precisely so we can learn what a real device returns.

/// The one FileManager metadata call the live probes use, wrapped so tests can inject file states
/// (mod-date-present, permission-denied 257, not-found 260) without touching the real filesystem.
public protocol PathMetadataReading: Sendable {
    /// Mirrors `FileManager.attributesOfItem(atPath:)`: the item's attributes, or throws the underlying
    /// error (Cocoa 257 = permission denied, 260 = not found; or the POSIX EACCES/ENOENT equivalents).
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
}

/// The production reader: `FileManager.default`. Metadata only; never reads contents.
public struct RealPathMetadata: PathMetadataReading {
    public init() {}
    public func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: path)
    }
}

/// Why a probe could not read a path. Codes are kept so the Diagnostics readout can show exactly what THIS
/// device returned (e.g. 257).
public enum ProbeUnavailable: Equatable, Sendable {
    /// The call was refused (Cocoa 257 / POSIX EACCES 13 / EPERM 1). Implies the path most likely *exists*
    /// but is outside the sandbox — the useful signal for the sysdiagnose watcher.
    case permissionDenied(code: Int)
    /// The path does not exist (Cocoa 260 / POSIX ENOENT 2). The feature degrades to nothing.
    case notFound(code: Int)
    /// The path resolved but carried no usable attribute (e.g. no modification date).
    case noModificationDate
    /// Any other error, code preserved for the readout.
    case otherError(code: Int)

    /// True when the error implies the path is present (a permission-denied refusal), which is itself a signal.
    public var impliesExists: Bool { if case .permissionDenied = self { return true } else { return false } }

    /// Classifies an NSError from a FileManager metadata call into permission-denied vs not-found vs other,
    /// handling both the Cocoa and the underlying POSIX domains.
    public static func classify(_ error: NSError) -> ProbeUnavailable {
        // Prefer the underlying POSIX error when Cocoa wrapped one.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return fromPosix(underlying.code) ?? fromCocoa(error.code) ?? .otherError(code: error.code)
        }
        if error.domain == NSPOSIXErrorDomain, let p = fromPosix(error.code) { return p }
        if error.domain == NSCocoaErrorDomain, let c = fromCocoa(error.code) { return c }
        return fromCocoa(error.code) ?? fromPosix(error.code) ?? .otherError(code: error.code)
    }

    private static func fromCocoa(_ code: Int) -> ProbeUnavailable? {
        switch code {
        case 257: return .permissionDenied(code: code)   // NSFileReadNoPermissionError
        case 260: return .notFound(code: code)           // NSFileReadNoSuchFileError
        default: return nil
        }
    }

    private static func fromPosix(_ code: Int) -> ProbeUnavailable? {
        switch code {
        case 1, 13: return .permissionDenied(code: code) // EPERM, EACCES
        case 2: return .notFound(code: code)             // ENOENT
        default: return nil
        }
    }
}

/// The live profile-status detector (CellGuard's ProfileTask analogue). Reads the modification date of
/// CommCenter's logging-subsystem plist; a present date is treated as the modem-logging profile install date.
public enum LiveProfileProbe {
    /// Written/updated when Apple's Baseband logging profile toggles CommCenter's logging subsystem.
    public static let commCenterPlistPath =
        "/private/var/preferences/Logging/Subsystems/com.apple.CommCenter.plist"

    /// The profile's lifetime today (see the profile stub: 7.0 days).
    public static let lifetimeDays: Double = 7

    /// The install date + 7 days.
    public static func expiry(installed: Date, lifetimeDays: Double = lifetimeDays) -> Date {
        installed.addingTimeInterval(lifetimeDays * 86_400)
    }

    /// Probes the plist. On success, `.live(installed:)` with its modification date; otherwise
    /// `.unavailable(reason:)` and the caller falls back to import-based detection with no user-facing error.
    public static func probe(path: String = commCenterPlistPath,
                             metadata: any PathMetadataReading = RealPathMetadata()) -> ProfileProbeStatus {
        do {
            let attrs = try metadata.attributesOfItem(atPath: path)
            guard let date = attrs[.modificationDate] as? Date else {
                return .unavailable(reason: .noModificationDate)
            }
            return .live(installed: date)
        } catch let error as NSError {
            return .unavailable(reason: ProbeUnavailable.classify(error))
        }
    }

    /// A `ProfileState` synthesised from the live install date, so the existing reminder scheduling
    /// (`ProfileState.expiryReminderDate`) and status views work unchanged. Not from an import stub — the
    /// removal date is an estimate (install + 7 days).
    public static func syntheticProfile(installed: Date, observedAt: Date = Date()) -> ProfileState {
        let removal = expiry(installed: installed)
        var state = ProfileState(identifier: ProfileStubReader.basebandIdentifier,
                                 displayName: "Baseband logging (detected on device)",
                                 installDate: installed, removalDate: removal, lifetimeDays: lifetimeDays,
                                 consentDays: Int(lifetimeDays), status: .unknown, observedAt: observedAt)
        state.status = state.status(at: observedAt)
        return state
    }
}

/// The result of the live profile probe: a live install date, or why it was unavailable.
public enum ProfileProbeStatus: Equatable, Sendable {
    case live(installed: Date)
    case unavailable(reason: ProbeUnavailable)

    public var installDate: Date? { if case .live(let d) = self { return d } else { return nil } }
    public var isLive: Bool { installDate != nil }
}

/// The sysdiagnose-creation watcher's pure part (CellGuard's SysdiagTask analogue). The App layer's
/// `SysdiagnoseWatcher` adds the UIKit screenshot-notification observation and the banner/notification.
public enum SysdiagnoseWatcherProbe {
    /// Where iOS assembles a sysdiagnose. Outside the sandbox.
    public static let sysdiagnoseDir =
        "/private/var/mobile/Library/Logs/CrashReporter/DiagnosticLogs/sysdiagnose/"

    /// Probes the directory by metadata only — NEVER reads its contents. A permission-denied error is the
    /// useful side channel: it implies the path exists (a capture may be in progress).
    public static func probe(path: String = sysdiagnoseDir,
                             metadata: any PathMetadataReading = RealPathMetadata()) -> DirProbeState {
        do {
            _ = try metadata.attributesOfItem(atPath: path)
            return .exists
        } catch let error as NSError {
            switch ProbeUnavailable.classify(error) {
            case .permissionDenied(let c): return .permissionDenied(code: c)
            case .notFound(let c): return .notFound(code: c)
            case .noModificationDate: return .exists
            case .otherError(let c): return .error(code: c)
            }
        }
    }

    /// True when the directory metadata implies the path is present (exists outright, or a permission-denied
    /// refusal). Not-found or another error means the feature degrades to nothing.
    public static func dirImpliesPresent(_ state: DirProbeState) -> Bool {
        switch state {
        case .exists, .permissionDenied: return true
        case .notFound, .error: return false
        }
    }

    /// The gate: prompt only when the user just took a screenshot (the sysdiagnose gesture takes one — a
    /// proxy signal) AND the directory is present. If the directory probe returns not-found (likely on
    /// iOS 26 sandbox tightening), this is always false and the feature is silent.
    public static func shouldPrompt(screenshotSeen: Bool, dirState: DirProbeState) -> Bool {
        screenshotSeen && dirImpliesPresent(dirState)
    }
}

/// What the sysdiagnose-directory metadata probe found.
public enum DirProbeState: Equatable, Sendable {
    case exists
    case permissionDenied(code: Int)
    case notFound(code: Int)
    case error(code: Int)
}

/// Runs both probes with the real reader and renders one plain-text line each for the Settings > Diagnostics
/// readout, so the user can confirm on their real iPhone whether the live detection works. No identifiers:
/// only fixed system paths, error codes, and a modification date.
public struct ProbeDiagnostics: Sendable {
    public var profile: ProfileProbeStatus
    public var sysdiagnoseDir: DirProbeState

    public init(profile: ProfileProbeStatus, sysdiagnoseDir: DirProbeState) {
        self.profile = profile
        self.sysdiagnoseDir = sysdiagnoseDir
    }

    public static func run(metadata: any PathMetadataReading = RealPathMetadata()) -> ProbeDiagnostics {
        ProbeDiagnostics(profile: LiveProfileProbe.probe(metadata: metadata),
                         sysdiagnoseDir: SysdiagnoseWatcherProbe.probe(metadata: metadata))
    }

    private static func dateText(_ d: Date) -> String {
        d.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().second())
    }

    /// e.g. "modification date 21 Sep 2026 at 19:40:06" / "not accessible (error 257)".
    public var profileLine: String {
        switch profile {
        case .live(let d): return "modification date \(Self.dateText(d))"
        case .unavailable(.permissionDenied(let c)): return "not accessible — permission denied (error \(c))"
        case .unavailable(.notFound(let c)): return "not found (error \(c))"
        case .unavailable(.noModificationDate): return "present but no modification date"
        case .unavailable(.otherError(let c)): return "not accessible (error \(c))"
        }
    }

    /// e.g. "exists" / "permission-denied (257) — implies present" / "not found (260)".
    public var sysdiagnoseLine: String {
        switch sysdiagnoseDir {
        case .exists: return "exists (readable)"
        case .permissionDenied(let c): return "permission-denied (\(c)) — implies present"
        case .notFound(let c): return "not found (\(c))"
        case .error(let c): return "error (\(c))"
        }
    }

    /// Whether the live features would engage on this device.
    public var profileLiveActive: Bool { profile.isLive }
    public var sysdiagnoseWatchActive: Bool { SysdiagnoseWatcherProbe.dirImpliesPresent(sysdiagnoseDir) }
}

/// Folds the live profile probe into the import-derived guide state. The live state only *strengthens* the
/// `.unknown` placeholder ("Not set up yet"): a real import is stronger evidence and always wins, and any
/// probe failure leaves the import-derived state untouched (the graceful fallback).
public enum LiveGuideResolver {
    public struct Resolved: Equatable, Sendable {
        public var state: GuideState
        /// True when `state` came from the live device probe rather than an import.
        public var isLive: Bool
        public init(state: GuideState, isLive: Bool) { self.state = state; self.isLive = isLive }
    }

    public static func resolve(imported: GuideState, live: ProfileProbeStatus, now: Date) -> Resolved {
        guard case .live(let installed) = live, case .unknown = imported else {
            return Resolved(state: imported, isLive: false)
        }
        let removal = LiveProfileProbe.expiry(installed: installed)
        let state: GuideState
        if removal <= now {
            state = .expired(removal)
        } else if removal.timeIntervalSince(now) <= ProfileState.expiringSoonInterval {
            state = .expiringSoon(removal)
        } else {
            state = .active(removal)
        }
        return Resolved(state: state, isLive: true)
    }
}
