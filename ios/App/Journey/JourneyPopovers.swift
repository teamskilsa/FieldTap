import SwiftUI
import FTApp
import FTJourney
import FTModel

/// What VoiceOver and the popovers say about a cell segment.
enum SegmentText {
    /// "LTE B66, EARFCN 67086, PCI 80".
    static func spoken(_ s: CellSegment) -> String {
        let lane = switch s.lane {
        case .pcell: ""
        case .pscell: "NR leg, "
        case .scell: "Secondary cell \(s.index), "
        }
        return "\(lane)\(JourneyStyle.rat(s.cell)) \(JourneyText.band(s)), \(JourneyText.channelName(s.cell)) \(s.cell.earfcn), PCI \(s.cell.pci)"
    }

    /// "2.4 s to 15.1 s, entered by re-attach".
    static func spokenValue(_ s: CellSegment, journey: Journey) -> String {
        var out = "\(JourneyText.clock(s.startMs)) to \(JourneyText.clock(s.endMs))"
        if let e = entered(s, journey: journey) { out += ", entered by \(e)" }
        if let l = left(s, journey: journey) { out += ", left by \(l)" }
        return out
    }

    /// How the phone came onto the cell: the move marker that arrived there, else the segment's own reason.
    static func entered(_ s: CellSegment, journey: Journey) -> String? {
        if s.lane == .pcell, let m = journey.markers.first(where: { move($0) && $0.to == s.cell && abs(($0.arrivalMs ?? $0.tMs) - s.startMs) < 1_500 }) {
            return m.kind == .reattach ? "re-attach" : m.title.lowercased()
        }
        if s.lane == .pscell { return "SCG add" + (s.addedMs.map { ", complete at \(JourneyText.clock($0))" } ?? "") }
        if s.lane == .scell { return "carrier aggregation (first PHY record)" }
        return s.startReason
    }

    static func left(_ s: CellSegment, journey: Journey) -> String? {
        if s.openAtEnd { return "the capture ending" }
        if s.endReason == "radioOff" { return "switch-off (radio off)" }
        if s.lane == .pcell, let m = journey.markers.first(where: { move($0) && $0.from == s.cell && abs(($0.arrivalMs ?? $0.tMs) - s.endMs) < 1_500 }) {
            return m.title.lowercased()
        }
        if s.lane == .pscell {
            // "LTE handover command (event 82); NR release not in the decoded fields" -> plain words.
            let reason = (s.endReason ?? "release").components(separatedBy: ";").first ?? "release"
            let plain = reason.replacingOccurrences(of: #" \(event \d+\)"#, with: "", options: .regularExpression)
            return s.endInferred ? "\(plain), inferred (no NR release was decoded)" : plain
        }
        if s.lane == .scell { return "last PHY record" }
        return s.endReason
    }

    private static func move(_ m: Marker) -> Bool {
        [.handover, .reselection, .reattach, .redirect, .reestablishment, .cellChange].contains(m.kind)
    }
}

/// The popover for a tapped segment: band, channel, PCI, DL MHz, time on the cell, how it was entered and left,
/// and the serving-cell record (TAC and cell identity masked unless revealed).
struct SegmentPopover: View {
    enum Content {
        case cell(CellSegment)
        case state(StateSegment, registration: RegistrationSegment?)
    }

    let content: Content
    @Bindable var session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch content {
            case .cell(let s): cell(s)
            case .state(let s, let r): state(s, r)
            }
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func cell(_ s: CellSegment) -> some View {
        let journey = session.analysis.journey
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(JourneyStyle.fill(s)).frame(width: 14, height: 14)
            Text(title(s)).font(.headline).monospacedDigit()
            Spacer(minLength: 0)
            if s.source == .phy { tag("from PHY") } else if s.endInferred { tag("end inferred") }
        }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row(JourneyText.channelName(s.cell), "\(s.cell.earfcn)")
            row("PCI", "\(s.cell.pci)")
            row("Band", bandText(s))
            if let mhz = s.dlMhz { row("DL", JourneyText.mhz(mhz)) }
            row("Time", "\(JourneyText.clock(s.startMs))–\(JourneyText.clock(s.endMs)) (\(JourneyText.duration(s.endMs - s.startMs)))")
            if let e = SegmentText.entered(s, journey: journey) { row("Entered by", e) }
            if let l = SegmentText.left(s, journey: journey) { row("Left by", l) }
            if let last = s.phyLastMs { row("NR PHY until", JourneyText.clock(last)) }
            if let info = session.analysis.flow.cellInfo(for: s.cell) {
                ForEach(Redaction.displayCellInfo(info, reveal: session.reveal).filter { ["PLMN", "TAC", "Cell identity", "Bandwidth"].contains($0.label) },
                        id: \.label) { r in
                    row(r.label, r.value)
                }
            }
        }
        .font(.footnote)
    }

    @ViewBuilder private func state(_ s: StateSegment, _ r: RegistrationSegment?) -> some View {
        Text(stateTitle(s.state)).font(.headline)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("When", "\(JourneyText.clock(s.startMs))–\(JourneyText.clock(s.endMs)) (\(JourneyText.duration(s.endMs - s.startMs)))")
            if let source = s.source { row("From", source) }
            if let r {
                row("Registration", r.state == .registered ? (r.assumed ? "registered (assumed)" : "registered")
                    : r.state == .deregistered ? "not registered" : "unknown")
            }
        }
        .font(.subheadline)
    }

    private func title(_ s: CellSegment) -> String {
        switch s.lane {
        case .pcell: "\(JourneyStyle.rat(s.cell)) \(JourneyText.cell(s).replacingOccurrences(of: "NR ", with: ""))"
        case .pscell: "NR leg \(s.cell.earfcn)/\(s.cell.pci)"
        case .scell: "SCell\(s.index) \(JourneyText.band(s)) \(s.cell.earfcn)/\(s.cell.pci)"
        }
    }

    /// "n5 or n26 (the channel is in both)": an NR-ARFCN alone cannot say which band.
    private func bandText(_ s: CellSegment) -> String {
        let names = s.bandCandidates.map { "n\($0)" }
        guard s.cell.nr, names.count > 1 else { return JourneyText.band(s) }
        let list = names.dropLast().joined(separator: ", ") + " or " + names.last!
        return "\(list) (the channel is in \(names.count == 2 ? "both" : "each"))"
    }

    private func stateTitle(_ s: RadioState) -> String {
        switch s {
        case .connected: "Connected"
        case .idle: "Idle"
        case .radioOff: "Radio off"
        case .unknown: "Before the first cell message"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(Color.secondary.opacity(0.6)))
            .foregroundStyle(.secondary)
    }
}

