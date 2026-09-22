import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// MAC-level downlink accounting from 0xB063: the bytes that actually reached the MAC, how many of them were
/// padding, and how they split between signalling and user data. It answers "the session looks busy but nothing is
/// moving", which the PHY throughput cannot.
///
/// Every total here carries its coverage, which is the honest part. The transport-block header is validated against
/// 0xB173 on four fields at once, but the walk over each record's PDCP tail only reaches about 80% of the transport
/// blocks the records declare, so these bytes are a floor, not a total — and 0xB173 stays the throughput source.
struct MacSection: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let window = session.visibleWindow
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "MAC downlink accounting", source: "0xB063 v50 MAC DL transport block, with 0xB173 as the throughput source",
                          session: session,
                          warning: RadioData.warning(phy, checks: ["b063VsB173"])) { t in
                Self.readouts(phy, t)
            }
            accounting
            splitChart(window)
            points("Transport block at the MAC", "bytes", .lte_mac_dl_bytes, window)
            points("Padding per transport block", "bytes", .lte_mac_dl_padding, window, badges: [.medium])
            controlElements
        }
    }

    static func readouts(_ phy: PhyCapture, _ t: Double) -> [Readout] {
        let bytes = RadioData.latest(phy, .lte_mac_dl_bytes, at: t, maxAge: 1_000, servingOnly: false)
        guard let mac = phy.summary.macDl else {
            return [Readout(label: "MAC bytes", value: "–", stale: true)]
        }
        return [
            Readout(label: "Block at cursor", value: RadioFormat.value(bytes?.value, 0, "B"), stale: bytes == nil),
            Readout(label: "MAC bytes", value: RadioFormat.count(mac.macBytes)),
            Readout(label: "Padding", value: "\(Int((mac.paddingShare * 100).rounded()))%"),
            Readout(label: "Coverage", value: "\(Int((mac.coverage * 100).rounded()))%"),
        ]
    }

    /// The numbers, each with what it is a share of, and the coverage sentence under them.
    private var accounting: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mac = phy.summary.macDl {
                let useful = mac.macBytes - mac.paddingBytes
                VStack(alignment: .leading, spacing: 6) {
                    row("Bytes at the MAC", RadioFormat.count(mac.macBytes) + " B",
                        "in \(RadioFormat.count(mac.foundBlocks)) transport blocks the walk reached")
                    row("Useful", RadioFormat.count(useful) + " B",
                        "\(Int((Double(useful) / Double(max(mac.macBytes, 1)) * 100).rounded()))% of the bytes; the rest is padding")
                    row("Padding", RadioFormat.count(mac.paddingBytes) + " B",
                        "\(Int((mac.paddingShare * 100).rounded()))% of the grant was wasted", badge: .medium)
                    row("User data", RadioFormat.count(mac.dataBytes) + " B", "SDUs on LCID 3 and up")
                    row("Signalling", RadioFormat.count(mac.signallingBytes) + " B", "SDUs on LCID 0-2: CCCH and the DCCHs")
                    Divider()
                    Text("Coverage: \(Int((mac.coverage * 100).rounded()))% — "
                         + "\(RadioFormat.count(mac.foundBlocks)) of the \(RadioFormat.count(mac.declaredBlocks)) transport "
                         + "blocks these \(RadioFormat.count(mac.records)) records declare. The walk over each record's "
                         + "PDCP tail loses the rest, so every byte total above is a floor. Throughput stays 0xB173's.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            } else {
                EmptyChartNote(text: RadioData.emptyReason(phy, .lte_mac_dl_bytes))
            }
        }
        .accessibilityIdentifier("macAccounting")
    }

    private func row(_ label: String, _ value: String, _ detail: String, badge: RadioBadge? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label).font(.caption.weight(.semibold))
                    if let badge { BadgeView(badge: badge) }
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(value).font(.footnote.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    /// Signalling against user data per second, so a busy-looking session with no user data is visible.
    private func splitChart(_ window: ClosedRange<Double>) -> some View {
        var bars: [StackedBar] = []
        var base: [Double: Double] = [:]
        func add(_ m: PhyMetric, _ group: String) {
            var perSecond: [Int: Double] = [:]
            for s in PhyQuery.slice(RadioData.series(phy, m), window) {
                guard let v = s.value else { continue }
                perSecond[Int((s.tMs / 1_000).rounded(.down)), default: 0] += v
            }
            for sec in perSecond.keys.sorted() {
                let t = Double(sec) * 1_000 + 500
                let low = base[t, default: 0]
                bars.append(StackedBar(id: bars.count, t: t, low: low, high: low + perSecond[sec]!, group: group))
                base[t] = low + perSecond[sec]!
            }
        }
        add(.lte_mac_dl_data_bytes, "user data")
        add(.lte_mac_dl_signalling_bytes, "signalling")
        add(.lte_mac_dl_padding, "padding")
        let seconds = max(1, (window.upperBound - window.lowerBound) / 1_000)
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: "Useful against wasted, per second", unit: "bytes",
                     empty: bars.isEmpty ? RadioData.emptyReason(phy, .lte_mac_dl_bytes) : nil,
                     yDomain: 0...max(1, (bars.map(\.high).max() ?? 1) * 1.05), height: 130, session: session) {
                ForEach(bars) { b in
                    BarMark(x: .value("t", b.t), yStart: .value("bytes", b.low), yEnd: .value("bytes", b.high),
                            width: .fixed(max(2, min(24, 300 / seconds))))
                        .foregroundStyle(colour(b.group))
                }
            }
            LegendRow(items: [("user data", colour("user data")), ("signalling", colour("signalling")),
                              ("padding", colour("padding"))])
        }
    }

    private func colour(_ group: String) -> Color {
        switch group {
        case "user data": RadioStyle.lines[0]
        case "signalling": RadioStyle.lines[2]
        default: RadioStyle.other
        }
    }

    /// The MAC control elements the records carried, by LCID. Their bodies are not in the record, which is why the
    /// timing-advance command gives no value.
    private var controlElements: some View {
        let ces = phy.summary.macDl?.controlElements ?? [:]
        return VStack(alignment: .leading, spacing: 4) {
            Text("MAC control elements (TS 36.321 table 6.2.1-1)").font(.subheadline.weight(.semibold))
            if ces.isEmpty {
                Text("None in this capture.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(ces.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }, id: \.self) { lcid in
                    Text("LCID \(lcid) \(Self.ceName(lcid)): \(RadioFormat.count(ces[lcid] ?? 0))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text("The record logs each control element's LCID and length, not its body, so the timing-advance command "
                 + "(LCID 29) carries no value here: the only validated timing advance is the one in each "
                 + "random-access response (see RACH).")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func ceName(_ lcid: String) -> String {
        switch Int(lcid) ?? -1 {
        case 26: "(long DRX command)"
        case 27: "(activation / deactivation)"
        case 28: "(UE contention resolution identity)"
        case 29: "(timing advance command)"
        case 30: "(DRX command)"
        case 31: "(padding)"
        default: ""
        }
    }

    private func points(_ title: String, _ unit: String, _ m: PhyMetric, _ window: ClosedRange<Double>,
                        badges: [RadioBadge] = []) -> some View {
        let s = RadioData.series(phy, m)
        let pts = RadioData.points(s, window: window, series: title)
        return PhyChart(title: title, unit: unit, badges: badges, empty: s.isEmpty ? RadioData.emptyReason(phy, m) : nil,
                        session: session) {
            ForEach(pts) { p in
                PointMark(x: .value("t", p.t), y: .value(unit, p.y))
                    .foregroundStyle(RadioStyle.lines[0].opacity(0.8))
                    .symbolSize(10)
            }
        }
    }
}
