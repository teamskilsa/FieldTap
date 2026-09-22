// A small builder for identifier-free call flows, so each journey rule can be tested on the few messages that
// trigger it. Names and keys follow the Kotlin decoders (see callflow-golden.json).

import FTModel
@testable import FTJourney

struct SyntheticFlow {
    static let b66 = Cell(earfcn: 67_086, pci: 80)
    static let b12 = Cell(earfcn: 5_110, pci: 235)
    static let b2 = Cell(earfcn: 650, pci: 80)
    static let nr = Cell(earfcn: 174_770, pci: 80, nr: true)
    static let nrPending = Cell(earfcn: 0xFFFF_FFFF, pci: 0xFFFF, nr: true)

    var events: [Event] = []
    var procedures: [Procedure] = []
    var steps: [Step] = []
    var connections: [Connection] = []
    var durationMs: Double
    var plmn = "310-410"

    init(durationMs: Double = 10_000) { self.durationMs = durationMs }

    @discardableResult
    mutating func rrc(_ t: Double, _ key: String, _ name: String, cell: Cell, uplink: Bool = false,
                      channel: String? = nil, fields: [Field] = [], cause: Int? = nil) -> Int {
        let nr = cell.nr
        return add(Event(index: events.count, record: events.count + 1, logCode: nr ? 0xB821 : 0xB0C0, timestampRaw: 0,
                  sinceStartMs: t, layer: .RRC, rat: nr ? "nr" : "lte", uplink: uplink, key: key, name: name,
                  summary: nil, cell: cell, channel: channel ?? (uplink ? "UL-DCCH" : "DL-DCCH"), fields: fields,
                  cause: cause, causeName: nil, protection: nil, ciphered: false, pdu: []))
    }

    @discardableResult
    mutating func nas(_ t: Double, _ key: String, cell: Cell, uplink: Bool, fields: [Field] = [], summary: String? = nil,
                      cause: Int? = nil, causeName: String? = nil) -> Int {
        return add(Event(index: events.count, record: events.count + 1, logCode: uplink ? 0xB0ED : 0xB0EC, timestampRaw: 0,
                  sinceStartMs: t, layer: .NAS, rat: "lte", uplink: uplink, key: key, name: key, summary: summary,
                  cell: cell, channel: "EMM", fields: fields, cause: cause, causeName: causeName, protection: nil,
                  ciphered: false, pdu: []))
    }

    private mutating func add(_ e: Event) -> Int {
        events.append(e)
        return e.index
    }

    mutating func procedure(_ name: String, _ layer: Layer, _ first: Int, _ last: Int, _ outcome: Outcome = .SUCCEEDED,
                            refusal: String? = nil) {
        procedures.append(Procedure(name: name, layer: layer, detail: nil, first: first, last: last, outcome: outcome,
                                    durationMs: events[last].sinceStartMs - events[first].sinceStartMs, refusal: refusal))
    }

    mutating func step(_ move: Move, from: Cell?, to: Cell, event: Int) {
        steps.append(Step(move: move, from: from, to: to, event: event, sinceStartMs: events[event].sinceStartMs))
    }

    mutating func connection(_ first: Int, _ last: Int?, _ outcome: ConnectionOutcome) {
        connections.append(Connection(first: first, last: last, establishmentCause: "mo-Data", releaseCause: nil,
                                      outcome: outcome, startMs: events[first].sinceStartMs,
                                      endMs: outcome == .OPEN_AT_END || outcome == .NO_ANSWER ? nil
                                          : last.map { events[$0].sinceStartMs }))
    }

    /// Request, setup, complete on `cell`, starting at `t`: returns the request's index.
    @discardableResult
    mutating func setup(_ t: Double, on cell: Cell) -> Int {
        let request = rrc(t, "rrcConnectionRequest", "RRC Connection Request", cell: cell, uplink: true, channel: "UL-CCCH")
        rrc(t + 60, "rrcConnectionSetup", "RRC Connection Setup", cell: cell, channel: "DL-CCCH")
        let complete = rrc(t + 65, "rrcConnectionSetupComplete", "RRC Connection Setup Complete", cell: cell, uplink: true)
        procedure("RRC connection setup", .RRC, request, complete)
        return request
    }

    /// An EN-DC SCG add (D4 pending header, then the complete on the real cell) at `t`.
    mutating func scgAdd(_ t: Double, lte: Cell) {
        rrc(t, "rrcConnectionReconfiguration", "RRC Connection Reconfiguration", cell: lte)
        rrc(t + 2, "rrcReconfiguration", "RRC Reconfiguration", cell: Self.nrPending, channel: "RRCReconfiguration")
        rrc(t + 16, "rrcReconfigurationComplete", "RRC Reconfiguration Complete", cell: Self.nr, uplink: true,
            channel: "RRCReconfigurationComplete")
        rrc(t + 18, "rrcConnectionReconfigurationComplete", "RRC Connection Reconfiguration Complete", cell: lte, uplink: true)
    }

    var flow: Flow {
        Flow(events: events, procedures: procedures, journey: steps, searched: [], connections: connections,
             cellDetails: [CellDetail(cell: Self.b66, info: ServingCellInfo(pci: 80, downlinkEarfcn: 67_086, uplinkEarfcn: 132_622,
                                                                             band: 66, plmn: plmn, tac: 1, cellIdentity: nil,
                                                                             bandwidthMhz: 10))],
             records: events.count, undecoded: 0, crcErrors: 0, durationMs: durationMs, startUtcMs: nil)
    }

    func journey(phy: PhySummary = .empty) -> Journey {
        JourneyBuilder.build(flow: flow, phy: phy, facts: CaptureFacts(traceWindowMs: durationMs, logRecords: events.count,
                                                                       distinctCodes: 0, encrypted: .empty, profile: nil,
                                                                       triggerUtc: nil))
    }
}
