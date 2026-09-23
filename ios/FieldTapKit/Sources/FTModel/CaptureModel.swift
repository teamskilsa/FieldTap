// Owned by WP3-capture (seeded by WP0). What an import keeps about a sysdiagnose (the summary persisted next
// to capture.qmdl), the Baseband profile state read from the archive, and the importer/store protocols.

import Foundation

public enum ProfileStatus: String, Codable, Hashable, Sendable {
    case active, expiringSoon, expired, missing, unknown
}

/// Apple's Baseband logging profile (com.apple.basebandlogging) as its stub in the archive describes it.
/// Dates come from each archive, never from a constant: the lifetime was 21 days in 2025 and is 7 days now.
public struct ProfileState: Hashable, Codable, Sendable {
    public var identifier: String?
    public var displayName: String?
    public var installDate: Date?
    public var removalDate: Date?
    public var lifetimeDays: Double?
    public var consentDays: Int?
    /// The status when the archive was taken (`observedAt`); use `status(at:)` for now.
    public var status: ProfileStatus
    public var observedAt: Date?

    public init(identifier: String?, displayName: String?, installDate: Date?, removalDate: Date?,
                lifetimeDays: Double?, consentDays: Int?, status: ProfileStatus, observedAt: Date?) {
        self.identifier = identifier
        self.displayName = displayName
        self.installDate = installDate
        self.removalDate = removalDate
        self.lifetimeDays = lifetimeDays
        self.consentDays = consentDays
        self.status = status
        self.observedAt = observedAt
    }

    /// Less than this much time left counts as "expires soon" (R1: warn within 1 day).
    public static let expiringSoonInterval: TimeInterval = 24 * 60 * 60

    /// The status at `now`, from the removal date.
    public func status(at now: Date) -> ProfileStatus {
        guard let removal = removalDate else { return status == .missing ? .missing : .unknown }
        if removal <= now { return .expired }
        if removal.timeIntervalSince(now) <= Self.expiringSoonInterval { return .expiringSoon }
        return .active
    }

    /// Whole days left before iOS removes the profile, never negative; nil without a removal date.
    public func daysLeft(at now: Date) -> Int? {
        guard let removal = removalDate else { return nil }
        return max(0, Int((removal.timeIntervalSince(now) / 86_400).rounded(.down)))
    }

    /// When the "logging expires soon" reminder should fire: `expiringSoonInterval` (a day) before removal,
    /// but at least a minute from `now` so a near-expiry profile still notifies right away. Nil when there is no
    /// removal date or it has already passed.
    public func expiryReminderDate(now: Date = Date()) -> Date? {
        guard let removal = removalDate, removal > now else { return nil }
        return max(removal.addingTimeInterval(-Self.expiringSoonInterval), now.addingTimeInterval(60))
    }
}

/// Why an import could not give a usable modem trace, or what the user should know about it. Each has a
/// fix-it in the Modem logging guide.
public enum ImportProblem: Hashable, Codable, Sendable {
    case notASysdiagnose
    case truncatedArchive
    /// No logs/Baseband/log-bb-*-qdss directory and no Baseband profile stub: modem logging was off.
    case noBasebandTrace
    /// logs/Baseband/ambtool_output.log says "Baseband logs are not enabled".
    case loggingNotEnabled
    case profileMissing
    case profileExpired(Date)
    /// The profile was active when the archive was taken but expires within 1 day of it.
    case profileExpiresSoon(Date)
    /// Installed after the trace window began, so the trace predates it.
    case profileInstalledAfterTrace
    /// The profile stub is present and active but the archive has no modem trace: restart and try again.
    case profileInstalledNoTrace
    case unsupportedTrace(String)
    case lowDiskSpace(needBytes: Int64)

    /// A stable token for reports and launch arguments ("profileExpired").
    public var token: String {
        switch self {
        case .notASysdiagnose: "notASysdiagnose"
        case .truncatedArchive: "truncatedArchive"
        case .noBasebandTrace: "noBasebandTrace"
        case .loggingNotEnabled: "loggingNotEnabled"
        case .profileMissing: "profileMissing"
        case .profileExpired: "profileExpired"
        case .profileExpiresSoon: "profileExpiresSoon"
        case .profileInstalledAfterTrace: "profileInstalledAfterTrace"
        case .profileInstalledNoTrace: "profileInstalledNoTrace"
        case .unsupportedTrace: "unsupportedTrace"
        case .lowDiskSpace: "lowDiskSpace"
        }
    }

    /// True for problems that leave no trace to analyse.
    public var meansNoTrace: Bool {
        switch self {
        case .notASysdiagnose, .truncatedArchive, .noBasebandTrace, .loggingNotEnabled, .profileInstalledNoTrace:
            true
        default:
            false
        }
    }
}

