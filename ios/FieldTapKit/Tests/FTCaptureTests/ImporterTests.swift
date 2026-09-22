import Foundation
import Testing
import FTModel
@testable import FTCapture

/// Synthetic sysdiagnose archives for every import outcome and every Modem logging guide state (R1): no profile
/// with "Baseband logs are not enabled", an expired profile, a profile without a trace, and a valid capture.
enum Archives {
    static let root = "sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84"
    static let trigger = date("2026-09-21T19:41:47Z")
    static let traceDir = "log-bb-2026-09-21-15-42-33-844-qdss"
    static let baseband = "com.apple.basebandlogging"

    static func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

    static func stub(identifier: String = baseband, install: Date?, removal: Date?, days: Int = 7) -> [UInt8] {
        var d: [String: Any] = [
            "PayloadIdentifier": identifier, "PayloadDisplayName": "Baseband and Telephony Logging",
            "ConsentText": ["default": "Logging data will be collected. The logs will expire after \(days) days."],
        ]
        d["InstallDate"] = install
        d["RemovalDate"] = removal
        return [UInt8](try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0))
    }

    static func ambtool(enabled: Bool) -> [UInt8] {
        Array((enabled ? "Baseband log collection: Success (ABM running)\n" : "Baseband logs are not enabled\n").utf8)
    }

    /// info.txt lists every file the modem wrote; the archive keeps only the newest. Local times, no zone.
    static func infoTxt(_ files: [(name: String, start: String)]) -> [UInt8] {
        Array(files.map { "File: \($0.name)\nStarting From: \($0.start)\nSize (Bytes): 1048576\n" }.joined().utf8)
    }

    /// Two chunks carrying three log records on two channels, aligned so each chunk ends on a frame.
    static func chunks() -> [[UInt8]] {
        let s = SyntheticQdss.self
        var a = s.channelUnit(lane: 0, channel: 0x0101)
        a += s.fragment(lane: 0, kind: 1, payload: s.logPacket(code: 0xB0C0, ts: s.ts(1_000), body: Array(0..<40))).flatMap { $0 }
        a += s.channelUnit(lane: 1, channel: 0x0202)
        a += s.fragment(lane: 1, kind: 1, payload: s.logPacket(code: 0xB0C1, ts: s.ts(2_000), body: (0..<300).map { UInt8($0 & 0xFF) })).flatMap { $0 }
        var b = s.fragment(lane: 0, kind: 1, payload: s.logPacket(code: 0xB821, ts: s.ts(3_000), body: [7, 7, 7])).flatMap { $0 }
        b += s.fragment(lane: 1, kind: 1, payload: s.securePacket(code: 0xB8DD, ts: s.ts(3_500), body: [1, 2])).flatMap { $0 }
        return [s.frames(Aligned.stream(a, firstFrame: true)), s.frames(Aligned.stream(b, firstFrame: false), switchID: false)]
    }

    static func entry(_ rel: String, _ bytes: [UInt8]) -> SyntheticArchive.Entry {
        SyntheticArchive.Entry(path: "\(root)/\(rel)", bytes: bytes)
    }

    /// Everything a sysdiagnose has that we skip, so the importer has to pick its files out.
    static var noise: [SyntheticArchive.Entry] {
        [entry("README.txt", Array("sysdiagnose\n".utf8)), entry("logs/Accessibility/a.log", [1, 2, 3]),
         entry("ps.txt", [UInt8](repeating: 0x41, count: 3_000))]
    }

    static func trace(dir: String = traceDir, kept: [String] = ["0x00000001.bin", "0x00000002.bin"]) -> [SyntheticArchive.Entry] {
        let c = chunks()
        return [
            entry("logs/Baseband/\(dir)/header.qmdl2", [UInt8](repeating: 0x11, count: 77)),
            entry("logs/Baseband/\(dir)/info.txt", infoTxt([("0x00000000.bin", "2026-09-21-15-41-45"),
                                                             ("0x00000001.bin", "2026-09-21-15-42-06"),
                                                             ("0x00000002.bin", "2026-09-21-15-42-30")])),
            entry("logs/Baseband/\(dir)/trace.info", Array("start 15:41:44\n".utf8)),
            entry("logs/Baseband/\(dir)/\(kept[1])", c[1]),                       // out of name order on purpose
            entry("logs/Baseband/\(dir)/\(kept[0])", c[0]),
        ]
    }

    static var validProfile: [UInt8] {
        stub(install: date("2026-09-21T19:40:06Z"), removal: date("2026-09-28T19:40:02Z"))
    }

    /// Writes the archive under its sysdiagnose name in a fresh folder.
    static func write(_ entries: [SyntheticArchive.Entry], appleDouble: Bool = true, name: String = root + ".tar.gz",
                      cut: Int? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-wp3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var gz = SyntheticArchive.gzip(SyntheticArchive.tar(entries, appleDouble: appleDouble))
        if let cut { gz = Array(gz.prefix(cut)) }
        let url = dir.appendingPathComponent(name)
        try Data(gz).write(to: url)
        return url
    }

    /// A store and scratch folder in a fresh temporary directory.
    static func importer(spare: Int64 = 0) throws -> (SysdiagnoseImporter, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-wp3-\(UUID().uuidString)")
        let store = try CaptureStore(root: dir.appendingPathComponent("Captures"))
        return (SysdiagnoseImporter(store: store, scratch: dir.appendingPathComponent("Scratch"), spareBytes: spare), dir)
    }

    static func run(_ archive: URL, spare: Int64 = 0) async throws -> (ImportedCapture, SysdiagnoseImporter) {
        let (importer, _) = try importer(spare: spare)
        let imported = try await importer.importArchive(at: archive, securityScoped: false) { _ in }
        return (imported, importer)
    }

    static func failure(_ archive: URL, spare: Int64 = 0) async -> [ImportProblem]? {
        do {
            _ = try await run(archive, spare: spare)
            return nil
        } catch let f as ImportFailure {
            return f.problems
        } catch {
            return [.unsupportedTrace("\(error)")]
        }
    }
}

