import Foundation
import FTCapture
import FTCore
import FTModel

/// Loads a fixture folder (ios/Fixtures/local, laid out by fixtures.sh) as if it had been imported, for
/// `-FTFixture` screenshots, SwiftUI previews and the FTApp tests.
///
/// The records go through `Analyzer` like a real capture. While a decoder package has not merged yet, its part
/// falls back to the contract fixtures: an empty call flow to contract/callflow-golden.json (via GoldenCodec) and
/// an empty PHY summary to contract/phy-summary.json. The summary is built the way an import would: the
/// archive name's trigger time, the Baseband profile stub (ProfileStubReader), ambtool_output.log and info.txt
/// (trace window after the press, overwritten files).
public enum FixtureLoader {
    /// Where each part of a loaded fixture came from ("qmdl", "golden", "phy-summary", "none").
    public struct Sources: Hashable, Sendable {
        public var flow: String
        public var phy: String
    }

    public struct Loaded: Sendable {
        public var analysis: CaptureAnalysis
        public var sources: Sources
    }

    /// A fixed id, so screen reports and screenshots of fixture runs are stable.
    /// No long digit runs in it, so screen reports pass the privacy gate's identifier patterns.
    public static let fixtureId = UUID(uuid: (0xF1, 0x7E, 0x1D, 0x7A, 0xF1, 0x7E, 0x4F, 0x1D,
                                              0xAF, 0x1D, 0xF1, 0x7E, 0x1D, 0x7A, 0xF1, 0x7E))

    public static func load(dir: URL) throws -> CaptureAnalysis { try loadWithSources(dir: dir).analysis }

    public static func loadWithSources(dir: URL) throws -> Loaded {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: dir.path]) }
        let summary = self.summary(dir: dir)

        var analysis: CaptureAnalysis
        var sources = Sources(flow: "none", phy: "none")
        if let qmdl = qmdlURL(in: dir) {
            let read = DiagProtocol.readQmdl(try Data(contentsOf: qmdl, options: .mappedIfSafe))
            analysis = Analyzer.analyze(records: read.records, summary: summary, crcErrors: read.crcErrors)
            if !analysis.flow.events.isEmpty { sources.flow = "qmdl" }
            if !analysis.phy.summary.isEmpty { sources.phy = "qmdl" }
        } else {
            analysis = Analyzer.analyze(records: [], summary: summary)
        }

        var fellBack = false
        if analysis.flow.events.isEmpty, let golden = firstExisting(dir, ["contract/callflow-golden.json", "callflow-golden.json"]) {
            analysis.flow = try GoldenCodec.decodeFlow(Data(contentsOf: golden)).flow
            sources.flow = "golden"
            fellBack = true
        }
        if analysis.phy.summary.isEmpty, let url = firstExisting(dir, phySummaryNames) {
            let census = analysis.phy.summary.encrypted
            analysis.phy.summary = try JSONDecoder().decode(PhySummary.self, from: Data(contentsOf: url))
            if census.codes > 0 { analysis.phy.summary.encrypted = census }
            sources.phy = "phy-summary"
            fellBack = true
        }
        if analysis.summary.secure == .empty { analysis.summary.secure = analysis.phy.summary.encrypted }
        if fellBack { analysis = Analyzer.rebuildJourney(analysis) }
        return Loaded(analysis: analysis, sources: sources)
    }

    /// The CaptureSummary an import of the fixture's archive would have written.
    public static func summary(dir: URL) -> CaptureSummary {
        func text(_ rel: String) -> String? {
            (try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let qmdl = qmdlURL(in: dir)
        let archiveName = text("baseband-meta/archive-name.txt")
        let trigger = archiveName.flatMap { BasebandArchive.triggerDate(archiveName: $0) }
        let traceDir = text("baseband-meta/trace-dir-name.txt")
        let deframe = (try? Data(contentsOf: dir.appendingPathComponent("qdss-full-stats.json")))
            .flatMap { try? JSONDecoder().decode(DeframeStats.self, from: $0) }

        var s = CaptureSummary(id: fixtureId, importedAt: trigger.map { $0.addingTimeInterval(600) } ?? Date(),
                               sourceName: archiveName ?? qmdl?.lastPathComponent ?? dir.lastPathComponent,
                               triggerUtc: trigger, traceDirName: traceDir, chunkCount: deframe?.chunks ?? 0,
                               deframe: deframe)
        if let stub = stubURL(in: dir), let data = try? Data(contentsOf: stub) {
            s.profile = ProfileStubReader.read(data, observedAt: trigger)
        }
        if let log = text("baseband-meta/ambtool_output.log") {
            s.basebandLoggingEnabled = !log.localizedCaseInsensitiveContains("not enabled")
        }
        if let info = text("baseband-meta/info.txt"), let name = archiveName {
            let listed = BasebandArchive.traceListing(infoTxt: info, archiveName: name).map(\.name)
            // The ring keeps the newest files: the kept ones are the last `chunkCount` listed.
            let kept = Set(listed.suffix(max(0, s.chunkCount)))
            if let timing = BasebandArchive.traceTiming(infoTxt: info, archiveName: name, traceDirName: traceDir,
                                                        keptChunks: kept) {
                s.traceWindowAfterPressMs = timing.windowAfterPressMs
                s.overwrittenFiles = timing.overwrittenFiles
                s.listedFiles = timing.listedFiles
            }
        }
        // An import takes the census from the deframer; the fixture keeps it only in the contract PHY summary.
        if let url = firstExisting(dir, phySummaryNames), let data = try? Data(contentsOf: url),
           let census = try? JSONDecoder().decode(CensusOnly.self, from: data).encrypted {
            s.secure = census
        }
        if s.profile == nil && archiveName != nil { s.problems.append(.profileMissing) }
        if s.basebandLoggingEnabled == false { s.problems.append(.loggingNotEnabled) }
        return s
    }

    /// The v1 summary (contract rules for NR DL and bins) first, then the WP0-pinned one.
    static let phySummaryNames = ["contract/phy-summary-v1.json", "contract/phy-summary.json", "phy-summary.json"]

    private struct CensusOnly: Decodable { var encrypted: EncryptedCensus? }

    static func qmdlURL(in dir: URL) -> URL? {
        let preferred = dir.appendingPathComponent("iphone-recovered.qmdl")
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".qmdl") }.sorted().first.map { dir.appendingPathComponent($0) }
    }

    static func stubURL(in dir: URL) -> URL? {
        let profile = dir.appendingPathComponent("profile")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profile.path)) ?? []
        return names.filter { $0.hasSuffix(".stub") && !$0.hasPrefix("._") }.sorted().first
            .map { profile.appendingPathComponent($0) }
    }

    static func firstExisting(_ dir: URL, _ candidates: [String]) -> URL? {
        candidates.map { dir.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
