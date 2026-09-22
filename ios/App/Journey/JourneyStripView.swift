import SwiftUI
import Charts
import FTApp
import FTJourney
import FTModel

/// The lane chart: state, PCell by band, the NR leg, SCells and markers, with the one time cursor. Drag scrubs
/// the cursor, pinch zooms (0.5 s to the whole trace), double-tap zooms to fit, a tap on a segment or marker
/// explains it. When zoomed, the bar underneath pans. Collapses to a 28 pt mini lane while the page scrolls.
struct JourneyStripView: View {
    @Bindable var session: CaptureSession

    var body: some View {
        let chrome = JourneyChrome.of(session)
        Group {
            if chrome.collapsed {
                CollapsedJourneyStrip(session: session, chrome: chrome)
                    .transition(.opacity)
            } else {
                FullJourneyStrip(session: session, chrome: chrome)
                    .transition(.opacity)
            }
        }
        .sheet(item: Bindable(chrome).markerSheet) { item in
            MarkerSheet(item: item, session: session)
                .presentationDetents([.height(330), .large])
                .presentationDragIndicator(.visible)
        }
        .background(CursorFollower(session: session, chrome: chrome))
        .onAppear { applyLaunchArguments(chrome) }
    }

    private func applyLaunchArguments(_ chrome: JourneyChrome) {
        #if DEBUG || FT_HARNESS
        guard !chrome.launchApplied else { return }
        chrome.launchApplied = true
        let args = JourneyLaunchArguments.current
        let journey = session.analysis.journey
        if let w = args.window {
            session.visibleWindow = max(0, w.lowerBound)...min(w.upperBound, max(session.durationMs, 1))
        }
        if args.collapsed { chrome.collapsed = true }
        if let key = args.marker {
            // A marker id opens that marker; a time opens the glyph cluster drawn there on an iPhone 17.
            let item: MarkerSheetItem?
            if let m = journey.markers.first(where: { $0.id == key }) {
                item = .marker(m)
            } else if let t = Double(key) {
                let clusters = JourneyLayout.clusters(journey.markers, window: session.visibleWindow, width: 336)
                let c = clusters.first { c in c.markers.contains { abs($0.tMs - t) < 1 } }
                item = c.map { $0.count == 1 ? .marker($0.lead) : .cluster($0.markers) }
            } else {
                item = nil
            }
            if let item {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    chrome.show(item, session: session)
                }
            }
        }
        #endif
    }
}

/// Keeps the cursor inside the visible window when something other than the strip moves it (the cursor bar's
/// marker buttons, a finding, the ladder). Not while scrubbing: the finger stays where it is, and the window bar
/// pans. A separate view so only it re-evaluates at 60 Hz.
private struct CursorFollower: View {
    @Bindable var session: CaptureSession
    let chrome: JourneyChrome

    var body: some View {
        Color.clear
            .onChange(of: session.cursor.ms) { _, t in
                guard !chrome.scrubbing else { return }
                let w = JourneyLayout.follow(session.visibleWindow, cursorMs: t, durationMs: session.durationMs)
                if w != session.visibleWindow { session.visibleWindow = w }
            }
    }
}

// MARK: - Full strip

private struct FullJourneyStrip: View {
    @Bindable var session: CaptureSession
    let chrome: JourneyChrome
    @State private var plotWidth = 340.0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let journey = session.analysis.journey
        let lanes = StripLanes(hasNr: journey.cells.contains { $0.lane == .pscell },
                               scellIndexes: Array(Set(journey.cells.filter { $0.lane == .scell }.map(\.index))))
        let window = session.visibleWindow
        let zoomed = window.upperBound - window.lowerBound < session.durationMs - 1
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                LaneLabels(journey: journey, lanes: lanes, chrome: chrome)
                    .frame(width: 34)
                JourneyLanesChart(session: session, chrome: chrome, journey: journey, window: window, lanes: lanes,
                                  plotWidth: plotWidth, nrPhy: session.analysis.phy.summary.nrDlActivity,
                                  dark: scheme == .dark)
                    .equatable()
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { plotWidth = max($0, 1) }
            }
            if zoomed {
                WindowBar(session: session, lanes: lanes)
                    .padding(.leading, 38)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.2), value: zoomed)
    }
}