/// The sheet for a tapped marker (or every marker in a tapped cluster): what happened, when, the numbers, and
/// "Show in call flow".
struct MarkerSheet: View {
    let item: MarkerSheetItem
    @Bindable var session: CaptureSession
    @State private var picked: Marker?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch item {
                case .marker(let m):
                    MarkerDetail(marker: m, session: session, dismiss: { dismiss() })
                case .cluster(let ms):
                    List(ms) { m in
                        Button {
                            session.cursor.set(m.tMs)
                            picked = m
                        } label: {
                            MarkerRow(marker: m, journey: session.analysis.journey)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .navigationDestination(item: $picked) { m in
                        MarkerDetail(marker: m, session: session, dismiss: { dismiss() })
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var title: String {
        switch item {
        case .marker(let m): JourneyText.clock(m.tMs)
        case .cluster(let ms): "\(ms.count) events near \(JourneyText.clock(ms.first?.tMs ?? 0))"
        }
    }
}

/// One marker in a list: glyph, title, time.
private struct MarkerRow: View {
    let marker: Marker
    let journey: Journey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: JourneyStyle.symbol(marker.kind))
                .font(.body.weight(.semibold))
                .foregroundStyle(JourneyStyle.color(marker.severity))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(JourneyText.markerTitle(marker, journey: journey)).font(.subheadline.weight(.semibold))
                if let d = marker.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            Text(JourneyText.clock(marker.tMs)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MarkerDetail: View {
    let marker: Marker
    @Bindable var session: CaptureSession
    let dismiss: () -> Void

    var body: some View {
        let journey = session.analysis.journey
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: JourneyStyle.symbol(marker.kind))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(JourneyStyle.color(marker.severity))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(JourneyStyle.color(marker.severity).opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(JourneyText.markerTitle(marker, journey: journey)).font(.headline)
                        if marker.severity != .info {
                            Text(marker.severity == .failure ? "Failure" : "Warning")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.severity(marker.severity))
                        }
                    }
                }
                if let d = marker.detail { Text(d).font(.subheadline) }
                let together = journey.markers.filter { $0.id != marker.id && abs($0.tMs - marker.tMs) < 1 }
                if !together.isEmpty {
                    Text("At the same moment: " + together.map { JourneyText.markerTitle($0, journey: journey) }.joined(separator: "; "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("At", JourneyText.clock(marker.tMs))
                    if let a = marker.arrivalMs { row("Arrived", JourneyText.clock(a)) }
                    if let d = marker.durationMs { row("Took", JourneyText.duration(d)) }
                    if let from = marker.from { row("From", cellText(from, journey: journey, before: marker.tMs)) }
                    if let to = marker.to { row("To", cellText(to, journey: journey, before: nil)) }
                    if let ta = marker.ta { row("Timing advance", "\(ta)") }
                    if let m = marker.distanceM { row("Distance", "about \(JourneyText.distance(m)) (timing advance × 78.12 m, rough)") }
                    if marker.inferred { row("Evidence", "inferred, not logged") }
                    if let e = marker.event { row("Message", "#\(e)" + (session.analysis.flow.events.indices.contains(e) ? " \(session.analysis.flow.events[e].name)" : "")) }
                }
                .font(.subheadline)
                if marker.event != nil {
                    Button {
                        showInCallFlow(session, event: marker.event, tMs: marker.tMs)
                        dismiss()
                    } label: {
                        Label("Show in call flow", systemImage: "arrow.left.arrow.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(20)
        }
        .onAppear { session.cursor.set(marker.tMs) }
    }

    private func cellText(_ c: Cell, journey: Journey, before: Double?) -> String {
        let seg = journey.cells.first { $0.cell == c && $0.lane != .scell }
        let band = seg.map(JourneyText.band) ?? (c.nr ? "NR" : "LTE")
        return c.isPendingNr ? "NR cell pending" : "\(band) \(c.earfcn)/\(c.pci)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
    }
}
