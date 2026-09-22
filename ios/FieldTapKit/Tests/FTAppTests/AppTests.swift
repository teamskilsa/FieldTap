import Foundation
import Testing
import FTModel
import FTCapture
import FTPresentation
import FTTestSupport
@testable import FTApp

/// A store and importer that keep everything in memory.
final class MemoryStore: CaptureStoring, @unchecked Sendable {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("ft-memory-store")
    var summaries: [CaptureSummary] = []
    var recordsById: [UUID: [LogRecord]] = [:]
    func list() throws -> [CaptureSummary] { summaries }
    func records(for id: UUID) throws -> [LogRecord] { recordsById[id] ?? [] }
    func update(_ summary: CaptureSummary) throws { summaries.removeAll { $0.id == summary.id }; summaries.append(summary) }
    func delete(_ id: UUID) throws { summaries.removeAll { $0.id == id } }
}

struct NoImporter: CaptureImporting {
    func importArchive(at url: URL, securityScoped: Bool,
                       progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> ImportedCapture {
        throw SeedError.notImplemented("test")
    }
}

@Suite struct LaunchPlanTests {
    @Test func everyArgument() throws {
        let plan = LaunchPlan.parse(arguments: [
            "-FTScreen", "radio", "-FTFixture", "/tmp/fx", "-FTOpenLatest", "-FTCursorMs", "14500", "-FTEvent", "82",
            "-FTFilter", "nas", "-FTRadioSection", "nr", "-FTImportState", "deframing", "-FTGuideState", "expiringSoon",
        ])
        #expect(plan.route == .radio)
        #expect(plan.fixtureDir?.path == "/tmp/fx")
        #expect(plan.openLatest && plan.cursorMs == 14_500 && plan.event == 82 && plan.filter == .NAS)
        #expect(plan.radioSection == "nr" && plan.importState == "deframing" && plan.guideState == "expiringSoon")
        #expect(plan.problems.isEmpty && plan.needsCapture && !plan.isEmpty)
    }

    @Test func aNormalLaunchIsEmptyAndBadValuesAreReported() {
        #expect(LaunchPlan.parse(arguments: []).isEmpty)
        #expect(LaunchPlan.parse(arguments: ["-NSDoubleLocalizedStrings", "YES"]).isEmpty)
        let bad = LaunchPlan.parse(arguments: ["-FTScreen", "nowhere", "-FTCursorMs", "soon", "-FTOpenLatest", "YES"])
        #expect(bad.route == nil && bad.cursorMs == nil && bad.openLatest)
        #expect(bad.problems == ["-FTScreen nowhere", "-FTCursorMs soon"])
        #expect(!LaunchPlan.parse(arguments: ["-FTScreen", "guide"]).needsCapture)
    }

    @Test func routesKnowTheirTabAndPage() {
        #expect(Route.message.page == .callflow && Route.message.tab == .captures)
        #expect(Route.guide.tab == .guide && Route.guide.page == nil)
        #expect(DetailPage.allCases.map(\.route) == [.overview, .callflow, .radio])
    }
}

@MainActor @Suite struct SessionTests {
    static func analysis(durationMs: Double = 10_000) -> CaptureAnalysis {
        var flow = Flow.empty
        flow.durationMs = durationMs
        flow.events = [Event(index: 0, record: 1, logCode: 0xB0C0, timestampRaw: 1, sinceStartMs: 2_500, layer: .RRC, rat: "lte",
                             uplink: false, key: "k", name: "n", summary: nil, cell: nil, channel: "DL-DCCH", fields: [],
                             cause: nil, causeName: nil, protection: nil, ciphered: false, pdu: [])]
        return CaptureAnalysis(summary: CaptureSummary(importedAt: .now, sourceName: "x"), timeBase: .empty, flow: flow,
                               phy: .empty, journey: .empty)
    }

    @Test func theCursorStaysInsideTheTrace() {
        let c = TimeCursor(durationMs: 1_000)
        c.set(400)
        c.step(100)
        #expect(c.ms == 500)
        c.step(10_000)
        #expect(c.ms == 1_000)
        c.ms = -5
        #expect(c.ms == 0)
        c.set(.nan)
        #expect(c.ms == 0)
    }

