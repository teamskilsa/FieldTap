import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// LTE uplink from 0xB139 (PUSCH) and 0xB064 (MAC): PRB, TBS, modulation and code rate, the MCS derived from the
/// TBS table, the required PUSCH power against Pcmax, power headroom, UL grants and the scheduled rate. BSR is
/// not plotted: its fields are not validated yet.
struct UplinkSection: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let window = session.visibleWindow
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Uplink, LTE", source: "0xB139 v162 PUSCH Tx report, 0xB064 v1 / 0x08 v7 MAC UL", session: session,
                          warning: RadioData.warning(phy, checks: ["b139TbsModulation", "b064HeaderAccounting"])) { t in
                Self.readouts(phy, t)
            }
            points("PRB", "PRB", .lte_ul_prb, window, yDomain: 0...50)
            points("TBS", "bytes", .lte_ul_tbs, window)
            points("Modulation", "Qm", .lte_ul_modulation, window, yDomain: 1...8.5)
            points("Code rate", "ratio", .lte_ul_code_rate, window)
            points("MCS", "index", .lte_ul_mcs_derived, window, yDomain: 0...28,
                   badges: [.derived, RadioBadge(text: "from the TBS table")])
            powerChart(window)
            points("Power headroom", "dB", .lte_power_headroom, window, badges: [RadioBadge(text: "PHR, 1 dB steps")])
            points("UL grant", "bytes", .lte_mac_ul_grant, window)
            scheduledChart(window)
        }
    }

    static func readouts(_ phy: PhyCapture, _ t: Double) -> [Readout] {
        let power = RadioData.latest(phy, .lte_pusch_tx_power_required, at: t)
        return [
            Readout(label: "PRB", value: RadioFormat.int(RadioData.latest(phy, .lte_ul_prb, at: t)?.value)),
            Readout(label: "MCS", value: RadioFormat.int(RadioData.latest(phy, .lte_ul_mcs_derived, at: t)?.value)),
            Readout(label: "PUSCH power", value: RadioFormat.value(power?.value, 1, "dBm"), stale: power == nil),
            Readout(label: "PHR", value: RadioFormat.value(RadioData.latest(phy, .lte_power_headroom, at: t, maxAge: 2000)?.value, 0, "dB")),
            Readout(label: "UL scheduled", value: RadioFormat.value(RadioData.bin(phy, .lte_ul_phy_throughput, at: t, carrier: nil), 2, "Mbit/s")),
        ]
    }

    private func points(_ title: String, _ unit: String, _ m: PhyMetric, _ window: ClosedRange<Double>,
                        yDomain: ClosedRange<Double>? = nil, badges: [RadioBadge] = []) -> some View {
        let s = RadioData.series(phy, m)
        let pts = RadioData.points(s, window: window, series: title)
        return PhyChart(title: title, unit: unit, badges: badges, empty: s.isEmpty ? RadioData.emptyReason(phy, m) : nil,
                        yDomain: yDomain, session: session) {
            ForEach(pts) { p in
                PointMark(x: .value("t", p.t), y: .value(unit, p.y))
                    .foregroundStyle(RadioStyle.lines[0].opacity(0.8))
                    .symbolSize(10)
            }
        }
    }

    /// Required PUSCH power (0.25 dB steps, before Pcmax): above about 23 dBm the UE is power-limited.
    private func powerChart(_ window: ClosedRange<Double>) -> some View {
        let s = RadioData.series(phy, .lte_pusch_tx_power_required)
        let pts = RadioData.points(s, window: window, series: "power")
        let top = max(30, (pts.map(\.y).max() ?? 23) + 2)
        return VStack(alignment: .leading, spacing: 4) {
            PhyChart(title: "PUSCH power required", unit: "dBm", badges: [.beforePcmax, RadioBadge(text: "±1.5 dB absolute", kind: .medium)],
                     empty: s.isEmpty ? RadioData.emptyReason(phy, .lte_pusch_tx_power_required) : nil, session: session) {
                RectangleMark(xStart: .value("t", window.lowerBound), xEnd: .value("t", window.upperBound),
                              yStart: .value("dBm", 23), yEnd: .value("dBm", top))
                    .foregroundStyle(Theme.severity(.warning).opacity(0.08))
                RuleMark(y: .value("Pcmax", 23))
                    .foregroundStyle(Theme.severity(.warning))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Pcmax ≈ 23 dBm").font(.caption2).foregroundStyle(.secondary)
                    }
                ForEach(pts) { p in
                    PointMark(x: .value("t", p.t), y: .value("dBm", p.y))
                        .foregroundStyle(RadioStyle.lines[0].opacity(0.8))
                        .symbolSize(10)
                }
            }
            Text("Above the line the UE is power-limited: it sends at Pcmax, not at the required power.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func scheduledChart(_ window: ClosedRange<Double>) -> some View {
        let s = RadioData.series(phy, .lte_ul_phy_throughput)
        let bars = RadioData.points(s, window: window, series: "UL scheduled")
        let seconds = max(1, (window.upperBound - window.lowerBound) / 1000)
        return VStack(alignment: .leading, spacing: 4) {
            PhyChart(title: "UL scheduled per second", unit: "Mbit/s", empty: s.isEmpty ? RadioData.emptyReason(phy, .lte_ul_phy_throughput) : nil,
                     height: 110, session: session) {
                ForEach(bars) { b in
                    BarMark(x: .value("t", b.t), yStart: .value("Mbit/s", 0), yEnd: .value("Mbit/s", b.y),
                            width: .fixed(max(2, min(24, 300 / seconds))))
                        .foregroundStyle(RadioStyle.lines[1])
                }
            }
            Text("Scheduled PUSCH TBS, retransmissions included: an upper bound, not delivered throughput.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
