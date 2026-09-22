import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// Random access and timing (0xB062): each RACH with the timing advance of its response, the distance that
/// implies, the preamble target power and the uplink channel. Tapping one moves the cursor there.
struct RachSection: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    var body: some View {
        let rach = phy.summary.rach
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "RACH and timing advance", source: "0xB062 v1 / 0x06 v50 MAC RACH attempt", session: session) { t in
                guard let last = rach.last(where: { $0.tMs <= t }) else { return [Readout(label: "Last RACH", value: "none yet")] }
                return [Readout(label: "Last RACH", value: RadioFormat.clockMs(last.tMs)), Readout(label: "TA", value: String(last.ta)),
                        Readout(label: "Distance", value: RadioFormat.value((last.distanceM ?? 0) / 1000, 2, "km"))]
            }
            if rach.isEmpty {
                EmptyChartNote(text: RadioData.emptyReason(phy, .lte_timing_advance_rar))
            } else {
                PhyChart(title: "Timing advance per RACH", unit: "TA (16 Ts)", yDomain: 0...max(32, Double(rach.map(\.ta).max() ?? 0) + 4),
                         height: 110, session: session) {
                    ForEach(rach.indices, id: \.self) { i in
                        PointMark(x: .value("t", rach[i].tMs), y: .value("TA", rach[i].ta))
                            .foregroundStyle(RadioStyle.lines[0]).symbolSize(50)
                            .annotation(position: .top) { Text(String(rach[i].ta)).font(.caption2) }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(rach.indices, id: \.self) { i in
                        Button { session.cursor.set(rach[i].tMs) } label: { row(rach[i]) }.buttonStyle(.plain)
                        if i < rach.count - 1 { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            }
            Text("Only the timing advance of each random-access response is logged in plain form. The TA commands in between "
                 + "(0xB063) are not decoded yet, so there is no continuous TA.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ r: RachEvent) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(RadioFormat.clockMs(r.tMs)).font(.subheadline.monospacedDigit().weight(.semibold))
                Text("UL EARFCN \(r.ulEarfcn.map(String.init) ?? "–")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("TA \(r.ta), ≈ \(RadioFormat.value((r.distanceM ?? 0) / 1000, 2, "km"))").font(.subheadline.monospacedDigit())
                Text("preamble target \(RadioFormat.value(r.preambleTargetDbm, 0, "dBm"))").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "scope").foregroundStyle(.tertiary)
        }
        .padding(12)
        .contentShape(Rectangle())
        .accessibilityHint("Moves the time cursor to this RACH")
    }
}
