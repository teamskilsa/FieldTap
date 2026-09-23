import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// The neighbours the modem measured, and the one number a handover turns on: the margin against the serving cell.
///
/// 0xB193 reports the neighbours it happens to measure on the serving carriers. 0xB179 reports the modem's own
/// intra-frequency list, continuously, while the phone is connected and without waiting for an RRC measurement
/// report — 501 measurements in 22 s of driving, on cells nothing else in the capture sees. Those records carry no
/// timestamp at all: each one is placed by its own TTI (PhyTtiAxis), which its self-check gates.
struct NeighboursSection: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let window = session.visibleWindow
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Neighbours", source: "0xB179 v56 intra-frequency measurements, 0xB193 v1 / 0x19 v66",
                          session: session,
                          warning: RadioData.warning(phy, checks: ["b179Length", "b179OwnTiming", "b179ServingRsrp"])) { t in
                Self.readouts(phy, t)
            }
            NeighbourTable(session: session)
            neighbourChart(window)
            marginChart(window)
        }
    }

    static func readouts(_ phy: PhyCapture, _ t: Double) -> [Readout] {
        let rows = NeighbourTable.rows(phy, at: t)
        let serving = NeighbourTable.serving(phy, at: t)
        let best = rows.first
        return [
            Readout(label: "Neighbours", value: rows.isEmpty ? "–" : String(rows.count), stale: rows.isEmpty),
            Readout(label: "Best neighbour", value: best.map { "PCI \($0.pci)" } ?? "–", stale: best == nil),
            Readout(label: "Best margin", value: best.map { ($0.marginDb >= 0 ? "+" : "") + RadioFormat.value($0.marginDb, 1, "dB") } ?? "–",
                    stale: best == nil),
            Readout(label: "Serving (0xB179)", value: RadioFormat.value(serving?.rsrp, 1, "dBm"), stale: serving == nil),
        ]
    }

    /// The margin of every neighbour against the serving cell, over the window: above zero the neighbour is
    /// stronger, and a handover becomes likely once one stays there.
    private func marginChart(_ window: ClosedRange<Double>) -> some View {
        let samples = RadioData.series(phy, .lte_intra_neighbour_margin)
        let pcis = orderedPcis(samples)
        let pts = RadioData.points(samples, window: window, series: "margin", group: { "PCI \($0.pci ?? -1)" })
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: "Neighbour margin against the serving cell", unit: "dB", badges: [.derived],
                     empty: samples.isEmpty ? RadioData.emptyReason(phy, .lte_intra_neighbour_margin) : nil,
                     session: session) {
                RuleMark(y: .value("equal", 0))
                    .foregroundStyle(Theme.severity(.warning))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("as strong as the serving cell").font(.caption2).foregroundStyle(.secondary)
                    }
                ForEach(pts) { p in
                    PointMark(x: .value("t", p.t), y: .value("dB", p.y))
                        .foregroundStyle(pciColor(p.group, pcis))
                        .symbol(pciShape(p.group, pcis))
                        .symbolSize(14)
                }
            }
            LegendRow(items: pcis.map { ($0, pciColor($0, pcis)) })
        }
    }

    /// Neighbour RSRP as points, one colour and shape per PCI (in the order the PCIs first appear). 0xB193's
    /// neighbours and 0xB179's are drawn together — hollow for 0xB179's, which is the only source for most of them
    /// — over the serving cell's own filtered RSRP, so the gap between them is the handover margin on screen.
    private func neighbourChart(_ window: ClosedRange<Double>) -> some View {
        let b193 = RadioData.series(phy, .lte_neighbour_rsrp)
        let b179 = RadioData.series(phy, .lte_intra_neighbour_rsrp)
        let pcis = orderedPcis(b193 + b179)
        let pts = RadioData.joined([
            RadioData.points(b193, window: window, series: "0xB193", group: { "PCI \($0.pci ?? -1)" }),
            RadioData.points(b179, window: window, series: "0xB179", group: { "PCI \($0.pci ?? -1)" }),
        ])
        let serving = RadioData.points(RadioData.serving(RadioData.series(phy, .lte_rsrp_filtered), carrier: 0),
                                       window: window, series: "Serving")
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: "Neighbour RSRP against the serving cell", unit: "dBm",
                     badges: [RadioBadge(text: "0xB179 v56 intra-frequency")],
                     empty: pts.isEmpty ? "No neighbour measurements in this capture." : nil, session: session) {
                ForEach(serving) { p in
                    LineMark(x: .value("t", p.t), y: .value("RSRP", p.y), series: .value("s", "serving-\(p.segment)"))
                        .foregroundStyle(.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                ForEach(pts) { p in
                    PointMark(x: .value("t", p.t), y: .value("RSRP", p.y))
                        .foregroundStyle(pciColor(p.group, pcis))
                        .symbol {
                            if p.series == "0xB179" {
                                Circle().strokeBorder(pciColor(p.group, pcis), lineWidth: 1.2).frame(width: 6, height: 6)
                            } else {
                                Circle().fill(pciColor(p.group, pcis)).frame(width: 5, height: 5)
                            }
                        }
                }
            }
            LegendRow(items: [("serving cell (filtered)", .primary)] + pcis.map { ($0, pciColor($0, pcis)) })
            Text("Filled: 0xB193's neighbours. Hollow: 0xB179's intra-frequency list, which is the only source for "
                 + "most of these cells.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func orderedPcis(_ samples: [PhySample]) -> [String] {
        var seen: [String] = []
        for s in samples { let k = "PCI \(s.pci ?? -1)"; if !seen.contains(k) { seen.append(k) } }
        return seen
    }

    private func pciColor(_ key: String, _ order: [String]) -> Color {
        guard let i = order.firstIndex(of: key), i < RadioStyle.points.count else { return RadioStyle.other }
        return RadioStyle.points[i]
    }

    private func pciShape(_ key: String, _ order: [String]) -> BasicChartSymbolShape {
        RadioStyle.shapes[(order.firstIndex(of: key) ?? 0) % RadioStyle.shapes.count]
    }
}
