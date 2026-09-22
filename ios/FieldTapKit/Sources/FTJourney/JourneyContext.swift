// What every journey rule reads from the parity call flow: the capture's end, the RRC events in order, the
// switch-off radio-off spans (J3) and the MCC the NR band rule narrows by. Built once per `JourneyBuilder.build`.

import FTCore
import FTModel

/// A J3 span: from the switch-off detach's release (or the detach itself) to the first RRC event after it.
struct RadioOff: Hashable, Sendable {
    var detachEvent: Int
    var detachMs: Double
    var releaseEvent: Int?
    var startMs: Double
    var endMs: Double
    /// The first RRC event after the span; nil when nothing was heard again before the capture ended.
    var nextEvent: Int?

    var openAtEnd: Bool { nextEvent == nil }

    func contains(_ tMs: Double) -> Bool { tMs >= startMs && tMs < endMs }
}

struct JourneyContext {
    let flow: Flow
    let phy: PhySummary
    /// Where every lane ends: the flow's duration (J1), or its last event when the duration is shorter. The
    /// OnePlus 5G registration golden has a negative duration (repo `main` behaviour, kept by D1) but events
    /// up to 188 s.
    let endMs: Double
    /// The first RRC event of any channel (J4: before it the state is 'unknown').
    let firstRrcMs: Double?
    let radioOffs: [RadioOff]
    /// From the first serving-cell record's PLMN ("310-410" -> 310), for NrBands.
    let mcc: Int?

    init(flow: Flow, phy: PhySummary) {
        self.flow = flow
        self.phy = phy
        let lastEvent = flow.events.map(\.sinceStartMs).max() ?? 0
        endMs = max(flow.durationMs, lastEvent, 0)
        firstRrcMs = flow.events.first { $0.layer == .RRC }?.sinceStartMs
        mcc = flow.cellDetails.first.flatMap { Self.mcc(plmn: $0.info.plmn) }
        radioOffs = Self.radioOffs(flow.events, endMs: endMs)
    }

    var events: [Event] { flow.events }

    /// "310-410" or "310410" -> 310.
    static func mcc(plmn: String) -> Int? {
        let digits = plmn.prefix { $0 != "-" }.filter(\.isNumber)
        return digits.count >= 3 ? Int(digits.prefix(3)) : nil
    }

    // MARK: - Event classes

    static func isRelease(_ e: Event) -> Bool {
        let k = e.key.lowercased()
        return e.layer == .RRC && (k.hasPrefix("rrcconnectionrelease") || k.hasPrefix("rrcrelease"))
    }

    static func isReestablishmentRequest(_ e: Event) -> Bool {
        e.layer == .RRC && e.key.lowercased().contains("reestablishmentrequest")
    }

    static func isScgFailure(_ e: Event) -> Bool { e.key.lowercased().contains("scgfailure") }

    /// J3: an uplink Detach (or 5G deregistration) request whose 'Switch off' field says yes.
    static func isSwitchOffDetach(_ e: Event) -> Bool {
        guard e.layer == .NAS, e.uplink else { return false }
        let k = e.key.lowercased()
        guard k.contains("detach request") || k.contains("deregistration request") || k.contains("de-registration request")
        else { return false }
        let field = e.fields.contains {
            $0.label.lowercased().contains("switch off") && ["yes", "switch off", "true", "1"].contains($0.value.lowercased())
        }
        return field || (e.summary?.lowercased().contains("switch off") ?? false)
    }

    // MARK: - J3

    static func radioOffs(_ events: [Event], endMs: Double) -> [RadioOff] {
        var out: [RadioOff] = []
        for (i, e) in events.enumerated() where isSwitchOffDetach(e) {
            let t0 = e.sinceStartMs
            if out.contains(where: { $0.contains(t0) || $0.detachEvent == i }) { continue }
            let rest = events.indices.dropFirst(i + 1)
            let release = rest.first { j in
                isRelease(events[j]) && events[j].sinceStartMs >= t0 && events[j].sinceStartMs <= t0 + 2_000
            }
            let startMs = release.map { events[$0].sinceStartMs } ?? t0
            let next: Int?
            if let r = release {
                next = events.indices.dropFirst(r + 1).first { events[$0].layer == .RRC && events[$0].sinceStartMs >= startMs }
            } else {
                // No release logged: the UL/DL-DCCH messages that carry the detach itself (within 2 s, on its
                // cell) are not a sign of the radio coming back.
                next = rest.first { j in
                    let x = events[j]
                    guard x.layer == .RRC, x.sinceStartMs >= t0 else { return false }
                    let carriesDetach = x.channel.hasSuffix("DCCH") && x.cell == e.cell && x.sinceStartMs <= t0 + 2_000
                    return !carriesDetach
                }
            }
            let endMs = next.map { events[$0].sinceStartMs } ?? endMs
            out.append(RadioOff(detachEvent: i, detachMs: t0, releaseEvent: release, startMs: startMs,
                                endMs: max(endMs, startMs), nextEvent: next))
        }
        return out
    }

    // MARK: - Queries

    /// The established connection open at `tMs`, if any.
    func connection(at tMs: Double) -> (index: Int, connection: Connection)? {
        for (i, c) in flow.connections.enumerated() where c.established {
            if tMs >= c.startMs && tMs <= (c.endMs ?? endMs) { return (i, c) }
        }
        return nil
    }

    /// The Handover procedure that starts at `event`, for its duration.
    func handoverProcedure(startingAt event: Int) -> Procedure? {
        flow.procedures.first { $0.name == "Handover" && $0.first == event }
    }

    func time(_ event: Int) -> Double? {
        flow.events.indices.contains(event) ? flow.events[event].sinceStartMs : nil
    }
}
