import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// Channel state from 0xB14E (PUSCH CSF, aperiodic) and 0xB14D (PUCCH CSF, periodic): wideband CQI per
/// codeword, rank and PMI, and the transmission mode. 0xB14D's bit positions are medium confidence.
struct CsiSection: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let window = session.visibleWindow
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Channel state (CSI), LTE PCell", source: "0xB14E and 0xB14D v164 CSF reports", session: session) { t in
                Self.readouts(phy, t)
            }
            HStack(spacing: 6) {
                if let tm = transmissionMode { BadgeView(badge: RadioBadge(text: "TM\(tm) (CSF)")) }
                BadgeView(badge: RadioBadge(text: "0xB14D: medium confidence", kind: .medium))
            }
            cqiChart(window)
            stepChart("Rank indicator", "rank", .lte_ri, window, yDomain: 0.5...2.5)
            stepChart("Wideband PMI", "index", .lte_pmi_wideband, window, yDomain: 0...15, points: true)
        }
    }

    static func readouts(_ phy: PhyCapture, _ t: Double) -> [Readout] {
        [
            Readout(label: "CQI CW0", value: RadioFormat.int(RadioData.latest(phy, .lte_cqi_wideband_cw0, at: t)?.value)),
            Readout(label: "CQI CW1", value: RadioFormat.int(RadioData.latest(phy, .lte_cqi_wideband_cw1, at: t)?.value)),
            Readout(label: "RI", value: RadioFormat.int(RadioData.latest(phy, .lte_ri, at: t)?.value)),
            Readout(label: "PMI", value: RadioFormat.int(RadioData.latest(phy, .lte_pmi_wideband, at: t)?.value)),
        ]
    }

    private var transmissionMode: Int? {
        let v = RadioData.series(phy, .lte_csf_tx_mode).compactMap(\.value)
        guard !v.isEmpty else { return nil }
        let counts = Dictionary(grouping: v, by: { Int($0) }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    private func pcell(_ m: PhyMetric) -> [PhySample] { RadioData.series(phy, m).filter { $0.carrier == 0 } }

    private func cqiChart(_ window: ClosedRange<Double>) -> some View {
        let cw0 = pcell(.lte_cqi_wideband_cw0), cw1 = pcell(.lte_cqi_wideband_cw1)
        let pts = RadioData.joined([
            RadioData.points(cw0, window: window, series: "CW0", group: { $0.tag == CsfSource.pucch ? "PUCCH" : "PUSCH" }),
            RadioData.points(cw1, window: window, series: "CW1"),
        ])
        return VStack(alignment: .leading, spacing: 6) {
            PhyChart(title: "Wideband CQI", unit: "CQI", badges: [.medium],
                     empty: cw0.isEmpty ? RadioData.emptyReason(phy, .lte_cqi_wideband_cw0) : nil, yDomain: 0...15, session: session) {
                ForEach(pts) { p in
                    LineMark(x: .value("t", p.t), y: .value("CQI", p.y), series: .value("s", "\(p.series)-\(p.segment)"))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(p.series == "CW0" ? RadioStyle.lines[0] : RadioStyle.lines[2])
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                ForEach(pts.filter { $0.group == "PUCCH" }) { p in
                    PointMark(x: .value("t", p.t), y: .value("CQI", p.y))
                        .symbol(.diamond).symbolSize(12).foregroundStyle(RadioStyle.lines[1])
                }
            }
            LegendRow(items: [("CW0", RadioStyle.lines[0]), ("CW1 (rank 2)", RadioStyle.lines[2]),
                              ("from 0xB14D (periodic)", RadioStyle.lines[1])])
        }
    }

    private func stepChart(_ title: String, _ unit: String, _ m: PhyMetric, _ window: ClosedRange<Double>,
                           yDomain: ClosedRange<Double>, points: Bool = false) -> some View {
        let s = pcell(m)
        let pts = RadioData.points(s, window: window, series: title)
        return PhyChart(title: title, unit: unit, badges: [.medium], empty: s.isEmpty ? RadioData.emptyReason(phy, m) : nil,
                        yDomain: yDomain, height: 110, session: session) {
            ForEach(pts) { p in
                if points {
                    PointMark(x: .value("t", p.t), y: .value(unit, p.y)).foregroundStyle(RadioStyle.lines[0]).symbolSize(10)
                } else {
                    LineMark(x: .value("t", p.t), y: .value(unit, p.y), series: .value("s", p.segment))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(RadioStyle.lines[0])
                }
            }
        }
    }
}
