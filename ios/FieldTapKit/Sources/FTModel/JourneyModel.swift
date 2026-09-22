// SEED from WP0; owned by WP5-journey. The journey lanes, markers, findings and KPI tiles FTJourney builds
// (rules J1-J12 in ios/Contract/CONTRACT.md) and the capture screens draw.

public enum RadioState: String, Codable, Hashable, Sendable, CaseIterable {
    case unknown, connected, idle, radioOff
}

public struct StateSegment: Hashable, Codable, Sendable {
    public var state: RadioState
    public var startMs: Double
    public var endMs: Double
    public var openAtEnd: Bool
    /// Why the segment is there ("connection 0 RELEASED", "switch-off detach (event 2)...").
    public var source: String?

    public init(state: RadioState, startMs: Double, endMs: Double, openAtEnd: Bool = false, source: String? = nil) {
        self.state = state
        self.startMs = startMs
        self.endMs = endMs
        self.openAtEnd = openAtEnd
        self.source = source
    }
}

public enum RegistrationState: String, Codable, Hashable, Sendable {
    case registered, deregistered, unknown
}

public struct RegistrationSegment: Hashable, Codable, Sendable {
    public var state: RegistrationState
    public var startMs: Double
    public var endMs: Double
    /// Registered only by inference (J5): the first NAS procedure was one a registered phone runs.
    public var assumed: Bool

    public init(state: RegistrationState, startMs: Double, endMs: Double, assumed: Bool = false) {
        self.state = state
        self.startMs = startMs
        self.endMs = endMs
        self.assumed = assumed
    }
}

public enum LaneKind: String, Codable, Hashable, Sendable {
    case pcell, pscell, scell
}

/// Where a segment came from: the decoded RRC, the PHY records, or an inference with no direct evidence.
public enum EvidenceSource: String, Codable, Hashable, Sendable {
    case rrc, phy, inferred
}

/// One cell on one lane for one span of time.
public struct CellSegment: Identifiable, Hashable, Codable, Sendable {
    public var lane: LaneKind
    /// Position within its lane (the SCell index for SCells).
    public var index: Int
    public var cell: Cell
    /// "B66"; nil for NR, whose band is ambiguous (see `bandCandidates`).
    public var band: String?
    /// NR bands the ARFCN falls in, e.g. [5, 26]; empty for LTE.
    public var bandCandidates: [Int]
    public var dlMhz: Double?
    public var startMs: Double
    public var endMs: Double
    /// For a PSCell: when the NR cell completed its addition (J8).
    public var addedMs: Double?
    public var openAtEnd: Bool
    /// The end was inferred (e.g. SCG release at an LTE handover command), not logged.
    public var endInferred: Bool
    public var startReason: String?
    public var endReason: String?
    public var source: EvidenceSource
    /// The last PHY record seen for this cell, to cross-check an inferred end.
    public var phyLastMs: Double?

    public init(lane: LaneKind, index: Int, cell: Cell, band: String?, bandCandidates: [Int] = [], dlMhz: Double?,
                startMs: Double, endMs: Double, addedMs: Double? = nil, openAtEnd: Bool = false,
                endInferred: Bool = false, startReason: String? = nil, endReason: String? = nil,
                source: EvidenceSource, phyLastMs: Double? = nil) {
        self.lane = lane
        self.index = index
        self.cell = cell
        self.band = band
        self.bandCandidates = bandCandidates
        self.dlMhz = dlMhz
        self.startMs = startMs
        self.endMs = endMs
        self.addedMs = addedMs
        self.openAtEnd = openAtEnd
        self.endInferred = endInferred
        self.startReason = startReason
        self.endReason = endReason
        self.source = source
        self.phyLastMs = phyLastMs
    }

    public var id: String { "\(lane.rawValue)-\(index)-\(Int(startMs))" }
}

public enum MarkerKind: String, Codable, Hashable, Sendable, CaseIterable {
    case handover, reselection, reattach, redirect, reestablishment, cellChange
    case scgAdd, scgModify, scgRelease, scgFailure
    case attach, detachSwitchOff, detach
    case rrcSetup, rrcRelease, rrcReject
    case rach
    case procedureFailed, procedureUnanswered, connectionLost, noAnswer, registrationReject
}

public enum Severity: String, Codable, Hashable, Sendable, Comparable {
    case info, warning, failure

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .failure: 2
        }
    }

    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

