import Foundation
import FTCore
import FTModel

/// Turns a sysdiagnose into a stored capture: scan, deframe, save, clean up.
///
/// 1. Checks there is room for the archive plus `spareBytes`, else `lowDiskSpace`.
/// 2. Streams the archive once (SysdiagScanner, bounded memory) and keeps only the modem trace: the chunks of
///    every logs/Baseband/log-bb-*-qdss directory go to a scratch folder, its info.txt / trace.info /
///    header.qmdl2, ambtool_output.log, the profile stubs and MCProfileEvents.plist stay in memory.
/// 3. Deframes the newest trace directory's chunks in name order and saves capture.qmdl and summary.json
///    through the store. An archive without a trace is saved as a summary only, so the guide can explain it.
/// 4. Deletes the scratch folder and, on the phone, the Inbox copy the share sheet made, whatever happens.
///
/// Cancelling the calling task stops the import between pieces and cleans up the same way.
public struct SysdiagnoseImporter: CaptureImporting {
    public let store: CaptureStore
    public let scratch: URL
    /// Free space an import needs beyond the archive's size: the trace chunks (about 130 MB) and the capture.
    public let spareBytes: Int64

    public static let defaultSpareBytes: Int64 = 200_000_000

    public init(store: CaptureStore, scratch: URL) {
        self.init(store: store, scratch: scratch, spareBytes: Self.defaultSpareBytes)
    }

    public init(store: CaptureStore, scratch: URL, spareBytes: Int64) {
        self.store = store
        self.scratch = scratch
        self.spareBytes = spareBytes
    }

