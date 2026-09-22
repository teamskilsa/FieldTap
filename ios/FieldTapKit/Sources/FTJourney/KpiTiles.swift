// KPI tiles in the operator groups MobileInsight's KPI manager uses (Accessibility, Mobility, Retainability,
// Integrity), computed from the parity procedures and connections, plus EN-DC from the journey.

import FTCore
import FTModel

public enum KpiTiles {
    public static func of(flow: Flow, journey: Journey, phy: PhySummary) -> [KpiTile] {
        var out: [KpiTile] = []
        func procedureTile(_ id: String, _ group: String, _ title: String, names: Set<String>) {
            let items = flow.procedures.filter { names.contains($0.name) }
            guard !items.isEmpty else { return }
            let ok = items.filter { $0.outcome == .SUCCEEDED }
            let value = median(ok.map(\.durationMs)).map { ok.count > 1 ? "median \(JourneyText.duration($0))" : JourneyText.duration($0) }
            out.append(KpiTile(id: id, group: group, title: title, succeeded: ok.count, attempts: items.count, value: value,
                               event: (items.first { $0.outcome != .SUCCEEDED } ?? items[0]).first))
        }
        procedureTile("rrcSetup", "Accessibility", "RRC setup", names: ["RRC connection setup", "RRC setup"])
        procedureTile("serviceRequest", "Accessibility", "Service request", names: ["Service request"])
        procedureTile("attach", "Accessibility", "Attach", names: ["Attach"])
        procedureTile("registration", "Accessibility", "Registration", names: ["Registration"])
        procedureTile("pdn", "Accessibility", "PDN", names: ["PDN connectivity", "PDU session establishment"])
        procedureTile("handover", "Mobility", "Handover", names: ["Handover"])

        let adds = journey.markers.filter { $0.kind == .scgAdd }
        if !adds.isEmpty {
            let added = adds.filter { $0.to != nil }.count
            out.append(KpiTile(id: "scgAdd", group: "EN-DC", title: "SCG add", succeeded: added, attempts: adds.count,
                               value: journey.cells.first { $0.lane == .pscell }.map { JourneyText.band($0) },
                               event: adds[0].event))
        }

        // Retainability: connections that ended without a release (radio link failure) plus re-establishments.
        let established = flow.connections.filter(\.established).count
        let lost = flow.connections.filter { $0.outcome == .LOST }
        let reestablishments = flow.events.indices.filter { JourneyContext.isReestablishmentRequest(flow.events[$0]) }
        let abnormal = lost.count + reestablishments.count
        out.append(KpiTile(id: "abnormalReleases", group: "Retainability", title: "Abnormal releases", succeeded: abnormal,
                           attempts: established,
                           value: "\(abnormal) of \(established) connection\(established == 1 ? "" : "s")",
                           event: lost.first?.last ?? reestablishments.first))

        let answered = flow.procedures.filter { $0.outcome != .UNANSWERED }.count
        out.append(KpiTile(id: "procedures", group: "Signalling", title: "Procedures answered", succeeded: answered,
                           attempts: flow.procedures.count,
                           value: flow.procedures.isEmpty ? nil
                               : answered == flow.procedures.count ? "all answered" : "\(flow.procedures.count - answered) unanswered",
                           event: flow.procedures.first { $0.outcome == .UNANSWERED }?.first))
        return out
    }

    /// Integrity tiles from the PHY series, when the capture has them: the LTE DL PHY and NR MAC throughput peaks.
    /// The bins are per (UTC second, carrier) (contract), so a second's carriers are added up first: with CA the
    /// peak is the phone's, not one carrier's. Separate from `of`, which sees only the PHY summary.
    public static func peaks(phy: PhyCapture) -> [KpiTile] {
        var out: [KpiTile] = []
        let pairs: [(PhyMetric, String, String)] = [(.lte_dl_phy_throughput, "lteDlPhyPeak", "LTE DL PHY peak"),
                                                    (.nr_dl_mac_throughput, "nrMacPeak", "NR MAC peak")]
        for (metric, id, title) in pairs {
            guard let s = phy.series[metric] else { continue }
            var perSecond: [Int: Double] = [:]
            for sample in s.samples {
                guard let v = sample.value else { continue }
                perSecond[Int((sample.tMs / 1_000).rounded(.down)), default: 0] += v
            }
            guard let peak = perSecond.values.max() else { continue }
            out.append(KpiTile(id: id, group: "Integrity", title: title, succeeded: 0, attempts: 0,
                               value: Fmt.fixed(peak, 1) + " Mbit/s"))
        }
        return out
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
