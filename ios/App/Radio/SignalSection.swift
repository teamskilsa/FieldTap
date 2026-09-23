import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// LTE serving-cell signal from 0xB193: RSRP per Rx antenna and filtered, RSRQ, RSSI, the Rx0-Rx1 imbalance and
/// every serving carrier's filtered RSRP. The neighbours are their own section (NeighboursSection).
struct SignalSection: View {
    @Bindable var session: CaptureSession
    @State private var shownRx: Set<Int> = [0, 1, 2, 3]
    @State private var showFiltered = true

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let window = session.visibleWindow
        let perRx = RadioData.serving(RadioData.series(phy, .lte_rsrp_per_rx), carrier: 0)
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Signal, LTE serving cell", source: "0xB193 v1 / 0x19 v66, per Rx antenna",
                          session: session, warning: RadioData.warning(phy, checks: ["b193RsrqIdentity"])) { t in
                Self.readouts(phy, t)
            }
            rsrpChart(perRx, window)
            lineChart("RSRQ (filtered)", "dB", .lte_rsrq_filtered, window)
            lineChart("RSSI", "dBm", .lte_rssi, window)
            imbalanceChart(perRx, window)
            carriersChart(window)
        }
    }

    static func readouts(_ phy: PhyCapture, _ t: Double) -> [Readout] {
        let rsrp = RadioData.latest(phy, .lte_rsrp_filtered, at: t)
        let perRx = RadioData.latest(phy, .lte_rsrp_per_rx, at: t)?.perIndex
        let imbalance: Double? = perRx.flatMap { p in p.count > 1 ? p[0].flatMap { a in p[1].map { a - $0 } } : nil }
        var out = [
            Readout(label: "RSRP", value: RadioFormat.value(rsrp?.value, 1, "dBm"), stale: rsrp == nil),
            Readout(label: "RSRQ", value: RadioFormat.value(RadioData.latest(phy, .lte_rsrq_filtered, at: t)?.value, 1, "dB")),
            Readout(label: "RSSI", value: RadioFormat.value(RadioData.latest(phy, .lte_rssi, at: t)?.value, 1, "dBm")),
            Readout(label: "Rx antennas", value: RadioFormat.int(RadioData.latest(phy, .lte_rx_antennas_measured, at: t)?.value)),
            Readout(label: "Rx0 − Rx1", value: RadioFormat.value(imbalance, 1, "dB")),
        ]
        if let s = rsrp, let e = s.earfcn, let p = s.pci {
            out.append(Readout(label: "PCell", value: "\(RadioFormat.band(e) ?? "") \(e)/\(p)"))
        }
        return out
    }

    private func rsrpChart(_ perRx: [PhySample], _ window: ClosedRange<Double>) -> some View {
        var parts: [[TimePoint]] = (0..<4).filter { shownRx.contains($0) }.map { k in
            RadioData.points(perRx, window: window, series: "Rx\(k)", value: { s in
                s.perIndex.flatMap { k < $0.count ? $0[k] : nil }
            })
        }
        if showFiltered {
            parts.append(RadioData.points(RadioData.serving(RadioData.series(phy, .lte_rsrp_filtered), carrier: 0),
                                          window: window, series: "Filtered"))
        }
        let pts = RadioData.joined(parts)
        let measured = (0..<4).filter { k in perRx.contains { s in s.perIndex.map { k < $0.count && $0[k] != nil } ?? false } }
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: "RSRP per Rx antenna (PCell)", unit: "dBm",
                     empty: perRx.isEmpty ? RadioData.emptyReason(phy, .lte_rsrp_per_rx) : nil, session: session) {
                ForEach(pts) { p in
                    LineMark(x: .value("t", p.t), y: .value("RSRP", p.y), series: .value("s", "\(p.series)-\(p.segment)"))
                        .foregroundStyle(color(p.series))
                        .lineStyle(StrokeStyle(lineWidth: p.series == "Filtered" ? 2.5 : 1))
                        .interpolationMethod(.linear)
                }
            }
            HStack(spacing: 6) {
                ForEach(measured, id: \.self) { k in
                    LegendChip(title: "Rx\(k)", color: RadioStyle.lines[k], isOn: toggle(k))
                }
                LegendChip(title: "Filtered", color: .primary, isOn: $showFiltered)
            }
        }
    }

    private func color(_ series: String) -> Color {
        if series == "Filtered" { return .primary }
        let k = Int(series.dropFirst(2)) ?? 0
        return RadioStyle.lines[k % RadioStyle.lines.count]
    }

    private func toggle(_ k: Int) -> Binding<Bool> {
        Binding(get: { shownRx.contains(k) }, set: { if $0 { shownRx.insert(k) } else { shownRx.remove(k) } })
    }

    private func lineChart(_ title: String, _ unit: String, _ m: PhyMetric, _ window: ClosedRange<Double>) -> some View {
        let samples = RadioData.serving(RadioData.series(phy, m), carrier: 0)
        let pts = RadioData.points(samples, window: window, series: title)
        return PhyChart(title: title + " (PCell)", unit: unit, empty: samples.isEmpty ? RadioData.emptyReason(phy, m) : nil,
                        session: session) {
            ForEach(pts) { p in
                LineMark(x: .value("t", p.t), y: .value(title, p.y), series: .value("s", p.segment))
                    .foregroundStyle(RadioStyle.lines[0])
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
    }

    private func imbalanceChart(_ perRx: [PhySample], _ window: ClosedRange<Double>) -> some View {
        let pts = RadioData.points(perRx, window: window, series: "imbalance", value: { s in
            guard let p = s.perIndex, p.count > 1, let a = p[0], let b = p[1] else { return nil }
            return a - b
        })
        return PhyChart(title: "Rx0 − Rx1 imbalance (PCell)", unit: "dB",
                        empty: pts.isEmpty ? RadioData.emptyReason(phy, .lte_rsrp_per_rx) : nil, session: session) {
            RuleMark(y: .value("zero", 0)).foregroundStyle(Color.secondary.opacity(0.5))
            ForEach(pts) { p in
                LineMark(x: .value("t", p.t), y: .value("dB", p.y), series: .value("s", p.segment))
                    .foregroundStyle(RadioStyle.lines[2])
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
    }

    /// Filtered RSRP of every serving carrier: the PCell and, while carrier aggregation is on, the SCells.
    private func carriersChart(_ window: ClosedRange<Double>) -> some View {
        let all = RadioData.series(phy, .lte_rsrp_filtered)
        let carriers = Set(all.map(\.carrier)).filter { $0 >= 0 }.sorted()
        let pts = RadioData.joined(carriers.map { c in
            RadioData.points(RadioData.serving(all, carrier: c), window: window, series: RadioStyle.carrierName(c), gapMs: 500)
        })
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: "Serving carriers, filtered RSRP", unit: "dBm",
                     empty: all.isEmpty ? RadioData.emptyReason(phy, .lte_rsrp_filtered) : nil, session: session) {
                ForEach(pts) { p in
                    LineMark(x: .value("t", p.t), y: .value("RSRP", p.y), series: .value("s", "\(p.series)-\(p.segment)"))
                        .foregroundStyle(RadioStyle.lines[carrierIndex(p.series) % RadioStyle.lines.count])
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            LegendRow(items: carriers.map { (RadioStyle.carrierName($0), RadioStyle.lines[$0 % RadioStyle.lines.count]) })
        }
    }

    private func carrierIndex(_ name: String) -> Int { name == "PCell" ? 0 : Int(name.dropFirst(6)) ?? 0 }
}
