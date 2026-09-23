// The local, no-network fake-base-station / IMSI-catcher report. A byte-for-byte port of the engine's
// SecurityReport shape (web/engine/src/types.ts, ruleset `fieldtap-security/1`): per-cell verdicts, an overall
// verdict, and a plain-language reason plus the exact decoded evidence for every finding. FTSecurity computes
// it from an already-decoded CaptureAnalysis; nothing here touches the network.
//
// These value types live in FTModel (like the shared Cell/Event/Field) so CaptureAnalysis can carry an optional
// `security` and FTSecurity, which owns the logic, depends only on FTModel. The Codable shape round-trips the
// engine's committed golden JSON (tests/security/golden/*.security.json): optional fields are omitted when nil,
// exactly as the engine's JSON leaves them out, so GoldenCodec.jsonDiff finds no extra keys.

/// trusted = nothing found; warning = an anomaly with an ordinary explanation; suspicious = a Layer-3 catcher tell.
public enum SecurityVerdict: String, Codable, Hashable, Sendable, CaseIterable {
    case trusted, warning, suspicious

    /// The worst wins when a cell or the capture rolls its findings up.
    public var rank: Int {
        switch self {
        case .trusted: 0
        case .warning: 1
        case .suspicious: 2
        }
    }
}

/// A finding's own weight. `info` never lowers a verdict; `warning` -> warning; `suspicious` -> suspicious.
public enum SecuritySeverity: String, Codable, Hashable, Sendable, CaseIterable {
    case info, warning, suspicious

    public var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .suspicious: 2
        }
    }

    /// The verdict this severity contributes.
    public var verdict: SecurityVerdict {
        switch self {
        case .suspicious: .suspicious
        case .warning: .warning
        case .info: .trusted
        }
    }
}

/// The checks this engine can support from the current RRC/NAS + cell + PHY decode.
public enum SecurityCheckId: String, Codable, Hashable, Sendable, CaseIterable {
    /// A NAS Security Mode Command that chose EEA0 (null ciphering) or EIA0 (null integrity).
    case nullCipher
    /// A registration/attach was accepted but no Security Mode Command (RRC or NAS) was ever seen.
    case noSecurityEstablished
    /// An Identity Request for the IMSI before security was established.
    case imsiRequestedInClear
    /// A forced redirection/reselection down to GERAN (2G) or UTRAN (3G) while on LTE/NR.
    case ratDowngrade
    /// An accept with no Authentication and no prior security context (the request was not integrity protected).
    case acceptedWithoutAuth
    /// A NAS reject whose cause pushes the phone off a legitimate network (#3/#6/#7/#8/#11..#15).
    case abnormalReject
    /// A serving-cell signal stronger than any real macro cell delivers, sustained over several samples.
    case implausibleSignal
    /// A cell the phone connected on that was reached by no normal mobility and appears in no neighbour evidence.
    case orphanCell
}

/// One anomaly, tied to the decoded evidence that raised it. `id` is unique within a report.
public struct SecurityFinding: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var check: SecurityCheckId
    public var severity: SecuritySeverity
    /// A short label ("Null security algorithm").
    public var title: String
    /// One plain-language sentence a non-specialist can act on.
    public var explanation: String
    /// The exact decoded field(s) this verdict read ("Security mode command: Ciphering = EEA0 (null ciphering)").
    public var evidence: [String]
    /// The cell the finding is attributed to, when it belongs to one.
    public var cell: Cell?
    /// Index into the flow's events, when one message raised it.
    public var event: Int?
    public var tMs: Double?

    public init(id: String, check: SecurityCheckId, severity: SecuritySeverity, title: String,
                explanation: String, evidence: [String], cell: Cell? = nil, event: Int? = nil, tMs: Double? = nil) {
        self.id = id
        self.check = check
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.evidence = evidence
        self.cell = cell
        self.event = event
        self.tMs = tMs
    }
}

/// The per-cell roll-up: the worst finding on the cell decides its verdict.
public struct SecurityCellVerdict: Identifiable, Hashable, Codable, Sendable {
    public var cell: Cell
    /// "B2", "n77".
    public var band: String?
    public var verdict: SecurityVerdict
    public var findings: [SecurityFinding]

    public init(cell: Cell, band: String? = nil, verdict: SecurityVerdict, findings: [SecurityFinding]) {
        self.cell = cell
        self.band = band
        self.verdict = verdict
        self.findings = findings
    }

    public var id: String { "\(cell.earfcn)/\(cell.pci)\(cell.nr ? "/nr" : "")" }
}

/// A candidate check the current decode cannot yet support, kept in the report so the gap is visible, not hidden.
public struct SecurityGap: Identifiable, Hashable, Codable, Sendable {
    public var check: String
    public var reason: String

    public init(check: String, reason: String) {
        self.check = check
        self.reason = reason
    }

    public var id: String { check }
}

/// The local security report, computed on this device from the already-decoded analysis. It reaches no network:
/// an external cell-database cross-check is a separate, opt-in step that iOS deliberately does not implement.
public struct SecurityReport: Hashable, Codable, Sendable {
    /// The whole-capture verdict: the worst of the per-cell and unattached findings.
    public var verdict: SecurityVerdict
    /// One calm sentence for the banner. Most captures are clean and it says so.
    public var headline: String
    /// Per serving/connected cell, worst finding first.
    public var cells: [SecurityCellVerdict]
    /// Findings not tied to a single cell.
    public var findings: [SecurityFinding]
    /// Checks that ran (whether or not they fired), for transparency.
    public var checksRun: [SecurityCheckId]
    /// Candidate checks the current RRC/NAS/PHY decode does not expose enough to support, with why.
    public var gaps: [SecurityGap]
    /// The ruleset version, so this port can match golden reports exactly.
    public var ruleset: String

    public init(verdict: SecurityVerdict, headline: String, cells: [SecurityCellVerdict],
                findings: [SecurityFinding], checksRun: [SecurityCheckId], gaps: [SecurityGap], ruleset: String) {
        self.verdict = verdict
        self.headline = headline
        self.cells = cells
        self.findings = findings
        self.checksRun = checksRun
        self.gaps = gaps
        self.ruleset = ruleset
    }

    /// Every finding, per-cell then unattached, for a flat count or list.
    public var allFindings: [SecurityFinding] { cells.flatMap(\.findings) + findings }
}
