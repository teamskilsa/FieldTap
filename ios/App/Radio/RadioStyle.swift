import SwiftUI
import Charts
import UIKit
import FTApp
import FTCore
import FTModel

/// Colours, formats and small pieces the Radio charts share. Series colours are validated with the dataviz
/// palette checker (adjacent pairs, light and dark): lines use blue, aqua, violet, magenta in that order; scatter
/// charts use the three slots that validate all-pairs plus a shape per series; modulation is one blue ramp,
/// light to dark by order. None of them is the signal scale's green, orange or red.
enum RadioStyle {
    /// Slots for line series in fixed order (Rx0-Rx3; PCell, SCell 1-3).
    static let lines: [Color] = [
        .adaptive(0x2A_78D6, 0x39_87E5), .adaptive(0x1B_AF7A, 0x19_9E70),
        .adaptive(0x4A_3AA7, 0x90_85E9), .adaptive(0xE8_7BA4, 0xD5_5181),
    ]

    /// Slots for point clouds where every pair can touch (PCIs); the fourth and later fold into grey.
    static let points: [Color] = [.adaptive(0x2A_78D6, 0x39_87E5), .adaptive(0xEB_6834, 0xD9_5926),
                                  .adaptive(0x1B_AF7A, 0x19_9E70)]
    static let other = Color.adaptive(0x89_8781, 0x89_8781)

    /// QPSK, 16QAM, 64QAM, 256QAM: one hue, darker (light mode) or brighter (dark mode) with order.
    static let modulation: [Color] = [.adaptive(0x86_B6EF, 0x1C_5CAB), .adaptive(0x39_87E5, 0x2A_78D6),
                                      .adaptive(0x25_6ABF, 0x55_98E7), .adaptive(0x10_4281, 0x9E_C5F4)]
    static let modulationNames = ["QPSK", "16QAM", "64QAM", "256QAM"]

    static func modulationName(qm: Int) -> String {
        switch qm {
        case 2: "QPSK"
        case 4: "16QAM"
        case 6: "64QAM"
        case 8: "256QAM"
        default: "Qm \(qm)"
        }
    }

    static let chartHeight: CGFloat = 150

    /// The shapes that go with `points` (identity never rests on colour alone).
    static let shapes: [BasicChartSymbolShape] = [.circle, .square, .triangle, .diamond, .pentagon, .cross]

    static func carrierName(_ index: Int) -> String { index == 0 ? "PCell" : "SCell \(index)" }
}

extension Color {
    /// A colour with its own light and dark step (0xRRGGBB).
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

/// How the Radio page writes times and values.
enum RadioFormat {
    /// "0:15" for axis labels.
    static func clock(_ ms: Double) -> String {
        let s = max(0, ms / 1000)
        let whole = Int(s)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// "0:15.040" for the cursor and event times.
    static func clockMs(_ ms: Double) -> String {
        let total = max(0, Int((ms).rounded()))
        return "\(total / 60_000):" + String(format: "%02d.%03d", (total / 1000) % 60, total % 1000)
    }

    static func value(_ v: Double?, _ digits: Int, _ unit: String = "") -> String {
        guard let v, v.isFinite else { return "–" }
        return Fmt.fixed(v, digits) + (unit.isEmpty ? "" : " " + unit)
    }

    static func int(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        return String(Int(v.rounded()))
    }

    static func count(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }

    static func hex(_ code: UInt16) -> String { Fmt.hex(code, width: 4) }

    /// "B66" for an LTE EARFCN, or nil.
    static func band(_ earfcn: Int64?) -> String? { Spectrum.lte(earfcn).map { "B\($0.band)" } }
}

/// A small label beside a chart title: how far to trust a value, or where it comes from.
struct RadioBadge: Identifiable, Hashable {
    enum Kind: Hashable { case info, derived, medium, warning }
    var text: String
    var kind: Kind = .info
    var id: String { text }

    static let derived = RadioBadge(text: "derived", kind: .derived)
    static let medium = RadioBadge(text: "medium confidence", kind: .medium)
    static let beforePcmax = RadioBadge(text: "before Pcmax", kind: .medium)

    static func confidence(_ c: PhyConfidence) -> RadioBadge? {
        switch c {
        case .high: nil
        case .medium: .medium
        case .derived: .derived
        }
    }
}

struct BadgeView: View {
    var badge: RadioBadge

    var body: some View {
        Label {
            Text(badge.text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(foreground)
        .background(Capsule().fill(foreground.opacity(0.12)))
        .accessibilityLabel(badge.text)
    }

    private var symbol: String? {
        switch badge.kind {
        case .info: nil
        case .derived: "function"
        case .medium: "questionmark.circle"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var foreground: Color {
        switch badge.kind {
        case .info: .secondary
        case .derived, .medium: Theme.accent
        case .warning: Theme.severity(.warning)
        }
    }
}

/// A legend entry that also toggles its series.
struct LegendChip: View {
    var title: String
    var color: Color
    var shape: BasicChartSymbolShape? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle().fill(isOn ? color : Color.clear).strokeBorder(color, lineWidth: 1.5).frame(width: 9, height: 9)
                Text(title).font(.caption2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(isOn ? 0.12 : 0.04)))
            .foregroundStyle(isOn ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "shown" : "hidden")
    }
}

/// A plain legend (series identity without a toggle).
struct LegendRow: View {
    var items: [(String, Color)]

    var body: some View {
        FlowRow(spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(items[i].1).frame(width: 10, height: 10)
                    Text(items[i].0).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
        }
    }
}

/// One value at the cursor in a section header.
struct Readout: Identifiable, Hashable {
    var label: String
    var value: String
    var stale = false
    var id: String { label }
}

/// A section's title, source records and values at the cursor (only this view follows the cursor).
struct SectionHeader: View {
    var title: String
    var source: String
    @Bindable var session: CaptureSession
    var warning: String? = nil
    var readouts: (Double) -> [Readout]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text("at " + RadioFormat.clockMs(session.cursor.ms)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(source).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            let values = readouts(session.cursor.ms)
            if !values.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6, alignment: .leading)], alignment: .leading,
                          spacing: 4) {
                    ForEach(values) { r in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            Text(r.value).font(.footnote.monospacedDigit().weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(r.stale ? .tertiary : .primary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.severity(.warning))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

/// What an empty chart says instead of drawing nothing.
struct EmptyChartNote: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.tertiary))
    }
}
