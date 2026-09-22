// The comparator for journey-expected.json, whose schema is not the Codable Journey (critique): cells are
// [earfcn, pci] pairs, the PSCell says "arfcn", markers carry "completeEvent" and "stepMove", findings are
// category names that repeat, and tiles are pairs or plain counts. Only keys present in the fixture are
// compared. Tolerance: 1 ms for event-derived times, 100 ms for PHY-derived ones (SCells, RACH, NR PHY end).

import Foundation
import FTModel
@testable import FTJourney

struct JourneyExpectation: Decodable {
    struct State: Decodable {
        var state: String
        var startMs: Double
        var endMs: Double
        var source: String?
        var openAtEnd: Bool?
    }

    struct Registration: Decodable {
        var state: String
        var startMs: Double
        var endMs: Double
        var assumed: Bool?
    }

    struct Segment: Decodable {
        var index: Int?
        var earfcn: Int64?
        var arfcn: Int64?
        var pci: Int
        var band: String?
        var bandCandidates: [Int]?
        var dlMhz: Double?
        var startMs: Double
        var addedMs: Double?
        var endMs: Double
        var endInferred: Bool?
        var openAtEnd: Bool?
        var startReason: String?
        var endReason: String?
        var phyLastMs: Double?
        var source: String?
    }

    struct Lanes: Decodable {
        var state: [State]
        var registration: [Registration]
        var pcell: [Segment]
        var pscell: [Segment]
        var scell: [Segment]
    }

    struct MarkerRow: Decodable {
        var kind: String
        var tMs: Double
        var event: Int?
        var endEvent: Int?
        var completeEvent: Int?
        var arrivalMs: Double?
        var stepMove: String?
        var from: [Int64]?
        var to: [Int64]?
        var durationMs: Double?
        var ta: Int?
        var distanceM: Double?
        var inferred: Bool?
        var severity: String
    }

