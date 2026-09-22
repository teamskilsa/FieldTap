import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// Antennas and MIMO. The measured configuration comes first, from 0xB126's own per-subframe fields — the cell's
/// transmit antenna ports, the receive antennas in use and the MIMO rank — with the MIB's broadcast kept below it
/// as the fallback it now is. Then the transmission mode, per-Rx RSRP at the cursor for every active carrier, how
/// often each layer count was used, and the Rx0-Rx1 imbalance.
struct AntennaPanel: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let window = session.visibleWindow
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Antennas and MIMO",
                          source: "0xB126 v163 measured per subframe; 0xB0C1 v2 MIB, 0xB193 Rx map, 0xB14E Tx mode, 0xB173 / 0xB887 layers",
                          session: session,
                          warning: RadioData.warning(phy, checks: ["b126TxAntennaPorts", "b126Rank"])) { t in
                Self.readouts(phy, t)
            }
            MeasuredAntennasView(session: session)
            badges
            PerRxBars(session: session)
            layersShare(window)
            sparkline(window)
        }
    }

    static func readouts(_ phy: PhyCapture, _ t: Double) -> [Readout] {
        // The 0xB126 series carry the subframe in `tag`, which can be 0, so they are read without the
        // serving-cell filter (that filter means "tag is not CellRole.neighbour" on the 0xB193 series).
        let ports = RadioData.latest(phy, .lte_tx_antenna_ports, at: t, maxAge: 1_000, servingOnly: false)
        let rx = RadioData.latest(phy, .lte_rx_antennas_used, at: t, maxAge: 1_000, servingOnly: false)
        let rank = RadioData.latest(phy, .lte_dl_rank, at: t, maxAge: 1_000, servingOnly: false)
        return [
            Readout(label: "Cell Tx ports", value: RadioFormat.int(ports?.value), stale: ports == nil),
            Readout(label: "Rx in use", value: RadioFormat.int(rx?.value), stale: rx == nil),
            Readout(label: "Rank", value: RadioFormat.int(rank?.value), stale: rank == nil),
            Readout(label: "Rx measured", value: RadioFormat.int(RadioData.latest(phy, .lte_rx_antennas_measured, at: t)?.value)),
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
                    BadgeView(badge: RadioBadge(text: "broadcast: eNB \(s.txAntennasMib.map(String.init).joined(separator: "/")) Tx (MIB)"))
                }
                if let tm { BadgeView(badge: RadioBadge(text: "TM\(tm)")) }
                if let nrMax { BadgeView(badge: RadioBadge(text: "NR: up to \(nrMax) layers used")) }
            }
            if !s.rxAntennasByEarfcn.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("UE Rx antennas measured (0xB193 Rx map), PCell records per band").font(.caption.weight(.semibold))
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


/// The antenna configuration 0xB126 measured, per serving cell and per subframe, with its source named: this is
/// what replaced inferring the antennas from the MIB's broadcast plus the measurement record. The MIB stays
/// below as the fallback for a cell whose 0xB126 sub-records never named it.
struct MeasuredAntennasView: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let antennas = phy.summary.antennas
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Measured").font(.subheadline.weight(.semibold))
                if let badge = RadioData.checkBadge(phy, "b126TxAntennaPorts", passed: "matches the MIB") {
                    BadgeView(badge: badge)
                }
                Spacer(minLength: 0)
            }
            if let a = antennas, a.subRecords > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    rows("Cell Tx antenna ports, per serving cell", cellPorts(a))
                    rows("Rx antennas in use", share(a.rxAntennas, unit: "Rx"), badge: .medium)
                    rows("Rank (spatial layers) per subframe", share(a.rank, unit: "layer"))
                    Text("\(a.source), \(RadioFormat.count(a.subRecords)) subframes in this capture. Measured from the "
                         + "record, not inferred from the broadcast.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            } else {
                EmptyChartNote(text: RadioData.emptyReason(phy, .lte_tx_antenna_ports)
                    + " The antenna configuration below is the MIB's broadcast plus the 0xB193 Rx map, which is an inference.")
            }
        }
        .accessibilityIdentifier("measuredAntennas")
    }

    private func rows(_ title: String, _ lines: [String], badge: RadioBadge? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                if let badge { BadgeView(badge: badge) }
            }
            if lines.isEmpty {
                Text("not measured in this capture").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(lines, id: \.self) { Text($0).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
    }

    /// "B2 650/235: 4 ports in 1,043 subframes" per cell, strongest first; the MIB's own count beside it.
    private func cellPorts(_ a: MeasuredAntennas) -> [String] {
        a.txPortsByCell.keys.sorted().compactMap { key in
            let counts = a.txPortsByCell[key] ?? [:]
            let parts = counts.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
                .map { "\($0) port\($0 == "1" ? "" : "s") in \(RadioFormat.count(counts[$0] ?? 0))" }
            let cell = key == "unknown" ? "no serving cell at that moment" : name(key)
            return "\(cell): " + parts.joined(separator: ", ")
        }
    }

    /// "B2 650/235" from the summary's "EARFCN/PCI" key.
    private func name(_ key: String) -> String {
        let parts = key.split(separator: "/")
        guard parts.count == 2, let earfcn = Int64(parts[0]) else { return key }
        return "\(RadioFormat.band(earfcn) ?? "EARFCN") \(key)"
    }

    private func share(_ counts: [String: Int], unit: String) -> [String] {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return counts.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }.map { k in
            let n = counts[k] ?? 0
            return "\(k) \(unit)\(k == "1" ? "" : "s"): \(RadioFormat.count(n)) subframes (\(Int((Double(n) / Double(total) * 100).rounded()))%)"
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
