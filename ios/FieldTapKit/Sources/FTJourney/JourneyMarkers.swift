// The marker row: moves (J7), connection outcomes (J2), switch-off detach (J3), procedures (RRC setup, attach,
// detach), RRC releases, RACH (J10) and failures (J11). The NR leg's markers come from JourneyEnDc (J8).

import FTCore
import FTModel

enum JourneyMarkers {
    static func build(_ ctx: JourneyContext, endc: [Marker]) -> [Marker] {
        var markers: [Marker] = []
        markers += moves(ctx)
        markers += procedures(ctx)
        markers += releases(ctx)
        markers += ctx.radioOffs.map { off in
            Marker(id: "detachSwitchOff-\(off.detachEvent)", kind: .detachSwitchOff, tMs: off.detachMs,
                   event: off.detachEvent, from: ctx.events[off.detachEvent].cell, title: "Switched off",
                   detail: "Switch-off detach: the phone told the network it was powering its radio down.")
        }
        markers += rach(ctx)
        markers += endc
        markers += merged(problems(ctx))
        return uniqueIds(sorted(markers))
    }

    // MARK: - J7 moves

    static func moves(_ ctx: JourneyContext) -> [Marker] {
        let events = ctx.events
        var out: [Marker] = []
        for (n, step) in ctx.flow.journey.enumerated() {
            switch step.move {
            case .FIRST_SEEN:
                continue
            case .HANDOVER:
                // The command is the last handover RRCConnectionReconfiguration within 1 s before the arrival.
                let command = events.indices.last { i in
                    let e = events[i]
                    return e.isHandoverCommand && e.sinceStartMs <= step.sinceStartMs && e.sinceStartMs >= step.sinceStartMs - 1_000
                }
                let t = command.map { events[$0].sinceStartMs } ?? step.sinceStartMs
                let duration = command.flatMap { ctx.handoverProcedure(startingAt: $0)?.durationMs }
                    ?? (command == nil ? nil : step.sinceStartMs - t)
                out.append(Marker(id: "handover-\(command ?? step.event)", kind: .handover, tMs: t,
                                  arrivalMs: step.sinceStartMs, event: command ?? step.event, endEvent: step.event,
                                  from: step.from, to: step.to, durationMs: duration, inferred: command == nil,
                                  title: "Handover", detail: command == nil ? "no handover command logged within 1 s" : nil))
            case .RESELECTION:
                let reattach = isReattach(ctx, step: step, index: n)
                out.append(Marker(id: "\(reattach ? "reattach" : "reselection")-\(step.event)",
                                  kind: reattach ? .reattach : .reselection, tMs: step.sinceStartMs, event: step.event,
                                  from: step.from, to: step.to, title: reattach ? "Re-attach" : "Reselection",
                                  detail: reattach ? "Reselection, after switch-off detach" : "Idle-mode reselection"))
            case .REDIRECT:
                out.append(Marker(id: "redirect-\(step.event)", kind: .redirect, tMs: step.sinceStartMs, event: step.event,
                                  from: step.from, to: step.to, severity: .warning, title: "Redirect",
                                  detail: "The network released the connection and sent the phone to another cell."))
            case .REESTABLISHMENT:
                out.append(Marker(id: "reestablishment-\(step.event)", kind: .reestablishment, tMs: step.sinceStartMs,
                                  event: step.event, from: step.from, to: step.to, severity: .warning,
                                  title: "Re-establishment",
                                  detail: "The phone re-established its connection, usually after a radio link failure."))
            case .CELL_CHANGE:
                out.append(Marker(id: "cellChange-\(step.event)", kind: .cellChange, tMs: step.sinceStartMs,
                                  event: step.event, from: step.from, to: step.to, severity: .warning, title: "Cell change",
                                  detail: "Changed cell while connected without a logged handover."))
            }
        }
        return out
    }