/// The QDSS deframer's counters, with the keys of qdss_deframe.py's stats.json (snake_case).
/// Compared with the Python in WP3's parity tests: `comparedKeys`.
public struct DeframeStats: Hashable, Codable, Sendable {
    public var atid32Bytes: Int
    public var chunks: Int
    /// The Python's "stats" object: "phase" plus the parser counters (u_cont, messages, ...).
    public var counters: [String: Int]
    public var fits: [String: Int]
    public var fragmentKinds: [String: Int]
    public var packets: [String: Int]
    public var logRecords: Int
    public var distinctCodes: Int
    public var ts: [String: Int]
    public var incompleteRecords: Int
    public var targets: [String: Int]
    public var topCodes: [CodeCount]

    public struct CodeCount: Hashable, Codable, Sendable {
        public var code: String
        public var count: Int

        public init(code: String, count: Int) {
            self.code = code
            self.count = count
        }

        // The Python writes each as a two-element array: ["0x1375", 10934].
        public init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            code = try c.decode(String.self)
            count = try c.decode(Int.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(code)
            try c.encode(count)
        }
    }

    enum CodingKeys: String, CodingKey {
        case atid32Bytes = "atid32_bytes", chunks, counters = "stats", fits, fragmentKinds = "fragment_kinds"
        case packets, logRecords = "log_records", distinctCodes = "distinct_codes", ts
        case incompleteRecords = "incomplete_records", targets, topCodes = "top_codes"
    }

    /// The keys a Swift deframer must reproduce exactly (the rest are diagnostics).
    public static let comparedKeys: [String] = [
        "atid32_bytes", "chunks", "stats", "fits", "fragment_kinds", "packets", "log_records", "distinct_codes", "ts",
    ]

    public init(atid32Bytes: Int, chunks: Int, counters: [String: Int], fits: [String: Int],
                fragmentKinds: [String: Int], packets: [String: Int], logRecords: Int, distinctCodes: Int,
                ts: [String: Int], incompleteRecords: Int = 0, targets: [String: Int] = [:], topCodes: [CodeCount] = []) {
        self.atid32Bytes = atid32Bytes
        self.chunks = chunks
        self.counters = counters
        self.fits = fits
        self.fragmentKinds = fragmentKinds
        self.packets = packets
        self.logRecords = logRecords
        self.distinctCodes = distinctCodes
        self.ts = ts
        self.incompleteRecords = incompleteRecords
        self.targets = targets
        self.topCodes = topCodes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        atid32Bytes = try c.decode(Int.self, forKey: .atid32Bytes)
        chunks = try c.decode(Int.self, forKey: .chunks)
        counters = try c.decodeIfPresent([String: Int].self, forKey: .counters) ?? [:]
        fits = try c.decodeIfPresent([String: Int].self, forKey: .fits) ?? [:]
        fragmentKinds = try c.decodeIfPresent([String: Int].self, forKey: .fragmentKinds) ?? [:]
        packets = try c.decodeIfPresent([String: Int].self, forKey: .packets) ?? [:]
        logRecords = try c.decode(Int.self, forKey: .logRecords)
        distinctCodes = try c.decode(Int.self, forKey: .distinctCodes)
        ts = try c.decodeIfPresent([String: Int].self, forKey: .ts) ?? [:]
        incompleteRecords = try c.decodeIfPresent(Int.self, forKey: .incompleteRecords) ?? 0
        targets = try c.decodeIfPresent([String: Int].self, forKey: .targets) ?? [:]
        topCodes = try c.decodeIfPresent([CodeCount].self, forKey: .topCodes) ?? []
    }

    /// Phase-detection result (the Python's stats.phase).
    public var phase: Int { counters["phase"] ?? 0 }
}

/// One PCell span for the capture card's mini strip.
public struct PreviewSegment: Hashable, Codable, Sendable {
    public var band: String
    public var startMs: Double
    public var endMs: Double

