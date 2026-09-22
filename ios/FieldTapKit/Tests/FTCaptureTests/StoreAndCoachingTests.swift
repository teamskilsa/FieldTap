import Foundation
import Testing
import FTModel
@testable import FTCapture

@Suite struct CaptureStoreTests {
    static func store() throws -> CaptureStore {
        try CaptureStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("ft-wp3-\(UUID().uuidString)"))
    }

    @Test func savesListsUpdatesAndDeletes() throws {
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let records = [LogRecord(code: 0xB0C0, timestampRaw: 5, body: [1, 2, 3]),
                       LogRecord(code: 0xB821, timestampRaw: 6, body: [0x7E])]
        let older = CaptureSummary(importedAt: Date(timeIntervalSinceReferenceDate: 1_000), sourceName: "a.tar.gz")
        var newer = CaptureSummary(importedAt: Date(timeIntervalSinceReferenceDate: 2_000), sourceName: "b.tar.gz",
                                   problems: [.profileExpired(Date(timeIntervalSinceReferenceDate: 500))],
                                   traceWindowAfterPressMs: TraceWindow(startMs: 19_000, endMs: 46_844))
        let url = try store.save(records: records, summary: older)
        #expect(url.lastPathComponent == "capture.qmdl")
        try store.save(records: [], summary: newer)
        #expect(try store.list().map(\.id) == [newer.id, older.id])
        #expect(try store.records(for: older.id) == records)
        #expect(try store.records(for: newer.id).isEmpty)
        #expect(throws: (any Error).self) { try store.records(for: UUID()) }

        newer.digest = "B2 → B66, 0 failures"
        try store.update(newer)
        let listed = try #require(try store.list().first)
        #expect(listed == newer)
        #expect(store.sizeBytes() > 0 && store.sizeBytes(of: older.id) > 0)

        #expect(try store.rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try store.delete(older.id)
        #expect(try store.list().map(\.id) == [newer.id])
        #expect(throws: (any Error).self) { try store.update(older) }
    }

    /// A folder with a damaged summary is skipped, not fatal.
    @Test func damagedSummaryIsSkipped() throws {
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let good = CaptureSummary(importedAt: Date(), sourceName: "a.tar.gz")
        try store.save(records: [], summary: good)
        let bad = store.rootURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bad.appendingPathComponent("summary.json"))
        try FileManager.default.createDirectory(at: store.rootURL.appendingPathComponent("not-a-capture"),
                                                withIntermediateDirectories: true)
        #expect(try store.list().map(\.id) == [good.id])
    }
}

@Suite struct CoachingTests {
    /// R2, both captures: get ready for 3 s, do it until 12 s, then wait for the sysdiagnose.
    @Test func countdownPhases() {
        let press = Date(timeIntervalSinceReferenceDate: 0)
        let c = CaptureCountdown(pressedAt: press)
        #expect(c.phase(at: press) == .getReady(secondsLeft: 3))
        #expect(c.phase(at: press.addingTimeInterval(2.2)) == .getReady(secondsLeft: 1))
        #expect(c.phase(at: press.addingTimeInterval(3)) == .doItNow(secondsLeft: 9))
        #expect(c.phase(at: press.addingTimeInterval(8)).token == "doItNow")
        #expect(c.phase(at: press.addingTimeInterval(11.9)) == .doItNow(secondsLeft: 1))
        #expect(c.phase(at: press.addingTimeInterval(12)) == .waiting(secondsLeft: 588))
        #expect(c.phase(at: press.addingTimeInterval(599.5)) == .waiting(secondsLeft: 1))
        #expect(c.phase(at: press.addingTimeInterval(600)) == .ready)
        #expect(c.readyAt.timeIntervalSince(press) == 600 && c.doItNowAt.timeIntervalSince(press) == 3)
        #expect(c.waitAt.timeIntervalSince(press) == 12 && CaptureCountdown.doItBySeconds == 12)
    }