    @Test func selectingAnEventMovesTheCursor() {
        let s = CaptureSession(analysis: Self.analysis())
        #expect(s.visibleWindow == 0...10_000 && s.page == .overview && s.filter == .ALL && !s.reveal)
        s.select(event: 0)
        #expect(s.selectedEvent == 0 && s.cursor.ms == 2_500)
        s.select(event: 7)
        #expect(s.selectedEvent == 0, "an unknown index is ignored")
        s.visibleWindow = 100...200
        s.zoomToFit()
        #expect(s.visibleWindow == 0...10_000)
    }

    @Test func theAppListsNewestFirstAndOpensFromTheStore() async throws {
        let store = MemoryStore()
        let old = CaptureSummary(importedAt: Date(timeIntervalSince1970: 1_000), sourceName: "old")
        let new = CaptureSummary(importedAt: Date(timeIntervalSince1970: 2_000), sourceName: "new")
        store.summaries = [old, new]
        let app = AppModel(store: store, importer: NoImporter())
        app.refresh()
        #expect(app.captures.map(\.sourceName) == ["new", "old"])
        #expect(app.latest?.sourceName == "new")
        #expect(app.guideState() == GuideState.from(latest: new, now: .now))
        let session = try await app.open(new.id)
        #expect(session.id == new.id)
        await app.show(old.id)
        #expect(app.openSession?.id == old.id && app.tab == .captures)
        app.requestImport(URL(fileURLWithPath: "/tmp/a.tar.gz"), securityScoped: true)
        #expect(app.pendingImport?.securityScoped == true)
        try app.deleteAll()
        #expect(app.captures.isEmpty && app.openSession == nil)
    }

    @Test func overridesFromALaunchPlan() async {
        let app = AppModel(store: MemoryStore(), importer: NoImporter())
        await app.apply(LaunchPlan.parse(arguments: ["-FTScreen", "guide", "-FTGuideState", "expired"]))
        #expect(app.tab == .guide)
        if case .expired = app.guideState() {} else { Issue.record("guide override not applied") }
        await app.apply(LaunchPlan.parse(arguments: ["-FTScreen", "importSheet", "-FTImportState", "noBasebandTrace"]))
        #expect(app.importPreview == .failed([.noBasebandTrace]) && app.pendingImport != nil)
    }
}

@Suite struct ScreenReportTests {
    @Test func fileNamesAndJSON() throws {
        let r = ScreenReport(route: .message, qualifier: "82", captureId: FixtureLoader.fixtureId, cursorMs: 15_040,
                             values: ["masked": .bool(true), "rowIds": .strings(["event-0"]), "rows": .number(157)])
        #expect(r.fileName == "screen-message-82.json")
        #expect(ScreenReport(route: .captures).fileName == "screen-captures.json")
        let back = try JSONDecoder().decode(ScreenReport.self, from: r.encoded())
        #expect(back == r)
        let json = try #require(JSONSerialization.jsonObject(with: r.encoded()) as? [String: Any])
        #expect(json["ready"] as? Bool == true && json["rendered"] as? Bool == true && json["route"] as? String == "message")
    }
}

/// FixtureLoader against ios/Fixtures/local. Holds whether or not the decoders have merged: without them the
/// flow and PHY summary come from the contract goldens, with them from the qmdl, and the numbers are the same.
@Suite struct FixtureLoaderTests {
    @Test(.fixture("iphone-recovered.qmdl"))
    func theFixtureLoadsAsACapture() throws {
        guard let dir = Fixtures.root, Fixtures.require("iphone-recovered.qmdl") != nil else { return }
        let loaded = try FixtureLoader.loadWithSources(dir: dir)
        let a = loaded.analysis
        #expect(["qmdl", "golden"].contains(loaded.sources.flow))
        #expect(["qmdl", "phy-summary"].contains(loaded.sources.phy))
        #expect(a.flow.events.count == 128)
        #expect(abs(a.durationMs - 26_959.395) < 0.001)
        #expect(abs(a.timeBase.durationMs - 26_959.395) < 0.001)
        #expect(a.phy.summary.scellActivity.count == 3)
        #expect(a.summary.secure.records == 23_764 && a.summary.secure.codes == 61)
        #expect(a.summary.id == FixtureLoader.fixtureId)
    }

