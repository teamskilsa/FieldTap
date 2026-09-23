// Synthetic CaptureAnalysis inputs for the security check, a Swift port of
// web/engine/tests/security_support.ts. Everything here is invented — reserved test PLMN 001-01, invented
// PCIs/EARFCNs, a hand-built call flow — so it carries no capture-derived data. Each fixture carries exactly one
// IMSI-catcher signature (plus one clean control), so a test can assert the matching check fires and the others
// stay silent. The engine serialises `analyzeSecurity()` of the same inputs into tests/security/golden/*.json,
// which this port must reproduce byte for byte (via GoldenCodec.jsonDiff).

import FTModel
import FTSecurity

/// The decoded pieces the security check reads, and its report over them.
struct SyntheticCapture {
    var events: [Event] = []
    var steps: [Step] = []
    var connections: [Connection] = []
    var cellDetails: [CellDetail] = []
    var journeyCells: [CellSegment] = []
    var phy: [PhyMetric: PhySeries] = [:]
    var phySummary: PhySummary = .empty

    var report: SecurityReport {
        SecurityDetector.report(events: events, steps: steps, connections: connections, cellDetails: cellDetails,
                                journeyCells: journeyCells, phy: phy, phySummary: phySummary)
    }
}

enum SecurityFixtures {
    static let anchor = Cell(earfcn: 100, pci: 11, nr: false)   // A: first-seen cell
    static let second = Cell(earfcn: 200, pci: 22, nr: false)   // B: a second LTE cell

    /// The NAS security-protected-copy header a legitimate context-reuse carries (type 1 = "integrity protected").
    static let integrityProtected = Protection(headerType: 1, mac: 1, sequence: 1)

    /// A field.
    static func field(_ label: String, _ value: String, _ children: [Field] = []) -> Field {
        Field(label: label, value: value, children: children)
    }

    /// The engine's `ev()`: a minimal Event with the index/time/channel defaults it uses.
    final class Seq {
        private var next = 0

        func ev(layer: Layer, name: String, key: String? = nil, index: Int? = nil, sinceStartMs: Double? = nil,
                rat: String = "LTE", uplink: Bool = false, channel: String? = nil, fields: [Field] = [],
                cell: Cell? = nil, cause: Int? = nil, causeName: String? = nil, protection: Protection? = nil) -> Event {
            let i = index ?? next
            if index == nil { next += 1 }
            return Event(index: i, record: 0, logCode: 0, timestampRaw: 0, sinceStartMs: sinceStartMs ?? Double(i) * 100,
                         layer: layer, rat: rat, uplink: uplink, key: key ?? name, name: name, summary: nil,
                         cell: cell, channel: channel ?? (layer == .NAS ? "EMM" : "DL-DCCH"), fields: fields,
                         cause: cause, causeName: causeName, protection: protection, ciphered: false, pdu: [])
        }
    }

    static func journeyCell(_ cell: Cell, startMs: Double, band: String) -> CellSegment {
        CellSegment(lane: .pcell, index: 0, cell: cell, band: band, dlMhz: nil, startMs: startMs,
                    endMs: startMs + 5000, source: .rrc)
    }

    static func rsrpSeries(_ values: [Double]) -> PhySeries {
        let samples = values.enumerated().map { i, v in
            PhySample(tMs: Double(i) * 100, value: v, earfcn: 100, pci: 11, carrier: 0)
        }
        return PhySeries(metric: .lte_rsrp, unit: "dBm", code: 0, version: "", confidence: .high, samples: samples)
    }

    // MARK: the fixtures, keyed by golden file name

