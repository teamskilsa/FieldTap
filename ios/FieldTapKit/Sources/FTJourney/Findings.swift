// "What happened" (rule J12): a handful of sentences, each tied to the moment it describes, ordered by time,
// then the fixed tail: the problems (or "no failures"), the encrypted records, the trace window.

import FTCore
import FTModel

public enum Findings {
    public static func of(flow: Flow, journey: Journey, facts: CaptureFacts) -> [Finding] {
        var timed: [Finding] = []
        let markers = journey.markers
        let states = journey.states

        // Switched off, and when the radio came back.
        for m in markers where m.kind == .detachSwitchOff {
            let off = states.first { $0.state == .radioOff && $0.startMs >= m.tMs - 0.5 && $0.startMs <= m.tMs + 2_000.5 }
            let on = pcell(at: m.tMs, journey).map { " on \(JourneyText.shortCell($0))" } ?? ""
            let text: String
            if let off, !off.openAtEnd {
                text = "Switched off (switch-off detach)\(on) at \(JourneyText.clock(m.tMs)); radio back "
                    + "\(JourneyText.seconds(off.endMs - off.startMs)) later."
            } else {
                text = "Switched off at the end: switch-off detach\(on) at \(JourneyText.clock(m.tMs))."
            }
            timed.append(Finding(id: "switchedOff-\(m.event ?? 0)", kind: .switchedOff, severity: .info, text: text,
                                 tMs: m.tMs, event: m.event))
        }

        // Attach / registration, and whether it was a re-attach after the switch-off.
        let reattachCells = Set(markers.filter { $0.kind == .reattach }.compactMap(\.to))
        for m in markers where m.kind == .attach {
            let seg = m.to.flatMap { c in journey.cells.first { $0.lane == .pcell && $0.cell == c && $0.endMs >= m.tMs } }
            let place = seg.map { " on \(JourneyText.shortCell($0)) (\(JourneyText.channelName($0.cell)) \($0.cell.earfcn))" } ?? ""
            let took = m.durationMs.map { " in \(JourneyText.duration($0))" } ?? ""
            let re = m.to.map { reattachCells.contains($0) } ?? false
            let verb = m.title == "Registration" ? (re ? "Re-registered" : "Registered") : (re ? "Re-attached" : "Attached")
            timed.append(Finding(id: "\(re ? "reattach" : "attach")-\(m.event ?? 0)", kind: re ? .reattach : .attach,
                                 severity: .info, text: "\(verb)\(place)\(took).", tMs: m.tMs, event: m.event))
        }

        // PDN connections beyond the attach's default bearer (the IMS one, on this capture).
        for p in flow.procedures where p.outcome == .SUCCEEDED
            && (p.name == "PDN connectivity" || p.name.hasPrefix("PDU session")) {
            guard flow.events.indices.contains(p.first) else { continue }
            let apn = p.detail.map(Redaction.scrub)
            let ims = apn?.lowercased().hasPrefix("ims") == true
            let what = p.name == "PDN connectivity" ? "PDN connected" : "PDU session established"
            let text = ims ? "IMS \(what) in \(JourneyText.duration(p.durationMs))."
                : "\(what.prefix(1).uppercased() + what.dropFirst())\(apn.map { " (\($0))" } ?? "") in \(JourneyText.duration(p.durationMs))."
            timed.append(Finding(id: "pdnConnected-\(p.first)", kind: .pdnConnected, severity: .info, text: text,
                                 tMs: flow.events[p.first].sinceStartMs, event: p.first))
        }

        // The NR leg, and whether NR data outlived its inferred end.
        for s in journey.cells where s.lane == .pscell {
            let add = markers.first { $0.kind == .scgAdd && abs($0.tMs - s.startMs) < 0.5 }
            timed.append(Finding(id: "scgAdded-\(add?.event ?? Int(s.startMs))", kind: .scgAdded, severity: .info,
                                 text: "5G NR leg added at \(JourneyText.clock(s.startMs)) (NR-ARFCN \(s.cell.earfcn), "
                                     + "PCI \(s.cell.pci), \(JourneyText.band(s))).",
                                 tMs: s.startMs, event: add?.event))
            if s.endInferred, let last = s.phyLastMs, last > s.endMs + 500 {
                timed.append(Finding(id: "scgPhyOutlived-\(Int(s.endMs))", kind: .scgPhyOutlived, severity: .warning,
                                     text: "NR data continued \(JourneyText.seconds(last - s.endMs)) after the NR leg's "
                                         + "inferred end at \(JourneyText.clock(s.endMs)).",
                                     tMs: s.endMs, event: nil))
            }
        }

        // Moves.
        for m in markers where m.kind == .handover || m.kind == .reselection {
            let title = JourneyText.markerTitle(m, journey: journey)
            let took = m.durationMs.map { " in \(JourneyText.duration($0))" } ?? ""
            let text = m.kind == .handover ? "\(title)\(took)." : "\(title) (idle) at \(JourneyText.clock(m.tMs))."
            timed.append(Finding(id: "\(m.kind == .handover ? "handover" : "reselection")-\(m.event ?? Int(m.tMs))",
                                 kind: m.kind == .handover ? .handover : .other, severity: .info, text: text, tMs: m.tMs,
                                 event: m.event))
        }

        // Carrier aggregation.
        let scells = journey.cells.filter { $0.lane == .scell }
        if let first = scells.min(by: { $0.startMs < $1.startMs }) {
            let pcis = Set(scells.map(\.cell.pci))
            let on = pcis.count == 1 ? " on PCI \(pcis.first!)" : ""
            let noun = scells.count == 1 ? "SCell" : "SCells"
            timed.append(Finding(id: "carrierAggregation", kind: .carrierAggregation, severity: .info,
                                 text: "Carrier aggregation: \(scells.count) \(noun)\(on) (\(scells.map(JourneyText.band).joined(separator: ", "))), "
                                     + "from \(JourneyText.clock(first.startMs)).",
                                 tMs: first.startMs, event: nil))
        }

        timed = timed.enumerated().sorted {
            ($0.element.tMs ?? 0, $0.offset) < ($1.element.tMs ?? 0, $1.offset)
        }.map(\.element)
        return unique(timed + problems(flow: flow, journey: journey) + tail(flow: flow, journey: journey, facts: facts))
    }