    /// The timing advice lives in one constant, and it is the advice the evidence supports: press first, do the
    /// thing 3-5 s later, be finished by about 12 s, press within 2-3 s for something that already happened,
    /// and an idle phone reaches back minutes. Nothing here may say 20 to 40 seconds again.
    @Test func timingAdviceMatchesTheCountdown() {
        let t = CaptureWording.timing
        #expect(t.hasPrefix("Press the buttons first"))
        #expect(t.contains("3 to 5 seconds later"))
        #expect(t.contains("\(Int(CaptureCountdown.doItBySeconds)) seconds"))
        #expect(t.contains("2 to 3 seconds"))
        #expect(t.contains("reaches back minutes"))
        #expect(!t.contains("20 to 40") && !t.contains("27 seconds"))
        // One paragraph, no line breaks: it is shown inside cards and under the countdown ring.
        #expect(!t.contains("\n"))
    }

    @Test func wording() {
        #expect(CaptureWording.minutesSeconds(19) == "0:19")
        #expect(CaptureWording.minutesSeconds(46.844) == "0:46")
        #expect(CaptureWording.minutesSeconds(65) == "1:05")
        #expect(CaptureWording.pressWindow(TraceWindow(startMs: 19_000, endMs: 46_844))
            == "covers 0:19–0:46 after you pressed the buttons")
        #expect(CaptureWording.pressWindow(TraceWindow(startMs: -2_000, endMs: 30_000))
            == "covers 0:02 before to 0:30 after you pressed the buttons")
        #expect(CaptureWording.pressWindow(TraceWindow(startMs: -30_000, endMs: -1_000))
            == "covers 0:30–0:01 before you pressed the buttons")
        #expect(CaptureWording.overwritten(111, listed: 241) == "111 of 241 trace files had already been overwritten")
        #expect(CaptureWording.overwritten(0, listed: 130) == nil)
        #expect(CaptureWording.overwritten(1, listed: nil) == "1 trace file had already been overwritten")
        #expect(CaptureWording.traceLength(ms: 27_004) == "27.0 s trace")
        #expect(CaptureWording.traceLength(ms: nil) == nil)
    }

    static func segment(_ lane: LaneKind, _ band: String?, _ start: Double, _ end: Double) -> CellSegment {
        CellSegment(lane: lane, index: 0, cell: Cell(earfcn: 1_000, pci: 1, nr: band == nil), band: band, dlMhz: nil, startMs: start,
                    endMs: end, source: .rrc)
    }

    @Test func digestFromTheJourney() throws {
        #expect(CaptureDigest.of(journey: .empty) == nil)
        var j = Journey.empty
        j.cells = [Self.segment(.pcell, "B2", 0, 5_000), Self.segment(.pcell, "B66", 5_000, 9_000),
                   Self.segment(.pcell, "B66", 9_000, 12_000), Self.segment(.pcell, "B12", 12_000, 20_000),
                   Self.segment(.pcell, "B2", 20_000, 27_000), Self.segment(.pscell, nil, 1_000, 4_000)]
        let d = try #require(CaptureDigest.of(journey: j))
        #expect(d.digest == "B2 → B66 → B12 → B2, NR, 0 failures")
        #expect(d.preview.segments.count == 5 && d.preview.nr && d.preview.failures == 0)
        #expect(d.preview.segments.first == PreviewSegment(band: "B2", startMs: 0, endMs: 5_000))
    }

    @Test func leftoversAreSwept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ft-wp3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = root.appendingPathComponent("Import"), inbox = root.appendingPathComponent("Inbox")
        for dir in [scratch.appendingPathComponent("import-old"), scratch.appendingPathComponent("import-new"),
                    scratch.appendingPathComponent("other"), inbox] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let old = inbox.appendingPathComponent("sysdiagnose_old.tar.gz"), keep = inbox.appendingPathComponent("keep.tar.gz")
        let fresh = inbox.appendingPathComponent("fresh.tar.gz")
        for f in [old, keep, fresh] { try Data([1]).write(to: f) }
        let hourAgo = Date().addingTimeInterval(-3_600)
        for url in [old, keep, scratch.appendingPathComponent("import-old"), scratch.appendingPathComponent("other")] {
            try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: url.path)
        }
        let removed = ImportLeftovers.sweep(scratch: scratch, inbox: inbox, keep: keep)
        #expect(removed == 2)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: scratch.path))
        #expect(names == ["import-new", "other"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: inbox.path)) == ["keep.tar.gz", "fresh.tar.gz"])
    }
}
