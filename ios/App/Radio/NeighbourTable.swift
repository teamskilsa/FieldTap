import SwiftUI
import FTApp
import FTModel
import FTPhy

/// The neighbour table 0xB179 makes possible: at the cursor, every intra-frequency neighbour the modem measured,
/// strongest first, with its RSRP, RSRQ and — the point of the table — its margin against the serving cell on the
/// same frequency. A neighbour that never gets more than a decibel or two ahead is why the phone did not hand
/// over, and no other record in the capture measures most of these cells at all.
///
/// 0xB179 carries no timestamp: every row here was placed in time by the record's own TTI (see PhyTtiAxis), which
/// the "own timing" self-check gates.
struct NeighbourTable: View {
    @Bindable var session: CaptureSession
    /// How far either side of the cursor a measurement still counts as "now".
    static let windowMs = 600.0

    private var phy: PhyCapture { session.analysis.phy }

    struct Row: Identifiable, Hashable {
        var pci: Int
        var earfcn: Int64?
        var rsrp: Double
        var rsrq: Double?
        var marginDb: Double
        var tMs: Double
        var id: String { "\(earfcn ?? 0)/\(pci)" }
    }

    var body: some View {
        let t = session.cursor.ms
        let rows = Self.rows(phy, at: t)
        let serving = Self.serving(phy, at: t)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Neighbours at \(RadioFormat.clockMs(t))").font(.subheadline.weight(.semibold))
                if let badge = RadioData.checkBadge(phy, "b179ServingRsrp", passed: "on 0xB193's scale") {
                    BadgeView(badge: badge)
                }
                Spacer(minLength: 0)
            }
            if rows.isEmpty {
                EmptyChartNote(text: empty)
            } else {
                VStack(spacing: 0) {
                    header
                    ForEach(rows) { r in
                        Divider()
                        row(r)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                if let s = serving {
                    // 0xB193's own value for the same cell, when it measured it at the same moment: that agreement
                    // is what fixes 0xB179's scale, so it is worth stating and never worth stating across cells.
                    let against = Self.b193Rsrp(phy, at: t, earfcn: s.earfcn, pci: s.pci)
                        .map { " (0xB193 measured the same cell at \(RadioFormat.value($0, 1, "dBm")))" } ?? ""
                    Text("Serving cell \(cellName(earfcn: s.earfcn, pci: s.pci)) at \(RadioFormat.value(s.rsrp, 1, "dBm"))"
                         + against + ". Margin is the neighbour minus the serving cell on its own frequency: "
                         + "positive means the neighbour is stronger.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("neighbourTable")
    }

    private var empty: String {
        let all = RadioData.series(phy, .lte_intra_neighbour_rsrp)
        if all.isEmpty { return RadioData.emptyReason(phy, .lte_intra_neighbour_rsrp) }
        return "No intra-frequency neighbour measurement within 0.6 s of the cursor. The modem logs these while it "
            + "is connected: \(RadioFormat.count(all.count)) in this capture."
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("PCI").frame(width: 46, alignment: .leading)
            Text("Frequency").frame(maxWidth: .infinity, alignment: .leading)
            Text("RSRP").frame(width: 62, alignment: .trailing)
            Text("RSRQ").frame(width: 52, alignment: .trailing)
            Text("Margin").frame(width: 60, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(_ r: Row) -> some View {
        HStack(spacing: 8) {
            Text(String(r.pci)).frame(width: 46, alignment: .leading)
            Text(cellName(earfcn: r.earfcn, pci: nil)).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(RadioFormat.value(r.rsrp, 1)).frame(width: 62, alignment: .trailing)
            Text(RadioFormat.value(r.rsrq, 1)).frame(width: 52, alignment: .trailing).foregroundStyle(.secondary)
            Text(margin(r.marginDb)).frame(width: 60, alignment: .trailing)
                .foregroundStyle(r.marginDb >= 0 ? Theme.severity(.warning) : .primary)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PCI \(r.pci), RSRP \(RadioFormat.value(r.rsrp, 1, "dBm")), margin \(margin(r.marginDb)) dB")
    }

    private func margin(_ v: Double) -> String { (v >= 0 ? "+" : "") + RadioFormat.value(v, 1) }

    private func cellName(earfcn: Int64?, pci: Int?) -> String {
        guard let earfcn else { return pci.map(String.init) ?? "–" }
        let band = RadioFormat.band(earfcn) ?? "EARFCN"
        return pci.map { "\(band) \(earfcn)/\($0)" } ?? "\(band) \(earfcn)"
    }

    /// The neighbours measured nearest to `t`, one row per (EARFCN, PCI), strongest first.
    static func rows(_ phy: PhyCapture, at t: Double) -> [Row] {
        let rsrp = PhyQuery.slice(RadioData.series(phy, .lte_intra_neighbour_rsrp), (t - windowMs)...(t + windowMs))
        let rsrq = PhyQuery.slice(RadioData.series(phy, .lte_intra_neighbour_rsrq), (t - windowMs)...(t + windowMs))
        let margin = PhyQuery.slice(RadioData.series(phy, .lte_intra_neighbour_margin), (t - windowMs)...(t + windowMs))
        func key(_ s: PhySample) -> String { "\(s.earfcn ?? 0)/\(s.pci ?? -1)/\(s.tMs)" }
        let rsrqByKey = Dictionary(rsrq.map { (key($0), $0.value) }, uniquingKeysWith: { a, _ in a })
        let marginByKey = Dictionary(margin.map { (key($0), $0.value) }, uniquingKeysWith: { a, _ in a })
        var best: [String: Row] = [:]
        for s in rsrp {
            guard let v = s.value, let pci = s.pci else { continue }
            let row = Row(pci: pci, earfcn: s.earfcn, rsrp: v, rsrq: (rsrqByKey[key(s)] ?? nil),
                          marginDb: (marginByKey[key(s)] ?? nil) ?? 0, tMs: s.tMs)
            if let old = best[row.id], abs(old.tMs - t) <= abs(row.tMs - t) { continue }
            best[row.id] = row
        }
        return best.values.sorted { ($0.rsrp, $0.pci) > ($1.rsrp, $1.pci) }
    }

    /// 0xB179's own measurement of the serving cell nearest to `t`.
    static func serving(_ phy: PhyCapture, at t: Double) -> (earfcn: Int64?, pci: Int?, rsrp: Double)? {
        let s = PhyQuery.slice(RadioData.series(phy, .lte_intra_serving_rsrp), (t - windowMs)...(t + windowMs))
            .min { abs($0.tMs - t) < abs($1.tMs - t) }
        guard let s, let v = s.value else { return nil }
        return (s.earfcn, s.pci, v)
    }

    /// 0xB193's filtered RSRP of one cell at the same moment, or nil when it did not measure that cell there.
    static func b193Rsrp(_ phy: PhyCapture, at t: Double, earfcn: Int64?, pci: Int?) -> Double? {
        guard let earfcn, let pci else { return nil }
        return PhyQuery.slice(RadioData.series(phy, .lte_rsrp_filtered), (t - windowMs)...(t + windowMs))
            .filter { $0.earfcn == earfcn && $0.pci == pci && $0.tag != CellRole.neighbour }
            .min { abs($0.tMs - t) < abs($1.tMs - t) }?.value
    }
}
