import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// LTE downlink from 0xB173: MCS per transport block (colour = modulation, hollow = retransmission), the
/// modulation mix per second, PRB and TBS per block, layers used against the rank reported, BLER and PHY
/// throughput per second.
struct DownlinkSection: View {
    @Bindable var session: CaptureSession
    /// nil = every carrier.
    @State private var carrier: Int?

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let window = session.visibleWindow
        let carriers = Set(RadioData.series(phy, .lte_dl_mcs).map(\.carrier)).sorted()
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Downlink, LTE", source: "0xB173 v50 PDSCH stat, C-RNTI transport blocks", session: session,
                          warning: RadioData.warning(phy, checks: ["b173TbsTable"])) { t in
                Self.readouts(phy, t)
            }
            if carriers.count > 1 {
                Picker("Carrier", selection: $carrier) {
                    // "All carriers" truncates in a five-way segmented control on a 402 pt iPhone.
                    Text("All").tag(Int?.none)
                    ForEach(carriers, id: \.self) { Text(RadioStyle.carrierName($0)).tag(Int?.some($0)) }
                }
                .pickerStyle(.segmented)
            }
            mcsChart(window)
            modulationMix(window)
            blockChart("PRB per transport block", "PRB", .lte_dl_prb, window, yDomain: 0...50)
            blockChart("TBS per transport block", "bytes", .lte_dl_tbs, window)
            layersChart(window)
            rankShare(window)
            binChart("BLER per second", "%", .lte_dl_bler, window, stacked: false)
            binChart("PHY throughput per second", "Mbit/s", .lte_dl_phy_throughput, window,
                     badges: [RadioBadge(text: "CRC-pass TBS")])
        }
    }

    static func readouts(_ phy: PhyCapture, _ t: Double) -> [Readout] {
        let layers = RadioData.latest(phy, .lte_dl_layers, at: t)
        return [
            Readout(label: "MCS, 1 s median", value: RadioFormat.int(RadioData.median1s(phy, .lte_dl_mcs, at: t, carrier: 0))),
            Readout(label: "Layers", value: RadioData.layersLabel(layers), stale: layers == nil),
            Readout(label: "BLER", value: RadioFormat.value(RadioData.bin(phy, .lte_dl_bler, at: t, carrier: 0), 1, "%")),
            Readout(label: "PHY, all CCs", value: RadioFormat.value(RadioData.bin(phy, .lte_dl_phy_throughput, at: t, carrier: nil), 2, "Mbit/s")),
        ]
    }

    private func samples(_ m: PhyMetric) -> [PhySample] {
        let s = RadioData.series(phy, m)
        guard let carrier else { return s }
        return s.filter { $0.carrier == carrier }
    }

    private func mcsChart(_ window: ClosedRange<Double>) -> some View {
        let mcs = samples(.lte_dl_mcs), qm = samples(.lte_dl_modulation)
        // The same transport blocks in the same order: modulation i belongs to MCS i.
        var byTime: [Double: [Double]] = [:]
        for s in qm { if let v = s.value { byTime[s.tMs, default: []].append(v) } }
        var used: [Double: Int] = [:]
        var pts: [TimePoint] = []
        for s in PhyQuery.decimate(mcs, window: window, maxPoints: RadioData.maxPoints) {
            guard let v = s.value else { continue }
            let k = used[s.tMs, default: 0]
            used[s.tMs] = k + 1
            let q = byTime[s.tMs].flatMap { k < $0.count ? Int($0[k]) : nil } ?? 0
            pts.append(TimePoint(id: pts.count, t: s.tMs, y: v, series: "mcs", segment: 0,
                                 group: RadioStyle.modulationName(qm: q), hollow: v >= 29))
        }
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: "MCS per transport block", unit: "index", badges: tbsBadge,
                     empty: mcs.isEmpty ? RadioData.emptyReason(phy, .lte_dl_mcs) : nil, yDomain: 0...32, session: session) {
                ForEach(pts) { p in
                    PointMark(x: .value("t", p.t), y: .value("MCS", p.y))
                        .foregroundStyle(modulationColor(p.group))
                        .symbol {
                            if p.hollow {
                                Circle().strokeBorder(modulationColor(p.group), lineWidth: 1.2).frame(width: 7, height: 7)
                            } else {
                                Circle().fill(modulationColor(p.group)).frame(width: 5, height: 5)
                            }
                        }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                LegendRow(items: zip(RadioStyle.modulationNames, RadioStyle.modulation).map { ($0, $1) })
                HStack(spacing: 4) {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: 8, height: 8)
                    Text("retransmission (29-31)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tbsBadge: [RadioBadge] {
        if !LteTbs.isAvailable { return [RadioBadge(text: "TBS check not run")] }
        return RadioData.checkBadge(phy, "b173TbsTable", passed: "36.213 TBS check").map { [$0] } ?? []
    }

    private func modulationColor(_ name: String) -> Color {
        RadioStyle.modulationNames.firstIndex(of: name).map { RadioStyle.modulation[$0] } ?? RadioStyle.other
    }

    /// Share of transport blocks per modulation in each second (100% stacked, drawn as explicit ranges).
    private func modulationMix(_ window: ClosedRange<Double>) -> some View {
        var counts: [Int: [Int: Int]] = [:]
        for s in PhyQuery.slice(samples(.lte_dl_modulation), window) {
            guard let v = s.value else { continue }
            counts[Int((s.tMs / 1000).rounded(.down)), default: [:]][Int(v), default: 0] += 1
        }
        var bars: [StackedBar] = []
        for sec in counts.keys.sorted() {
            let row = counts[sec] ?? [:]
            let total = Double(row.values.reduce(0, +))
            var base = 0.0
            for qm in [2, 4, 6, 8] {
                guard let n = row[qm], n > 0 else { continue }
                let share = Double(n) / total
                bars.append(StackedBar(id: bars.count, t: Double(sec) * 1000 + 500, low: base, high: base + share,
                                       group: RadioStyle.modulationName(qm: qm)))
                base += share
            }
        }
        return PhyChart(title: "Modulation mix per second", unit: "share of TBs",
                        empty: bars.isEmpty ? RadioData.emptyReason(phy, .lte_dl_modulation) : nil,
                        yDomain: 0...1, height: 110, session: session) {
            ForEach(bars) { b in
                BarMark(x: .value("t", b.t), yStart: .value("share", b.low), yEnd: .value("share", b.high),
                        width: .fixed(barWidth(window)))
                    .foregroundStyle(modulationColor(b.group))
            }
        }
    }

    private func barWidth(_ window: ClosedRange<Double>) -> CGFloat {
        let seconds = max(1, (window.upperBound - window.lowerBound) / 1000)
        return max(2, min(24, 300 / seconds))
    }

    private func blockChart(_ title: String, _ unit: String, _ m: PhyMetric, _ window: ClosedRange<Double>,
                            yDomain: ClosedRange<Double>? = nil) -> some View {
        let s = samples(m)
        let pts = RadioData.points(s, window: window, series: title)
        return PhyChart(title: title, unit: unit, empty: s.isEmpty ? RadioData.emptyReason(phy, m) : nil, yDomain: yDomain,
                        session: session) {
            ForEach(pts) { p in
                PointMark(x: .value("t", p.t), y: .value(unit, p.y))
                    .foregroundStyle(RadioStyle.lines[0].opacity(0.8))
                    .symbolSize(10)
            }
        }
    }

    /// Layers per scheduling record as a step line (transmit diversity drawn at 1, in its own colour), with the rank
    /// the CSI reported dashed on the same axis.
    private func layersChart(_ window: ClosedRange<Double>) -> some View {
        let layers = samples(.lte_dl_layers)
        let used = RadioData.points(layers, window: window, series: "Layers used", gapMs: 500,
                                    group: { RadioData.layersCategory(layers: Int($0.value ?? 0), transportBlocks: $0.tag ?? 0) },
                                    value: { s in
                                        guard let v = s.value else { return nil }
                                        return v == 4 && s.tag == 1 ? 1 : v
                                    })
        let ri = RadioData.points(RadioData.series(phy, .lte_ri).filter { carrier == nil ? $0.carrier == 0 : $0.carrier == carrier },
                                  window: window, series: "RI reported", gapMs: 1000)
        let pts = RadioData.joined([used, ri])
        let txd = used.filter { $0.group == "TxD" }
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: "Layers used and rank reported", unit: "layers",
                     empty: layers.isEmpty ? RadioData.emptyReason(phy, .lte_dl_layers) : nil, yDomain: 0.5...4.5, session: session) {
                ForEach(pts) { p in
                    LineMark(x: .value("t", p.t), y: .value("layers", p.y), series: .value("s", "\(p.series)-\(p.segment)"))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(p.series == "RI reported" ? RadioStyle.lines[2] : RadioStyle.lines[0])
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: p.series == "RI reported" ? [4, 3] : []))
                }
                ForEach(txd) { p in
                    PointMark(x: .value("t", p.t), y: .value("layers", 1)).foregroundStyle(RadioStyle.lines[3]).symbolSize(14)
                }
            }
            LegendRow(items: [("Layers used", RadioStyle.lines[0]), ("RI reported (CSF)", RadioStyle.lines[2]),
                              ("TxD: 4 ports, 1 layer", RadioStyle.lines[3])])
            if layers.contains(where: { $0.value == 3 }) {
                Text("3 layers appear in \(layers.filter { $0.value == 3 }.count) records only and are not verified.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Time share of the layers used against the rank the UE reported, over the visible window.
    private func rankShare(_ window: ClosedRange<Double>) -> some View {
        var used: [String: Int] = [:]
        var total = 0
        for s in PhyQuery.slice(samples(.lte_dl_layers), window) {
            guard let v = s.value else { continue }
            used[RadioData.layersCategory(layers: Int(v), transportBlocks: s.tag ?? 0), default: 0] += 1
            total += 1
        }
        let riSeries = PhySeries(metric: .lte_ri, unit: "rank", code: 0xB14E, version: "", confidence: .medium,
                                 samples: RadioData.series(phy, .lte_ri).filter { $0.carrier == (carrier ?? 0) })
        let reported = PhyQuery.timeShare(riSeries, window: window)
        let order = ["1", "2", "3 (unverified)", "TxD"]
        var bars: [TimePoint] = []
        for cat in order where (used[cat] ?? 0) > 0 {
            bars.append(TimePoint(id: bars.count, t: 0, y: Double(used[cat]!) / Double(max(total, 1)), series: "Used", segment: 0, group: cat))
        }
        for r in reported.keys.sorted() {
            bars.append(TimePoint(id: bars.count, t: 0, y: reported[r]!, series: "Reported", segment: 0, group: String(r)))
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Rank used vs reported (visible window)").font(.subheadline.weight(.semibold))
            if bars.isEmpty {
                EmptyChartNote(text: RadioData.emptyReason(phy, .lte_dl_layers))
            } else {
                Chart(bars) { b in
                    BarMark(x: .value("share", b.y), y: .value("", b.series))
                        .foregroundStyle(by: .value("layers", b.group))
                        .annotation(position: .overlay) {
                            if b.y > 0.12 { Text(b.group + " " + percent(b.y)).font(.caption2).foregroundStyle(.white) }
                        }
                }
                .chartForegroundStyleScale(domain: order, range: [RadioStyle.lines[0], RadioStyle.lines[2], RadioStyle.other, RadioStyle.lines[3]])
                .chartXAxis { AxisMarks(values: [0, 0.5, 1]) { AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent()) } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 90)
            }
        }
    }

    private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
}

