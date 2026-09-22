import Foundation
import FTCore
import FTModel

/// Captures on the phone: Application Support/Captures/<uuid>/{capture.qmdl, summary.json}.
///
/// Files are written with complete file protection (unreadable while the phone is locked) and the folders are
/// excluded from backups: a capture holds the subscriber's identifiers and stays on this iPhone. An import
/// without a modem trace keeps only its summary, so the Modem logging guide can say why.
public final class CaptureStore: CaptureStoring, @unchecked Sendable {
    public let rootURL: URL
    // The store holds no mutable state; every call goes to the file system, which serialises the writes.

    static let qmdlName = "capture.qmdl"
    static let summaryName = "summary.json"

    public init(root: URL) throws {
        rootURL = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func directory(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func qmdlURL(for id: UUID) -> URL { directory(id).appendingPathComponent(Self.qmdlName) }

    /// Every readable summary; a folder whose summary is missing or damaged is skipped, not fatal.
    public func list() throws -> [CaptureSummary] {
        let names = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
        return names.compactMap { name -> CaptureSummary? in
            guard UUID(uuidString: name) != nil else { return nil }
            let url = rootURL.appendingPathComponent(name).appendingPathComponent(Self.summaryName)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(CaptureSummary.self, from: data)
        }
        .sorted { $0.importedAt > $1.importedAt }
    }

    /// The capture's records, read back from its .qmdl; none for an import without a trace.
    public func records(for id: UUID) throws -> [LogRecord] {
        let url = qmdlURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: directory(id).path) { return [] }
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return DiagProtocol.readQmdl(try Data(contentsOf: url, options: .mappedIfSafe)).records
    }

    public func update(_ summary: CaptureSummary) throws {
        let dir = directory(summary.id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: dir.path])
        }
        try Self.write(Self.encoder.encode(summary), to: dir.appendingPathComponent(Self.summaryName))
    }

    public func delete(_ id: UUID) throws {
        let dir = directory(id)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    /// Writes the capture (records as capture.qmdl, when there are any) and its summary; returns the .qmdl URL.
    @discardableResult
    public func save(records: [LogRecord], summary: CaptureSummary) throws -> URL {
        let dir = directory(summary.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.excludeFromBackup(dir)
        let qmdl = dir.appendingPathComponent(Self.qmdlName)
        do {
            if !records.isEmpty {
                _ = try Qdss.writeQmdl(records, to: qmdl)
                Self.protect(qmdl)
            }
            try Self.write(Self.encoder.encode(summary), to: dir.appendingPathComponent(Self.summaryName))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return qmdl
    }

    /// Bytes on disk under the root (Settings, and the size a delete frees).
    public func sizeBytes() -> Int64 { Self.allocatedBytes(rootURL) }

    /// Bytes on disk for one capture.
    public func sizeBytes(of id: UUID) -> Int64 { Self.allocatedBytes(directory(id)) }

    static func allocatedBytes(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
