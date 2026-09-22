import SwiftUI
import FTApp
import FTJourney
import FTModel
import FTPhy

/// Carrier aggregation and EN-DC at a glance: one column per active carrier (PCell, SCells, NR PSCell) with the
/// values at the cursor, row labels fixed on the left and the columns paging three at a time.
struct CarriersGrid: View {
    @Bindable var session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Carriers", source: "Active carriers from the journey (else 0xB193 serving records); values at the cursor",
                          session: session) { _ in [] }
            CarrierTable(session: session)
        }
    }
}

/// The table itself; only it follows the cursor.
struct CarrierTable: View {
    @Bindable var session: CaptureSession

    static let rows = ["EARFCN / ARFCN", "PCI", "Band", "BW (PRB)", "Rx antennas", "RSRP", "RSRQ", "CQI", "RI",
                       "DL MCS (1 s median)", "Layers", "BLER", "PHY Mbit/s", "UL PRB / MCS", "PUSCH power", "PHR", "TA"]

    struct Column: Identifiable {
        var id: String
        var title: String
        var values: [String?]
    }

    var body: some View {
        let t = session.cursor.ms
        let columns = Self.columns(at: t, session: session)
        VStack(alignment: .leading, spacing: 6) {
            if columns.isEmpty {
                EmptyChartNote(text: "No serving carrier at \(RadioFormat.clockMs(t)) (radio off, or idle between connections).")
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        cell("", header: true)
                        ForEach(Self.rows, id: \.self) { cell($0, label: true) }
                    }
                    .frame(width: 118)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) {
                            ForEach(columns) { col in
                                VStack(alignment: .leading, spacing: 0) {
                                    cell(col.title, header: true)
                                    ForEach(Self.rows.indices, id: \.self) { i in cell(col.values[i]) }
                                }
                                .containerRelativeFrame(.horizontal, count: min(3, columns.count), spacing: 0)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                if columns.count > 3 {
                    Text("Swipe for more carriers").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func cell(_ text: String?, header: Bool = false, label: Bool = false) -> some View {
        Text(text ?? "–")
            .font(header ? .caption.weight(.semibold) : (label ? .caption : .caption.monospacedDigit()))
            .foregroundStyle(label ? .secondary : (text == nil ? .tertiary : .primary))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, 8)
    }

    @MainActor static func columns(at t: Double, session: CaptureSession) -> [Column] {
        let phy = session.analysis.phy
        let active = RadioData.active(at: t, session: session)
        let inferred = PhyBandwidth.inferredPrb(phy)
        var out: [Column] = active.lte.map { c in
            let i = c.index
            func v(_ m: PhyMetric, _ digits: Int, _ unit: String = "", maxAge: Double = 500) -> String? {
                RadioData.latest(phy, m, at: t, maxAge: maxAge, carrier: i)?.value.map { RadioFormat.value($0, digits, unit) }
            }
            let mib = PhyQuery.latest(RadioData.series(phy, .lte_dl_bandwidth_prb), atOrBefore: t, maxAgeMs: .infinity) {
                $0.earfcn == c.earfcn
            }
            let bw = (i == 0 ? mib?.value.map { Int($0) } : nil) ?? inferred[c.earfcn]
            let layers = RadioData.latest(phy, .lte_dl_layers, at: t, carrier: i)
            let ulPrb = v(.lte_ul_prb, 0), ulMcs = v(.lte_ul_mcs_derived, 0)
            let rach = i == 0 ? phy.summary.rach.last(where: { $0.tMs <= t }) : nil
            return Column(id: "lte\(i)", title: RadioStyle.carrierName(i), values: [
                String(c.earfcn), String(c.pci), RadioFormat.band(c.earfcn), bw.map { "\($0)\(i == 0 && mib != nil ? "" : " (inferred)")" },
                v(.lte_rx_antennas_measured, 0), v(.lte_rsrp_filtered, 1, "dBm"), v(.lte_rsrq_filtered, 1, "dB"),
                v(.lte_cqi_wideband_cw0, 0), v(.lte_ri, 0),
                RadioData.median1s(phy, .lte_dl_mcs, at: t, carrier: i).map { RadioFormat.int($0) },
                layers.map { RadioData.layersLabel($0) },
                RadioData.bin(phy, .lte_dl_bler, at: t, carrier: i).map { RadioFormat.value($0, 1, "%") },
                RadioData.bin(phy, .lte_dl_phy_throughput, at: t, carrier: i).map { RadioFormat.value($0, 2) },
                (ulPrb == nil && ulMcs == nil) ? nil : "\(ulPrb ?? "–") / \(ulMcs ?? "–")",
                v(.lte_pusch_tx_power_required, 1, "dBm"), v(.lte_power_headroom, 0, "dB", maxAge: 2000),
                rach.map { "\($0.ta) (\(RadioFormat.value(($0.distanceM ?? 0) / 1000, 2, "km")))" },
            ])
        }
        if let nr = active.nr {
            let serving = { (m: PhyMetric) in
                PhyQuery.latest(RadioData.series(phy, m), atOrBefore: t, maxAgeMs: 2000) { $0.tag == CellRole.serving }
            }
            let bands = nr.arfcn.map { NrBands.candidates(arfcn: $0, mcc: nil) } ?? []
            out.append(Column(id: "nr", title: "NR PSCell", values: [
                nr.arfcn.map(String.init), nr.pci.map(String.init), bands.isEmpty ? nil : bands.map { "n\($0)" }.joined(separator: "/"),
                nil, nil, serving(.nr_ss_rsrp)?.value.map { RadioFormat.value($0, 1, "dBm") },
                serving(.nr_ss_rsrq)?.value.map { RadioFormat.value($0, 1, "dB") }, "encrypted", "encrypted",
                RadioData.median1s(phy, .nr_dl_mcs, at: t, carrier: nil).map { RadioFormat.int($0) },
                RadioData.latest(phy, .nr_dl_layers, at: t, carrier: nil)?.value.map { RadioFormat.int($0) },
                RadioData.latest(phy, .nr_dl_bler, at: t, maxAge: 2000, carrier: nil)?.value.map { RadioFormat.value($0, 1, "%") },
                RadioData.latest(phy, .nr_dl_mac_throughput, at: t, maxAge: 2000, carrier: nil)?.value.map { RadioFormat.value($0, 2) },
                "not decoded", nil, nil, nil,
            ]))
        }
        return out
    }
}