/// One bar drawn from `low` to `high` (stacks are computed here, not by the chart).
struct StackedBar: Identifiable {
    var id: Int
    var t: Double
    var low: Double
    var high: Double
    var group: String
    var carrier = 0
}

extension DownlinkSection {

    /// Per-second bins, one bar per second with each carrier's part stacked in carrier order.
    private func binChart(_ title: String, _ unit: String, _ m: PhyMetric, _ window: ClosedRange<Double>,
                          badges: [RadioBadge] = [], stacked: Bool = true) -> some View {
        let s = samples(m)
        var bars: [StackedBar] = []
        var base: [Double: Double] = [:]
        for x in PhyQuery.slice(s, window) {
            guard let v = x.value else { continue }
            let low = stacked ? base[x.tMs, default: 0] : 0
            bars.append(StackedBar(id: bars.count, t: x.tMs, low: low, high: low + v, group: RadioStyle.carrierName(x.carrier),
                                   carrier: x.carrier))
            if stacked { base[x.tMs] = low + v }
        }
        let carriers = Set(s.map(\.carrier)).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: title, unit: unit, badges: badges, empty: s.isEmpty ? RadioData.emptyReason(phy, m) : nil,
                     yDomain: 0...max(bars.map(\.high).max() ?? 1, stacked ? 0.1 : 1) * 1.05, height: 110, session: session) {
                ForEach(bars) { b in
                    BarMark(x: .value("t", b.t), yStart: .value(unit, b.low), yEnd: .value(unit, b.high), width: .fixed(barWidth(window)))
                        .foregroundStyle(RadioStyle.lines[b.carrier % RadioStyle.lines.count].opacity(stacked ? 1 : 0.7))
                }
            }
            if carriers.count > 1 {
                LegendRow(items: carriers.map { (RadioStyle.carrierName($0), RadioStyle.lines[$0 % RadioStyle.lines.count]) })
            }
        }
    }

    private func carrierIndex(_ name: String) -> Int { name == "PCell" ? 0 : Int(name.dropFirst(6)) ?? 0 }
}
