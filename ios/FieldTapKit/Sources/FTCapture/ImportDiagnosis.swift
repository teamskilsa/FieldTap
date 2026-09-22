import Foundation
import FTCore
import FTModel

/// An import that produced no capture at all: not a sysdiagnose, cut short, or no room to unpack it.
public struct ImportFailure: Error, Hashable, Sendable {
    public var problems: [ImportProblem]

    public init(_ problems: [ImportProblem]) {
        self.problems = problems
    }

    /// The problem a scanner error means: a file that is not gzip is not a sysdiagnose; one that stops part way
    /// was cut short in the copy.
    public static func of(_ error: SysdiagScanError) -> ImportFailure {
        switch error {
        case .notGzip: ImportFailure([.notASysdiagnose])
        case .truncated, .corrupt: ImportFailure([.truncatedArchive])
        case .cannotOpen(let why), .readFailed(let why): ImportFailure([.unsupportedTrace(why)])
        }
    }
}

/// What the archive said about modem logging, and the problems that follow from it. Pure, so every guide state
/// can be tested from synthetic archives.
public struct ImportEvidence: Hashable, Sendable {
    /// Trace chunks kept in the newest log-bb-*-qdss directory.
    public var chunkCount: Int
    /// The Baseband profile from its stub, or from MCProfileEvents when iOS had already removed it.
    public var profile: ProfileState?
    /// ambtool_output.log's verdict: false for "Baseband logs are not enabled", nil without the log.
    public var basebandLoggingEnabled: Bool?
    public var triggerUtc: Date?
    /// The first 'Starting From' in info.txt: when the modem's trace ring began.
    public var traceStart: Date?

    public init(chunkCount: Int, profile: ProfileState?, basebandLoggingEnabled: Bool?, triggerUtc: Date?,
                traceStart: Date?) {
        self.chunkCount = chunkCount
        self.profile = profile
        self.basebandLoggingEnabled = basebandLoggingEnabled
        self.triggerUtc = triggerUtc
        self.traceStart = traceStart
    }

    /// ambtool_output.log's text -> enabled or not.
    public static func loggingEnabled(ambtoolLog: String?) -> Bool? {
        guard let log = ambtoolLog else { return nil }
        return !log.localizedCaseInsensitiveContains("not enabled")
    }

    /// The problems, most important first: the missing trace, then why it is missing, then the profile's dates.
    public var problems: [ImportProblem] {
        var out: [ImportProblem] = []
        let hasTrace = chunkCount > 0
        if !hasTrace { out.append(.noBasebandTrace) }
        if basebandLoggingEnabled == false { out.append(.loggingNotEnabled) }
        guard let profile, profile.status != .missing else {
            out.append(.profileMissing)
            return out
        }
        if let removal = profile.removalDate, let trigger = triggerUtc ?? profile.observedAt, removal <= trigger {
            out.append(.profileExpired(removal))
            return out
        }
        if let install = profile.installDate, let start = traceStart, install > start {
            out.append(.profileInstalledAfterTrace)
        }
        if !hasTrace { out.append(.profileInstalledNoTrace) }
        if let removal = profile.removalDate, let trigger = triggerUtc,
           removal.timeIntervalSince(trigger) <= ProfileState.expiringSoonInterval {
            out.append(.profileExpiresSoon(removal))
        }
        return out
    }
}
