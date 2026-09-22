import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTCapture

/// The user's real archives, read in place (never copied): the capture taken with the profile (FT_SYSDIAGNOSE)
/// and an earlier one taken without it.
enum UserArchives {
    static var onSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static func env(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        return (e[name] ?? e["TEST_RUNNER_" + name]).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// sysdiagnose_2026.09.21_14-39-54-...: taken before the profile was installed (FT_SYSDIAGNOSE_NOPROFILE, or the
    /// file of that name next to FT_SYSDIAGNOSE).
    static var withoutProfile: URL? {
        let name = "sysdiagnose_2026.09.21_14-39-54-0400_iPhone-OS_iPhone_23F84.tar.gz"
        let path = env("FT_SYSDIAGNOSE_NOPROFILE")
            ?? env("FT_SYSDIAGNOSE").map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent(name).path }
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Bytes on disk under `url`.
    static func size(_ url: URL) -> Int64 { CaptureStore.allocatedBytes(url) }
}

/// Records the largest scratch folder seen while an import runs.
final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    let dir: URL

    init(_ dir: URL) { self.dir = dir }

    func measure() {
        let now = UserArchives.size(dir)
        lock.lock()
        peak = max(peak, now)
        lock.unlock()
    }

    var bytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

@Suite struct FullSysdiagnoseTests {
    /// The whole import of the user's 408 MB capture: md5 parity of capture.qmdl with qdss_deframe.py, every
    /// compared stat, the secure census, the trace directory, no problems, under a minute (Release), the scratch
    /// folder gone and never over 200 MB. Skipped on the simulator by design: its Debug build of a 124 MB deframe
    /// takes minutes and the macOS run already covers the same code.
    /// Gated on the archive itself: the .tar.gz is not kept on this Mac for ever (it is 408 MB and the disk is
    /// small), and a test that cannot read it should say which file it wants, not fail. The deframer parity it
    /// checks is also checked from the extracted chunks by `fullCaptureChunksMatchPython`, which survives the
    /// archive.
    @Test(.enabled(if: Fixtures.sysdiagnose != nil,
                   "needs the 2026-09-21 15-41-47 sysdiagnose archive (FT_SYSDIAGNOSE)"),
          .fixture("qdss-full-stats.json"),
          .disabled(if: UserArchives.onSimulator, "the full sysdiagnose runs on macOS (swift test), not the simulator"))
    func fullSysdiagnose() async throws {
        guard let archive = Fixtures.sysdiagnose, let statsURL = Fixtures.require("qdss-full-stats.json") else {
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-wp3-full-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(root: dir.appendingPathComponent("Captures"))
        let scratch = dir.appendingPathComponent("Scratch")
        let meter = PeakMeter(scratch)
        let importer = SysdiagnoseImporter(store: store, scratch: scratch)
        let t0 = Date()
        let imported = try await importer.importArchive(at: archive, securityScoped: false) { p in
            // Every chunk is in scratch when deframing starts: the peak.
            if p.stage == .deframing && p.fraction == 0 { meter.measure() }
            if p.stage == .saving { meter.measure() }
        }
        let elapsed = Date().timeIntervalSince(t0)
        let s = imported.summary

        #expect(try Qdss.md5(of: imported.qmdlURL) == "e53a167b29b25560938d1f089e719d33")
        #expect(imported.records.count == 92_133)
        let expected = try DeframerParityTests.json(statsURL)
        let stats = try #require(s.deframe)
        try DeframerParityTests.expectStats(stats, equal: expected, keys: DeframeStats.comparedKeys)
        try DeframerParityTests.expectStats(stats, equal: expected, keys: ["incomplete_records", "targets", "top_codes"])
        #expect(stats.atid32Bytes == 124_618_275)
        #expect(stats.counters["u_start"] == 1_128_612 && stats.counters["u_cont"] == 5_411_059)
        #expect(stats.counters["u_chan"] == 1_129_175 && stats.counters["u_fill"] == 119_795)
        #expect(stats.counters["qshrink_f3"] == 818_097 && stats.counters["messages"] == 172_707)
        #expect(stats.counters["gather_flushed_unterminated"] == 632 && stats.counters["gather_left_open"] == 1)
        #expect(stats.packets["secure"] == 23_764 && stats.packets["log"] == 91_500 && stats.packets["log_unterm"] == 633)
        #expect(s.secure.records == 23_764 && s.secure.codes == 61)
        #expect(s.traceDirName == "log-bb-2026-09-21-15-42-33-844-qdss")
        #expect(s.chunkCount == 130)
        #expect(s.problems.isEmpty)
        #expect(s.profile?.identifier == "com.apple.basebandlogging")
        // R2: info.txt lists 241 files, the archive keeps the newest 130, 19-46.8 s after the press.
        #expect(s.listedFiles == 241 && s.overwrittenFiles == 111)
        let w = try #require(s.traceWindowAfterPressMs)
        #expect(abs(w.startMs - 19_000) < 1 && abs(w.endMs - 46_844) < 1)
        #expect(CaptureWording.pressWindow(w) == "covers 0:19–0:46 after you pressed the buttons")
        #expect(GuideState.from(latest: s, now: s.triggerUtc!.addingTimeInterval(86_400)).token == "active")

        let left = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        #expect(left.isEmpty, "scratch not cleaned: \(left)")
        #expect(meter.bytes > 100_000_000 && meter.bytes < 200_000_000, "peak scratch \(meter.bytes) bytes")
        print("fullSysdiagnose: \(String(format: "%.1f", elapsed)) s, peak scratch \(meter.bytes / 1_000_000) MB, "
              + "timings \(s.timings.mapValues { String(format: "%.2f", $0) })")
        #if !DEBUG
        #expect(elapsed < 60, "import took \(elapsed) s")
        #endif
    }

    /// The whole 2026-09-21 capture straight from its 130 extracted chunk files: the same md5 and the same
    /// stats as qdss_deframe.py, with the resync code in place. The stream never loses sync (no bad-type unit
    /// in 7.7 M, no gap in the chunk numbering), so resync must not touch a byte of it; this is the test that
    /// says so now that the archive itself may be gone.
    @Test(.chunks(CaptureChunks.first, "the 2026-09-21 15-41-47 capture"), .fixture("qdss-full-stats.json"),
          .disabled(if: CaptureChunks.onSimulator, "the 124 MB deframe runs on macOS (swift test)"))
    func fullCaptureChunksMatchPython() throws {
        guard let dir = CaptureChunks.first, let statsURL = Fixtures.require("qdss-full-stats.json") else { return }
        let files = CaptureChunks.files(dir)
        #expect(files.count == 130)
        let out = try Qdss.deframe(chunkFiles: files)
        let qmdl = DeframerParityTests.temp("iphone-recovered.qmdl")
        defer { try? FileManager.default.removeItem(at: qmdl) }
        let written = try Qdss.writeQmdl(out.records, to: qmdl)
        #expect(written.md5 == "e53a167b29b25560938d1f089e719d33")
        #expect(out.records.count == 92_133)
        let expected = try DeframerParityTests.json(statsURL)
        try DeframerParityTests.expectStats(out.stats, equal: expected, keys: DeframeStats.comparedKeys)
        try DeframerParityTests.expectStats(out.stats, equal: expected, keys: ["incomplete_records", "targets", "top_codes"])
        // Nothing resynced: the counters that only resync writes are absent.
        #expect(out.stats.counters["resyncs"] == nil && out.stats.counters["chunk_gaps"] == nil)
        #expect(out.stats.counters["resync_dropped_fragments"] == nil && out.stats.counters["u_badtype"] == nil)
    }

    /// The 2026-09-22 capture, taken while moving: three chunk files listed in info.txt are missing from the
    /// archive and the stream also slips inside a chunk, so one fixed phase recovers less than a quarter of it.
    /// With resync the whole trace comes back, and every record is complete.
    @Test(.chunks(CaptureChunks.second, "the 2026-09-22 08-57-25 capture"),
          .disabled(if: CaptureChunks.onSimulator, "the 128 MB deframe runs on macOS (swift test)"))
    func secondCaptureResyncsThroughTheGaps() throws {
        guard let dir = CaptureChunks.second else { return }
        let files = CaptureChunks.files(dir)
        let numbers = files.compactMap { Qdss.sequence(of: $0.lastPathComponent) }
        let missing = numbers.isEmpty ? 0 : (numbers.max()! - numbers.min()! + 1) - numbers.count
        let out = try Qdss.deframe(chunkFiles: files)
        print("secondCapture: \(files.count) chunks, \(missing) missing, \(out.records.count) records, "
              + "\(out.stats.distinctCodes) codes, \(out.stats.incompleteRecords) incomplete, "
              + "counters \(out.stats.counters.filter { $0.key.hasPrefix("resync") || $0.key == "chunk_gaps" || $0.key == "u_badtype" })")
        #expect(missing == 3)
        #expect(out.stats.counters["chunk_gaps"] == 3)
        #expect((out.stats.counters["resyncs"] ?? 0) >= 1)
        #expect(out.records.count >= 80_000, "\(out.records.count) records")
        #expect(out.stats.distinctCodes >= 200)
        #expect(out.stats.incompleteRecords == 0)
        try writeFixture(out, chunks: files.count, dir: dir)
    }

    /// With FT_CAPTURE2_FIXTURE_OUT set, the recovered capture is written there as a -FTFixture folder (a .qmdl
    /// plus the trace's own info.txt and name), so the harness can screenshot this capture without an archive.
    /// Nothing is written otherwise, and never inside the repo except under the git-ignored Fixtures/local.
    func writeFixture(_ out: DeframeOutput, chunks: Int, dir: URL) throws {
        guard let path = UserArchives.env("FT_CAPTURE2_FIXTURE_OUT") else { return }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("baseband-meta"), withIntermediateDirectories: true)
        _ = try Qdss.writeQmdl(out.records, to: root.appendingPathComponent("capture2.qmdl"))
        try JSONEncoder().encode(out.stats).write(to: root.appendingPathComponent("qdss-full-stats.json"))
        let name = CaptureChunks.secondName + ".tar.gz"
        try name.write(to: root.appendingPathComponent("baseband-meta/archive-name.txt"), atomically: true, encoding: .utf8)
        try dir.lastPathComponent.write(to: root.appendingPathComponent("baseband-meta/trace-dir-name.txt"),
                                        atomically: true, encoding: .utf8)
        // info.txt alone: FixtureLoader reads the listing from it, and trace.info is not used.
        for leaf in ["info.txt"] where fm.fileExists(atPath: dir.appendingPathComponent(leaf).path) {
            try? fm.removeItem(at: root.appendingPathComponent("baseband-meta/" + leaf))
            try fm.copyItem(at: dir.appendingPathComponent(leaf), to: root.appendingPathComponent("baseband-meta/" + leaf))
        }
        print("secondCapture: wrote a -FTFixture folder to \(root.path)")
    }

