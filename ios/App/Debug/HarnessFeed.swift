// DEBUG/Harness only (WP7). FT_FEED_PATH: the user's sysdiagnose read in place from the host (the simulator
// can read host paths), never copied into the container. -FTScanOnly proves the archive route alone (scan.json);
// otherwise the archive goes through the app's own importer and Analyzer (import.json, analysis.json).

#if DEBUG || FT_HARNESS
import CryptoKit
import Foundation
import Synchronization
import FTApp
import FTCapture
import FTJourney
import FTCore
import FTModel

enum HarnessFeed {
    /// What one streaming pass over the archive saw (scan.json). Counts only.
    struct ScanReport: Codable, Sendable {
        var ok: Bool
        var error: String?
        var compressedBytes = 0
        var uncompressedBytes = 0
        var tarEntries = 0
        /// Regular files under logs/Baseband/, AppleDouble twins excluded.
        var basebandFiles = 0
        var basebandBytes = 0
        var adler32Hex = ""
        var appleDoubleSkipped = 0
        /// QDSS trace chunks (log-bb-*-qdss/0x*.bin) and the directories they sit in.
        var qdssChunks = 0
        var qdssDirs = 0
        /// logs/MCState/Shared/profile-*.stub files seen (not read).
        var profileStubs = 0
        /// ambtool_output.log present, and whether it says baseband logs are enabled (R1).
        var ambtoolLog = false
        var basebandLoggingEnabled: Bool?
        var seconds = 0.0
    }

    /// -FTScanOnly: the same pass the POC measured (135 Baseband files, 130 chunks, adler32 a0e39d83).
    @MainActor static func scan(_ url: URL) async {
        let report = await Task.detached(priority: .userInitiated) { scanReport(url) }.value
        DebugFiles.write(report, as: "scan.json")
    }

    static func scanReport(_ url: URL) -> ScanReport {
        var report = ScanReport(ok: false)
        var chunks = 0, stubs = 0
        var dirs = Set<String>()
        var ambtool: [UInt8]?
        do {
            let r = try SysdiagScanner.scan(url, select: { path in
                if BasebandArchive.isProfileStub(path) { stubs += 1 }
                return path.contains("/logs/Baseband/")
            }, sink: { path, _, bytes, isLast in
                if path.hasSuffix("/ambtool_output.log") {
                    ambtool = (ambtool ?? []) + Array(bytes.prefix(4_096))
                }
                guard isLast, BasebandArchive.isQdssFile(path) else { return }
                chunks += 1
                if let dir = BasebandArchive.traceDirName(path) { dirs.insert(dir) }
            })
            report.ok = true
            report.compressedBytes = r.compressedBytes
            report.uncompressedBytes = r.uncompressedBytes
            report.tarEntries = r.tarEntries
            report.basebandFiles = r.selectedFiles
            report.basebandBytes = r.selectedBytes
            report.adler32Hex = r.adler32Hex
            report.appleDoubleSkipped = r.appleDoubleSkipped
            report.seconds = DebugFiles.r3(r.seconds)
        } catch {
            report.error = String(describing: error)
        }
        report.qdssChunks = chunks
        report.qdssDirs = dirs.count
        report.profileStubs = stubs
        if let text = ambtool.map({ String(decoding: $0, as: UTF8.self) }) {
            report.ambtoolLog = true
            report.basebandLoggingEnabled = !text.localizedCaseInsensitiveContains("not enabled")
        }
        return report
    }

