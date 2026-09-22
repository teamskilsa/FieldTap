import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// Antennas and MIMO: the eNB's Tx ports (MIB), the Rx antennas the UE measured per band, the transmission mode,
/// per-Rx RSRP at the cursor for every active carrier, how often each layer count was used, and the Rx0-Rx1
/// imbalance.
struct AntennaPanel: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let window = session.visibleWindow
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Antennas and MIMO", source: "0xB0C1 v2 MIB, 0xB193 Rx map, 0xB14E Tx mode, 0xB173 / 0xB887 layers",
                          session: session) { t in
                Self.readouts(phy, t)
            }
            badges
            PerRxBars(session: session)
            layersShare(window)
            sparkline(window)
        }
    }

    static func readouts(_ phy: PhyCapture, _ t: Double) -> [Readout] {
        [
            Readout(label: "Rx (PCell)", value: RadioFormat.int(RadioData.latest(phy, .lte_rx_antennas_measured, at: t)?.value)),
            Readout(label: "LTE layers", value: RadioData.layersLabel(RadioData.latest(phy, .lte_dl_layers, at: t))),
            Readout(label: "NR layers", value: RadioFormat.int(RadioData.latest(phy, .nr_dl_layers, at: t, carrier: nil)?.value)),
        ]
    }

    private var badges: some View {
        let s = phy.summary
        let tm = RadioData.series(phy, .lte_csf_tx_mode).compactMap(\.value).first.map { Int($0) }
        let nrMax = RadioData.series(phy, .nr_dl_layers).compactMap(\.value).max().map { Int($0) }
        return VStack(alignment: .leading, spacing: 8) {
            FlowRow {
                if !s.txAntennasMib.isEmpty {
                    BadgeView(badge: RadioBadge(text: "eNB \(s.txAntennasMib.map(String.init).joined(separator: "/")) Tx (MIB)"))
                }
                if let tm { BadgeView(badge: RadioBadge(text: "TM\(tm)")) }
                if let nrMax { BadgeView(badge: RadioBadge(text: "NR: up to \(nrMax) layers used")) }
            }
            if !s.rxAntennasByEarfcn.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("UE Rx antennas measured, PCell records per band").font(.caption.weight(.semibold))
                    ForEach(s.rxAntennasByEarfcn.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }, id: \.self) { e in
                        let counts = s.rxAntennasByEarfcn[e] ?? [:]
                        let parts = counts.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
                            .map { "\($0) Rx in \(RadioFormat.count(counts[$0] ?? 0))" }
                        Text("\(RadioFormat.band(Int64(e)) ?? "EARFCN") (\(e)): " + parts.joined(separator: ", "))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Time share of layers used: LTE 1/2/3/TxD and NR 1/2 over the visible window.
    private func layersShare(_ window: ClosedRange<Double>) -> some View {
        var bars: [TimePoint] = []
        func add(_ rat: String, _ samples: ArraySlice<PhySample>, category: (PhySample) -> String?) {
            var counts: [String: Int] = [:]
            var total = 0
            for s in samples { if let c = category(s) { counts[c, default: 0] += 1; total += 1 } }
            for c in ["1", "2", "3 (unverified)", "TxD"] where (counts[c] ?? 0) > 0 {
                bars.append(TimePoint(id: bars.count, t: 0, y: Double(counts[c]!) / Double(total), series: rat, segment: 0, group: c))
            }
        }
        add("LTE", PhyQuery.slice(RadioData.series(phy, .lte_dl_layers), window)) { s in
            s.value.map { RadioData.layersCategory(layers: Int($0), transportBlocks: s.tag ?? 0) }
        }
        add("NR", PhyQuery.slice(RadioData.series(phy, .nr_dl_layers), window)) { s in s.value.map { String(Int($0)) } }
        let order = ["1", "2", "3 (unverified)", "TxD"]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Layers used (visible window)").font(.subheadline.weight(.semibold))
            if bars.isEmpty {
                EmptyChartNote(text: "No DL scheduling records in the visible window.")
            } else {
                Chart(bars) { b in
                    BarMark(x: .value("share", b.y), y: .value("RAT", b.series))
                        .foregroundStyle(by: .value("layers", b.group))
                        .annotation(position: .overlay) {
                            if b.y > 0.1 { Text("\(b.group) \(Int((b.y * 100).rounded()))%").font(.caption2).foregroundStyle(.white) }
                        }
                }
                .chartForegroundStyleScale(domain: order, range: [RadioStyle.lines[0], RadioStyle.lines[2], RadioStyle.other, RadioStyle.lines[3]])
                .chartXAxis { AxisMarks(values: [0, 0.5, 1]) { AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent()) } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 90)
            }
        }
    }

    private func sparkline(_ window: ClosedRange<Double>) -> some View {
        let perRx = RadioData.serving(RadioData.series(phy, .lte_rsrp_per_rx), carrier: 0)
        let pts = RadioData.points(perRx, window: window, series: "imbalance", maxPoints: 600, value: { s in
            guard let p = s.perIndex, p.count > 1, let a = p[0], let b = p[1] else { return nil }
            return a - b
        })
        return PhyChart(title: "Rx0 − Rx1 imbalance (PCell)", unit: "dB", empty: pts.isEmpty ? "No per-antenna measurements." : nil,
                        height: 70, session: session) {
            RuleMark(y: .value("zero", 0)).foregroundStyle(Color.secondary.opacity(0.4))
            ForEach(pts) { p in
                LineMark(x: .value("t", p.t), y: .value("dB", p.y), series: .value("s", p.segment))
                    .foregroundStyle(RadioStyle.lines[2]).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
    }
}

/// Per-Rx RSRP bars at the cursor, one small chart per active carrier (this view alone follows the cursor).
struct PerRxBars: View {
    @Bindable var session: CaptureSession

    var body: some View {
        let t = session.cursor.ms
        let phy = session.analysis.phy
        let carriers = RadioData.active(at: t, session: session).lte
        VStack(alignment: .leading, spacing: 6) {
            Text("RSRP per Rx antenna at \(RadioFormat.clockMs(t))").font(.subheadline.weight(.semibold))
            if carriers.isEmpty {
                EmptyChartNote(text: "No serving carrier at the cursor (radio off or idle).")
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(carriers, id: \.index) { c in
                        let sample = RadioData.latest(phy, .lte_rsrp_per_rx, at: t, carrier: c.index)
                        let bars = (sample?.perIndex ?? []).enumerated().compactMap { k, v in v.map { (k, $0) } }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(RadioStyle.carrierName(c.index)) \(RadioFormat.band(c.earfcn) ?? "") \(String(c.earfcn))/\(String(c.pci))")
                                .font(.caption2.weight(.semibold))
                            if bars.isEmpty {
                                Text("no measurement within 500 ms").font(.caption2).foregroundStyle(.tertiary).frame(height: 100)
                            } else {
                                Chart(bars, id: \.0) { k, v in
                                    BarMark(x: .value("Rx", "Rx\(k)"), yStart: .value("dBm", -140), yEnd: .value("dBm", v), width: .ratio(0.6))
                                        .foregroundStyle(RadioStyle.lines[k % RadioStyle.lines.count])
                                        .annotation(position: .top) { Text(Fmt1(v)).font(.system(size: 9).monospacedDigit()) }
                                }
                                .chartYScale(domain: -140 ... -65)
                                .chartYAxis(.hidden)
                                .frame(height: 100)
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
                    }
                }
            }
        }
    }

    private func Fmt1(_ v: Double) -> String { RadioFormat.value(v, 0) }
}

/// Wraps its children onto more lines as needed.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