    public init(band: String, startMs: Double, endMs: Double) {
        self.band = band
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// What the capture list shows without opening a capture.
public struct JourneyPreview: Hashable, Codable, Sendable {
    public var segments: [PreviewSegment]
    public var nr: Bool
    public var failures: Int

    public init(segments: [PreviewSegment], nr: Bool, failures: Int) {
        self.segments = segments
        self.nr = nr
        self.failures = failures
    }
}

/// A span in milliseconds relative to some reference; for the trace window, relative to the button press.
public struct TraceWindow: Hashable, Codable, Sendable {
    public var startMs: Double
    public var endMs: Double

    public init(startMs: Double, endMs: Double) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Double { endMs - startMs }
}

/// What info.txt says about the modem's trace ring, relative to the button press (R2). The modem lists every
/// file it wrote; the archive keeps only the newest ones, so listed minus kept is how many were overwritten.
public struct TraceTiming: Hashable, Codable, Sendable {
    public var listedFiles: Int
    public var keptFiles: Int
    /// The kept trace, in ms after the press: from the first kept file's "Starting From" to the last one's
    /// (or trace.info's end). Nil when the archive name gave no trigger time.
    public var windowAfterPressMs: TraceWindow?

    public init(listedFiles: Int, keptFiles: Int, windowAfterPressMs: TraceWindow?) {
        self.listedFiles = listedFiles
        self.keptFiles = keptFiles
        self.windowAfterPressMs = windowAfterPressMs
    }

    public var overwrittenFiles: Int { max(0, listedFiles - keptFiles) }
}

/// What one import produced, persisted as summary.json next to the capture.
public struct CaptureSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var importedAt: Date
    /// The archive's file name (sysdiagnose_YYYY.MM.DD_HH-MM-SS-ZZZZ_...tar.gz).
    public var sourceName: String
    /// When the user pressed the buttons: the time in the archive's name.
    public var triggerUtc: Date?
    public var traceDirName: String?
    public var chunkCount: Int
    public var chunkBytes: Int
    public var deframe: DeframeStats?
    public var secure: EncryptedCensus
    public var profile: ProfileState?
    public var problems: [ImportProblem]
    public var durationMs: Double?
    /// "B2 -> B66 -> B12 -> B2, NR, 0 failures".
    public var digest: String?
    public var preview: JourneyPreview?
    /// Seconds per import stage, for the import sheet and the performance log.
    public var timings: [String: Double]
    /// R2: the kept trace relative to the button press ("covers 0:19-0:46 after you pressed the buttons"),
    /// from the archive name's trigger time and info.txt 'Starting From' / chunk times.
    public var traceWindowAfterPressMs: TraceWindow?
    /// R2: how many trace files the modem's ring overwrote before the dump (info.txt lists them all).
    public var overwrittenFiles: Int?
    /// How many trace files info.txt listed in total.
    public var listedFiles: Int?
    /// From logs/Baseband/ambtool_output.log: false when it says baseband logs are not enabled.
    public var basebandLoggingEnabled: Bool?
    /// Older log-bb-*-qdss directories in the same archive, which the import did not use (only the newest).
    public var otherTraceDirs: [String]?

    public init(id: UUID = UUID(), importedAt: Date, sourceName: String, triggerUtc: Date? = nil,
                traceDirName: String? = nil, chunkCount: Int = 0, chunkBytes: Int = 0, deframe: DeframeStats? = nil,
                secure: EncryptedCensus = .empty, profile: ProfileState? = nil, problems: [ImportProblem] = [],
                durationMs: Double? = nil, digest: String? = nil, preview: JourneyPreview? = nil,
                timings: [String: Double] = [:], traceWindowAfterPressMs: TraceWindow? = nil,
                overwrittenFiles: Int? = nil, listedFiles: Int? = nil, basebandLoggingEnabled: Bool? = nil,
                otherTraceDirs: [String]? = nil) {
        self.id = id
        self.importedAt = importedAt
        self.sourceName = sourceName
        self.triggerUtc = triggerUtc
        self.traceDirName = traceDirName
        self.chunkCount = chunkCount
        self.chunkBytes = chunkBytes
        self.deframe = deframe
        self.secure = secure
        self.profile = profile
        self.problems = problems
        self.durationMs = durationMs
        self.digest = digest
        self.preview = preview
        self.timings = timings
        self.traceWindowAfterPressMs = traceWindowAfterPressMs
        self.overwrittenFiles = overwrittenFiles
        self.listedFiles = listedFiles
        self.basebandLoggingEnabled = basebandLoggingEnabled
        self.otherTraceDirs = otherTraceDirs
    }

    /// True when the archive held a modem trace to analyse.
    public var hasTrace: Bool { chunkCount > 0 && !problems.contains { $0.meansNoTrace } }
}

/// The capture facts FTJourney's findings quote (trace window, record counts, encrypted census, profile).
public struct CaptureFacts: Hashable, Sendable {
    public var traceWindowMs: Double
    public var logRecords: Int
    public var distinctCodes: Int
    public var encrypted: EncryptedCensus
    public var profile: ProfileState?
    public var triggerUtc: Date?
    public var traceWindowAfterPressMs: TraceWindow?
    public var overwrittenFiles: Int?

