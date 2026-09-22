// Rule J8: the EN-DC NR leg. The parity call flow has no SCG model, so the PSCell is read from the NR RRC
// messages logged inside an open LTE connection, and its end is inferred from what ends an SCG (v1 decodes
// no SCG release).

import FTCore
import FTModel

enum JourneyEnDc {
    struct Result {
        var pscells: [CellSegment] = []
        var markers: [Marker] = []
    }

    private struct Active {
        var cell: Cell
        var startMs: Double
        var addedMs: Double?
    }

    static func build(_ ctx: JourneyContext, pcells: [CellSegment]) -> Result {
        let events = ctx.events
        var result = Result()
        var active: Active?
        var lastMs = 0.0

        func close(at t: Double, inferred: Bool, reason: String, event: Int?) {
            guard let a = active else { return }
            result.pscells.append(JourneyLanes.segment(
                .pscell, index: result.pscells.count, cell: a.cell, mcc: ctx.mcc, startMs: a.startMs, endMs: max(t, a.startMs),
                addedMs: a.addedMs, endInferred: inferred, startReason: "SCG add", endReason: reason, source: .rrc))
            if inferred {
                result.markers.append(Marker(id: "scgRelease-\(event.map(String.init) ?? JourneyText.idTime(t))",
                                             kind: .scgRelease, tMs: t, event: event, from: a.cell, inferred: true,
                                             title: "NR leg released (inferred)", detail: reason))
            }
            active = nil
        }

        for (i, e) in events.enumerated() {
            if active != nil, let off = ctx.radioOffs.first(where: { $0.startMs > lastMs && $0.startMs <= e.sinceStartMs }) {
                close(at: off.startMs, inferred: true, reason: "radio off (switch-off detach, event \(off.detachEvent))",
                      event: off.detachEvent)
            }
            lastMs = e.sinceStartMs
            if active != nil, e.rat == "lte" {
                if e.isHandoverCommand {
                    close(at: e.sinceStartMs, inferred: true,
                          reason: "LTE handover command (event \(i)); NR release not in the decoded fields", event: i)
                } else if JourneyContext.isRelease(e) {
                    close(at: e.sinceStartMs, inferred: true, reason: "LTE RRC release (event \(i))", event: i)
                } else if JourneyContext.isReestablishmentRequest(e) {
                    close(at: e.sinceStartMs, inferred: true, reason: "RRC re-establishment request (event \(i))", event: i)
                }
            }
            if active != nil, JourneyContext.isScgFailure(e) {
                // Logged, not inferred: the failure marker itself comes from J11 (the event is a failure).
                close(at: e.sinceStartMs, inferred: false, reason: "SCG failure (event \(i))", event: i)
            }
            guard e.layer == .RRC, e.rat == "nr", !e.uplink, e.key.lowercased() == "rrcreconfiguration" else { continue }
            guard ctx.connection(at: e.sinceStartMs) != nil,
                  let pcell = pcells.first(where: { e.sinceStartMs >= $0.startMs && e.sinceStartMs <= $0.endMs }),
                  !pcell.cell.nr else { continue }

            let header = e.cell
            if let a = active, let h = header, !h.isPendingNr, h == a.cell {
                result.markers.append(Marker(id: "scgModify-\(i)", kind: .scgModify, tMs: e.sinceStartMs, event: i,
                                             to: a.cell, title: "NR leg modified"))
                continue
            }
            // An SCG add: the PSCell is the first NR RRC message on a real cell within 200 ms (usually the
            // NR RRCReconfigurationComplete, D4 pending header before it).
            let window = events.indices.dropFirst(i).prefix { events[$0].sinceStartMs <= e.sinceStartMs + 200 }
            let named = window.first { j in
                let x = events[j]
                return x.layer == .RRC && x.rat == "nr" && x.cell.map { !$0.isPendingNr } == true
            }
            let complete = window.first { j in
                events[j].rat == "nr" && events[j].key.lowercased() == "rrcreconfigurationcomplete"
            }
            guard let j = named, let cell = events[j].cell else {
                result.markers.append(Marker(id: "scgAdd-\(i)", kind: .scgAdd, tMs: e.sinceStartMs, event: i,
                                             title: "NR leg requested", detail: "no NR cell logged within 200 ms"))
                continue
            }
            if active != nil {
                close(at: e.sinceStartMs, inferred: true, reason: "SCG change (event \(i))", event: i)
            }
            let addedMs = ctx.time(complete ?? j)
            active = Active(cell: cell, startMs: e.sinceStartMs, addedMs: addedMs)
            result.markers.append(Marker(id: "scgAdd-\(i)", kind: .scgAdd, tMs: e.sinceStartMs, event: i,
                                         endEvent: complete ?? j, to: cell,
                                         durationMs: addedMs.map { $0 - e.sinceStartMs }, title: "NR leg added"))
        }
        if let a = active {
            result.pscells.append(JourneyLanes.segment(
                .pscell, index: result.pscells.count, cell: a.cell, mcc: ctx.mcc, startMs: a.startMs, endMs: ctx.endMs,
                addedMs: a.addedMs, openAtEnd: true, startReason: "SCG add", source: .rrc))
        }
        attributeNrPhy(ctx.phy.nrDlActivity, to: &result.pscells)
        return result
    }

    /// The NR DL PHY activity carries no cell (or, from the reference extractor, one it did not read from the
    /// record), so it is given to the PSCell it overlaps in time.
    static func attributeNrPhy(_ activity: CarrierActivity?, to pscells: inout [CellSegment]) {
        guard let a = activity else { return }
        for k in pscells.indices {
            let s = pscells[k]
            if let earfcn = a.earfcn, earfcn != s.cell.earfcn { continue }
            if let pci = a.pci, pci != s.cell.pci { continue }
            let nextStart = k + 1 < pscells.count ? pscells[k + 1].startMs : Double.infinity
            guard a.firstMs < nextStart, a.lastMs >= s.startMs else { continue }
            pscells[k].phyLastMs = min(a.lastMs, nextStart)
        }
    }
}