    @Test(.fixture("baseband-meta/archive-name.txt"))
    func theSummaryIsBuiltLikeAnImport() throws {
        guard let dir = Fixtures.root, Fixtures.require("baseband-meta/archive-name.txt") != nil else { return }
        let s = FixtureLoader.summary(dir: dir)
        #expect(s.sourceName.hasPrefix("sysdiagnose_2026.09.21_15-41-47"))
        #expect(s.triggerUtc == (try Date("2026-09-21T19:41:47Z", strategy: .iso8601)))
        #expect(s.traceDirName?.hasSuffix("-qdss") == true)
        #expect(s.chunkCount == 130 && s.deframe?.logRecords == 92_133)
        #expect(s.basebandLoggingEnabled == true)
        #expect(s.problems.isEmpty)
        let p = try #require(s.profile)
        #expect(p.identifier == "com.apple.basebandlogging")
        #expect(abs((p.lifetimeDays ?? 0) - 7) < 0.001 && p.consentDays == 7)
        #expect(p.status == .active)
        // R2: the kept trace starts well after the press; files before it were overwritten.
        let w = try #require(s.traceWindowAfterPressMs)
        #expect(w.startMs > 0 && w.endMs > w.startMs)
        #expect((s.overwrittenFiles ?? 0) > 0 && s.listedFiles == (s.overwrittenFiles ?? 0) + 130)
        #expect(GuideState.from(latest: s, now: p.installDate!.addingTimeInterval(86_400)) == .active(p.removalDate!))
    }

    @Test func aMissingFolderThrows() {
        #expect(throws: (any Error).self) { try FixtureLoader.load(dir: URL(fileURLWithPath: "/nonexistent-ft-fixture")) }
    }