    public func importArchive(at url: URL, securityScoped: Bool,
                              progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> ImportedCapture {
        let store = self.store, scratch = self.scratch, spare = spareBytes
        let job = Task.detached(priority: .userInitiated) {
            try Self.run(url: url, securityScoped: securityScoped, store: store, scratch: scratch, spareBytes: spare,
                         progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    static func run(url: URL, securityScoped: Bool, store: CaptureStore, scratch: URL, spareBytes: Int64,
                    progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportedCapture {
        let started = Date()
        var timings: [String: Double] = [:]
        let accessing = securityScoped && url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            deleteInboxCopy(url)
        }
        let archiveBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        progress(ImportProgress(stage: .reading, fraction: 0,
                                detail: ByteCountFormatter.string(fromByteCount: archiveBytes, countStyle: .file)))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let need = archiveBytes + spareBytes
        if let free = freeBytes(at: scratch), free < need { throw ImportFailure([.lowDiskSpace(needBytes: need)]) }

        let work = scratch.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Stage 1-2: one pass over the archive.
        let contents = ArchiveContents(work: work, progress: progress)
        progress(ImportProgress(stage: .extracting, fraction: -1, detail: "Looking for the modem trace"))
        do {
            _ = try SysdiagScanner.scan(url, select: { contents.wants($0) }, sink: { try contents.take($0, $1, $2, $3) })
        } catch let e as SysdiagScanError {
            throw ImportFailure.of(e)
        }
        try Task.checkCancellation()
        timings["extract"] = Date().timeIntervalSince(started)
        guard contents.sawLogsTree else { throw ImportFailure([.notASysdiagnose]) }

        // What the archive says.
        let name = archiveName(url: url, rootName: contents.rootName)
        let trigger = BasebandArchive.triggerDate(archiveName: name)
        let dirs = contents.chunks.keys.sorted()
        let newest = dirs.last ?? contents.metadata.keys.sorted().last
        let chunks = newest.flatMap { contents.chunks[$0] } ?? []
        let info = newest.flatMap { contents.metadata[$0]?["info.txt"] }.map { String(decoding: $0, as: UTF8.self) }
        let kept = Set(chunks.map(\.lastPathComponent))
        let timing = info.flatMap {
            BasebandArchive.traceTiming(infoTxt: $0, archiveName: name, traceDirName: newest, keptChunks: kept)
        }
        let traceStart = info.flatMap { BasebandArchive.traceListing(infoTxt: $0, archiveName: name).first?.start }
        let profile = readProfile(stubs: contents.stubs, events: contents.events, observedAt: trigger)
        let loggingEnabled = ImportEvidence.loggingEnabled(ambtoolLog: contents.ambtool.map {
            String(decoding: $0, as: UTF8.self)
        })
        let evidence = ImportEvidence(chunkCount: chunks.count, profile: profile, basebandLoggingEnabled: loggingEnabled,
                                      triggerUtc: trigger, traceStart: traceStart)

        var summary = CaptureSummary(importedAt: Date(), sourceName: name, triggerUtc: trigger, traceDirName: newest,
                                     chunkCount: chunks.count, chunkBytes: newest.flatMap { contents.chunkBytes[$0] } ?? 0,
                                     profile: profile, problems: evidence.problems,
                                     traceWindowAfterPressMs: timing?.windowAfterPressMs,
                                     overwrittenFiles: timing?.overwrittenFiles, listedFiles: timing?.listedFiles,
                                     basebandLoggingEnabled: loggingEnabled,
                                     otherTraceDirs: dirs.count > 1 ? Array(dirs.dropLast()) : nil)

        // Stage 3: the DIAG log.
        var records: [LogRecord] = []
        if !chunks.isEmpty {
            let t0 = Date()
            progress(ImportProgress(stage: .deframing, fraction: 0, detail: "\(chunks.count) trace files"))
            let out = try Qdss.deframe(chunkFiles: chunks) { done, total in
                progress(ImportProgress(stage: .deframing, fraction: Double(done) / Double(max(1, total)),
                                        detail: "\(done) of \(total) trace files"))
            }
            records = out.records
            summary.deframe = out.stats
            summary.secure = out.census
            if records.isEmpty { summary.problems.append(.unsupportedTrace("The trace held no readable modem log.")) }
            timings["deframe"] = Date().timeIntervalSince(t0)
        }

        // Stage 5: the store.
        try Task.checkCancellation()
        let t1 = Date()
        progress(ImportProgress(stage: .saving, fraction: 0, detail: ""))
        timings["total"] = Date().timeIntervalSince(started)
        summary.timings = timings
        let qmdl = try store.save(records: records, summary: summary)
        summary.timings["save"] = Date().timeIntervalSince(t1)
        try? store.update(summary)
        progress(ImportProgress(stage: .done, fraction: 1, detail: ""))
        return ImportedCapture(summary: summary, records: records, qmdlURL: qmdl)
    }

    /// The archive's name as Apple wrote it: the file's own name, or the folder inside when the file was renamed.
    static func archiveName(url: URL, rootName: String?) -> String {
        let file = url.lastPathComponent
        if BasebandArchive.triggerDate(archiveName: file) != nil { return file }
        if let root = rootName, BasebandArchive.triggerDate(archiveName: root) != nil { return root + ".tar.gz" }
        return file
    }

    /// The Baseband profile from its stub, or, when iOS already removed it, from its last MCProfileEvents entry.
    static func readProfile(stubs: [(path: String, data: Data)], events: Data?, observedAt: Date?) -> ProfileState? {
        for stub in stubs.sorted(by: { $0.path < $1.path }) {
            if let p = ProfileStubReader.read(stub.data, observedAt: observedAt) { return p }
        }
        if let events, let last = ProfileStubReader.lastBasebandEvent(events), last.removed {
            return ProfileState(identifier: ProfileStubReader.basebandIdentifier, displayName: nil, installDate: nil,
                                removalDate: last.at, lifetimeDays: nil, consentDays: nil, status: .expired,
                                observedAt: observedAt)
        }
        return nil
    }

    /// Free space for important use (what iOS will free up for a user-started import).
    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                       .volumeAvailableCapacityKey])
        if let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// "Share > FieldTap" and "Open in" hand the app a copy in Documents/Inbox. It holds the whole 400 MB
    /// sysdiagnose (messages, location, identifiers), so it goes as soon as the import ends. Nothing outside the
    /// Inbox is ever deleted.
    static func deleteInboxCopy(_ url: URL) {
        #if os(iOS)
        guard isInboxCopy(url) else { return }
        try? FileManager.default.removeItem(at: url)
        #endif
    }

    static func isInboxCopy(_ url: URL) -> Bool {
        let inbox = ImportLeftovers.inboxURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(inbox)
    }
}

/// What one scan keeps. Used on the importer's own thread only.
final class ArchiveContents {
    let work: URL
    let progress: @Sendable (ImportProgress) -> Void
    private(set) var sawLogsTree = false
    private(set) var rootName: String?
    /// Trace directory -> its chunk files in scratch.
    private(set) var chunks: [String: [URL]] = [:]
    private(set) var chunkBytes: [String: Int] = [:]
    /// Trace directory -> leaf -> bytes (info.txt, trace.info, header.qmdl2).
    private(set) var metadata: [String: [String: Data]] = [:]
    private(set) var ambtool: Data?
    private(set) var stubs: [(path: String, data: Data)] = []
    private(set) var events: Data?

    private var handle: FileHandle?
    private var current: String?
    private var small = Data()
    private var chunkTotal = 0
    /// Small files larger than this are not what we expect; their bytes are dropped.
    static let smallLimit = 8 << 20

    init(work: URL, progress: @escaping @Sendable (ImportProgress) -> Void) {
        self.work = work
        self.progress = progress
    }

    func wants(_ path: String) -> Bool {
        if rootName == nil { rootName = path.split(separator: "/").first.map(String.init) }
        guard BasebandArchive.isInLogsTree(path) else { return false }
        sawLogsTree = true
        return BasebandArchive.isQdssFile(path) || BasebandArchive.isTraceMetadata(path)
            || BasebandArchive.isAmbtoolLog(path) || BasebandArchive.isProfileStub(path)
            || BasebandArchive.isProfileEvents(path)
    }

    func take(_ path: String, _ size: Int, _ bytes: UnsafeRawBufferPointer, _ isLast: Bool) throws {
        if Task.isCancelled { throw CancellationError() }
        if BasebandArchive.isQdssFile(path), let dir = BasebandArchive.traceDirName(path) {
            if current != path {
                try? handle?.close()
                let folder = work.appendingPathComponent(dir, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent(BasebandArchive.leaf(path))
                FileManager.default.createFile(atPath: file.path, contents: nil)
                handle = try FileHandle(forWritingTo: file)
                current = path
            }
            if !bytes.isEmpty { try handle?.write(contentsOf: bytes) }
            if isLast {
                try handle?.close()
                handle = nil
                current = nil
                let file = work.appendingPathComponent(dir, isDirectory: true).appendingPathComponent(BasebandArchive.leaf(path))
                chunks[dir, default: []].append(file)
                chunkBytes[dir, default: 0] += size
                chunkTotal += 1
                progress(ImportProgress(stage: .extracting, fraction: -1, detail: "Found \(chunkTotal) trace files"))
            }
            return
        }
        if small.count + bytes.count <= Self.smallLimit { small.append(contentsOf: bytes) }
        guard isLast else { return }
        let data = small
        small = Data()
        if BasebandArchive.isTraceMetadata(path), let dir = BasebandArchive.traceDirName(path) {
            metadata[dir, default: [:]][BasebandArchive.leaf(path)] = data
        } else if BasebandArchive.isAmbtoolLog(path) {
            ambtool = data
        } else if BasebandArchive.isProfileStub(path) {
            stubs.append((path, data))
        } else if BasebandArchive.isProfileEvents(path) {
            events = data
        }
    }

    deinit { try? handle?.close() }
}