/// Pads a unit stream with fill units so the formatter frames end exactly on it (14 bytes in the frame that sets
/// the ID, 15 in every other), keeping the next chunk's units aligned.
enum Aligned {
    static func stream(_ s: [UInt8], firstFrame: Bool) -> [UInt8] {
        var out = s
        func fits() -> Bool { firstFrame ? (out.count >= 14 && (out.count - 14) % 15 == 0) : out.count % 15 == 0 }
        while !fits() { out += SyntheticQdss.fillUnit() }
        return out
    }
}

@Suite struct ImporterTests {
    @Test func validArchiveImportsAndIsActive() async throws {
        let archive = try Archives.write(Archives.noise + Archives.trace() + [
            Archives.entry("logs/Baseband/ambtool_output.log", Archives.ambtool(enabled: true)),
            Archives.entry("logs/MCState/Shared/profile-aa.stub", Archives.validProfile),
            Archives.entry("logs/MCState/Shared/profile-bb.stub", Archives.stub(identifier: "com.example.carrier",
                                                                                   install: nil, removal: nil)),
        ])
        let (imported, importer) = try await Archives.run(archive)
        let s = imported.summary
        #expect(s.problems.isEmpty)
        #expect(s.chunkCount == 2 && s.traceDirName == Archives.traceDir)
        #expect(s.triggerUtc == Archives.trigger)
        #expect(imported.records.map(\.code) == [0xB0C0, 0xB0C1, 0xB821])
        #expect(s.secure.records == 1 && s.secure.byCode == ["0xB8DD": 1])
        #expect(s.deframe?.chunks == 2 && s.deframe?.logRecords == 3)
        #expect(s.basebandLoggingEnabled == true)
        #expect(s.profile?.identifier == Archives.baseband && s.profile?.consentDays == 7)
        // R2: kept files start 19 s after the press; the dump in the directory name is 46.844 s after it.
        #expect(s.listedFiles == 3 && s.overwrittenFiles == 1)
        #expect(s.traceWindowAfterPressMs?.startMs == 19_000)
        #expect(abs((s.traceWindowAfterPressMs?.endMs ?? 0) - 46_844) < 0.5)
        #expect(GuideState.from(latest: s, now: Archives.trigger.addingTimeInterval(86_400))
            == .active(Archives.date("2026-09-28T19:40:02Z")))
        // Stored: the summary lists, the records read back, and the scratch folder is gone.
        #expect(try importer.store.list().map(\.id) == [s.id])
        #expect(try importer.store.records(for: s.id) == imported.records)
        #expect(try FileManager.default.contentsOfDirectory(atPath: importer.scratch.path).isEmpty)
        // The archive outside the Inbox is never touched.
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    /// R1 (b): no Baseband stub (another profile's stub only), ambtool "Baseband logs are not enabled", no trace.
    @Test func loggingOffArchive() async throws {
        let archive = try Archives.write(Archives.noise + [
            Archives.entry("logs/Baseband/ambtool_output.log", Archives.ambtool(enabled: false)),
            Archives.entry("logs/MCState/Shared/profile-bb.stub", Archives.stub(identifier: "com.example.carrier",
                                                                                   install: nil, removal: nil)),
        ])
        let (imported, importer) = try await Archives.run(archive)
        let s = imported.summary
        #expect(s.problems == [.noBasebandTrace, .loggingNotEnabled, .profileMissing])
        #expect(!s.hasTrace && imported.records.isEmpty && s.profile == nil)
        #expect(s.basebandLoggingEnabled == false)
        let state = GuideState.from(latest: s, now: Archives.trigger)
        #expect(state == .off)
        #expect(state.needsAttention)
        #expect(state.headline(now: Archives.trigger, date: { _ in "" }) == "Modem logging is off")
        // A trace-less import is kept as a summary so the guide can explain it.
        #expect(try importer.store.list().count == 1)
        #expect(try importer.store.records(for: s.id).isEmpty)
    }