    /// A tile is [succeeded, attempts] or a single count.
    enum TileValue: Decodable {
        case pair(Int, Int)
        case count(Int)

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) {
                self = .count(n)
            } else {
                let p = try c.decode([Int].self)
                self = .pair(p[0], p.count > 1 ? p[1] : p[0])
            }
        }
    }

    var durationMs: Double
    var lanes: Lanes
    var markers: [MarkerRow]
    var failureMarkers: Int
    var findings: [String]
    var tiles: [String: TileValue]

    /// The fixture's finding categories, as FindingKind.
    static let findingKinds: [String: FindingKind] = [
        "radioOffOn": .switchedOff, "reattach": .reattach, "attach": .attach, "registration": .attach,
        "imsPdn": .pdnConnected, "endcAdded": .scgAdded, "handover": .handover,
        "carrierAggregation": .carrierAggregation, "failure": .failure, "noFailures": .noFailures,
        "encryptedRecords": .encryptedRecords, "traceWindow": .traceWindow,
    ]

    static let eventTolerance = 1.0
    static let phyTolerance = 100.0

    /// Every difference between `journey` and this expectation, as readable paths; empty means equal.
    func differences(_ journey: Journey, flow: Flow) -> [String] {
        var out: [String] = []
        func near(_ path: String, _ got: Double?, _ want: Double?, _ tol: Double = Self.eventTolerance) {
            guard let want else { return }
            guard let got else { out.append("\(path): missing, want \(want)"); return }
            if abs(got - want) > tol { out.append("\(path): \(got) != \(want)") }
        }
        func same<T: Equatable>(_ path: String, _ got: T?, _ want: T?) {
            guard let want else { return }
            if got != want { out.append("\(path): \(String(describing: got)) != \(want)") }
        }

        near("durationMs", journey.durationMs, durationMs)

        // Lanes.
        if journey.states.count != lanes.state.count {
            out.append("states.length: \(journey.states.count) != \(lanes.state.count)")
        }
        for (i, (g, w)) in zip(journey.states, lanes.state).enumerated() {
            same("states[\(i)].state", g.state.rawValue, w.state)
            near("states[\(i)].startMs", g.startMs, w.startMs)
            near("states[\(i)].endMs", g.endMs, w.endMs)
            same("states[\(i)].source", g.source, w.source)
            same("states[\(i)].openAtEnd", g.openAtEnd, w.openAtEnd)
        }
        if journey.registration.count != lanes.registration.count {
            out.append("registration.length: \(journey.registration.count) != \(lanes.registration.count)")
        }
        for (i, (g, w)) in zip(journey.registration, lanes.registration).enumerated() {
            same("registration[\(i)].state", g.state.rawValue, w.state)
            near("registration[\(i)].startMs", g.startMs, w.startMs)
            near("registration[\(i)].endMs", g.endMs, w.endMs)
            same("registration[\(i)].assumed", g.assumed, w.assumed)
        }
        for (lane, want, tol) in [(LaneKind.pcell, lanes.pcell, Self.eventTolerance), (.pscell, lanes.pscell, Self.eventTolerance),
                                  (.scell, lanes.scell, Self.phyTolerance)] {
            let got = journey.cells.filter { $0.lane == lane }
            if got.count != want.count { out.append("\(lane.rawValue).length: \(got.count) != \(want.count)") }
            for (i, (g, w)) in zip(got, want).enumerated() {
                let p = "\(lane.rawValue)[\(i)]"
                same("\(p).index", g.index, w.index)
                same("\(p).earfcn", g.cell.earfcn, w.earfcn ?? w.arfcn)
                same("\(p).pci", g.cell.pci, w.pci)
                same("\(p).band", g.band, w.band)
                same("\(p).bandCandidates", g.bandCandidates, w.bandCandidates)
                near("\(p).dlMhz", g.dlMhz, w.dlMhz, 0.001)
                near("\(p).startMs", g.startMs, w.startMs, tol)
                near("\(p).endMs", g.endMs, w.endMs, tol)
                near("\(p).addedMs", g.addedMs, w.addedMs)
                same("\(p).endInferred", g.endInferred, w.endInferred)
                same("\(p).openAtEnd", g.openAtEnd, w.openAtEnd)
                same("\(p).startReason", g.startReason, w.startReason)
                same("\(p).endReason", g.endReason, w.endReason)
                near("\(p).phyLastMs", g.phyLastMs, w.phyLastMs, Self.phyTolerance)
                if let s = w.source { same("\(p).source", g.source, s.hasPrefix("PHY") ? .phy : s.hasPrefix("RRC") ? .rrc : .inferred) }
            }
        }

        // Markers, in the contract order (stable by time, then kind rank).
        let want = sortedMarkers()
        if journey.markers.count != want.count { out.append("markers.length: \(journey.markers.count) != \(want.count)") }
        for (i, (g, w)) in zip(journey.markers, want).enumerated() {
            let p = "markers[\(i)] (\(w.kind))"
            same("\(p).kind", g.kind.rawValue, w.kind)
            let phy = w.kind == "rach"
            near("\(p).tMs", g.tMs, w.tMs, phy ? Self.phyTolerance : Self.eventTolerance)
            same("\(p).event", g.event, w.event)
            same("\(p).endEvent", g.endEvent, w.endEvent ?? w.completeEvent)
            near("\(p).arrivalMs", g.arrivalMs, w.arrivalMs)
            near("\(p).durationMs", g.durationMs, w.durationMs)
            same("\(p).ta", g.ta, w.ta)
            near("\(p).distanceM", g.distanceM, w.distanceM, 0.05)
            same("\(p).inferred", g.inferred, w.inferred)
            same("\(p).severity", g.severity.rawValue, w.severity)
            same("\(p).from", g.from.map { [$0.earfcn, Int64($0.pci)] }, w.from)
            same("\(p).to", g.to.map { [$0.earfcn, Int64($0.pci)] }, w.to)
            if let move = w.stepMove {
                let ok = flow.journey.contains { $0.move.rawValue == move && $0.event == g.event }
                if !ok { out.append("\(p).stepMove: no \(move) step at event \(String(describing: g.event))") }
            }
        }
        let failures = journey.markers.filter { $0.severity == .failure }.count
        if failures != failureMarkers { out.append("failureMarkers: \(failures) != \(failureMarkers)") }

        // Findings, as categories in order.
        let kinds = findings.map { Self.findingKinds[$0] }
        if kinds.contains(where: { $0 == nil }) { out.append("findings: unknown category in \(findings)") }
        let gotKinds = journey.findings.map(\.kind)
        if gotKinds != kinds.compactMap({ $0 }) {
            out.append("findings: \(gotKinds.map(\.rawValue)) != \(findings)")
        }

        // Tiles.
        var wantIds = Set<String>()
        for (name, value) in tiles {
            let id = name == "proceduresAnswered" ? "procedures" : name
            wantIds.insert(id)
            guard let t = journey.tiles.first(where: { $0.id == id }) else { out.append("tiles.\(name): missing"); continue }
            switch value {
            case .pair(let s, let a):
                if t.succeeded != s || t.attempts != a { out.append("tiles.\(name): \(t.succeeded)/\(t.attempts) != \(s)/\(a)") }
            case .count(let n):
                let got = name == "procedures" ? t.attempts : t.succeeded
                if got != n { out.append("tiles.\(name): \(got) != \(n)") }
            }
        }
        let extra = Set(journey.tiles.map(\.id)).subtracting(wantIds)
        if !extra.isEmpty { out.append("tiles: not in the fixture \(extra.sorted())") }
        return out
    }

    /// The fixture's markers in the contract order: a stable sort by tMs, then MarkerKind rank.
    func sortedMarkers() -> [MarkerRow] {
        let rank = { (k: String) in MarkerKind(rawValue: k).map(JourneyMarkers.rank) ?? Int.max }
        return markers.enumerated().sorted { a, b in
            if a.element.tMs != b.element.tMs { return a.element.tMs < b.element.tMs }
            if rank(a.element.kind) != rank(b.element.kind) { return rank(a.element.kind) < rank(b.element.kind) }
            return a.offset < b.offset
        }.map(\.element)
    }
}
