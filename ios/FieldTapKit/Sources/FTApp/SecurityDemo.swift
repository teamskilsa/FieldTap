import FTModel
import FTSecurity
import Foundation

/// A built-in, fully-synthetic Security capture for screenshots and previews of the Security screen, so a
/// flagged view can be shown without any capture-derived fixture. Everything here is invented (reserved test
/// PLMN space, invented PCIs/EARFCNs), mirroring the engine's `flaggedShowcase`. Plain logic only the DEBUG /
/// Harness launch hooks reach (via `-FTSecurityDemo`), dead-stripped from a Release app that never calls it.
public enum SecurityDemo {
    private static let cellA = Cell(earfcn: 100, pci: 11, nr: false)
    private static let cellB = Cell(earfcn: 200, pci: 22, nr: false)

    /// The demo capture for a token ("flagged" | "clean"); "flagged" for anything else.
    public static func analysis(_ token: String) -> CaptureAnalysis {
        token == "clean" ? clean() : flagged()
    }

    /// Cell A carries a null-cipher tell and an IMSI request in the clear, no authentication runs, a forced 2G
    /// downgrade follows, and an orphan LTE cell (B) is reached with no mobility context. A calm-but-suspicious
    /// multi-finding screen.
    static func flagged() -> CaptureAnalysis {
        var i = 0
        func ev(_ layer: Layer, _ name: String, key: String? = nil, tMs: Double, uplink: Bool = false,
                channel: String? = nil, fields: [Field] = [], cell: Cell?) -> Event {
            defer { i += 1 }
            return Event(index: i, record: 0, logCode: 0, timestampRaw: 0, sinceStartMs: tMs, layer: layer,
                         rat: "LTE", uplink: uplink, key: key ?? name, name: name, summary: nil, cell: cell,
                         channel: channel ?? (layer == .NAS ? "EMM" : "DL-DCCH"), fields: fields, cause: nil,
                         causeName: nil, protection: nil, ciphered: false, pdu: [])
        }
        let events = [
            ev(.RRC, "RRC Connection Setup", key: "rrcConnectionSetup", tMs: 500, channel: "DL-CCCH", cell: cellA),
            ev(.NAS, "Identity request", tMs: 900, fields: [Field(label: "Identity requested", value: "IMSI")], cell: cellA),
            ev(.NAS, "Identity response", tMs: 1100, uplink: true, cell: cellA),
            ev(.NAS, "Security mode command", tMs: 1500,
               fields: [Field(label: "Ciphering", value: "EEA0"), Field(label: "Integrity", value: "EIA0")], cell: cellA),
            ev(.NAS, "Attach accept", tMs: 2000, cell: cellA),
            ev(.RRC, "RRC Connection Release", key: "rrcConnectionRelease", tMs: 6000,
               fields: [Field(label: "Redirected to", value: "GERAN")], cell: cellA),
            ev(.RRC, "RRC Connection Setup", key: "rrcConnectionSetup", tMs: 11_000, channel: "DL-CCCH", cell: cellB),
        ]
        let connections = [
            Connection(first: 0, last: nil, establishmentCause: nil, releaseCause: nil, outcome: .RELEASED, startMs: 500, endMs: 6000),
            Connection(first: 6, last: nil, establishmentCause: nil, releaseCause: nil, outcome: .OPEN_AT_END, startMs: 11_000, endMs: nil),
        ]
        let steps = [Step(move: .FIRST_SEEN, from: nil, to: cellA, event: 0, sinceStartMs: 500)]
        let cells = [seg(cellA, startMs: 500, endMs: 6000, band: "B12"),
                     seg(cellB, startMs: 11_000, endMs: 14_000, band: "B66")]
        return assemble(name: "Security demo (flagged)", durationMs: 14_000, events: events,
                        connections: connections, steps: steps, cells: cells)
    }

    /// A legitimate LTE attach: integrity-protected request, an IMEISV identity request, an RRC Security Mode
    /// Command, one first-seen cell. Trusted, no findings.
    static func clean() -> CaptureAnalysis {
        var i = 0
        let ip = Protection(headerType: 1, mac: 1, sequence: 1)
        func ev(_ layer: Layer, _ name: String, key: String? = nil, tMs: Double, uplink: Bool = false,
                channel: String? = nil, fields: [Field] = [], protection: Protection? = nil, cell: Cell?) -> Event {
            defer { i += 1 }
            return Event(index: i, record: 0, logCode: 0, timestampRaw: 0, sinceStartMs: tMs, layer: layer,
                         rat: "LTE", uplink: uplink, key: key ?? name, name: name, summary: nil, cell: cell,
                         channel: channel ?? (layer == .NAS ? "EMM" : "DL-DCCH"), fields: fields, cause: nil,
                         causeName: nil, protection: protection, ciphered: false, pdu: [])
        }
        let events = [
            ev(.NAS, "Attach request", tMs: 300, uplink: true, protection: ip, cell: cellA),
            ev(.RRC, "RRC Connection Setup", key: "rrcConnectionSetup", tMs: 500, channel: "DL-CCCH", cell: cellA),
            ev(.NAS, "Identity request", tMs: 900, fields: [Field(label: "Identity requested", value: "IMEISV")], cell: cellA),
            ev(.RRC, "Security Mode Command", key: "securityModeCommand", tMs: 1500, cell: cellA),
            ev(.NAS, "Attach accept", tMs: 2000, cell: cellA),
        ]
        let connections = [Connection(first: 1, last: nil, establishmentCause: nil, releaseCause: nil,
                                      outcome: .OPEN_AT_END, startMs: 500, endMs: nil)]
        let steps = [Step(move: .FIRST_SEEN, from: nil, to: cellA, event: 0, sinceStartMs: 300)]
        let cells = [seg(cellA, startMs: 300, endMs: 12_000, band: "B12")]
        return assemble(name: "Security demo (clean)", durationMs: 12_000, events: events,
                        connections: connections, steps: steps, cells: cells)
    }

    private static func seg(_ cell: Cell, startMs: Double, endMs: Double, band: String) -> CellSegment {
        CellSegment(lane: .pcell, index: 0, cell: cell, band: band, dlMhz: nil, startMs: startMs, endMs: endMs, source: .rrc)
    }

    private static func assemble(name: String, durationMs: Double, events: [Event], connections: [Connection],
                                 steps: [Step], cells: [CellSegment]) -> CaptureAnalysis {
        let flow = Flow(events: events, procedures: [], journey: steps, searched: [], connections: connections,
                        cellDetails: [], records: events.count, undecoded: 0, crcErrors: 0, durationMs: durationMs,
                        startUtcMs: nil)
        var summary = CaptureSummary(id: demoId, importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                     sourceName: name, durationMs: durationMs)
        summary.digest = name
        let journey = Journey(durationMs: durationMs, states: [], registration: [], cells: cells, markers: [],
                              findings: [], tiles: [])
        var analysis = CaptureAnalysis(summary: summary, timeBase: .empty, flow: flow, phy: .empty, journey: journey)
        analysis.security = SecurityDetector.analyze(analysis)
        return analysis
    }

    /// A fixed id (no long digit runs, so screen reports pass the privacy gate).
    public static let demoId = UUID(uuid: (0x5E, 0xC0, 0x1D, 0x7A, 0x5E, 0xC0, 0x4D, 0x1E,
                                           0xAF, 0x1D, 0x5E, 0xC0, 0x1D, 0x7A, 0x5E, 0xC0))
}