/// The lane names in a narrow gutter, aligned with the lanes, and the collapse chevron.
private struct LaneLabels: View {
    let journey: Journey
    let lanes: StripLanes
    let chrome: JourneyChrome

    var body: some View {
        let pcellRat = Set(journey.cells.filter { $0.lane == .pcell }.map { JourneyStyle.rat($0.cell) })
        ZStack(alignment: .topLeading) {
            label("State", lanes.state.mid)
            label(pcellRat.count == 1 ? pcellRat.first! : "Cell", lanes.pcell.mid)
            if let nr = lanes.nr { label("NR", nr.mid) }
            if let first = lanes.scells.values.map(\.top).min(), let last = lanes.scells.values.map(\.bottom).max() {
                label("CA", (first + last) / 2)
            }
            Button {
                chrome.toggle()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse the journey strip")
            .offset(y: lanes.markers.mid - 11)
        }
        .frame(height: lanes.height, alignment: .topLeading)
    }

    private func label(_ text: String, _ mid: Double) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 34, height: 12, alignment: .leading)
            .offset(y: mid - 6)
            .accessibilityHidden(true)
    }
}

// MARK: - The chart

/// Everything that does not move with the cursor. Equatable, so a cursor move (60 Hz while scrubbing)
/// re-evaluates only the overlays that read it, not the marks.
private struct JourneyLanesChart: View, @MainActor Equatable {
    let session: CaptureSession
    let chrome: JourneyChrome
    let journey: Journey
    let window: ClosedRange<Double>
    let lanes: StripLanes
    let plotWidth: Double
    let nrPhy: CarrierActivity?
    let dark: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.session === b.session && a.journey == b.journey && a.window == b.window && a.lanes == b.lanes
            && abs(a.plotWidth - b.plotWidth) < 0.5 && a.nrPhy == b.nrPhy && a.dark == b.dark
    }

    @Environment(\.self) private var env

    var body: some View {
        let clusters = JourneyLayout.clusters(journey.markers, window: window, width: plotWidth)
        let ticks = JourneyLayout.ticks(window, count: plotWidth > 300 ? 6 : 4)
        let step = ticks.count > 1 ? ticks[1] - ticks[0] : 1_000
        Chart {
            ForEach(visibleStates, id: \.startMs) { s in
                RectangleMark(xStart: .value("Start", clamp(s.startMs)), xEnd: .value("End", clamp(s.endMs)),
                              yStart: .value("Top", y(lanes.state.top)), yEnd: .value("Bottom", y(lanes.state.bottom)))
                    .foregroundStyle(s.state == .unknown ? Color.secondary.opacity(0.12) : JourneyStyle.state(s.state, dark: dark))
                    .accessibilityLabel(stateName(s.state))
                    .accessibilityValue("\(JourneyText.clock(s.startMs)) to \(JourneyText.clock(s.endMs))")
            }
            ForEach(journey.registration.filter { $0.state == .deregistered && overlaps($0.startMs, $0.endMs) }, id: \.startMs) { r in
                RectangleMark(xStart: .value("Start", clamp(r.startMs)), xEnd: .value("End", clamp(r.endMs)),
                              yStart: .value("Top", y(lanes.registration.top)), yEnd: .value("Bottom", y(lanes.registration.bottom)))
                    .foregroundStyle(Theme.severity(.warning).opacity(0.85))
                    .accessibilityLabel("Not registered")
                    .accessibilityValue("\(JourneyText.clock(r.startMs)) to \(JourneyText.clock(r.endMs))")
            }
            ForEach(visibleCells) { s in
                if let lane = lanes.lane(for: s) {
                    let fill = JourneyStyle.fill(s)
                    let width = pixels(clamp(s.endMs) - clamp(s.startMs))
                    RectangleMark(xStart: .value("Start", clamp(s.startMs)), xEnd: .value("End", clamp(s.endMs)),
                                  yStart: .value("Top", y(lane.top)), yEnd: .value("Bottom", y(lane.bottom)))
                        .foregroundStyle(fill.opacity(s.lane == .scell ? 0.85 : 1))
                        .cornerRadius(s.lane == .pcell ? 5 : 3)
                        .annotation(position: .overlay, alignment: .center, spacing: 0) {
                            if let text = JourneyLayout.label(JourneyLayout.labels(for: s), width: width,
                                                              perCharPt: s.lane == .scell ? 4.9 : 6.4) {
                                Text(text)
                                    .font(.system(size: s.lane == .scell ? 8 : s.lane == .pscell ? 10 : 11, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(JourneyStyle.ink(on: fill, in: env))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .accessibilityLabel(SegmentText.spoken(s))
                        .accessibilityValue(SegmentText.spokenValue(s, journey: journey))
                }
            }
            if let a = nrPhy, let nr = lanes.nr, overlaps(a.firstMs, a.lastMs) {
                // Where NR PHY records exist (0xB887), a thin bar inside the NR lane.
                RectangleMark(xStart: .value("Start", clamp(a.firstMs)), xEnd: .value("End", clamp(a.lastMs)),
                              yStart: .value("Top", y(nr.bottom - 4)), yEnd: .value("Bottom", y(nr.bottom - 2)))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .accessibilityLabel("NR PHY data")
                    .accessibilityValue("\(JourneyText.clock(a.firstMs)) to \(JourneyText.clock(a.lastMs))")
            }
            ForEach(clusters) { c in
                PointMark(x: .value("Time", c.tMs), y: .value("Row", y(lanes.markers.mid)))
                    .symbol { MarkerGlyph(cluster: c) }
                    .accessibilityLabel(c.count == 1 ? JourneyText.markerTitle(c.lead, journey: journey)
                                        : "\(c.count) events, \(JourneyText.markerTitle(c.lead, journey: journey)) and more")
                    .accessibilityValue(JourneyText.clock(c.tMs))
            }
        }
        .chartXScale(domain: window.lowerBound...window.upperBound, range: .plotDimension(padding: 0))
        .chartYScale(domain: 0...lanes.height, range: .plotDimension(padding: 0))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(JourneyLayout.tickLabel(v, step: step)).font(.system(size: 9)).monospacedDigit()
                    }
                }
            }
        }
        .chartPlotStyle { $0.frame(height: lanes.height) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let plot = geo[anchor]
                    ZStack(alignment: .topLeading) {
                        EdgeDecorations(journey: journey, window: window, lanes: lanes, proxy: proxy, plot: plot)
                        StripGestures(session: session, chrome: chrome, journey: journey, lanes: lanes, clusters: clusters,
                                      proxy: proxy, plot: plot)
                        CursorLine(session: session, chrome: chrome, proxy: proxy, plot: plot)
                    }
                }
            }
        }
        .frame(height: lanes.height + 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Journey")
    }

    // MARK: Geometry

    private func y(_ top: Double) -> Double { lanes.height - top }

    private func clamp(_ t: Double) -> Double { min(max(t, window.lowerBound), window.upperBound) }

    private func overlaps(_ a: Double, _ b: Double) -> Bool { b > window.lowerBound && a < window.upperBound }

    private func pixels(_ ms: Double) -> Double {
        ms / max(window.upperBound - window.lowerBound, 1) * plotWidth
    }

    private var visibleStates: [StateSegment] { journey.states.filter { overlaps($0.startMs, $0.endMs) } }

    private var visibleCells: [CellSegment] { journey.cells.filter { overlaps($0.startMs, max($0.endMs, $0.startMs + 1)) } }

    private func stateName(_ s: RadioState) -> String {
        switch s {
        case .connected: "Connected"
        case .idle: "Idle"
        case .radioOff: "Radio off"
        case .unknown: "State unknown"
        }
    }
}