    /// FT_FEED_PATH without -FTScanOnly: the app's importer on the host file in place (not security scoped:
    /// a simulator process reads host paths directly), then the Analyzer, then analysis.json. The capture
    /// the importer stored stays in the container, so later launches can open it with -FTOpenLatest.
    @MainActor static func importAndAnalyze(_ url: URL, app: AppModel) async {
        let log = ImportLog(archiveBytes: fileSize(url))
        log.begin()
        let importer = app.importer
        let store = app.store
        let started = ContinuousClock.now
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try await importer.importArchive(at: url, securityScoped: false) { log.record($0) }
            }.value
            let importSeconds = seconds(since: started)
            log.finish(error: nil)
            var importRun = log.runInfo()
            importRun.importSeconds = importSeconds
            importRun.importerTimings = DebugFiles.r3(imported.summary.timings)
            let baseRun = importRun
            let report = await Task.detached(priority: .userInitiated) {
                var run = baseRun
                let t0 = ContinuousClock.now
                var analysis = Analyzer.analyze(records: imported.records, summary: imported.summary)
                run.analyzeSeconds = seconds(since: t0)
                // Finish the stored summary as ImportCoordinator does, so the capture card shows its digest.
                if imported.summary.hasTrace, let d = JourneyDigest.of(analysis.journey) {
                    var summary = imported.summary
                    summary.durationMs = analysis.summary.durationMs
                    summary.digest = d.digest
                    summary.preview = d.preview
                    try? store.update(summary)
                    analysis.summary.digest = d.digest
                    analysis.summary.preview = d.preview
                }
                let t1 = ContinuousClock.now
                var report = AnalysisReport.of(analysis, source: "import", records: imported.records,
                                               qmdl: imported.qmdlURL, run: run)
                // The screens read the capture back from the store: check that round trip too.
                report.capture?.storedRecords = try? store.records(for: imported.summary.id).count
                report.run.reportSeconds = seconds(since: t1)
                return report
            }.value
            DebugFiles.write(report, as: "analysis.json")
        } catch {
            log.finish(error: error)
            var run = log.runInfo()
            run.importSeconds = seconds(since: started)
            DebugFiles.write(AnalysisReport.failed(source: "import", error: error, run: run), as: "analysis.json")
            print("FieldTap harness: FT_FEED_PATH import failed: \(error)")
        }
        app.refresh()
    }

    /// -FTDumpAnalysis with -FTFixture: the loaded fixture's analysis, with the fixture's qmdl re-read for the
    /// record counts (the loader keeps no records), as analysis-fixture.json.
    @MainActor static func dumpFixture(_ analysis: CaptureAnalysis, dir: URL) async {
        let report = await Task.detached(priority: .userInitiated) { () -> AnalysisReport in
            let t0 = ContinuousClock.now
            let qmdl = dir.appendingPathComponent("iphone-recovered.qmdl")
            let data = try? Data(contentsOf: qmdl, options: .mappedIfSafe)
            let read = data.map { DiagProtocol.readQmdl($0) }
            var run = AnalysisReport.Run()
            // Where the loader's parts came from: golden events carry no PDU bytes, and a PHY summary with
            // no series came from contract/phy-summary.json.
            run.flowSource = analysis.flow.events.isEmpty ? "none"
                : analysis.flow.events.contains { !$0.pdu.isEmpty } ? "qmdl" : "golden"
            run.phySource = analysis.phy.summary.isEmpty ? "none" : analysis.phy.series.isEmpty ? "phy-summary" : "qmdl"
            var report = AnalysisReport.of(analysis, source: "fixture", records: read?.records,
                                           qmdl: data == nil ? nil : qmdl, run: run)
            if let read { report.capture?.crcErrors = read.crcErrors }
            report.run.reportSeconds = seconds(since: t0)
            return report
        }.value
        DebugFiles.write(report, as: "analysis-fixture.json")
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return DebugFiles.r3(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    static func md5(_ url: URL) -> (hex: String, bytes: Int)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(), data.count)
    }
}

/// import.json: every stage the importer reported, when, and how long each took. Written from the importer's
/// progress callback (any thread), throttled to a few writes a second plus every stage change and the end.
final class ImportLog: Sendable {
    struct Entry: Codable, Sendable {
        var t: Double
        var stage: String
        var fraction: Double
        var detail: String
    }

    struct File: Codable, Sendable {
        var state = "running"
        var archiveBytes: Int?
        var elapsedS = 0.0
        /// Seconds from each stage's first progress event to the next stage's (or the end).
        var stageSeconds: [String: Double] = [:]
        var progressEvents = 0
        /// Stage changes, plus at most one event per stage every 0.5 s.
        var events: [Entry] = []
        var error: String?
    }

    private struct State: Sendable {
        var file = File()
        var stageStarts: [(stage: String, t: Double)] = []
        var lastKept = -1.0
        var lastWrite = -1.0
    }

    private let started = ContinuousClock.now
    private let state: Mutex<State>

    init(archiveBytes: Int?) {
        var s = State()
        s.file.archiveBytes = archiveBytes
        state = Mutex(s)
    }

    func begin() { DebugFiles.write(state.withLock { $0.file }, as: "import.json") }

    func record(_ p: ImportProgress) {
        let t = HarnessFeed.seconds(since: started)
        let snapshot: File? = state.withLock { s in
            s.file.progressEvents += 1
            let newStage = s.stageStarts.last?.stage != p.stage.rawValue
            if newStage { s.stageStarts.append((p.stage.rawValue, t)) }
            if newStage || t - s.lastKept >= 0.5 {
                s.file.events.append(Entry(t: t, stage: p.stage.rawValue, fraction: DebugFiles.r3(p.fraction),
                                           detail: p.detail))
                s.lastKept = t
            }
            s.file.elapsedS = t
            s.file.stageSeconds = Self.durations(s.stageStarts, end: t)
            guard newStage || t - s.lastWrite >= 0.5 else { return nil }
            s.lastWrite = t
            return s.file
        }
        if let snapshot { DebugFiles.write(snapshot, as: "import.json") }
    }

    func finish(error: (any Error)?) {
        let t = HarnessFeed.seconds(since: started)
        let file = state.withLock { s in
            s.file.state = error == nil ? "done" : "failed"
            s.file.error = error.map { String(describing: $0) }
            s.file.elapsedS = t
            s.file.stageSeconds = Self.durations(s.stageStarts, end: t)
            return s.file
        }
        DebugFiles.write(file, as: "import.json")
    }

    /// The run section of analysis.json: the stage times as the progress events saw them.
    func runInfo() -> AnalysisReport.Run {
        state.withLock { s in
            var run = AnalysisReport.Run()
            run.stageSeconds = s.file.stageSeconds
            run.progressEvents = s.file.progressEvents
            run.feedBytes = s.file.archiveBytes
            return run
        }
    }

    private static func durations(_ starts: [(stage: String, t: Double)], end: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for (i, s) in starts.enumerated() {
            let next = i + 1 < starts.count ? starts[i + 1].t : end
            out[s.stage, default: 0] += max(0, next - s.t)
        }
        return DebugFiles.r3(out)
    }
}
#endif
