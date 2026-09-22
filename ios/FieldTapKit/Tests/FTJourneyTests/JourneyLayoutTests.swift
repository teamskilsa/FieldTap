// The strip's layout rules on an iPhone 17 (402 pt wide: 16 pt margins, a 34 pt lane-name gutter, so about
// 336 pt of plot): which markers share a glyph, which labels fit, and how zoom, pan and follow move the window.

import Testing
import FTModel
@testable import FTJourney

@Suite struct JourneyLayoutTests {
    static let plotWidth = 336.0

    @Test(.fixture("contract/callflow-golden.json"), .fixture("contract/phy-summary.json"))
    func markersClusterAtTheFullWindow() throws {
        guard let (_, _, j) = try JourneyContractTests.iphone() else { return }
        let full = JourneyLayout.clusters(j.markers, window: 0...j.durationMs, width: Self.plotWidth)
        // 1.8-2.7 s (switch-off to re-attach and RACH), 13.8-15.1 s (NR add and modify, the handover with the
        // inferred SCG release, its RACH), and the 21.65 s handover with its RACH.
        #expect(full.map(\.count) == [6, 5, 2])
        #expect(full.map(\.lead.kind) == [.reattach, .handover, .handover])
        // Neighbouring glyphs never overlap: centres at least a glyph apart.
        let xs = full.map { $0.tMs / j.durationMs * Self.plotWidth }
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $1 - $0 >= JourneyLayout.clusterSpacingPt })
        #expect(full.reduce(0) { $0 + $1.count } == j.markers.count)
        #expect(Set(full.map(\.id)).count == full.count)

        // Zoomed on 14.95-15.25 s the handover and the SCG release still share an instant; the RACH stands alone.
        let zoomed = JourneyLayout.clusters(j.markers, window: 14_950...15_250, width: Self.plotWidth)
        #expect(zoomed.map(\.count) == [2, 1])
        #expect(zoomed[0].lead.kind == .handover && zoomed[0].markers.map(\.kind) == [.handover, .scgRelease])
        #expect(zoomed[1].lead.kind == .rach)
    }

    @Test func failuresLeadAClusterAndClustersAreBounded() {
        let a = Marker(id: "rrcSetup-1", kind: .rrcSetup, tMs: 1_000, event: 1, title: "a")
        let b = Marker(id: "handover-2", kind: .handover, tMs: 1_010, event: 2, title: "b")
        let c = Marker(id: "procedureFailed-3", kind: .procedureFailed, tMs: 1_020, event: 3, severity: .failure, title: "c")
        let d = Marker(id: "attach-4", kind: .attach, tMs: 1_300, event: 4, title: "d")
        // 10 ms per point: a-c are within 2 pt, d is 30 pt away.
        let out = JourneyLayout.clusters([a, b, c, d], window: 0...3_360, width: Self.plotWidth)
        #expect(out.map(\.count) == [3, 1])
        #expect(out[0].lead.id == "procedureFailed-3")
        #expect(out[0].tMs == 1_010)
        // A chain of markers 10 pt apart does not collapse into one: a cluster spans less than 60 pt.
        let chain = (0..<12).map { Marker(id: "m\($0)", kind: .rach, tMs: Double($0) * 100, title: "") }
        #expect(JourneyLayout.clusters(chain, window: 0...3_360, width: Self.plotWidth).map(\.count) == [6, 6])
    }

    @Test func labelsShortenWhenNarrow() {
        let cell = CellSegment(lane: .pcell, index: 1, cell: Cell(earfcn: 67_086, pci: 80), band: "B66", dlMhz: 2175,
                               startMs: 0, endMs: 1, source: .rrc)
        let labels = JourneyLayout.labels(for: cell)
        #expect(labels == ["B66 67086/80", "B66"])
        #expect(JourneyLayout.label(labels, width: 160) == "B66 67086/80")
        #expect(JourneyLayout.label(labels, width: 40) == "B66")
        #expect(JourneyLayout.label(labels, width: 15) == nil)
        let nr = CellSegment(lane: .pscell, index: 0, cell: Cell(earfcn: 174_770, pci: 80, nr: true), band: nil,
                             bandCandidates: [5, 26], dlMhz: 873.85, startMs: 0, endMs: 1, source: .rrc)
        #expect(JourneyLayout.labels(for: nr) == ["NR 174770/80, n5/n26", "NR 174770/80", "NR"])
    }

    @Test func zoomPanAndFollow() {
        let d = 26_959.395
        // Pinch x2 around 15 s: half the span, 15 s stays where it was.
        let z = JourneyLayout.zoom(0...d, scale: 2, anchorMs: 15_000, durationMs: d)
        #expect(abs((z.upperBound - z.lowerBound) - d / 2) < 0.001)
        #expect(abs((15_000 - z.lowerBound) / (z.upperBound - z.lowerBound) - 15_000 / d) < 0.000_1)
        // Never below 0.5 s, never beyond the trace.
        let tight = JourneyLayout.zoom(14_900...15_300, scale: 10, anchorMs: 15_000, durationMs: d)
        #expect(abs((tight.upperBound - tight.lowerBound) - 500) < 0.001)
        #expect(JourneyLayout.zoom(0...1_000, scale: 0.01, anchorMs: 0, durationMs: d) == 0...d)
        #expect(near(JourneyLayout.clamp(start: 26_800, span: 500, durationMs: d), (d - 500)...d))
        #expect(JourneyLayout.clamp(start: -50, span: 500, durationMs: d) == 0...500)
        // The cursor outside a zoomed window recentres it; inside, nothing moves; the full window never moves.
        #expect(near(JourneyLayout.follow(14_950...15_250, cursorMs: 21_653.9, durationMs: d), 21_503.9...21_803.9))
        #expect(JourneyLayout.follow(14_950...15_250, cursorMs: 15_040, durationMs: d) == 14_950...15_250)
        #expect(JourneyLayout.follow(0...d, cursorMs: d, durationMs: d) == 0...d)
    }

    private func near(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Bool {
        abs(a.lowerBound - b.lowerBound) < 0.001 && abs(a.upperBound - b.upperBound) < 0.001
    }

    @Test func axisTicks() {
        let full = JourneyLayout.ticks(0...26_959.395, count: 6)
        #expect(full == [0, 5_000, 10_000, 15_000, 20_000, 25_000])
        #expect(JourneyLayout.tickLabel(25_000, step: 5_000) == "0:25")
        let zoomed = JourneyLayout.ticks(14_950...15_250, count: 6)
        #expect(zoomed == [15_000, 15_100, 15_200])
        #expect(JourneyLayout.tickLabel(15_100, step: 100) == "15.1")
        #expect(JourneyLayout.tickLabel(15_050, step: 50) == "15.05")
    }
}
