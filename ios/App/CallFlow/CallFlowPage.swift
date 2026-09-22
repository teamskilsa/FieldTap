import SwiftUI
import UIKit
import FTApp
import FTJourney
import FTModel
import FTPresentation

/// The call-flow page of an open capture: filter chips with counts, a search over names and summaries, the lane
/// header and the ladder (CallFlowPresentation.rows). The row at the time cursor is highlighted, and the ladder
/// scrolls to it when the cursor moves from another view. Tapping a message moves the cursor there and opens
/// its sheet; a long press copies its line, masked.
struct CallFlowPage: View {
    @Bindable var session: CaptureSession
    @State private var query = ""
    @State private var searching = false
    @State private var showProcedures = false
    @State private var proceduresDetent: PresentationDetent = .medium
    /// Bumped by a jump from the procedures list, so the ladder scrolls even when the cursor did not move.
    @State private var jumpToken = 0
    @State private var memo = LadderMemo()
    @State private var highlight = LadderHighlight()

    var body: some View {
        let flow = session.analysis.flow
        let ladder = memo.ladder(flow: flow, filter: session.filter, query: query, reveal: session.reveal)
        VStack(spacing: 0) {
            LadderHeader(flow: flow, filter: $session.filter, query: $query, searching: $searching,
                         onProcedures: { showProcedures = true })
            if flow.events.isEmpty {
                ContentUnavailableView {
                    Label("No call flow", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("No RRC or NAS messages could be read from this capture.")
                }
            } else if ladder.rows.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No \(session.filter.rawValue) messages", systemImage: "line.3.horizontal.decrease",
                                           description: Text("Choose All to see every message."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                LadderList(ladder: ladder, session: session, memo: memo, highlight: highlight, jumpToken: jumpToken)
            }
        }
        .environment(\.callFlowReveal, session.reveal)
        .sheet(isPresented: $showProcedures) {
            NavigationStack {
                ScrollView {
                    ProcedureSummaryView(flow: flow) { index in
                        showProcedures = false
                        jump(to: index)
                    }
                    .padding(16)
                }
                .navigationTitle("Procedures")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showProcedures = false } }
                }
            }
            .presentationDetents([.medium, .large], selection: $proceduresDetent)
            .accessibilityIdentifier("proceduresSheet")
        }
        .task { await openDebugPanel() }
    }

    /// A procedure instance was picked: show All when the filter or search hides it, then scroll to it.
    private func jump(to eventIndex: Int) {
        let flow = session.analysis.flow
        guard flow.events.indices.contains(eventIndex) else { return }
        let visible = memo.ladder(flow: flow, filter: session.filter, query: query, reveal: session.reveal)
        if CallFlowPresentation.rowOf(visible.rows, eventIndex: eventIndex) == nil {
            query = ""
            searching = false
            session.filter = .ALL
        }
        memo.pinned = eventIndex
        session.cursor.set(flow.events[eventIndex].sinceStartMs)
        jumpToken += 1
    }

    /// DEBUG/Harness: `-FTCallFlowPanel procedures` opens the procedures list once (full height with
    /// `-FTSheetDetent large`), for its screenshot.
    private func openDebugPanel() async {
        #if DEBUG || FT_HARNESS
        guard !Self.debugPanelOpened, UserDefaults.standard.string(forKey: "FTCallFlowPanel") == "procedures" else { return }
        Self.debugPanelOpened = true
        if UserDefaults.standard.string(forKey: "FTSheetDetent") == "large" { proceduresDetent = .large }
        try? await Task.sleep(for: .milliseconds(300))
        showProcedures = true
        #endif
    }

    #if DEBUG || FT_HARNESS
    @MainActor private static var debugPanelOpened = false
    #endif
}

/// The rows for one filter and search, with what the cursor needs to find its row quickly.
struct Ladder {
    var rows: [LadderRow]
    var lanes: CallFlowPresentation.Lanes
    /// Start time and row index of every message row, by time: the cursor's row is found by binary search.
    private var starts: [(ms: Double, row: Int)]
    /// The row each shown message is on (CallFlowPresentation.rowOf, without the linear scan).
    private var rowOfEvent: [Int: Int] = [:]

    init(rows: [LadderRow], lanes: CallFlowPresentation.Lanes) {
        self.rows = rows
        self.lanes = lanes
        starts = rows.indices.compactMap { i in rows[i].event.map { ($0.sinceStartMs, i) } }
        starts.sort { $0.ms < $1.ms }
        for (i, row) in rows.enumerated() {
            for e in row.events { rowOfEvent[e.index] = i }
        }
    }