    /// J7: a reselection is a re-attach when a switch-off radio off ended inside the gap before it and an
    /// Attach starts on the new cell before, or inside, the first connection after the radio came back.
    static func isReattach(_ ctx: JourneyContext, step: Step, index: Int) -> Bool {
        let previous = index > 0 ? ctx.flow.journey[index - 1].sinceStartMs : 0
        guard let off = ctx.radioOffs.last(where: { !$0.openAtEnd && $0.endMs >= previous && $0.endMs <= step.sinceStartMs + 0.000_5 })
        else { return false }
        let firstConnection = ctx.flow.connections.filter { $0.startMs >= off.endMs }.min { $0.startMs < $1.startMs }
        let limit = firstConnection.map { $0.endMs ?? ctx.endMs } ?? ctx.endMs
        return ctx.flow.procedures.contains { p in
            guard JourneyLanes.registering.contains(p.name), let t = ctx.time(p.first) else { return false }
            return t >= off.endMs && t <= limit && ctx.events[p.first].cell == step.to
        }
    }

    // MARK: - Procedures and releases

    static func procedures(_ ctx: JourneyContext) -> [Marker] {
        var out: [Marker] = []
        let switchOff = Set(ctx.radioOffs.map(\.detachEvent))
        for p in ctx.flow.procedures where p.outcome == .SUCCEEDED {
            guard let t = ctx.time(p.first) else { continue }
            switch p.name {
            case "RRC connection setup", "RRC setup":
                out.append(Marker(id: "rrcSetup-\(p.first)", kind: .rrcSetup, tMs: t, event: p.first, endEvent: p.last,
                                  durationMs: p.durationMs, title: "RRC setup", detail: p.detail.map(Redaction.scrub)))
            case "Attach", "Registration":
                out.append(Marker(id: "attach-\(p.first)", kind: .attach, tMs: t, event: p.first, endEvent: p.last,
                                  to: ctx.events[p.first].cell, durationMs: p.durationMs, title: p.name,
                                  detail: p.detail.map(Redaction.scrub)))
            case "Detach", "Deregistration":
                guard !switchOff.contains(p.first) else { continue }
                out.append(Marker(id: "detach-\(p.first)", kind: .detach, tMs: t, event: p.first, endEvent: p.last,
                                  from: ctx.events[p.first].cell, durationMs: p.durationMs, title: p.name,
                                  detail: p.detail.map(Redaction.scrub)))
            default:
                continue
            }
        }
        return out
    }

    static func releases(_ ctx: JourneyContext) -> [Marker] {
        ctx.events.enumerated().compactMap { i, e in
            guard JourneyContext.isRelease(e) else { return nil }
            return Marker(id: "rrcRelease-\(i)", kind: .rrcRelease, tMs: e.sinceStartMs, event: i, from: e.cell,
                          title: "RRC release", detail: e.summary.map { "Cause: \(Redaction.scrub($0))" })
        }
    }

    // MARK: - J10

    static func rach(_ ctx: JourneyContext) -> [Marker] {
        ctx.phy.rach.map { r in
            let metres = r.distanceM ?? Spectrum.lteTimingAdvanceMetres(r.ta).map { ($0 * 10).rounded() / 10 }
            return Marker(id: "rach-\(JourneyText.idTime(r.tMs))", kind: .rach, tMs: r.tMs, ta: r.ta, distanceM: metres,
                          title: "Random access",
                          detail: "Timing advance \(r.ta)" + (metres.map { ", about \(JourneyText.distance($0)) from the cell" } ?? ""))
        }
    }

    // MARK: - J2, J11

