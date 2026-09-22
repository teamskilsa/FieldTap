// DEBUG/Harness only (WP7). analysis.json: what the whole pipeline produced for one capture, as counts, kinds
// and ids, never a decoded field value, so it can be compared with the committed
// ios/Fixtures/expected/sim-analysis.json (scripts/check_sim_analysis.py) and pass the privacy gate.

#if DEBUG || FT_HARNESS
import Foundation
import FTApp
import FTModel

struct AnalysisReport: Codable, Sendable {
    var schema = 1
    /// "import" (FT_FEED_PATH through the importer) or "fixture" (-FTFixture through FixtureLoader).
    var source: String
    var ok: Bool
    var error: String?
    var capture: Capture?
    var flow: FlowCounts?
    var phy: PhyCounts?
    var journey: JourneyCounts?
    /// Times and provenance: never compared exactly (the checker bounds importSeconds only).
    var run: Run

    struct Census: Codable, Sendable {
        var records: Int
        var codes: Int
    }

    struct Window: Codable, Sendable {
        var startMs: Double
        var endMs: Double
    }

    struct Profile: Codable, Sendable {
        var baseband: Bool
        /// The status when the archive was taken (ProfileState.status), so the file does not change with the date.
        var statusAtTrigger: String
        var lifetimeDays: Double?
        var consentDays: Int?
    }

    struct Deframe: Codable, Sendable {
        var atid32Bytes: Int
        var chunks: Int
        var phase: Int
        var logRecords: Int
        var distinctCodes: Int
        var incompleteRecords: Int
        var packets: [String: Int]
        var ts: [String: Int]
    }

    struct Capture: Codable, Sendable {
        /// Records handed to the Analyzer, and their distinct log codes.
        var records: Int?
        var distinctCodes: Int?
        var crcErrors: Int
        /// The stored capture.qmdl (import) or the fixture's qmdl.
        var qmdlMd5: String?
        var qmdlBytes: Int?
        /// Records read back from the store, as the screens will read them (import only).
        var storedRecords: Int?
        var chunkCount: Int
        var chunkBytes: Int
        var traceDirFound: Bool
        var hasTrace: Bool
        var problems: [String]
        var basebandLoggingEnabled: Bool?
        var profile: Profile?
        /// R2: the kept trace relative to the button press, and the files the ring overwrote.
        var traceWindowAfterPressMs: Window?
        var overwrittenFiles: Int?
        var listedFiles: Int?
        var deframe: Deframe?
        var secure: Census
        var durationMs: Double?
        var hasDigest: Bool
        var hasPreview: Bool
    }

    struct FlowCounts: Codable, Sendable {
        var records: Int
        var undecoded: Int
        var crcErrors: Int
        var durationMs: Double
        var startUtcKnown: Bool
        var events: Int
        /// "RRC/lte/UL" -> 50.
        var eventsByLayerRatDirection: [String: Int]
        /// Events on a pending NR cell (D4).
        var pendingNrEvents: Int
        var failures: Int
        var procedures: Int
        var procedureOutcomes: [String: Int]
        var steps: [String]
        var connections: [String]
        var cellDetails: Int
        var searched: Int
    }

    struct PhyCounts: Codable, Sendable {
        var series: Int
        /// Samples per metric for all 48 PhyMetric cases (0 when a series is missing).
        var samples: [String: Int]
        var versionMisses: [String: Int]
        var checks: Int
        var checksPassed: Int
        var checksFailed: [String]
        var availability: Int
        var scellActivity: Int
        var nrDlRecords: Int?
        /// Contract rule: the NR DL records carry no ARFCN; FTJourney attributes it.
        var nrDlEarfcnKnown: Bool
        var rach: Int
        var rachTa: [Int]
        var txAntennasMib: [Int]
        var rxAntennaEarfcns: Int
        var encrypted: Census
    }

    struct JourneyCounts: Codable, Sendable {
        var durationMs: Double
        /// state, registration, pcell, pscell, scell -> segments.
        var lanes: [String: Int]
        var states: [String]
        var registration: [String]
        var pcellBands: [String]
        var pscellBandCandidates: [[Int]]
        var markers: Int
        var markersByKind: [String: Int]
        var failureMarkers: Int
        var markerIdsUnique: Bool
        var findings: Int
        var findingIds: [String]
        var findingKinds: [String]
        /// J12's fixed tail: failures or noFailures, encryptedRecords, traceWindow.
        var findingKindsTail: [String]
        var findingIdsUnique: Bool
        /// Tile id -> "succeeded/attempts".
        var tiles: [String: String]
    }

    struct Run: Codable, Sendable {
        var config: String = {
            #if DEBUG
            "Debug"
            #else
            "Harness"
            #endif
        }()
        var feedBytes: Int?
        var importSeconds: Double?
        var analyzeSeconds: Double?
        var reportSeconds: Double?
        /// From the importer's progress events (import.json).
        var stageSeconds: [String: Double] = [:]
        /// CaptureSummary.timings, as the importer measured them.
        var importerTimings: [String: Double] = [:]
        var progressEvents = 0
        /// Fixture runs: where FixtureLoader took the call flow and the PHY summary from.
        var flowSource: String?
        var phySource: String?
    }

    static func failed(source: String, error: any Error, run: Run) -> AnalysisReport {
        AnalysisReport(source: source, ok: false, error: String(describing: error), run: run)
    }

    static func of(_ a: CaptureAnalysis, source: String, records: [LogRecord]?, qmdl: URL?, run: Run) -> AnalysisReport {
        var report = AnalysisReport(source: source, ok: true, run: run)
        let md5 = qmdl.flatMap { HarnessFeed.md5($0) }
        report.capture = capture(a.summary, records: records, md5: md5, flowCrc: a.flow.crcErrors)
        report.flow = flow(a.flow)
        report.phy = phy(a.phy)
        report.journey = journey(a.journey)
        return report
    }