    /// The row at the cursor: the last message that started at or before it. `pinned`, a message the user picked,
    /// wins while the cursor is on its time, so of two messages logged in the same millisecond the right one lights.
    func highlightedRow(cursorMs: Double, pinned: Int?) -> String? {
        if let pinned, let i = rowOfEvent[pinned],
           let e = rows[i].events.first(where: { $0.index == pinned }), abs(e.sinceStartMs - cursorMs) < 0.000_5 {
            return rows[i].id
        }
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid].ms <= cursorMs + 0.000_5 { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? rows[starts[lo - 1].row].id : nil
    }
}

/// The row the cursor is on. CursorFollower alone reads the cursor and sets this, so a 60 Hz cursor drag re-renders
/// the rows only when the highlighted row changes.
@Observable @MainActor final class LadderHighlight {
    var rowID: String?
}

/// Remembers the last ladder built, so a cursor move or a sheet does not rebuild 40,000 rows. Not observed: what it
/// holds is derived, and changing it must not re-render anything.
@MainActor final class LadderMemo {
    private struct Key: Equatable {
        var events: Int
        var filter: FlowFilter
        var query: String
        var reveal: Bool
    }

    private var key: Key?
    private var cached = Ladder(rows: [], lanes: .init(phone: "UE", ran: "RAN", core: "Core"))
    /// The message the user tapped or jumped to.
    var pinned: Int?
    /// A row the ladder itself moved the cursor to: highlighting it must not scroll the list.
    var suppressScroll: String?

    func ladder(flow: Flow, filter: FlowFilter, query: String, reveal: Bool) -> Ladder {
        let k = Key(events: flow.events.count, filter: filter, query: query, reveal: reveal)
        if k == key { return cached }
        var rows = CallFlowPresentation.rows(flow, filter)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            // Search what the screen shows: while masked, a hidden number must not be findable by typing it.
            func hit(_ s: String?) -> Bool {
                guard let s else { return false }
                return (reveal ? s : Redaction.scrub(s)).localizedStandardContains(q)
            }
            rows = rows.filter { row in
                switch row {
                case .message(let e, let repeats): ([e] + repeats).contains { hit($0.name) || hit($0.summary) }
                case .procedureStart(let p, _): hit(p.name)
                case .move(let s): hit(CallFlowStyle.moveName(s.move)) || hit(CallFlowPresentation.shortCell(s.to))
                }
            }
        }
        cached = Ladder(rows: rows, lanes: CallFlowPresentation.lanes(flow))
        key = k
        return cached
    }
}

/// The lazy list of rows. Only a zero-size follower reads the cursor; the rows read the highlight it sets.
private struct LadderList: View {
    let ladder: Ladder
    let session: CaptureSession
    let memo: LadderMemo
    let highlight: LadderHighlight
    let jumpToken: Int

    var body: some View {
        let flow = session.analysis.flow
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ladder.rows) { row in
                        LadderCell(row: row, ladder: ladder, session: session, memo: memo, highlight: highlight,
                                   annotation: annotation(row))
                            .id(row.id)
                    }
                    if flow.undecoded > 0 {
                        Text("\(flow.undecoded) signalling records are not shown: no decoder could place them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            // Room under the last message for the floating cursor bar (CapturePageLayout).
            .contentMargins(.bottom, CapturePageLayout.scrollBottomInset, for: .scrollContent)
            .background {
                CursorFollower(ladder: ladder, session: session, memo: memo, highlight: highlight, proxy: proxy,
                               jumpToken: jumpToken)
            }
            .accessibilityIdentifier("callFlowLadder")
        }
    }

    private func annotation(_ row: LadderRow) -> String? {
        guard case .move(let step) = row else { return nil }
        return JourneyQuery.annotation(forStepEvent: step.event, in: session.analysis.journey)
    }
}

private struct LadderCell: View {
    let row: LadderRow
    let ladder: Ladder
    let session: CaptureSession
    let memo: LadderMemo
    let highlight: LadderHighlight
    let annotation: String?

    var body: some View {
        let flow = session.analysis.flow
        let highlighted = highlight.rowID == row.id
        Button(action: tap) {
            LadderRowView(row: row, gapMs: row.event.flatMap { CallFlowPresentation.gap(flow.events, $0.index) },
                          highlighted: highlighted, annotation: annotation)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let e = row.event {
                Button("Copy line", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = MessageSheetModel.oneLine(e, lanes: ladder.lanes, reveal: session.reveal)
                }
            }
        }
        .accessibilityIdentifier("ladderRow-\(row.id)")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityHint(row.event != nil ? "Opens the message" : "Moves the cursor here")
    }

    private func tap() {
        memo.suppressScroll = row.id
        switch row {
        case .message(let e, _):
            memo.pinned = e.index
            session.select(event: e.index)
        case .move(let step):
            memo.pinned = step.event
            session.cursor.set(session.analysis.flow.events.indices.contains(step.event)
                ? session.analysis.flow.events[step.event].sinceStartMs : step.sinceStartMs)
        case .procedureStart(let p, _):
            memo.pinned = p.first
            if session.analysis.flow.events.indices.contains(p.first) {
                session.cursor.set(session.analysis.flow.events[p.first].sinceStartMs)
            }
        }
    }
}