    /// The user's 14:39 archive, taken before the profile was installed: 'Modem logging is off' and no trace.
    /// Gated on the file itself (it is not one of FT_FIXTURES / FT_SYSDIAGNOSE, which FT_REQUIRE_FIXTURES covers):
    /// skipped, and named as skipped, when it is not next to FT_SYSDIAGNOSE.
    @Test(.enabled(if: UserArchives.withoutProfile != nil,
                   "needs sysdiagnose_2026.09.21_14-39-54 next to FT_SYSDIAGNOSE (or FT_SYSDIAGNOSE_NOPROFILE)"))
    func earlierArchiveWithoutProfileMeansLoggingOff() async throws {
        guard let archive = UserArchives.withoutProfile else { return }
        let (imported, importer) = try await Archives.run(archive, spare: SysdiagnoseImporter.defaultSpareBytes)
        let s = imported.summary
        #expect(s.problems.contains(.noBasebandTrace))
        #expect(s.problems.contains(.loggingNotEnabled))
        #expect(s.problems.contains(.profileMissing))
        #expect(s.chunkCount == 0 && imported.records.isEmpty && s.profile == nil)
        #expect(s.basebandLoggingEnabled == false)
        let state = GuideState.from(latest: s, now: Date())
        #expect(state == .off)
        #expect(state.headline(now: Date(), date: { _ in "" }) == "Modem logging is off")
        #expect(FileManager.default.fileExists(atPath: archive.path), "the user's archive must never be deleted")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: importer.scratch.path)) ?? []
        #expect(left.isEmpty)
    }
}
