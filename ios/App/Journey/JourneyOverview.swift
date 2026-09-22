import SwiftUI
import FTApp
import FTJourney
import FTModel

/// "What happened": the findings, each tied to its moment (a tap moves the cursor and offers "Show in call
/// flow"), then the KPI tiles, the procedures (WP6), the cells visited, what could not be read, and the
/// capture's facts.
struct OverviewPage: View {
    @Bindable var session: CaptureSession
    @State private var selectedFinding: String?
    @State private var notReadable = false

    var body: some View {
        let analysis = session.analysis
        let journey = analysis.journey
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("What happened", id: "findings") {
                    VStack(spacing: 0) {
                        ForEach(Array(journey.findings.enumerated()), id: \.element.id) { i, f in
                            if i > 0 { Divider().padding(.leading, 52) }
                            FindingRow(finding: f, selected: selectedFinding == f.id, session: session) {
                                select(f)
                            }
                        }
                    }
                    .card()
                }
                section("Key numbers", id: "tiles") {
                    KpiGrid(tiles: journey.tiles + KpiTiles.peaks(phy: analysis.phy), session: session)
                }
                section("Procedures", id: "procedures") {
                    ProcedureSummaryView(flow: analysis.flow) { event in
                        showInCallFlow(session, event: event, tMs: nil)
                    }
                }
                section("Cells visited", id: "cells") {
                    CellsVisited(journey: journey, session: session)
                }
                Button { notReadable = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "lock")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not readable in this capture").font(.subheadline.weight(.semibold))
                            Text(notReadableSummary(analysis)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .card()
                section("About this capture", id: "facts") {
                    CaptureFactsCard(analysis: analysis).card()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .journeyStripCollapses(with: session)
        .onAppear { scrollForLaunch(reader) }
        }
        .sheet(isPresented: $notReadable) {
            NotReadableSheet(analysis: analysis, session: session)
                .presentationDetents([.medium, .large])
        }
    }

    private func select(_ f: Finding) {
        withAnimation(.snappy(duration: 0.2)) { selectedFinding = selectedFinding == f.id ? nil : f.id }
        if let t = f.tMs { session.cursor.set(t) }
    }

    private func notReadableSummary(_ a: CaptureAnalysis) -> String {
        let census = a.summary.secure.records > 0 ? a.summary.secure : a.phy.summary.encrypted
        var parts: [String] = []
        if census.records > 0 { parts.append("\(JourneyText.count(census.records)) encrypted records") }
        let missing = a.phy.availability.filter { $0.status != .available }.count
        if missing > 0 { parts.append("\(missing) measurements not available") }
        if a.flow.undecoded > 0 { parts.append("\(a.flow.undecoded) signalling records not decoded") }
        return parts.isEmpty ? "Everything logged was read" : parts.joined(separator: " · ")
    }

    /// DEBUG/Harness: -FTJourneyScroll <section> for screenshots of the lower sections.
    private func scrollForLaunch(_ reader: ScrollViewProxy) {
        #if DEBUG || FT_HARNESS
        guard let id = JourneyLaunchArguments.current.scroll else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            reader.scrollTo(id, anchor: .top)
        }
        #endif
    }

    private func section<Content: View>(_ title: String, id: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .id(id)
    }
}