    public init(traceWindowMs: Double, logRecords: Int, distinctCodes: Int, encrypted: EncryptedCensus,
                profile: ProfileState?, triggerUtc: Date?, traceWindowAfterPressMs: TraceWindow? = nil,
                overwrittenFiles: Int? = nil) {
        self.traceWindowMs = traceWindowMs
        self.logRecords = logRecords
        self.distinctCodes = distinctCodes
        self.encrypted = encrypted
        self.profile = profile
        self.triggerUtc = triggerUtc
        self.traceWindowAfterPressMs = traceWindowAfterPressMs
        self.overwrittenFiles = overwrittenFiles
    }

    public init(summary: CaptureSummary) {
        self.init(traceWindowMs: summary.durationMs ?? 0,
                  logRecords: summary.deframe?.logRecords ?? 0,
                  distinctCodes: summary.deframe?.distinctCodes ?? 0,
                  encrypted: summary.secure,
                  profile: summary.profile,
                  triggerUtc: summary.triggerUtc,
                  traceWindowAfterPressMs: summary.traceWindowAfterPressMs,
                  overwrittenFiles: summary.overwrittenFiles)
    }
}

public enum ImportStage: String, Codable, Hashable, Sendable, CaseIterable {
    case reading, extracting, deframing, decoding, saving, done
}

public struct ImportProgress: Hashable, Codable, Sendable {
    public var stage: ImportStage
    /// 0...1 through the stage, or negative when the stage cannot tell how far it is (the archive scan: gzip
    /// gives no total, so the sheet shows activity and the trace files found instead of a made-up bar).
    public var fraction: Double
    public var detail: String

    public init(stage: ImportStage, fraction: Double, detail: String = "") {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
    }
}

public struct ImportedCapture: Sendable {
    public var summary: CaptureSummary
    public var records: [LogRecord]
    public var qmdlURL: URL

    public init(summary: CaptureSummary, records: [LogRecord], qmdlURL: URL) {
        self.summary = summary
        self.records = records
        self.qmdlURL = qmdlURL
    }
}

/// Turns a sysdiagnose archive into a stored capture (FTCapture.SysdiagnoseImporter).
public protocol CaptureImporting: Sendable {
    func importArchive(at url: URL, securityScoped: Bool,
                       progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> ImportedCapture
}

/// Where captures live on the phone (FTCapture.CaptureStore).
public protocol CaptureStoring: Sendable {
    var rootURL: URL { get }
    func list() throws -> [CaptureSummary]
    func records(for id: UUID) throws -> [LogRecord]
    func update(_ summary: CaptureSummary) throws
    func delete(_ id: UUID) throws
}

/// Where an import stands, for the import sheet. `-FTImportState <token>` (DEBUG/Harness) shows one without
/// importing anything, so every sheet state can be screenshotted from the fixtures.
public enum ImportState: Hashable, Sendable {
    case idle
    case running(ImportProgress)
    case finished(CaptureSummary)
    case failed([ImportProblem])

    public var token: String {
        switch self {
        case .idle: "idle"
        case .running(let p): p.stage.rawValue
        case .finished: "done"
        case .failed(let problems): problems.first?.token ?? "failed"
        }
    }

    /// The state a launch-argument token names: "idle", a stage ("reading" ... "saving", shown half way),
    /// "done" (with `summary`), or an ImportProblem token ("noBasebandTrace", "profileExpired", ...).
    public static func preview(token: String, summary: CaptureSummary?, now: Date) -> ImportState? {
        if token == "idle" { return .idle }
        if token == "done" { return summary.map { .finished($0) } }
        if let stage = ImportStage(rawValue: token), stage != .done {
            return .running(ImportProgress(stage: stage, fraction: 0.5, detail: ""))
        }
        let removal = summary?.profile?.removalDate ?? now.addingTimeInterval(-86_400)
        let problem: ImportProblem? = switch token {
        case "notASysdiagnose": .notASysdiagnose
        case "truncatedArchive": .truncatedArchive
        case "noBasebandTrace": .noBasebandTrace
        case "loggingNotEnabled": .loggingNotEnabled
        case "profileMissing": .profileMissing
        case "profileExpired": .profileExpired(removal)
        case "profileExpiresSoon": .profileExpiresSoon(now.addingTimeInterval(12 * 3_600))
        case "profileInstalledAfterTrace": .profileInstalledAfterTrace
        case "profileInstalledNoTrace": .profileInstalledNoTrace
        case "unsupportedTrace": .unsupportedTrace("preview")
        case "lowDiskSpace": .lowDiskSpace(needBytes: 600_000_000)
        default: nil
        }
        return problem.map { .failed([$0]) }
    }
}