    static func capture(_ s: CaptureSummary, records: [LogRecord]?, md5: (hex: String, bytes: Int)?,
                        flowCrc: Int) -> Capture {
        let d = s.deframe
        return Capture(
            records: records?.count, distinctCodes: records.map { Set($0.map(\.code)).count },
            crcErrors: flowCrc, qmdlMd5: md5?.hex, qmdlBytes: md5?.bytes, storedRecords: nil,
            chunkCount: s.chunkCount, chunkBytes: s.chunkBytes, traceDirFound: s.traceDirName != nil,
            hasTrace: s.hasTrace, problems: s.problems.map(\.token), basebandLoggingEnabled: s.basebandLoggingEnabled,
            profile: s.profile.map {
                Profile(baseband: $0.identifier == "com.apple.basebandlogging", statusAtTrigger: $0.status.rawValue,
                        lifetimeDays: DebugFiles.r3($0.lifetimeDays), consentDays: $0.consentDays)
            },
            traceWindowAfterPressMs: s.traceWindowAfterPressMs.map {
                Window(startMs: DebugFiles.r3($0.startMs), endMs: DebugFiles.r3($0.endMs))
            },
            overwrittenFiles: s.overwrittenFiles, listedFiles: s.listedFiles,
            deframe: d.map {
                Deframe(atid32Bytes: $0.atid32Bytes, chunks: $0.chunks, phase: $0.phase, logRecords: $0.logRecords,
                        distinctCodes: $0.distinctCodes, incompleteRecords: $0.incompleteRecords, packets: $0.packets,
                        ts: $0.ts)
            },
            secure: Census(records: s.secure.records, codes: s.secure.codes), durationMs: DebugFiles.r3(s.durationMs),
            hasDigest: s.digest != nil, hasPreview: s.preview != nil)
    }

    static func flow(_ f: Flow) -> FlowCounts {
        var byKey: [String: Int] = [:]
        for e in f.events { byKey["\(e.layer.rawValue)/\(e.rat)/\(e.uplink ? "UL" : "DL")", default: 0] += 1 }
        var outcomes: [String: Int] = [:]
        for p in f.procedures { outcomes[p.outcome.rawValue, default: 0] += 1 }
        return FlowCounts(
            records: f.records, undecoded: f.undecoded, crcErrors: f.crcErrors, durationMs: DebugFiles.r3(f.durationMs),
            startUtcKnown: f.startUtcMs != nil, events: f.events.count, eventsByLayerRatDirection: byKey,
            pendingNrEvents: f.events.count { $0.cell?.isPendingNr == true }, failures: f.failures,
            procedures: f.procedures.count, procedureOutcomes: outcomes, steps: f.journey.map(\.move.rawValue),
            connections: f.connections.map(\.outcome.rawValue), cellDetails: f.cellDetails.count,
            searched: f.searched.count)
    }

    static func phy(_ p: PhyCapture) -> PhyCounts {
        var samples: [String: Int] = [:]
        for m in PhyMetric.allCases { samples[m.rawValue] = p.series[m]?.samples.count ?? 0 }
        let s = p.summary
        return PhyCounts(
            series: p.series.count, samples: samples, versionMisses: p.versionMisses, checks: p.checks.count,
            checksPassed: p.checks.count(where: \.passed), checksFailed: p.checks.filter { !$0.passed }.map(\.id),
            availability: p.availability.count, scellActivity: s.scellActivity.count,
            nrDlRecords: s.nrDlActivity?.records, nrDlEarfcnKnown: s.nrDlActivity?.earfcn != nil, rach: s.rach.count,
            rachTa: s.rach.map(\.ta), txAntennasMib: s.txAntennasMib, rxAntennaEarfcns: s.rxAntennasByEarfcn.count,
            encrypted: Census(records: s.encrypted.records, codes: s.encrypted.codes))
    }

    static func journey(_ j: Journey) -> JourneyCounts {
        var lanes: [String: Int] = ["state": j.states.count, "registration": j.registration.count]
        for kind in [LaneKind.pcell, .pscell, .scell] { lanes[kind.rawValue] = j.cells.count { $0.lane == kind } }
        var byKind: [String: Int] = [:]
        for m in j.markers { byKind[m.kind.rawValue, default: 0] += 1 }
        var tiles: [String: String] = [:]
        for t in j.tiles { tiles[t.id] = "\(t.succeeded)/\(t.attempts)" }
        let pcells = j.cells.filter { $0.lane == .pcell }.sorted { $0.startMs < $1.startMs }
        return JourneyCounts(
            durationMs: DebugFiles.r3(j.durationMs), lanes: lanes, states: j.states.map(\.state.rawValue),
            registration: j.registration.map(\.state.rawValue), pcellBands: pcells.map { $0.band ?? "NR" },
            pscellBandCandidates: j.cells.filter { $0.lane == .pscell }.map(\.bandCandidates),
            markers: j.markers.count, markersByKind: byKind, failureMarkers: j.markers.count { $0.severity == .failure },
            markerIdsUnique: Set(j.markers.map(\.id)).count == j.markers.count, findings: j.findings.count,
            findingIds: j.findings.map(\.id), findingKinds: j.findings.map(\.kind.rawValue),
            findingKindsTail: j.findings.suffix(3).map(\.kind.rawValue),
            findingIdsUnique: Set(j.findings.map(\.id)).count == j.findings.count, tiles: tiles)
    }
}
#endif
