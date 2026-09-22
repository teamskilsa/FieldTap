// Port of the model types in android/diag/src/main/kotlin/com/fieldtap/diag/CallFlow.kt (contract v1),
// Field from LteRrc.kt and Serving from CellInfo.kt. Behaviour lives in FTSignalling (WP2); these are the
// values both apps agree on, checked through the golden JSON (GoldenCodec).

public enum Layer: String, Codable, Hashable, Sendable, CaseIterable {
    case RRC, NAS
}

/// A cell as the RRC header names it. `earfcn` is the EARFCN for LTE and the NR-ARFCN for NR: two different
/// number spaces, so `nr` travels with it.
public struct Cell: Hashable, Codable, Sendable {
    public var earfcn: Int64
    public var pci: Int
    public var nr: Bool

    public init(earfcn: Int64, pci: Int, nr: Bool = false) {
        self.earfcn = earfcn
        self.pci = pci
        self.nr = nr
    }

    /// Contract v1 (D4): an NR RRC header logged before the SCG cell is assigned carries PCI 0xFFFF or
    /// ARFCN 0xFFFF_FFFF. Such a cell is shown as "NR cell pending", never as a real PCI.
    public var isPendingNr: Bool { nr && (pci == 0xFFFF || earfcn == 0xFFFF_FFFF) }
}

/// One decoded field: a label, its value as shown, and nested fields.
public struct Field: Hashable, Codable, Sendable {
    public var label: String
    public var value: String
    public var children: [Field]

    public init(label: String, value: String, children: [Field] = []) {
        self.label = label
        self.value = value
        self.children = children
    }
}

/// How a NAS message went over the air, from its security-protected copy.
public struct Protection: Hashable, Codable, Sendable {
    public var headerType: Int
    public var mac: UInt32
    public var sequence: Int

    public init(headerType: Int, mac: UInt32, sequence: Int) {
        self.headerType = headerType
        self.mac = mac
        self.sequence = sequence
    }

    public var headerName: String {
        switch headerType {
        case 1: "integrity protected"
        case 2: "integrity protected and ciphered"
        case 3: "integrity protected, new security context"
        case 4: "integrity protected and ciphered, new security context"
        default: "type \(headerType)"
        }
    }
}

/// One message on the call-flow timeline.
public struct Event: Identifiable, Hashable, Codable, Sendable {
    public var index: Int
    /// 1-based position of the log record in the file, counting every record.
    public var record: Int
    public var logCode: UInt16
    public var timestampRaw: UInt64
    /// Since the capture's time base (D1).
    public var sinceStartMs: Double
    public var layer: Layer
    /// "lte" or "nr".
    public var rat: String
    public var uplink: Bool
    /// What the message is called, for matching: the ASN.1 name for RRC, the 3GPP name for NAS.
    public var key: String
    /// What the message is called, for reading.
    public var name: String
    /// The one line under the name: a cause, an APN, a handover target.
    public var summary: String?
    /// The cell it was on: from its own header for RRC, from the nearest RRC message for NAS.
    public var cell: Cell?
    /// The logical channel, for RRC; the sublayer, upper-cased, for NAS.
    public var channel: String
    public var fields: [Field]
    public var cause: Int?
    public var causeName: String?
    public var protection: Protection?
    /// The type could not be read: ciphered, and no plain copy was logged.
    public var ciphered: Bool
    /// The raw PDU. Empty when the flow came from a golden fixture (goldens carry only its length).
    public var pdu: [UInt8]
    /// For NAS pulled out of an RRC message: which one. On 5G the RRC message is the only copy there is.
    public var carrier: String?

    public init(index: Int, record: Int, logCode: UInt16, timestampRaw: UInt64, sinceStartMs: Double,
                layer: Layer, rat: String, uplink: Bool, key: String, name: String, summary: String?,
                cell: Cell?, channel: String, fields: [Field], cause: Int?, causeName: String?,
                protection: Protection?, ciphered: Bool, pdu: [UInt8], carrier: String? = nil) {
        self.index = index
        self.record = record
        self.logCode = logCode
        self.timestampRaw = timestampRaw
        self.sinceStartMs = sinceStartMs
        self.layer = layer
        self.rat = rat
        self.uplink = uplink
        self.key = key
        self.name = name
        self.summary = summary
        self.cell = cell
        self.channel = channel
        self.fields = fields
        self.cause = cause
        self.causeName = causeName
        self.protection = protection
        self.ciphered = ciphered
        self.pdu = pdu
        self.carrier = carrier
    }

    public var id: Int { index }

    /// The label LteRrc gives the field that marks an RRCConnectionReconfiguration as a handover command.
    public static let handoverFieldLabel = "Handover"

    public var isFailure: Bool {
        cause != nil || key.range(of: "reject", options: .caseInsensitive) != nil
            || key.range(of: "failure", options: .caseInsensitive) != nil
    }

    public var isHandoverCommand: Bool { fields.contains { $0.label == Self.handoverFieldLabel } }
}

public enum Outcome: String, Codable, Hashable, Sendable, CaseIterable {
    case SUCCEEDED, FAILED, UNANSWERED
}

/// A request and what answered it. `first` and `last` index `Flow.events`.
public struct Procedure: Hashable, Codable, Sendable {
    public var name: String
    public var layer: Layer
    public var detail: String?
    public var first: Int
    public var last: Int
    public var outcome: Outcome
    public var durationMs: Double
    /// What the answer said, when it was a refusal: the reject's cause.
    public var refusal: String?