    /// R1 (c): the profile's RemovalDate had passed when the archive was taken.
    @Test func expiredProfileArchive() async throws {
        let removal = Archives.date("2026-09-20T12:00:00Z")
        let archive = try Archives.write(Archives.noise + [
            Archives.entry("logs/Baseband/ambtool_output.log", Archives.ambtool(enabled: false)),
            Archives.entry("logs/MCState/Shared/profile-aa.stub",
                           Archives.stub(install: removal.addingTimeInterval(-7 * 86_400), removal: removal)),
        ])
        let s = try await Archives.run(archive).0.summary
        #expect(s.problems.contains(.profileExpired(removal)))
        #expect(s.problems.contains(.noBasebandTrace))
        #expect(s.profile?.status == .expired)
        #expect(GuideState.from(latest: s, now: Archives.trigger) == .expired(removal))
    }

    /// R1: the stub is there and active, but the archive has no modem trace: restart and try again.
    @Test func stubWithoutTraceArchive() async throws {
        let archive = try Archives.write(Archives.noise + [
            Archives.entry("logs/Baseband/ambtool_output.log", Archives.ambtool(enabled: false)),
            Archives.entry("logs/MCState/Shared/profile-aa.stub", Archives.validProfile),
        ])
        let s = try await Archives.run(archive).0.summary
        #expect(s.problems.contains(.noBasebandTrace))
        #expect(s.problems.contains(.profileInstalledNoTrace))
        #expect(!s.problems.contains(.profileMissing))
        let state = GuideState.from(latest: s, now: Archives.trigger)
        #expect(state == .installedNoTrace)
        #expect(state.headline(now: Archives.trigger, date: { _ in "" })
            == "Profile installed but no modem trace — restart your iPhone and try again")
    }

    /// R1 (d): active when taken, but iOS removes the profile within a day.
    @Test func expiringSoonArchive() async throws {
        let removal = Archives.trigger.addingTimeInterval(10 * 3_600)
        let archive = try Archives.write(Archives.trace() + [
            Archives.entry("logs/Baseband/ambtool_output.log", Archives.ambtool(enabled: true)),
            Archives.entry("logs/MCState/Shared/profile-aa.stub",
                           Archives.stub(install: removal.addingTimeInterval(-7 * 86_400), removal: removal)),
        ])
        let s = try await Archives.run(archive).0.summary
        #expect(s.problems == [.profileExpiresSoon(removal)])
        #expect(s.hasTrace)
        #expect(GuideState.from(latest: s, now: Archives.trigger) == .expiringSoon(removal))
    }

    /// The critique's rule: installed after the first info.txt 'Starting From', so the trace predates it.
    @Test func profileInstalledAfterTraceStart() async throws {
        let archive = try Archives.write(Archives.trace() + [
            Archives.entry("logs/MCState/Shared/profile-aa.stub",
                           Archives.stub(install: Archives.date("2026-09-21T19:41:50Z"),
                                         removal: Archives.date("2026-09-28T19:41:50Z"))),
        ])
        let s = try await Archives.run(archive).0.summary
        #expect(s.problems == [.profileInstalledAfterTrace])
    }

    @Test func syntheticProblems() async throws {
        // No trace directory at all.
        let noTrace = try Archives.write(Archives.noise + [
            Archives.entry("logs/MCState/Shared/profile-aa.stub", Archives.validProfile)])
        #expect(try await Archives.run(noTrace).0.summary.problems.contains(.noBasebandTrace))
        // No Baseband stub, with a trace.
        let noStub = try Archives.write(Archives.trace())
        #expect(try await Archives.run(noStub).0.summary.problems == [.profileMissing])
        // Expired before the trigger.
        let removal = Archives.date("2026-09-21T10:00:00Z")
        let expired = try Archives.write(Archives.trace() + [
            Archives.entry("logs/MCState/Shared/profile-aa.stub",
                           Archives.stub(install: removal.addingTimeInterval(-7 * 86_400), removal: removal))])
        #expect(try await Archives.run(expired).0.summary.problems == [.profileExpired(removal)])
        // A copy cut short part way through the gzip stream.
        let whole = try Archives.write(Archives.noise + Archives.trace())
        let size = try Data(contentsOf: whole).count
        let truncated = try Archives.write(Archives.noise + Archives.trace(), cut: size / 2)
        #expect(await Archives.failure(truncated) == [.truncatedArchive])
        // A gzip'd tar without a logs/ tree, and a file that is not gzip at all.
        let other = try Archives.write([SyntheticArchive.Entry(path: "photos/a.jpg", bytes: [1, 2, 3])], name: "photos.tar.gz")
        #expect(await Archives.failure(other) == [.notASysdiagnose])
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("ft-wp3-\(UUID().uuidString).tar.gz")
        try Data("hello, not a sysdiagnose".utf8).write(to: text)
        #expect(await Archives.failure(text) == [.notASysdiagnose])
    }

    @Test func lowDiskSpaceStopsBeforeUnpacking() async throws {
        let archive = try Archives.write(Archives.trace())
        let problems = await Archives.failure(archive, spare: Int64.max / 4)
        guard case .lowDiskSpace(let need)? = problems?.first else {
            Issue.record("expected lowDiskSpace, got \(String(describing: problems))")
            return
        }
        #expect(need > Int64.max / 4)
    }

    /// Several trace directories: the newest by name is used and the others are noted.
    @Test func newestTraceDirectoryWins() async throws {
        let older = "log-bb-2026-09-21-15-30-00-100-qdss"
        let archive = try Archives.write(Archives.trace(dir: older) + Archives.trace() + [
            Archives.entry("logs/MCState/Shared/profile-aa.stub", Archives.validProfile)])
        let s = try await Archives.run(archive).0.summary
        #expect(s.traceDirName == Archives.traceDir)
        #expect(s.otherTraceDirs == [older])
        #expect(s.chunkCount == 2)
    }

    /// A renamed file still gives the trigger time, from the folder inside the archive.
    @Test func renamedArchiveUsesItsRootFolder() async throws {
        let archive = try Archives.write(Archives.trace() + [
            Archives.entry("logs/MCState/Shared/profile-aa.stub", Archives.validProfile)], name: "capture.tar.gz")
        let s = try await Archives.run(archive).0.summary
        #expect(s.triggerUtc == Archives.trigger)
        #expect(s.sourceName == Archives.root + ".tar.gz")
    }

    /// A profile iOS already removed leaves no stub, but MCProfileEvents records the removal.
    @Test func removedProfileFromProfileEvents() throws {
        let removedAt = Archives.date("2026-09-19T08:00:00Z")
        let events: [String: Any] = ["ProfileEvents": [
            ["com.apple.basebandlogging-AAAA": ["Operation": "install", "Process": "p", "Timestamp": removedAt.addingTimeInterval(-7 * 86_400)]],
            ["com.apple.basebandlogging-AAAA": ["Operation": "remove", "Process": "p", "Timestamp": removedAt]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: events, format: .xml, options: 0)
        let p = try #require(SysdiagnoseImporter.readProfile(stubs: [], events: data, observedAt: Archives.trigger))
        #expect(p.status == .expired && p.removalDate == removedAt)
        let evidence = ImportEvidence(chunkCount: 0, profile: p, basebandLoggingEnabled: false, triggerUtc: Archives.trigger,
                                      traceStart: nil)
        #expect(evidence.problems == [.noBasebandTrace, .loggingNotEnabled, .profileExpired(removedAt)])
    }

    @Test func cancellationCleansUp() async throws {
        let archive = try Archives.write(Archives.noise + Archives.trace())
        let (importer, _) = try Archives.importer()
        let task = Task {
            try await importer.importArchive(at: archive, securityScoped: false) { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            // Small archives can finish before the cancel lands; then it must have stored normally.
            #expect(try importer.store.list().count == 1)
        } catch {
            #expect(error is CancellationError)
            #expect(try importer.store.list().isEmpty)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: importer.scratch.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func progressReportsEachStage() async throws {
        let archive = try Archives.write(Archives.trace() + [
            Archives.entry("logs/MCState/Shared/profile-aa.stub", Archives.validProfile)])
        let (importer, _) = try Archives.importer()
        let seen = StageLog()
        _ = try await importer.importArchive(at: archive, securityScoped: false) { seen.add($0.stage) }
        #expect(seen.stages == [.reading, .extracting, .deframing, .saving, .done])
    }
}

/// Collects the stages a progress callback saw, in order, once each.
final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ImportStage] = []

    func add(_ s: ImportStage) {
        lock.lock()
        defer { lock.unlock() }
        if list.last != s { list.append(s) }
    }

    var stages: [ImportStage] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}
