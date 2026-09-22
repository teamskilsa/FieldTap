import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// The NR leg (EN-DC): SS-RSRP/RSRQ per PCI from 0xB97F, DL MCS, PRB, layers and TBS per slot from 0xB887,
/// BLER and MAC throughput from the 0xB888 counters. NR SINR and CSI are encrypted by the modem.
struct NrSection: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let window = session.visibleWindow
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "NR leg (EN-DC)", source: "0xB97F v3.0 searcher, 0xB887 v3.13 PDSCH status, 0xB888 v3.1 counters",
                          session: session, warning: RadioData.warning(phy, checks: ["b887VsB888", "b887TbsFormula"])) { t in
                Self.readouts(phy, t)
            }
            zoomRow
            mcsChart(window)
            measurementChart("SS-RSRP per PCI", "dBm", .nr_ss_rsrp, window)
            measurementChart("SS-RSRQ per PCI", "dB", .nr_ss_rsrq, window)
            slotChart("PRB per slot", "PRB", .nr_dl_prb, window, yDomain: 0...52)
            slotChart("Layers per slot", "layers", .nr_dl_layers, window, yDomain: 0.5...2.5, step: true)
            slotChart("TBS per slot", "bytes", .nr_dl_tbs, window)
            counterChart("BLER per window", "%", .nr_dl_bler, window)
            counterChart("MAC DL throughput", "Mbit/s", .nr_dl_mac_throughput, window)
        }
    }

    static func readouts(_ phy: PhyCapture, _ t: Double) -> [Readout] {
        let rsrp = PhyQuery.latest(RadioData.series(phy, .nr_ss_rsrp), atOrBefore: t, maxAgeMs: 2000) { $0.tag == CellRole.serving }
        let rsrq = PhyQuery.latest(RadioData.series(phy, .nr_ss_rsrq), atOrBefore: t, maxAgeMs: 2000) { $0.tag == CellRole.serving }
        let cell = PhyCarriers.nrCell(at: t, in: phy)
        var out = [
            Readout(label: "SS-RSRP", value: RadioFormat.value(rsrp?.value, 1, "dBm"), stale: rsrp == nil),
            Readout(label: "SS-RSRQ", value: RadioFormat.value(rsrq?.value, 1, "dB"), stale: rsrq == nil),
            Readout(label: "MCS, 1 s median", value: RadioFormat.int(RadioData.median1s(phy, .nr_dl_mcs, at: t, carrier: nil))),
            Readout(label: "Layers", value: RadioFormat.int(RadioData.latest(phy, .nr_dl_layers, at: t, carrier: nil)?.value)),
            Readout(label: "BLER", value: RadioFormat.value(RadioData.latest(phy, .nr_dl_bler, at: t, maxAge: 2000, carrier: nil)?.value, 1, "%")),
            Readout(label: "MAC DL", value: RadioFormat.value(RadioData.latest(phy, .nr_dl_mac_throughput, at: t, maxAge: 2000, carrier: nil)?.value, 2, "Mbit/s")),
        ]
        if let cell {
            out.insert(Readout(label: "NR cell", value: "\(cell.arfcn.map(String.init) ?? "–")/\(cell.pci.map(String.init) ?? "–")"), at: 0)
        }
        return out
    }

    /// The NR leg lasts about a second here: offer to zoom the shared window to it.
    @ViewBuilder private var zoomRow: some View {
        if let nr = phy.summary.nrDlActivity {
            let leg = max(0, nr.firstMs - 300)...(nr.lastMs + 300)
            HStack {
                Text("NR DL active \(RadioFormat.clockMs(nr.firstMs))–\(RadioFormat.clockMs(nr.lastMs)), \(RadioFormat.count(nr.records)) slots")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.visibleWindow == leg {
                    Button("Show all") { session.zoomToFit() }.font(.caption.weight(.semibold))
                } else {
                    Button("Zoom to NR leg") { session.visibleWindow = leg }.font(.caption.weight(.semibold))
                }
            }
        }
    }

    private func measurementChart(_ title: String, _ unit: String, _ m: PhyMetric, _ window: ClosedRange<Double>) -> some View {
        let s = RadioData.series(phy, m)
        var order: [String] = []
        for x in s { let k = "PCI \(x.pci ?? -1)"; if !order.contains(k) { order.append(k) } }
        let pts = RadioData.points(s, window: window, series: title, group: { "PCI \($0.pci ?? -1)" })
        func color(_ k: String) -> Color {
            order.firstIndex(of: k).flatMap { $0 < RadioStyle.points.count ? RadioStyle.points[$0] : nil } ?? RadioStyle.other
        }
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: title, unit: unit, badges: [RadioBadge(text: "cell level")],
                     empty: s.isEmpty ? RadioData.emptyReason(phy, m) : nil, session: session) {
                ForEach(pts) { p in
                    PointMark(x: .value("t", p.t), y: .value(unit, p.y))
                        .foregroundStyle(color(p.group))
                        .symbol(RadioStyle.shapes[(order.firstIndex(of: p.group) ?? 0) % RadioStyle.shapes.count])
                        .symbolSize(30)
                }
            }
            LegendRow(items: order.map { ($0, color($0)) })
        }
    }

    private func mcsChart(_ window: ClosedRange<Double>) -> some View {
        let mcs = RadioData.series(phy, .nr_dl_mcs), qm = RadioData.series(phy, .nr_dl_modulation)
        var pts: [TimePoint] = []
        // nr_dl_mcs and nr_dl_modulation hold the same slots in the same order.
        let paired = mcs.count == qm.count
        for (i, s) in mcs.enumerated() where window.contains(s.tMs) {
            guard let v = s.value else { continue }
            let q = paired ? Int(qm[i].value ?? 0) : 0
            pts.append(TimePoint(id: pts.count, t: s.tMs, y: v, series: "mcs", segment: 0,
                                 group: RadioStyle.modulationName(qm: q), hollow: v >= 28))
        }
        func color(_ name: String) -> Color {
            RadioStyle.modulationNames.firstIndex(of: name).map { RadioStyle.modulation[$0] } ?? RadioStyle.other
        }
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: "DL MCS per slot (qam256 table)", unit: "index",
                     badges: RadioData.checkBadge(phy, "b887VsB888", passed: "sums = 0xB888 counters").map { [$0] } ?? [],
                     empty: mcs.isEmpty ? RadioData.emptyReason(phy, .nr_dl_mcs) : nil, yDomain: 0...32, session: session) {
                ForEach(pts) { p in
                    PointMark(x: .value("t", p.t), y: .value("MCS", p.y))
                        .foregroundStyle(color(p.group))
                        .symbol {
                            if p.hollow {
                                Circle().strokeBorder(color(p.group), lineWidth: 1.2).frame(width: 7, height: 7)
                            } else {
                                Circle().fill(color(p.group)).frame(width: 5, height: 5)
                            }
                        }
                }
            }
            LegendRow(items: zip(RadioStyle.modulationNames, RadioStyle.modulation).map { ($0, $1) })
        }
    }

    private func slotChart(_ title: String, _ unit: String, _ m: PhyMetric, _ window: ClosedRange<Double>,
                           yDomain: ClosedRange<Double>? = nil, step: Bool = false) -> some View {
        let s = RadioData.series(phy, m)
        let pts = RadioData.points(s, window: window, series: title, gapMs: 300)
        return PhyChart(title: title, unit: unit, empty: s.isEmpty ? RadioData.emptyReason(phy, m) : nil, yDomain: yDomain,
                        height: 110, session: session) {
            ForEach(pts) { p in
                if step {
                    LineMark(x: .value("t", p.t), y: .value(unit, p.y), series: .value("s", p.segment))
                        .interpolationMethod(.stepEnd).foregroundStyle(RadioStyle.lines[0])
                } else {
                    PointMark(x: .value("t", p.t), y: .value(unit, p.y)).foregroundStyle(RadioStyle.lines[0].opacity(0.8)).symbolSize(10)
                }
            }
        }
    }

    private func counterChart(_ title: String, _ unit: String, _ m: PhyMetric, _ window: ClosedRange<Double>) -> some View {
        let s = RadioData.series(phy, m)
        let pts = RadioData.points(s, window: window, series: title, gapMs: 1500)
        return PhyChart(title: title, unit: unit, badges: [RadioBadge(text: "0xB888 deltas")],
                        empty: s.isEmpty ? RadioData.emptyReason(phy, m) : nil, height: 110, session: session) {
            ForEach(pts) { p in
                LineMark(x: .value("t", p.t), y: .value(unit, p.y), series: .value("s", p.segment)).foregroundStyle(RadioStyle.lines[1])
                PointMark(x: .value("t", p.t), y: .value(unit, p.y)).foregroundStyle(RadioStyle.lines[1]).symbolSize(14)
            }
        }
    }
}