/// Scrolls the ladder to the cursor's row when the cursor moves from elsewhere (the strip, the cursor bar, a
/// finding), when the filter changes, and on a jump; not when the ladder itself moved it.
private struct CursorFollower: View {
    let ladder: Ladder
    let session: CaptureSession
    let memo: LadderMemo
    let highlight: LadderHighlight
    let proxy: ScrollViewProxy
    let jumpToken: Int

    var body: some View {
        let target = ladder.highlightedRow(cursorMs: session.cursor.ms, pinned: memo.pinned)
        Color.clear
            .onChange(of: target) { _, new in
                highlight.rowID = new
                // A tap already has its row on screen; any later move clears the tap's claim.
                let tapped = memo.suppressScroll != nil && memo.suppressScroll == new
                memo.suppressScroll = nil
                guard let new, !tapped else { return }
                withAnimation(.snappy) { proxy.scrollTo(new, anchor: .center) }
            }
            .onChange(of: ladder.rows.count) { scroll(target, animated: false) }
            .onChange(of: jumpToken) { scroll(target, animated: true) }
            .onAppear {
                highlight.rowID = target
                if session.cursor.ms > 0 { scroll(target, animated: false) }
            }
    }

    private func scroll(_ id: String?, animated: Bool) {
        guard let id else { return }
        memo.suppressScroll = nil
        if animated {
            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
        } else {
            // After the rows' first layout, or the lazy stack has nothing to scroll to yet.
            Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
        }
    }
}

/// Filter chips with counts, search and procedures buttons, the search field, and the lane names.
private struct LadderHeader: View {
    let flow: Flow
    @Binding var filter: FlowFilter
    @Binding var query: String
    @Binding var searching: Bool
    var onProcedures: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    FilterChips(flow: flow, filter: $filter)
                }
                .scrollBounceBehavior(.basedOnSize)
                Button {
                    searching.toggle()
                    if searching { focused = true } else { query = "" }
                } label: {
                    Image(systemName: searching ? "xmark" : "magnifyingglass")
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .accessibilityLabel(searching ? "Close search" : "Search messages")
                .accessibilityIdentifier("ladderSearchButton")
                Button(action: onProcedures) {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                        Text("\(flow.procedures.count)").monospacedDigit()
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .disabled(flow.procedures.isEmpty)
                .accessibilityLabel("Procedures, \(flow.procedures.count)")
                .accessibilityIdentifier("proceduresButton")
            }
            .padding(.horizontal, 12)
            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Message name or summary", text: $query)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityIdentifier("ladderSearchField")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground)))
                .padding(.horizontal, 12)
            }
            LaneHeader(lanes: CallFlowPresentation.lanes(flow))
            Divider()
        }
        .padding(.top, 8)
        .background(Color(uiColor: .systemBackground))
    }
}

/// All / RRC / NAS with how many messages each shows (Android FlowFilter).
struct FilterChips: View {
    let flow: Flow
    @Binding var filter: FlowFilter

    var body: some View {
        let rrc = flow.events.count { $0.layer == .RRC }
        HStack(spacing: 6) {
            chip(.ALL, "All", flow.events.count, .primary)
            chip(.RRC, "RRC", rrc, CallFlowStyle.layer(.RRC))
            chip(.NAS, "NAS", flow.events.count - rrc, CallFlowStyle.layer(.NAS))
        }
    }

    private func chip(_ f: FlowFilter, _ label: String, _ count: Int, _ accent: Color) -> some View {
        let selected = filter == f
        return Button {
            filter = f
        } label: {
            HStack(spacing: 5) {
                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(selected ? accent : .secondary)
                Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(selected ? accent.opacity(0.16) : .clear))
            .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.7) : Color(uiColor: .separator), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(count) messages")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("filterChip-\(f.rawValue)")
    }
}

/// The lane names over the lane lines: "UE | RAN | Core", "UE | eNB | MME" for LTE only, "UE | gNB | AMF" for NR.
struct LaneHeader: View {
    let lanes: CallFlowPresentation.Lanes

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: CallFlowStyle.gutter)
            ZStack {
                HStack { label(lanes.phone); Spacer(minLength: 0) }
                label(lanes.ran)
                HStack { Spacer(minLength: 0); label(lanes.core) }
            }
        }
        .padding(.trailing, CallFlowStyle.endPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lanes: \(lanes.phone), \(lanes.ran), \(lanes.core)")
    }

    /// Centred on its lane: the phone and core lanes sit 18 pt in, under the middle of a 36 pt label.
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: CallFlowStyle.laneInset * 2, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .tertiarySystemFill)))
    }
}