    /// A legitimate LTE attach: integrity-protected request, an IMEISV identity request, an RRC Security Mode
    /// Command, ordinary signal, one first-seen cell. Every check must stay silent.
    static func clean() -> SyntheticCapture {
        let s = Seq()
        let A = anchor
        let events = [
            s.ev(layer: .NAS, name: "Attach request", uplink: true, cell: A, protection: integrityProtected),
            s.ev(layer: .RRC, name: "RRC Connection Request", key: "rrcConnectionRequest", uplink: true, channel: "UL-CCCH", cell: A),
            s.ev(layer: .RRC, name: "RRC Connection Setup", key: "rrcConnectionSetup", channel: "DL-CCCH", cell: A),
            s.ev(layer: .NAS, name: "Identity request", fields: [field("Identity requested", "IMEISV")], cell: A),
            s.ev(layer: .NAS, name: "Identity response", uplink: true, cell: A),
            s.ev(layer: .RRC, name: "Security Mode Command", key: "securityModeCommand", cell: A),
            s.ev(layer: .RRC, name: "Security Mode Complete", key: "securityModeComplete", uplink: true, cell: A),
            s.ev(layer: .NAS, name: "Attach accept", cell: A),
        ]
        return SyntheticCapture(
            events: events,
            steps: [Step(move: .FIRST_SEEN, from: nil, to: A, event: 0, sinceStartMs: 0)],
            connections: [Connection(first: 1, last: nil, establishmentCause: nil, releaseCause: nil,
                                     outcome: .OPEN_AT_END, startMs: 100, endMs: nil)],
            journeyCells: [journeyCell(A, startMs: 0, band: "B12")],
            phy: [.lte_rsrp: rsrpSeries([-95, -96, -94, -97, -95, -96, -98, -95])])
    }

    static func nullCipher() -> SyntheticCapture {
        let s = Seq()
        let A = anchor
        let events = [
            s.ev(layer: .NAS, name: "Attach request", uplink: true, cell: A, protection: integrityProtected),
            s.ev(layer: .NAS, name: "Security mode command",
                 fields: [field("Ciphering", "EEA0"), field("Integrity", "EIA0")], cell: A),
            s.ev(layer: .NAS, name: "Attach accept", cell: A),
        ]
        return SyntheticCapture(events: events, steps: [Step(move: .FIRST_SEEN, from: nil, to: A, event: 0, sinceStartMs: 0)],
                                journeyCells: [journeyCell(A, startMs: 0, band: "B12")])
    }

    static func imsiInClear() -> SyntheticCapture {
        let s = Seq()
        let A = anchor
        let events = [
            s.ev(layer: .RRC, name: "RRC Connection Setup", key: "rrcConnectionSetup", channel: "DL-CCCH", cell: A),
            s.ev(layer: .NAS, name: "Identity request", fields: [field("Identity requested", "IMSI")], cell: A),
            s.ev(layer: .NAS, name: "Identity response", uplink: true, cell: A),
            s.ev(layer: .RRC, name: "Security Mode Command", key: "securityModeCommand", cell: A),
        ]
        return SyntheticCapture(events: events, steps: [Step(move: .FIRST_SEEN, from: nil, to: A, event: 0, sinceStartMs: 0)],
                                journeyCells: [journeyCell(A, startMs: 0, band: "B12")])
    }

    static func downgrade2g() -> SyntheticCapture {
        let s = Seq()
        let A = anchor
        let events = [
            s.ev(layer: .RRC, name: "Security Mode Command", key: "securityModeCommand", cell: A),
            s.ev(layer: .RRC, name: "RRC Connection Release", key: "rrcConnectionRelease",
                 fields: [field("Redirected to", "GERAN")], cell: A),
        ]
        return SyntheticCapture(events: events, steps: [Step(move: .FIRST_SEEN, from: nil, to: A, event: 0, sinceStartMs: 0)],
                                journeyCells: [journeyCell(A, startMs: 0, band: "B12")])
    }

    /// Plain (not integrity-protected) attach request, an SMC is present, an accept, and NO authentication.
    static func acceptedWithoutAuth() -> SyntheticCapture {
        let s = Seq()
        let A = anchor
        let events = [
            s.ev(layer: .NAS, name: "Attach request", uplink: true, cell: A),
            s.ev(layer: .RRC, name: "Security Mode Command", key: "securityModeCommand", cell: A),
            s.ev(layer: .NAS, name: "Attach accept", cell: A),
        ]
        return SyntheticCapture(events: events, steps: [Step(move: .FIRST_SEEN, from: nil, to: A, event: 0, sinceStartMs: 0)],
                                journeyCells: [journeyCell(A, startMs: 0, band: "B12")])
    }

