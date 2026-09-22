// The journey strip's lanes (rules J2-J6, J9 in ios/Contract/CONTRACT.md): RRC state, registration, PCell and
// SCells. The NR leg (J8) is in JourneyEnDc.swift because it also makes markers.

import FTCore
import FTModel

enum JourneyLanes {
    // MARK: - J2-J4 state

    static func states(_ ctx: JourneyContext) -> [StateSegment] {
        let end = ctx.endMs
        var segs: [StateSegment]
        if let first = ctx.firstRrcMs {
            segs = [StateSegment(state: .unknown, startMs: 0, endMs: min(first, end)),
                    StateSegment(state: .idle, startMs: min(first, end), endMs: end)]
        } else {
            segs = [StateSegment(state: .unknown, startMs: 0, endMs: end)]
        }
        for (i, c) in ctx.flow.connections.enumerated() where c.established {
            let s = StateSegment(state: .connected, startMs: c.startMs, endMs: min(c.endMs ?? end, end),
                                 openAtEnd: c.endMs == nil || c.outcome == .OPEN_AT_END,
                                 source: "connection \(i) \(c.outcome.rawValue)")
            paint(&segs, s)
        }
        for off in ctx.radioOffs {
            var source = "switch-off detach (event \(off.detachEvent))"
            if let r = off.releaseEvent { source += " then release (event \(r))" }
            source += off.nextEvent.map { "; next cell heard (event \($0))" } ?? "; nothing heard after it"
            paint(&segs, StateSegment(state: .radioOff, startMs: off.startMs, endMs: off.endMs, openAtEnd: off.openAtEnd,
                                      source: source))
        }
        return merged(segs)
    }

    /// Lays `s` over the segments, cutting whatever it covers.
    static func paint(_ segs: inout [StateSegment], _ s: StateSegment) {
        guard s.endMs > s.startMs else { return }
        var out: [StateSegment] = []
        for x in segs {
            if x.endMs <= s.startMs || x.startMs >= s.endMs {
                out.append(x)
                continue
            }
            if x.startMs < s.startMs {
                var left = x
                left.endMs = s.startMs
                left.openAtEnd = false
                out.append(left)
            }
            if x.endMs > s.endMs {
                var right = x
                right.startMs = s.endMs
                out.append(right)
            }
        }
        out.append(s)
        segs = out.filter { $0.endMs - $0.startMs > 0.000_5 }.sorted { $0.startMs < $1.startMs }
    }