    @Test func analyzerFillsTheDurationFromTheRecords() {
        let t0: UInt64 = 0x0112_0000_0000_0000
        let records = [LogRecord(code: 0xB0C0, timestampRaw: t0, body: []),
                       LogRecord(code: 0xB0C0, timestampRaw: t0 + (800 << 16), body: [])]
        let a = Analyzer.analyze(records: records, summary: CaptureSummary(importedAt: .now, sourceName: "x"))
        #expect(a.timeBase == TimeBase.of(records))
        #expect(a.summary.durationMs == 1_000)
        #expect(a.durationMs == 1_000)
    }
}

/// The 2026-09-22 capture, taken while the phone was moving: the one capture where the QDSS stream loses sync,
/// read end to end (deframe, decode, PHY). Gated on its extracted trace directory, since the archive itself is
/// not always kept on this Mac; macOS only, because a 128 MB Debug deframe on the simulator takes minutes.
@Suite struct SecondCaptureTests {
    @Test(.chunks(CaptureChunks.second, "the 2026-09-22 08-57-25 capture"),
          .disabled(if: CaptureChunks.onSimulator, "the 128 MB deframe runs on macOS (swift test)"))
    func secondCaptureDeframesDecodesAndMeasures() throws {
        guard let dir = CaptureChunks.second else { return }
        let out = try Qdss.deframe(chunkFiles: CaptureChunks.files(dir))
        var summary = CaptureSummary(importedAt: .now, sourceName: CaptureChunks.secondName + ".tar.gz")
        summary.deframe = out.stats
        summary.secure = out.census
        let analysis = Analyzer.analyze(records: out.records, summary: summary)
        let events = analysis.flow.events
        let lteRrc = events.count { $0.layer == .RRC && $0.rat == "lte" }
        let nrRrc = events.count { $0.layer == .RRC && $0.rat == "nr" }
        let nas = events.count { $0.layer == .NAS }
        let tbs = analysis.phy.checks.first { $0.id == "b887TbsFormula" }
        print("secondCapture: \(out.records.count) records, \(out.stats.distinctCodes) codes, "
              + "\(events.count) messages (\(lteRrc) LTE RRC, \(nrRrc) NR RRC, \(nas) NAS), "
              + "b887TbsFormula \(tbs.map { "\($0.passed): \($0.measured)" } ?? "none")")

        // Fix 1: resync through the three missing chunk files and the mid-chunk slip.
        #expect(out.records.count >= 80_000, "\(out.records.count) records")
        #expect(out.stats.incompleteRecords == 0)
        // Fix 1: the decoders then have something to read.
        #expect(events.count >= 90, "\(events.count) decoded messages")
        #expect(lteRrc >= 60 && nas >= 25 && nrRrc >= 3, "\(lteRrc) LTE RRC, \(nas) NAS, \(nrRrc) NR RRC")
        // Fix 2: the 0xB887 v3.13 field widths, which only this capture's transport blocks exercise.
        let check = try #require(tbs, "the capture has no 0xB887 records")
        #expect(check.passed, "\(check.measured)")
        // About 828 new transmissions, every one of them explained: "N of N new transmissions match".
        let counted = check.measured.split(separator: " ").prefix(3).compactMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        #expect(counted.count == 2 && counted[0] == counted[1] && counted[0] >= 800, "\(check.measured)")
    }
}

/// Where a capture opens, and what stays put when the user moves between the three pages.
@Suite struct OpeningCursorTests {
    /// The real capture: it opens on the first PCell, not at 0:00.000 where the header has no serving cell yet
    /// and every value in it is a dash.
    @Test(.fixture("iphone-recovered.qmdl")) @MainActor
    func aCaptureOpensOnTheFirstServingCell() throws {
        guard let dir = Fixtures.root, Fixtures.require("iphone-recovered.qmdl") != nil else { return }
        let analysis = try FixtureLoader.load(dir: dir)
        let firstPcell = try #require(analysis.journey.cells.filter { $0.lane == .pcell }.map(\.startMs).min())
        #expect(firstPcell > 0, "the capture's first cell is at 0, so this test proves nothing")
        let session = CaptureSession(analysis: analysis)
        #expect(session.cursor.ms == firstPcell)
        // A cell really is serving at that moment, so the header names one.
        #expect(analysis.journey.cells.contains { $0.lane == .pcell && $0.startMs <= session.cursor.ms
            && session.cursor.ms <= $0.endMs })
        // Moving between the pages keeps the user's position: one cursor, in the session.
        session.cursor.set(15_040)
        session.page = .radio
        #expect(session.cursor.ms == 15_040)
        session.page = .callflow
        #expect(session.cursor.ms == 15_040)
    }

    /// Without cells the first event, and with neither the start of the trace.
    @MainActor @Test func withoutCellsItOpensOnTheFirstEvent() {
        let event = Event(index: 0, record: 1, logCode: 0xB0C0, timestampRaw: 0, sinceStartMs: 412.5, layer: .RRC,
                          rat: "lte", uplink: false, key: "k", name: "n", summary: nil, cell: nil, channel: "BCCH",
                          fields: [], cause: nil, causeName: nil, protection: nil, ciphered: false, pdu: [])
        let flow = Flow(events: [event], procedures: [], journey: [], searched: [], connections: [], records: 1,
                        undecoded: 0, crcErrors: 0, durationMs: 1_000, startUtcMs: nil)
        let summary = CaptureSummary(importedAt: .now, sourceName: "x")
        let analysis = CaptureAnalysis(summary: summary, timeBase: .empty, flow: flow, phy: .empty, journey: .empty)
        #expect(CaptureSession(analysis: analysis).cursor.ms == 412.5)

        let empty = CaptureAnalysis(summary: summary, timeBase: .empty, flow: .empty, phy: .empty, journey: .empty)
        #expect(CaptureSession(analysis: empty).cursor.ms == 0)
    }
}