    /// Authentication runs (so acceptedWithoutAuth stays silent) and the request is integrity protected, but no
    /// Security Mode Command is ever seen: isolates noSecurityEstablished.
    static func noSecurityEstablished() -> SyntheticCapture {
        let s = Seq()
        let A = anchor
        let events = [
            s.ev(layer: .NAS, name: "Attach request", uplink: true, cell: A, protection: integrityProtected),
            s.ev(layer: .NAS, name: "Authentication request", cell: A),
            s.ev(layer: .NAS, name: "Authentication response", uplink: true, cell: A),
            s.ev(layer: .NAS, name: "Attach accept", cell: A),
        ]
        return SyntheticCapture(events: events, steps: [Step(move: .FIRST_SEEN, from: nil, to: A, event: 0, sinceStartMs: 0)],
                                journeyCells: [journeyCell(A, startMs: 0, band: "B12")])
    }

    static func abnormalReject() -> SyntheticCapture {
        let s = Seq()
        let A = anchor
        let events = [
            s.ev(layer: .RRC, name: "Security Mode Command", key: "securityModeCommand", cell: A),
            s.ev(layer: .NAS, name: "Attach reject", cell: A, cause: 3, causeName: "Illegal UE"),
        ]
        return SyntheticCapture(events: events, steps: [Step(move: .FIRST_SEEN, from: nil, to: A, event: 0, sinceStartMs: 0)],
                                journeyCells: [journeyCell(A, startMs: 0, band: "B12")])
    }

    static func implausibleSignal() -> SyntheticCapture {
        let s = Seq()
        let A = anchor
        let events = [s.ev(layer: .RRC, name: "Security Mode Command", key: "securityModeCommand", cell: A)]
        return SyntheticCapture(events: events, steps: [Step(move: .FIRST_SEEN, from: nil, to: A, event: 0, sinceStartMs: 0)],
                                journeyCells: [journeyCell(A, startMs: 0, band: "B12")],
                                phy: [.lte_rsrp: rsrpSeries([-42, -40, -41, -39, -43, -40, -38, -41])])
    }

    /// Two LTE serving cells: A is the anchor (first-seen). B appears later with no handover/reselection step
    /// into it, is in no neighbour measurement, and the phone opens a connection on it.
    static func orphanCell() -> SyntheticCapture {
        let s = Seq()
        let A = anchor
        let B = second
        let events = [
            s.ev(layer: .RRC, name: "Security Mode Command", key: "securityModeCommand", cell: A),
            s.ev(layer: .RRC, name: "RRC Connection Setup", key: "rrcConnectionSetup", sinceStartMs: 9000, channel: "DL-CCCH", cell: B),
        ]
        return SyntheticCapture(
            events: events,
            steps: [Step(move: .FIRST_SEEN, from: nil, to: A, event: 0, sinceStartMs: 0)],
            connections: [
                Connection(first: 0, last: nil, establishmentCause: nil, releaseCause: nil, outcome: .RELEASED, startMs: 0, endMs: 5000),
                Connection(first: 1, last: nil, establishmentCause: nil, releaseCause: nil, outcome: .OPEN_AT_END, startMs: 9000, endMs: nil),
            ],
            journeyCells: [journeyCell(A, startMs: 0, band: "B12"), journeyCell(B, startMs: 9000, band: "B66")])
    }

    /// Every synthetic fixture's golden file name, in the engine's order.
    static let names: [String] = [
        "clean", "null-cipher", "imsi-in-clear", "downgrade-2g", "accepted-without-auth",
        "no-security-established", "abnormal-reject", "implausible-signal", "orphan-cell",
    ]

    /// The synthetic input for one golden name.
    static func make(_ name: String) -> SyntheticCapture {
        switch name {
        case "clean": clean()
        case "null-cipher": nullCipher()
        case "imsi-in-clear": imsiInClear()
        case "downgrade-2g": downgrade2g()
        case "accepted-without-auth": acceptedWithoutAuth()
        case "no-security-established": noSecurityEstablished()
        case "abnormal-reject": abnormalReject()
        case "implausible-signal": implausibleSignal()
        case "orphan-cell": orphanCell()
        default: SyntheticCapture()
        }
    }
}