    /// Joins neighbouring unknown/idle pieces (connected spans from different connections stay apart).
    static func merged(_ segs: [StateSegment]) -> [StateSegment] {
        var out: [StateSegment] = []
        for s in segs {
            if var last = out.last, last.state == s.state, last.source == nil, s.source == nil,
               abs(last.endMs - s.startMs) < 0.000_5 {
                last.endMs = s.endMs
                last.openAtEnd = s.openAtEnd
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: - J5 registration

    static let assumedRegisteredFirst: Set<String> = ["Detach", "Tracking area update", "Service request", "Deregistration"]
    static let registering: Set<String> = ["Attach", "Registration"]

    static func registration(_ ctx: JourneyContext) -> [RegistrationSegment] {
        let events = ctx.events
        var transitions: [(t: Double, state: RegistrationState)] = []
        for e in events where e.layer == .NAS {
            let k = e.key.lowercased()
            if JourneyContext.isSwitchOffDetach(e) || k.contains("detach accept") || k.contains("deregistration accept")
                || k.contains("attach reject") || k.contains("registration reject") {
                transitions.append((e.sinceStartMs, .deregistered))
            }
        }
        for p in ctx.flow.procedures where p.layer == .NAS && registering.contains(p.name) && p.outcome == .SUCCEEDED {
            if let t = ctx.time(p.last) { transitions.append((t, .registered)) }
        }
        transitions.sort { $0.t < $1.t }

        let firstNas = ctx.flow.procedures.filter { $0.layer == .NAS }.min { $0.first < $1.first }
        let assumed = firstNas.map { assumedRegisteredFirst.contains($0.name) } ?? false
        var state: RegistrationState = assumed ? .registered : .unknown
        var isAssumed = assumed
        var start = 0.0
        var out: [RegistrationSegment] = []
        for (t, next) in transitions where next != state {
            let at = min(max(t, start), ctx.endMs)
            if at > start { out.append(RegistrationSegment(state: state, startMs: start, endMs: at, assumed: isAssumed)) }
            state = next
            isAssumed = false
            start = at
        }
        if ctx.endMs > start || out.isEmpty {
            out.append(RegistrationSegment(state: state, startMs: start, endMs: ctx.endMs, assumed: isAssumed))
        }
        return out
    }

    // MARK: - J6 PCell

    static func pcells(_ ctx: JourneyContext) -> [CellSegment] {
        let steps = ctx.flow.journey
        let events = ctx.events
        var out: [CellSegment] = []
        var previousEnd = 0.0
        for (n, step) in steps.enumerated() where !step.to.isPendingNr {
            let nextStepMs = n + 1 < steps.count ? steps[n + 1].sinceStartMs : nil
            let limit = min(nextStepMs ?? ctx.endMs, ctx.endMs)
            // J6: the earlier of the step and the first RRC message on the new cell since the last segment ended.
            let firstHere = events.first { $0.layer == .RRC && $0.cell == step.to && $0.sinceStartMs >= previousEnd }
            var start = min(step.sinceStartMs, firstHere?.sinceStartMs ?? step.sinceStartMs)
            var startReason: String?
            if let e = firstHere, e.sinceStartMs < step.sinceStartMs - 0.000_5 {
                startReason = "first message on the cell (\(shortName(e)))"
            }
            if let off = ctx.radioOffs.first(where: { $0.contains(start) }) {
                start = off.endMs
                startReason = "back after radio off"
            }
            var pieces: [(start: Double, end: Double, startReason: String?, endReason: String?, open: Bool)] = []
            var cursor = start
            var reason = startReason
            while cursor < limit {
                if let off = ctx.radioOffs.first(where: { $0.startMs >= cursor && $0.startMs < limit }) {
                    pieces.append((cursor, off.startMs, reason, "radioOff", false))
                    // The same cell again after the radio came back, if that is where it came back.
                    guard off.endMs < limit, let back = off.nextEvent, events[back].cell == step.to else { break }
                    cursor = off.endMs
                    reason = "back after radio off"
                } else {
                    pieces.append((cursor, limit, reason, nil, nextStepMs == nil))
                    break
                }
            }
            for p in pieces where p.end > p.start {
                out.append(segment(.pcell, index: out.count, cell: step.to, mcc: ctx.mcc, startMs: p.start, endMs: p.end,
                                   openAtEnd: p.open, startReason: p.startReason, endReason: p.endReason, source: .rrc))
            }
            previousEnd = pieces.last?.end ?? limit
        }
        return out
    }

    /// "SIB1", "SI", "MIB" for the broadcast messages; otherwise the event's name.
    static func shortName(_ e: Event) -> String {
        switch e.key {
        case "systemInformationBlockType1": "SIB1"
        case "systemInformation": "SI"
        case "mib", "masterInformationBlock": "MIB"
        default: e.name
        }
    }

    // MARK: - J9 SCells

    static func scells(_ ctx: JourneyContext) -> [CellSegment] {
        ctx.phy.scellActivity.sorted { $0.index < $1.index }.compactMap { a in
            guard let earfcn = a.earfcn else { return nil }
            return segment(.scell, index: a.index, cell: Cell(earfcn: earfcn, pci: a.pci ?? -1), mcc: ctx.mcc,
                           startMs: a.firstMs, endMs: max(a.lastMs, a.firstMs), startReason: "first PHY record",
                           endReason: "last PHY record", source: .phy)
        }
    }

    // MARK: - Segments

    static func segment(_ lane: LaneKind, index: Int, cell: Cell, mcc: Int?, startMs: Double, endMs: Double,
                        addedMs: Double? = nil, openAtEnd: Bool = false, endInferred: Bool = false,
                        startReason: String? = nil, endReason: String? = nil, source: EvidenceSource,
                        phyLastMs: Double? = nil) -> CellSegment {
        let band: String?
        let candidates: [Int]
        let mhz: Double?
        if cell.nr {
            band = nil
            candidates = NrBands.candidates(arfcn: cell.earfcn, mcc: mcc)
            mhz = NrBands.dlMhz(arfcn: cell.earfcn)
        } else {
            let carrier = Spectrum.lte(cell.earfcn)
            band = carrier.map { "B\($0.band)" }
            candidates = []
            mhz = carrier?.dlMhz
        }
        return CellSegment(lane: lane, index: index, cell: cell, band: band, bandCandidates: candidates, dlMhz: mhz,
                           startMs: startMs, endMs: endMs, addedMs: addedMs, openAtEnd: openAtEnd,
                           endInferred: endInferred, startReason: startReason, endReason: endReason, source: source,
                           phyLastMs: phyLastMs)
    }
}