    /// Failure and warning markers, before merging duplicates at one event. Event failures come first so that,
    /// at equal severity, the merge keeps the most specific marker.
    static func problems(_ ctx: JourneyContext) -> [Marker] {
        let events = ctx.events
        var out: [Marker] = []
        for (i, e) in events.enumerated() where e.isFailure {
            let k = e.key.lowercased()
            let kind: MarkerKind =
                JourneyContext.isScgFailure(e) ? .scgFailure
                : k.contains("reject") ? (e.layer == .RRC ? .rrcReject : .registrationReject)
                : .procedureFailed
            out.append(Marker(id: "\(kind.rawValue)-\(i)", kind: kind, tMs: e.sinceStartMs, event: i, from: e.cell,
                              severity: .failure, title: e.name, detail: causeText(e)))
        }
        for p in ctx.flow.procedures where p.outcome != .SUCCEEDED {
            guard let t = ctx.time(p.first) else { continue }
            let failed = p.outcome == .FAILED
            out.append(Marker(id: "\(failed ? "procedureFailed" : "procedureUnanswered")-\(p.first)",
                              kind: failed ? .procedureFailed : .procedureUnanswered, tMs: t, event: p.first,
                              endEvent: p.last, from: events[p.first].cell, durationMs: failed ? p.durationMs : nil,
                              severity: failed ? .failure : .warning,
                              title: failed ? "\(p.name) failed" : "\(p.name): no answer",
                              detail: failed ? p.refusal.map(Redaction.scrub) : "Nothing answered this request in the capture."))
        }
        for c in ctx.flow.connections {
            switch c.outcome {
            case .LOST:
                let at = c.last ?? c.first
                out.append(Marker(id: "connectionLost-\(at)", kind: .connectionLost, tMs: c.endMs ?? events[at].sinceStartMs,
                                  event: at, from: events[at].cell, severity: .failure, title: "Connection lost",
                                  detail: "The phone was idle again with no release logged, typically a radio link failure."))
            case .REJECTED:
                let at = c.last ?? c.first
                out.append(Marker(id: "rrcReject-\(at)", kind: .rrcReject, tMs: events[at].sinceStartMs, event: at,
                                  from: events[at].cell, severity: .failure, title: "Connection rejected",
                                  detail: c.establishmentCause.map { "Requested for \($0)" }))
            case .NO_ANSWER:
                out.append(Marker(id: "noAnswer-\(c.first)", kind: .noAnswer, tMs: c.startMs, event: c.first,
                                  from: events[c.first].cell, severity: .warning, title: "Connection request not answered",
                                  detail: c.establishmentCause.map { "Requested for \($0)" }))
            case .RELEASED, .OPEN_AT_END:
                continue
            }
        }
        return out
    }

    /// J11: markers at one event merge, keeping the highest severity (the first one at a tie).
    static func merged(_ markers: [Marker]) -> [Marker] {
        var byEvent: [Int: Int] = [:]
        var out: [Marker] = []
        for m in markers {
            guard let e = m.event else { out.append(m); continue }
            if let k = byEvent[e] {
                if m.severity > out[k].severity { out[k] = m }
            } else {
                byEvent[e] = out.count
                out.append(m)
            }
        }
        return out
    }

    static func causeText(_ e: Event) -> String? {
        if let c = e.cause { return "#\(c)" + (e.causeName.map { " \($0)" } ?? "") }
        return e.summary.map(Redaction.scrub)
    }

    // MARK: - Order and ids

    /// Contract amendment: a stable sort by time, then kind rank (MarkerKind order), then event.
    static func sorted(_ markers: [Marker]) -> [Marker] {
        markers.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.tMs != y.tMs { return x.tMs < y.tMs }
            if rank(x.kind) != rank(y.kind) { return rank(x.kind) < rank(y.kind) }
            if (x.event ?? -1) != (y.event ?? -1) { return (x.event ?? -1) < (y.event ?? -1) }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func rank(_ kind: MarkerKind) -> Int { MarkerKind.allCases.firstIndex(of: kind) ?? MarkerKind.allCases.count }

    static func uniqueIds(_ markers: [Marker]) -> [Marker] {
        var seen: [String: Int] = [:]
        return markers.map { m in
            var m = m
            let n = seen[m.id, default: 0]
            seen[m.id] = n + 1
            if n > 0 { m.id += "-\(n + 1)" }
            return m
        }
    }
}