/// A marker glyph; a count badge when several markers share it; a small tick for RRC setup/release and RACH.
private struct MarkerGlyph: View {
    let cluster: MarkerCluster

    var body: some View {
        let lead = cluster.lead
        if cluster.count == 1 && JourneyStyle.isTick(lead.kind) {
            Capsule()
                .fill(Color.secondary)
                .frame(width: 2, height: lead.kind == .rach ? 6 : 10)
        } else {
            Image(systemName: JourneyStyle.symbol(lead.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(JourneyStyle.color(lead.severity))
                .frame(width: 16, height: 16)
                .overlay(alignment: .topTrailing) {
                    if cluster.count > 1 {
                        Text("\(cluster.count)")
                            .font(.system(size: 8, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 11, minHeight: 11)
                            .background(Capsule().fill(Theme.accent))
                            .offset(x: 7, y: -5)
                    }
                }
        }
    }
}

/// The hatching on radio-off spans and the dashed right edge of an NR leg whose end was inferred. Drawn once
/// per window (Swift Charts has no pattern fill).
private struct EdgeDecorations: View {
    let journey: Journey
    let window: ClosedRange<Double>
    let lanes: StripLanes
    let proxy: ChartProxy
    let plot: CGRect

    var body: some View {
        Canvas { ctx, _ in
            for s in journey.states where s.state == .radioOff {
                guard let r = rect(s.startMs, s.endMs, lanes.state) else { continue }
                var path = Path()
                var x = r.minX - r.height
                while x < r.maxX {
                    path.move(to: CGPoint(x: x, y: r.maxY))
                    path.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                    x += 4
                }
                ctx.drawLayer { layer in
                    layer.clip(to: Path(r))
                    layer.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 1)
                }
            }
            for s in journey.cells where s.lane == .pscell && s.endInferred {
                guard let lane = lanes.nr, window.contains(s.endMs), let x = proxy.position(forX: s.endMs) else { continue }
                var path = Path()
                path.move(to: CGPoint(x: plot.minX + x, y: plot.minY + lane.top - 1))
                path.addLine(to: CGPoint(x: plot.minX + x, y: plot.minY + lane.bottom + 1))
                ctx.stroke(path, with: .color(.primary.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rect(_ a: Double, _ b: Double, _ lane: StripLanes.Lane) -> CGRect? {
        let lo = max(a, window.lowerBound), hi = min(b, window.upperBound)
        guard hi > lo, let x0 = proxy.position(forX: lo), let x1 = proxy.position(forX: hi) else { return nil }
        return CGRect(x: plot.minX + x0, y: plot.minY + lane.top, width: x1 - x0, height: lane.height)
    }
}

// MARK: - Cursor

/// The cursor line across every lane, and its time while scrubbing. The only part of the strip that reads the
/// cursor.
private struct CursorLine: View {
    @Bindable var session: CaptureSession
    let chrome: JourneyChrome
    let proxy: ChartProxy
    let plot: CGRect

    var body: some View {
        let t = session.cursor.ms
        if let x = proxy.position(forX: t), x >= -1, x <= plot.width + 1 {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 1.5, height: plot.height + 6)
                    .offset(x: plot.minX + x - 0.75, y: plot.minY - 3)
                if chrome.scrubbing {
                    Text(JourneyText.clock(t))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent))
                        .fixedSize()
                        .offset(x: min(max(plot.minX + x - 28, 0), max(plot.maxX - 56, 0)), y: plot.minY - 2)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Gestures

private struct StripGestures: View {
    @Bindable var session: CaptureSession
    let chrome: JourneyChrome
    let journey: Journey
    let lanes: StripLanes
    let clusters: [MarkerCluster]
    let proxy: ChartProxy
    let plot: CGRect

    @State private var popover: PopoverItem?
    @State private var pinchStart: ClosedRange<Double>?
    @State private var pinchAnchor: Double?

    struct PopoverItem: Identifiable {
        var id: String
        var content: SegmentPopover.Content
        var rect: CGRect
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { _ in withAnimation(.snappy) { session.zoomToFit() } }
                    .exclusively(before: SpatialTapGesture().onEnded { tap($0.location) })
            )
            .simultaneousGesture(scrub)
            .simultaneousGesture(pinch)
            .popover(item: $popover, attachmentAnchor: .rect(.rect(popover?.rect ?? .zero)), arrowEdge: .top) { item in
                SegmentPopover(content: item.content, session: session)
                    .presentationCompactAdaptation(.popover)
            }
            .onAppear(perform: openLaunchSegment)
            .accessibilityHidden(true)
    }

    // MARK: Scrub

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { g in
                guard pinchStart == nil else { return }
                chrome.scrubbing = true
                if let t = time(atX: g.location.x) { session.cursor.set(t) }
            }
            .onEnded { _ in chrome.scrubbing = false }
    }

    // MARK: Pinch

    private var pinch: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { g in
                if pinchStart == nil {
                    pinchStart = session.visibleWindow
                    pinchAnchor = time(atX: g.startLocation.x)
                    chrome.scrubbing = false
                }
                guard let start = pinchStart else { return }
                session.visibleWindow = JourneyLayout.zoom(start, scale: g.magnification,
                                                           anchorMs: pinchAnchor ?? session.cursor.ms,
                                                           durationMs: session.durationMs)
            }
            .onEnded { _ in
                pinchStart = nil
                pinchAnchor = nil
            }
    }

    // MARK: Tap

    private func tap(_ p: CGPoint) {
        guard let t = time(atX: p.x) else { return }
        let yIn = p.y - plot.minY
        if yIn >= lanes.markers.top - 4 {
            guard let x = proxy.position(forX: t) else { return }
            let near = clusters.min { abs((proxy.position(forX: $0.tMs) ?? .infinity) - x) < abs((proxy.position(forX: $1.tMs) ?? .infinity) - x) }
            if let c = near, let cx = proxy.position(forX: c.tMs), abs(cx - x) <= 18 {
                chrome.show(c.count == 1 ? .marker(c.lead) : .cluster(c.markers), session: session)
            }
            return
        }
        if yIn <= lanes.registration.bottom + 1 {
            if let s = journey.states.first(where: { t >= $0.startMs && t < $0.endMs }) {
                present(.state(s, registration: journey.registration.first { t >= $0.startMs && t < $0.endMs }),
                        start: s.startMs, end: s.endMs, lane: lanes.state, id: "state-\(s.startMs)")
            }
            return
        }
        let hit = journey.cells.first { s in
            guard let lane = lanes.lane(for: s) else { return false }
            return yIn >= lane.top - 2 && yIn <= lane.bottom + 2 && t >= s.startMs && t <= s.endMs
        }
        if let s = hit, let lane = lanes.lane(for: s) {
            // The segment's start, or the window's edge when it starts off screen (the popover stays anchored).
            session.cursor.set(max(s.startMs, session.visibleWindow.lowerBound))
            present(.cell(s), start: s.startMs, end: s.endMs, lane: lane, id: s.id)
        }
    }

    private func present(_ content: SegmentPopover.Content, start: Double, end: Double, lane: StripLanes.Lane, id: String) {
        let w = session.visibleWindow
        let lo = max(start, w.lowerBound), hi = min(end, w.upperBound)
        let x0 = proxy.position(forX: lo) ?? 0, x1 = proxy.position(forX: hi) ?? plot.width
        let rect = CGRect(x: plot.minX + x0, y: plot.minY + lane.top, width: max(x1 - x0, 4), height: lane.height)
        popover = PopoverItem(id: id, content: content, rect: rect)
    }

    private func time(atX x: CGFloat) -> Double? {
        let local = min(max(x - plot.minX, 0), plot.width)
        return proxy.value(atX: local, as: Double.self).map { min(max($0, 0), session.durationMs) }
    }

    private func openLaunchSegment() {
        #if DEBUG || FT_HARNESS
        guard popover == nil, let key = JourneyLaunchArguments.current.segment else { return }
        let parts = key.split(separator: ":")
        guard parts.count == 2, let lane = LaneKind(rawValue: String(parts[0])), let index = Int(parts[1]) else { return }
        let inLane = journey.cells.filter { $0.lane == lane }
        guard inLane.indices.contains(index), let l = lanes.lane(for: inLane[index]) else { return }
        let s = inLane[index]
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            session.cursor.set(s.startMs)
            present(.cell(s), start: s.startMs, end: s.endMs, lane: l, id: s.id)
        }
        #endif
    }
}

// MARK: - Window bar

/// When zoomed: the whole trace as a faint PCell lane with the visible window as a thumb. Drag or tap to pan.
private struct WindowBar: View {
    @Bindable var session: CaptureSession
    let lanes: StripLanes

    var body: some View {
        let journey = session.analysis.journey
        let total = max(session.durationMs, 1)
        GeometryReader { geo in
            let w = geo.size.width
            let window = session.visibleWindow
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                ForEach(journey.cells.filter { $0.lane == .pcell }) { s in
                    Rectangle()
                        .fill(JourneyStyle.fill(s).opacity(0.55))
                        .frame(width: max(1, (s.endMs - s.startMs) / total * w), height: 4)
                        .offset(x: s.startMs / total * w)
                }
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.15)))
                    .frame(width: max(8, (window.upperBound - window.lowerBound) / total * w), height: 12)
                    .offset(x: window.lowerBound / total * w)
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let span = window.upperBound - window.lowerBound
                let centre = Double(g.location.x / max(w, 1)) * total
                session.visibleWindow = JourneyLayout.clamp(start: centre - span / 2, span: span, durationMs: total)
            })
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("Visible part of the trace")
        .accessibilityValue("\(JourneyText.clock(session.visibleWindow.lowerBound)) to \(JourneyText.clock(session.visibleWindow.upperBound))")
        .accessibilityAdjustableAction { direction in
            let w = session.visibleWindow
            let span = w.upperBound - w.lowerBound
            let delta = direction == .increment ? span / 2 : -span / 2
            session.visibleWindow = JourneyLayout.clamp(start: w.lowerBound + delta, span: span, durationMs: session.durationMs)
        }
    }
}

// MARK: - Collapsed

/// The strip folded to one 28 pt lane: PCell by band over the whole trace, the NR tick, the cursor. Tap opens it.
private struct CollapsedJourneyStrip: View {
    @Bindable var session: CaptureSession
    let chrome: JourneyChrome

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30)
            ZStack(alignment: .leading) {
                JourneyMiniStrip(preview: JourneyDigest.preview(of: session.analysis.journey),
                                 durationMs: session.durationMs, height: 16)
                MiniCursor(session: session)
            }
            .frame(height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { chrome.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Journey strip, collapsed")
        .accessibilityHint("Opens the journey strip")
        .accessibilityAddTraits(.isButton)
    }
}

private struct MiniCursor: View {
    @Bindable var session: CaptureSession

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1.5, height: geo.size.height + 4)
                .offset(x: session.cursor.ms / max(session.durationMs, 1) * geo.size.width - 0.75, y: -2)
        }
        .allowsHitTesting(false)
    }
}