/// Something that happened at one moment, drawn on the marker row. `id` is unique within a journey:
/// kind plus the event (or the time for PHY-derived markers), e.g. "handover-82", "rach-2659.6".
public struct Marker: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: MarkerKind
    public var tMs: Double
    /// For a handover: when the phone arrived on the target cell.
    public var arrivalMs: Double?
    public var event: Int?
    public var endEvent: Int?
    public var from: Cell?
    public var to: Cell?
    public var durationMs: Double?
    public var ta: Int?
    public var distanceM: Double?
    public var inferred: Bool
    public var severity: Severity
    public var title: String
    public var detail: String?

    public init(id: String, kind: MarkerKind, tMs: Double, arrivalMs: Double? = nil, event: Int? = nil,
                endEvent: Int? = nil, from: Cell? = nil, to: Cell? = nil, durationMs: Double? = nil, ta: Int? = nil,
                distanceM: Double? = nil, inferred: Bool = false, severity: Severity = .info, title: String,
                detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.tMs = tMs
        self.arrivalMs = arrivalMs
        self.event = event
        self.endEvent = endEvent
        self.from = from
        self.to = to
        self.durationMs = durationMs
        self.ta = ta
        self.distanceM = distanceM
        self.inferred = inferred
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public enum FindingKind: String, Codable, Hashable, Sendable {
    case switchedOff, radioBack, reattach, attach, pdnConnected, scgAdded, scgPhyOutlived, handover
    case carrierAggregation, failure, warning, noFailures, encryptedRecords, traceWindow, other
}

/// One sentence of "What happened". `id` is unique (kind plus event or ordinal, e.g. "handover-82").
public struct Finding: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: FindingKind
    public var severity: Severity
    public var text: String
    public var tMs: Double?
    public var event: Int?

    public init(id: String, kind: FindingKind, severity: Severity, text: String, tMs: Double? = nil, event: Int? = nil) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.text = text
        self.tMs = tMs
        self.event = event
    }
}

/// A KPI tile: "Handover 2/2, median 34.9 ms".
public struct KpiTile: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var group: String
    public var title: String
    public var succeeded: Int
    public var attempts: Int
    public var value: String?
    public var event: Int?

    public init(id: String, group: String, title: String, succeeded: Int, attempts: Int, value: String? = nil,
                event: Int? = nil) {
        self.id = id
        self.group = group
        self.title = title
        self.succeeded = succeeded
        self.attempts = attempts
        self.value = value
        self.event = event
    }
}

public struct Journey: Hashable, Codable, Sendable {
    public var durationMs: Double
    public var states: [StateSegment]
    public var registration: [RegistrationSegment]
    public var cells: [CellSegment]
    public var markers: [Marker]
    public var findings: [Finding]
    public var tiles: [KpiTile]

    public init(durationMs: Double, states: [StateSegment], registration: [RegistrationSegment], cells: [CellSegment],
                markers: [Marker], findings: [Finding], tiles: [KpiTile]) {
        self.durationMs = durationMs
        self.states = states
        self.registration = registration
        self.cells = cells
        self.markers = markers
        self.findings = findings
        self.tiles = tiles
    }

    public static let empty = Journey(durationMs: 0, states: [], registration: [], cells: [], markers: [], findings: [],
                                      tiles: [])
}

/// The sticky header's values at the cursor. `stale` names the values older than their staleness limit.
public struct ServingSnapshot: Hashable, Sendable {
    public var tMs: Double
    public var state: RadioState
    public var pcell: CellSegment?
    public var pscell: CellSegment?
    public var scells: [CellSegment]
    public var rsrp: Double?
    public var rsrq: Double?
    public var rssi: Double?
    public var cqi: Int?
    public var ri: Int?
    public var dlMcs: Int?
    public var nrRsrp: Double?
    public var nrMcs: Int?
    public var stale: Set<String>

    public init(tMs: Double, state: RadioState = .unknown, pcell: CellSegment? = nil, pscell: CellSegment? = nil,
                scells: [CellSegment] = [], rsrp: Double? = nil, rsrq: Double? = nil, rssi: Double? = nil,
                cqi: Int? = nil, ri: Int? = nil, dlMcs: Int? = nil, nrRsrp: Double? = nil, nrMcs: Int? = nil,
                stale: Set<String> = []) {
        self.tMs = tMs
        self.state = state
        self.pcell = pcell
        self.pscell = pscell
        self.scells = scells
        self.rsrp = rsrp
        self.rsrq = rsrq
        self.rssi = rssi
        self.cqi = cqi
        self.ri = ri
        self.dlMcs = dlMcs
        self.nrRsrp = nrRsrp
        self.nrMcs = nrMcs
        self.stale = stale
    }
}