extension View {
    /// An inset-grouped card.
    fileprivate func card() -> some View {
        background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

// MARK: - Findings

private struct FindingRow: View {
    let finding: Finding
    let selected: Bool
    @Bindable var session: CaptureSession
    let onTap: () -> Void

    var body: some View {
        let color = finding.severity == .info ? Theme.accent : Theme.severity(finding.severity)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: JourneyStyle.symbol(finding.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let t = finding.tMs {
                    Text(JourneyText.clock(t)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if selected, finding.event != nil || finding.tMs != nil {
                    Button {
                        showInCallFlow(session, event: finding.event, tMs: finding.tMs)
                    } label: {
                        Label("Show in call flow", systemImage: "arrow.left.arrow.right.square")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? Theme.accent.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(finding.tMs == nil ? "" : "Moves the cursor to this moment")
        .accessibilityAction(named: "Show in call flow") {
            showInCallFlow(session, event: finding.event, tMs: finding.tMs)
        }
    }
}

// MARK: - KPI tiles

private struct KpiGrid: View {
    let tiles: [KpiTile]
    @Bindable var session: CaptureSession

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(tiles) { t in
                KpiTileView(tile: t)
                    .onTapGesture {
                        if let e = t.event, session.analysis.flow.events.indices.contains(e) {
                            session.cursor.set(session.analysis.flow.events[e].sinceStartMs)
                        }
                    }
                    .contextMenu {
                        if t.event != nil {
                            Button("Show in call flow", systemImage: "arrow.left.arrow.right.square") {
                                showInCallFlow(session, event: t.event, tMs: nil)
                            }
                        }
                    }
            }
        }
    }
}

private struct KpiTileView: View {
    let tile: KpiTile

    /// Count tiles show one number; ratio tiles show succeeded/attempts with a ring.
    private var isCount: Bool { tile.id == "abnormalReleases" }
    private var isValue: Bool { tile.group == "Integrity" }
    private var allGood: Bool { isCount ? tile.succeeded == 0 : tile.succeeded == tile.attempts }

    var body: some View {
        let tint = allGood ? Theme.accent : (isCount || tile.succeeded == 0 ? Theme.severity(.failure) : Theme.severity(.warning))
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.group).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(alignment: .firstTextBaseline) {
                Text(tile.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if !isValue {
                    Image(systemName: allGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(tint)
                }
            }
            Text(big)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(allGood || isValue ? Color.primary : tint)
            Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            if !isValue && !isCount && tile.attempts > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(tint).frame(width: g.size.width * Double(tile.succeeded) / Double(tile.attempts))
                    }
                }
                .frame(height: 4)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.title): \(big), \(sub)")
    }

    private var big: String {
        if isValue { return tile.value ?? "–" }
        if isCount { return "\(tile.succeeded)" }
        return "\(tile.succeeded)/\(tile.attempts)"
    }

    private var sub: String {
        if isValue { return "1 s bins" }
        return tile.value ?? (tile.succeeded == tile.attempts ? "all succeeded" : "\(tile.attempts - tile.succeeded) not")
    }
}

// MARK: - Cells visited

private struct CellsVisited: View {
    let journey: Journey
    @Bindable var session: CaptureSession

    struct Visit: Identifiable {
        var id: String
        var segment: CellSegment
        var totalMs: Double
        var firstMs: Double
    }

    var body: some View {
        ChipFlow(spacing: 8) {
            ForEach(visits) { v in
                Button { session.cursor.set(v.firstMs) } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(JourneyStyle.fill(v.segment)).frame(width: 10, height: 10)
                        Text(label(v.segment)).font(.caption.weight(.semibold)).monospacedDigit()
                        Text(JourneyText.duration(v.totalMs)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(SegmentText.spoken(v.segment)), \(JourneyText.duration(v.totalMs)) on the cell")
            }
        }
    }

    private func label(_ s: CellSegment) -> String {
        switch s.lane {
        case .pcell: JourneyText.cell(s)
        case .pscell: "NR \(s.cell.earfcn)/\(s.cell.pci) \(JourneyText.band(s))"
        case .scell: "SCell \(JourneyText.band(s)) \(s.cell.earfcn)/\(s.cell.pci)"
        }
    }

    private var visits: [Visit] {
        var order: [String] = []
        var byKey: [String: Visit] = [:]
        for s in journey.cells {
            let key = "\(s.lane.rawValue)-\(s.cell.earfcn)-\(s.cell.pci)-\(s.cell.nr)"
            if var v = byKey[key] {
                v.totalMs += s.endMs - s.startMs
                byKey[key] = v
            } else {
                order.append(key)
                byKey[key] = Visit(id: key, segment: s, totalMs: s.endMs - s.startMs, firstMs: s.startMs)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

/// Chips that wrap onto as many lines as they need.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

// MARK: - Facts

private struct CaptureFactsCard: View {
    let analysis: CaptureAnalysis

    var body: some View {
        let s = analysis.summary
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            row("Trace", "\(JourneyText.duration(analysis.durationMs)) of modem log"
                + (analysis.flow.startUtcMs.map { " from " + Date(timeIntervalSince1970: Double($0) / 1_000).formatted(date: .abbreviated, time: .standard) } ?? ""))
            if let w = s.traceWindowAfterPressMs {
                row("After the press", "\(JourneyText.shortClock(w.startMs))–\(JourneyText.shortClock(w.endMs)) after you pressed the buttons. "
                    + "This timing is based on early tests.")
            }
            if let o = s.overwrittenFiles, o > 0 {
                row("Overwritten", "\(o) older trace file\(o == 1 ? " was" : "s were") overwritten before the dump"
                    + (s.listedFiles.map { " (\($0 - o) of \($0) kept)" } ?? ""))
            }
            row("Records", "\(JourneyText.count(s.deframe?.logRecords ?? analysis.flow.records)) records"
                + ((s.deframe?.distinctCodes).map { ", \($0) log codes" } ?? ""))
            row("Messages", "\(analysis.flow.events.count) RRC/NAS messages, \(analysis.flow.procedures.count) procedures")
            if let p = s.profile, let removal = p.removalDate {
                row("Logging profile", (p.installDate.map { "Installed \($0.formatted(date: .abbreviated, time: .shortened)), " } ?? "")
                    + "expires \(removal.formatted(date: .abbreviated, time: .shortened))")
            }
            if !analysis.phy.checks.isEmpty {
                let passed = analysis.phy.checks.filter(\.passed).count
                row("Decoder health", "\(passed) of \(analysis.phy.checks.count) self-checks passed")
            }
        }
        .font(.subheadline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Not readable

private struct NotReadableSheet: View {
    let analysis: CaptureAnalysis
    @Bindable var session: CaptureSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let census = analysis.summary.secure.records > 0 ? analysis.summary.secure : analysis.phy.summary.encrypted
                if census.records > 0 {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(JourneyText.count(census.records)) records encrypted by the modem")
                                Text("\(census.codes) log codes. The modem writes them encrypted; no app can read them.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "lock") }
                    }
                }
                if analysis.flow.undecoded > 0 {
                    Section {
                        Label("\(analysis.flow.undecoded) signalling records no decoder could place", systemImage: "questionmark.square.dashed")
                    }
                }
                let missing = analysis.phy.availability.filter { $0.status != .available }
                if !missing.isEmpty {
                    Section("Measurements") {
                        ForEach(missing) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title)
                                Text(a.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Open Radio › Not available") {
                        session.radioSection = "unavailable"
                        session.page = .radio
                        dismiss()
                    }
                }
            }
            .navigationTitle("Not readable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