    public init(name: String, layer: Layer, detail: String?, first: Int, last: Int, outcome: Outcome,
                durationMs: Double, refusal: String? = nil) {
        self.name = name
        self.layer = layer
        self.detail = detail
        self.first = first
        self.last = last
        self.outcome = outcome
        self.durationMs = durationMs
        self.refusal = refusal
    }
}

public enum Move: String, Codable, Hashable, Sendable, CaseIterable {
    case FIRST_SEEN, HANDOVER, RESELECTION, REDIRECT, REESTABLISHMENT, CELL_CHANGE
}

/// The phone arrived on `to`. `event` is the first message logged there.
public struct Step: Hashable, Codable, Sendable {
    public var move: Move
    public var from: Cell?
    public var to: Cell
    public var event: Int
    public var sinceStartMs: Double

    public init(move: Move, from: Cell?, to: Cell, event: Int, sinceStartMs: Double) {
        self.move = move
        self.from = from
        self.to = to
        self.event = event
        self.sinceStartMs = sinceStartMs
    }
}

public enum ConnectionOutcome: String, Codable, Hashable, Sendable, CaseIterable {
    /// Set up and released.
    case RELEASED
    /// Still connected when the capture ended.
    case OPEN_AT_END
    /// Set up, then the phone was idle again with no release logged: a radio link failure, typically.
    case LOST
    /// The network answered the request with a reject.
    case REJECTED
    /// Nothing answered the request.
    case NO_ANSWER
}

/// One RRC connection or attempt at one, from its request (or the first connected-mode message) to its end.
public struct Connection: Hashable, Codable, Sendable {
    public var first: Int
    /// The last message of it; nil while the capture ended connected.
    public var last: Int?
    public var establishmentCause: String?
    public var releaseCause: String?
    public var outcome: ConnectionOutcome
    public var startMs: Double
    public var endMs: Double?

    public init(first: Int, last: Int?, establishmentCause: String?, releaseCause: String?,
                outcome: ConnectionOutcome, startMs: Double, endMs: Double?) {
        self.first = first
        self.last = last
        self.establishmentCause = establishmentCause
        self.releaseCause = releaseCause
        self.outcome = outcome
        self.startMs = startMs
        self.endMs = endMs
    }

    public var established: Bool { outcome == .RELEASED || outcome == .OPEN_AT_END || outcome == .LOST }
}

/// What the modem's LTE serving-cell record (0xB0C2) said about a cell.
public struct ServingCellInfo: Hashable, Codable, Sendable {
    public var pci: Int
    public var downlinkEarfcn: Int64
    public var uplinkEarfcn: Int64
    public var band: Int
    public var plmn: String
    public var tac: Int
    /// E-UTRAN cell identity: eNB and sector. Nil when it came from a golden fixture, where it is masked.
    public var cellIdentity: Int64?
    /// Nil when the record's bandwidth code is not one CellInfo knows.
    public var bandwidthMhz: Double?

    public init(pci: Int, downlinkEarfcn: Int64, uplinkEarfcn: Int64, band: Int, plmn: String, tac: Int,
                cellIdentity: Int64?, bandwidthMhz: Double?) {
        self.pci = pci
        self.downlinkEarfcn = downlinkEarfcn
        self.uplinkEarfcn = uplinkEarfcn
        self.band = band
        self.plmn = plmn
        self.tac = tac
        self.cellIdentity = cellIdentity
        self.bandwidthMhz = bandwidthMhz
    }
}

/// One entry of Kotlin's `Flow.cellDetails` map, kept in its insertion order.
public struct CellDetail: Hashable, Codable, Sendable {
    public var cell: Cell
    public var info: ServingCellInfo

    public init(cell: Cell, info: ServingCellInfo) {
        self.cell = cell
        self.info = info
    }
}

/// A capture read the way an engineer reads one: RRC and NAS on one timeline, the procedures they make up,
/// and the cells the phone moved through.
public struct Flow: Hashable, Codable, Sendable {
    public var events: [Event]
    public var procedures: [Procedure]
    public var journey: [Step]
    /// Cells whose system information the phone read but never signalled on.
    public var searched: [Cell]
    public var connections: [Connection]
    public var cellDetails: [CellDetail]
    /// Every log record in the file.
    public var records: Int
    /// Signalling records not shown: NR RRC and NAS no decoder could place.
    public var undecoded: Int
    public var crcErrors: Int
    /// From the first counted record to the last (D1).
    public var durationMs: Double
    /// Wall-clock time of the first counted record, or nil when the modem had no network time.
    public var startUtcMs: Int64?

    public init(events: [Event], procedures: [Procedure], journey: [Step], searched: [Cell],
                connections: [Connection], cellDetails: [CellDetail] = [], records: Int, undecoded: Int,
                crcErrors: Int, durationMs: Double, startUtcMs: Int64?) {
        self.events = events
        self.procedures = procedures
        self.journey = journey
        self.searched = searched
        self.connections = connections
        self.cellDetails = cellDetails
        self.records = records
        self.undecoded = undecoded
        self.crcErrors = crcErrors
        self.durationMs = durationMs
        self.startUtcMs = startUtcMs
    }

    public static let empty = Flow(events: [], procedures: [], journey: [], searched: [], connections: [],
                                   records: 0, undecoded: 0, crcErrors: 0, durationMs: 0, startUtcMs: nil)

    public var failures: Int { events.count { $0.isFailure } }

    /// The serving-cell record for a cell, when the capture logged one.
    public func cellInfo(for cell: Cell) -> ServingCellInfo? {
        cellDetails.first { $0.cell == cell }?.info
    }
}