    // MARK: - Tail

    /// Failures and warnings, by time. A failed procedure whose own answer is already a failure marker (the
    /// Registration reject) is told once, at the reject.
    static func problems(flow: Flow, journey: Journey) -> [Finding] {
        let failedAt = Set(journey.markers.filter { $0.severity == .failure }.compactMap(\.event))
        var out: [Finding] = []
        for m in journey.markers where m.severity >= .warning {
            if m.kind == .procedureFailed, let last = m.endEvent, last != m.event, failedAt.contains(last) { continue }
            let failure = m.severity == .failure
            out.append(Finding(id: "\(failure ? "failure" : "warning")-\(m.id)", kind: failure ? .failure : .warning,
                               severity: m.severity, text: problemText(m, flow: flow, journey: journey), tMs: m.tMs,
                               event: m.event))
        }
        return out
    }

    static func problemText(_ m: Marker, flow: Flow, journey: Journey) -> String {
        let at = JourneyText.clock(m.tMs)
        let here = pcell(at: m.tMs, journey).map { " on \(JourneyText.shortCell($0))" } ?? ""
        let detail = m.detail.map { ": \($0)" } ?? ""
        switch m.kind {
        case .registrationReject, .rrcReject:
            // "Registration reject" -> "Registration rejected"; the procedure's duration when there is one.
            let name = m.title.lowercased().hasSuffix(" reject") ? String(m.title.dropLast(7)) + " rejected" : m.title
            let took = flow.procedures.first { $0.outcome == .FAILED && $0.last == m.event }
                .map { " after \(JourneyText.duration($0.durationMs))" } ?? ""
            return "\(name)\(here)\(took) at \(at)\(detail)."
        case .connectionLost:
            return "Connection lost\(here) at \(at), with no release logged (typically a radio link failure)."
        case .scgFailure:
            return "The NR leg failed (SCG failure) at \(at)\(detail)."
        case .procedureUnanswered:
            return "\(m.title)\(here) at \(at)."
        case .cellChange:
            return "\(JourneyText.markerTitle(m, journey: journey)) at \(at): changed cell while connected without a logged handover."
        case .redirect, .reestablishment:
            return "\(JourneyText.markerTitle(m, journey: journey)) at \(at)."
        default:
            return "\(m.title)\(here) at \(at)\(detail)."
        }
    }

    static func tail(flow: Flow, journey: Journey, facts: CaptureFacts) -> [Finding] {
        var out: [Finding] = []
        let failures = journey.markers.filter { $0.severity == .failure }.count
        if failures == 0 {
            let total = flow.procedures.count
            let unanswered = flow.procedures.filter { $0.outcome == .UNANSWERED }.count
            let text = total == 0 ? "No failures logged."
                : unanswered == 0 ? "No failures: \(total) procedure\(total == 1 ? "" : "s"), all answered."
                : "No failures; \(unanswered) of \(total) procedures got no answer."
            out.append(Finding(id: "noFailures", kind: .noFailures, severity: .info, text: text))
        }
        let census = facts.encrypted
        if census.records > 0 {
            let nrPhy = census.byCode.map { codes in
                !codes.isEmpty && codes.keys.allSatisfy { UInt16(hexCode: $0).map { (0xB800...0xB9FF).contains($0) } ?? false }
            } ?? false
            let what = nrPhy ? "NR PHY records" : "records"
            let codes = census.codes > 0 ? " in \(census.codes) log code\(census.codes == 1 ? "" : "s")" : ""
            out.append(Finding(id: "encryptedRecords", kind: .encryptedRecords, severity: .info,
                               text: "\(JourneyText.count(census.records)) \(what)\(codes) were encrypted by the modem and can't be read."))
        }
        let window = facts.traceWindowMs > 0 ? facts.traceWindowMs : journey.durationMs
        var text = "Trace covers \(Fmt.fixed(window / 1_000, 1)) s"
        if let w = facts.traceWindowAfterPressMs {
            text += " (\(JourneyText.shortClock(w.startMs))–\(JourneyText.shortClock(w.endMs)) after you pressed the buttons)"
        }
        out.append(Finding(id: "traceWindow", kind: .traceWindow, severity: .info, text: text + "."))
        return out
    }

    // MARK: - Helpers

    static func pcell(at t: Double, _ journey: Journey) -> CellSegment? {
        journey.cells.last { $0.lane == .pcell && t >= $0.startMs - 0.5 && t <= $0.endMs + 0.5 }
    }

    /// Ids are unique within a journey (SwiftUI lists key on them).
    static func unique(_ findings: [Finding]) -> [Finding] {
        var seen: [String: Int] = [:]
        return findings.map { f in
            var f = f
            let n = seen[f.id, default: 0]
            seen[f.id] = n + 1
            if n > 0 { f.id += "-\(n + 1)" }
            return f
        }
    }
}

extension UInt16 {
    /// "0xB8DD" or "B8DD".
    init?(hexCode: String) {
        let digits = hexCode.hasPrefix("0x") || hexCode.hasPrefix("0X") ? String(hexCode.dropFirst(2)) : hexCode
        self.init(digits, radix: 16)
    }
}
