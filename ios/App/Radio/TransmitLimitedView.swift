import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// Is the phone transmit-limited, and on which chain? 0x184C logs the front end's own transmit power per chain, in
/// 0.1 dBm, next to the limit the front end set for that chain, so the answer is a subtraction rather than an
/// inference. An uplink-limited phone at the cell edge is the commonest cause of "full bars, nothing works", and
/// nothing else FieldTap decodes says it: 0xB139 gives the power the network *asked* for, before Pcmax.
///
/// The power is labelled "front-end Tx power", not "the phone's transmit power": a best fit against 0xB139's PUSCH
/// target leaves a 3.8 dB residual, which is the point — this is the chain's own power at its own instants — but
/// the absolute scale wants a second device before it gets a plainer name.
struct TransmitLimitedView: View {
    @Bindable var session: CaptureSession

    private var phy: PhyCapture { session.analysis.phy }

    /// One chain's state at a moment.
    struct Live: Hashable {
        var chain: Int
        var powerDbm: Double
        var limitDbm: Double
        var gainState: Int?
        var headroomDb: Double { limitDbm - powerDbm }
        var limited: Bool { headroomDb <= Live.limitedDb }
        /// Headroom at or below this counts as transmit-limited (the same constant the extractor counts with).
        static let limitedDb = 0.5
    }

    static let limitedDb = Live.limitedDb
    static let cursorWindowMs = 200.0

    var body: some View {
        let t = session.cursor.ms
        let window = session.visibleWindow
        let chains = Self.chains(phy, at: t)
        let share = Self.limitedShare(phy, window: window)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Transmit-limited?").font(.subheadline.weight(.semibold))
                if let badge = RadioData.checkBadge(phy, "d184cFraming", passed: "0x184C framing") { BadgeView(badge: badge) }
                Spacer(minLength: 0)
            }
            if chains.isEmpty && share == nil {
                EmptyChartNote(text: RadioData.emptyReason(phy, .lte_tx_power_chain))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    verdict(chains, share: share)
                    ForEach(chains, id: \.chain) { c in chainRow(c) }
                    Text("Front-end Tx power against the limit that chain was given (0x184C v17, 0.1 dBm). A chain at "
                         + "−70.0 dBm is off and is not listed. This is the front end's own power, not the PUSCH "
                         + "target 0xB139 reports.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                headroomChart(window)
            }
        }
        .accessibilityIdentifier("transmitLimited")
    }

    private func verdict(_ chains: [Live], share: Double?) -> some View {
        let limited = chains.contains { $0.limited }
        let title = chains.isEmpty ? "No chain transmitting at the cursor"
            : limited ? "Transmit-limited at the cursor" : "Not transmit-limited at the cursor"
        return VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: limited ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(limited ? Theme.severity(.warning) : Theme.accent)
            if let share {
                Text("At its chain's limit in \(Int((share * 100).rounded()))% of the sub-records in the visible window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chainRow(_ c: Live) -> some View {
        HStack(spacing: 8) {
            Text(Self.chainName(c)).font(.caption.weight(.semibold)).frame(width: 76, alignment: .leading)
            Text(RadioFormat.value(c.powerDbm, 1, "dBm")).font(.caption.monospacedDigit()).frame(width: 74, alignment: .trailing)
            Text("of \(RadioFormat.value(c.limitDbm, 1, "dBm"))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if c.limited {
                BadgeView(badge: RadioBadge(text: "at the limit", kind: .warning))
            } else {
                Text("\(RadioFormat.value(c.headroomDb, 1, "dB")) to spare").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Headroom per chain over the window: at zero the chain is at its limit.
    private func headroomChart(_ window: ClosedRange<Double>) -> some View {
        let samples = RadioData.series(phy, .lte_tx_power_headroom)
        let chains = Array(Set(samples.compactMap(\.tag))).sorted()
        let pts = RadioData.joined(chains.map { chain in
            RadioData.points(samples.filter { $0.tag == chain }, window: window, series: String(chain), gapMs: 200)
        })
        return VStack(alignment: .leading, spacing: 4) {
            PhyChart(title: "Headroom to the chain's limit", unit: "dB", badges: [.medium],
                     empty: samples.isEmpty ? RadioData.emptyReason(phy, .lte_tx_power_headroom) : nil,
                     height: 120, session: session) {
                RuleMark(y: .value("limit", 0))
                    .foregroundStyle(Theme.severity(.warning))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("at the limit").font(.caption2).foregroundStyle(.secondary)
                    }
                ForEach(pts) { p in
                    PointMark(x: .value("t", p.t), y: .value("dB", p.y))
                        .foregroundStyle(Self.colour(Int(p.series) ?? 0))
                        .symbolSize(8)
                }
            }
            LegendRow(items: chains.map { (Self.chainLabel($0), Self.colour($0)) })
        }
    }

    // MARK: data

    /// Every chain that was transmitting within 200 ms of `t`, strongest first.
    static func chains(_ phy: PhyCapture, at t: Double) -> [Live] {
        let power = RadioData.series(phy, .lte_tx_power_chain)
        let limit = RadioData.series(phy, .lte_tx_power_limit)
        let state = RadioData.series(phy, .lte_tx_pa_state)
        let window = (t - cursorWindowMs)...(t + cursorWindowMs)
        var best: [Int: PhySample] = [:]
        for s in PhyQuery.slice(power, window) {
            guard let chain = s.tag else { continue }
            if let old = best[chain], abs(old.tMs - t) <= abs(s.tMs - t) { continue }
            best[chain] = s
        }
        func at(_ samples: [PhySample], _ chain: Int, _ tMs: Double) -> Double? {
            PhyQuery.slice(samples, (tMs - 0.5)...(tMs + 0.5)).first { $0.tag == chain }?.value
        }
        return best.values.compactMap { s -> Live? in
            guard let chain = s.tag, let p = s.value, let l = at(limit, chain, s.tMs) else { return nil }
            return Live(chain: chain, powerDbm: p, limitDbm: l, gainState: at(state, chain, s.tMs).map { Int($0) })
        }
        .sorted { $0.powerDbm > $1.powerDbm }
    }

    /// The chain transmitting hardest at `t`, which is the one the header shows.
    static func live(_ phy: PhyCapture, at t: Double) -> Live? { chains(phy, at: t).first }

    /// Share of live sub-records in the window that were at their chain's limit.
    static func limitedShare(_ phy: PhyCapture, window: ClosedRange<Double>) -> Double? {
        let headroom = PhyQuery.slice(RadioData.series(phy, .lte_tx_power_headroom), window).compactMap(\.value)
        guard !headroom.isEmpty else { return nil }
        return Double(headroom.count(where: { $0 <= limitedDb })) / Double(headroom.count)
    }

    static func chainName(_ c: Live) -> String { chainLabel(c.chain) }

    /// The record's own chain tag, as it writes it: the high nibble is the chain group.
    static func chainLabel(_ chain: Int) -> String { "chain " + String(format: "0x%02X", chain) }

    /// One colour per chain group (the tag's high nibble), so the same chain keeps its colour between captures.
    static func colour(_ chain: Int) -> Color { RadioStyle.lines[(chain >> 4) % RadioStyle.lines.count] }
}
