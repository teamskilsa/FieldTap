import SwiftUI
import FTApp
import FTJourney
import FTModel

/// Two lines above every capture page: where the phone was at the cursor (state, serving cell, the NR leg and
/// CA chips), then the signal values there. A value older than its staleness limit shows as a dimmed dash.
/// Tapping it opens Radio > Carriers.
struct ServingHeaderView: View {
    @Bindable var session: CaptureSession

    var body: some View {
        let snap = JourneyQuery.serving(at: session.cursor.ms, journey: session.analysis.journey, phy: session.analysis.phy)
        Button {
            session.radioSection = "carriers"
            session.page = .radio
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                cellLine(snap)
                valuesLine(snap)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(snap))
        .accessibilityHint("Opens the carriers on the Radio page")
    }

    // MARK: Line 1

    @ViewBuilder private func cellLine(_ s: ServingSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: stateSymbol(s.state))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(s.state == .connected ? Theme.accent : .secondary)
                .frame(width: 16)
            Text(primary(s))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let nr = s.pscell {
                chip("+NR \(nr.cell.earfcn)/\(nr.cell.pci) (\(JourneyText.band(nr)))", fill: JourneyStyle.fill(nr))
            }
            if !s.scells.isEmpty {
                chip("CA \(s.scells.count)", fill: Theme.accent)
            }
            Spacer(minLength: 0)
        }
    }

    private func primary(_ s: ServingSnapshot) -> String {
        guard let p = s.pcell else {
            switch s.state {
            case .radioOff: return "Radio off"
            case .unknown: return "No serving cell yet"
            default: return "No serving cell"
            }
        }
        let cell = "\(JourneyStyle.rat(p.cell)) \(JourneyText.band(p)) · \(p.cell.earfcn) · PCI \(p.cell.pci)"
        return s.state == .idle ? "Idle on \(cell)" : cell
    }

    private func chip(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill.opacity(0.18)))
            .overlay(Capsule().strokeBorder(fill.opacity(0.6), lineWidth: 0.5))
            .fixedSize()
    }

    // MARK: Line 2

    @ViewBuilder private func valuesLine(_ s: ServingSnapshot) -> some View {
        HStack(spacing: 10) {
            // Units only when they fit: on a 402 pt iPhone "RSRP −120 dBm" otherwise truncates to "RSRP −12…".
            ViewThatFits(in: .horizontal) {
                values(s, units: true, spacing: 10)
                values(s, units: false, spacing: 8)
                values(s, units: false, spacing: 5)
            }
            Spacer(minLength: 0)
            Text(JourneyText.clock(session.cursor.ms))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func values(_ s: ServingSnapshot, units: Bool, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            HStack(spacing: 3) {
                let level = Theme.SignalLevel.rsrp(s.rsrp)
                Image(systemName: "cellularbars", variableValue: bars(level))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.signal(level))
                value("RSRP", s.rsrp.map { "\(Int($0.rounded()))" + (units ? " dBm" : "") }, stale: s.stale.contains("rsrp"))
            }
            value("RSRQ", s.rsrq.map { "\(Int($0.rounded()))" + (units ? " dB" : "") }, stale: s.stale.contains("rsrq"))
            value("CQI", s.cqi.map(String.init), stale: s.stale.contains("cqi"))
            value("RI", s.ri.map(String.init), stale: s.stale.contains("ri"))
            value("MCS", s.dlMcs.map(String.init), stale: s.stale.contains("dlMcs"))
        }
        .fixedSize()
    }

    private func value(_ name: String, _ v: String?, stale: Bool) -> some View {
        HStack(spacing: 2) {
            Text(name).foregroundStyle(.secondary)
            Text(v.map { $0.replacingOccurrences(of: "-", with: "−") } ?? "–")
                .monospacedDigit()
                .foregroundStyle(v == nil ? .tertiary : .primary)
        }
        .opacity(stale ? 0.55 : 1)
    }

    private func bars(_ level: Theme.SignalLevel?) -> Double {
        switch level {
        case .excellent: 1
        case .good: 0.75
        case .fair: 0.5
        case .poor: 0.25
        case nil: 0
        }
    }

    private func stateSymbol(_ s: RadioState) -> String {
        switch s {
        case .connected: "dot.radiowaves.left.and.right"
        case .idle: "moon.zzz"
        case .radioOff: "power"
        case .unknown: "questionmark.circle"
        }
    }

    private func spoken(_ s: ServingSnapshot) -> String {
        var parts = [primary(s)]
        if let nr = s.pscell { parts.append("plus NR \(nr.cell.earfcn), PCI \(nr.cell.pci), band \(JourneyText.band(nr))") }
        if !s.scells.isEmpty { parts.append("\(s.scells.count) secondary cells") }
        if let r = s.rsrp { parts.append("RSRP \(Int(r.rounded())) dBm, \(Theme.SignalLevel.rsrp(r)?.word ?? "")") }
        if let q = s.rsrq { parts.append("RSRQ \(Int(q.rounded())) dB") }
        if let c = s.cqi { parts.append("CQI \(c)") }
        if let r = s.ri { parts.append("rank \(r)") }
        if let m = s.dlMcs { parts.append("MCS \(m)") }
        if !s.stale.isEmpty { parts.append("\(s.stale.count) values out of date") }
        parts.append("at \(JourneyText.clock(session.cursor.ms))")
        return parts.joined(separator: ", ")
    }
}
