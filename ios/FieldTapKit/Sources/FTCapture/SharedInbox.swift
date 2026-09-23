import Foundation

/// The App Group container the FieldTapShare extension drops sysdiagnose archives into, and the streaming copy
/// that gets one there without ever loading it into memory.
///
/// A sysdiagnose is ~400 MB and a Share Extension is capped near 120 MB, so `streamCopy` moves the file a chunk
/// at a time and holds only one chunk at once. The app then claims the file into its own container and runs the
/// normal import (`SharedInboxIngest`); the extension itself does no decoding.
public enum SharedInbox {
    /// The App Group both the app and the extension belong to. Enable App Groups on the com.fieldtap.app App ID
    /// and create this group in the developer portal before a device build will sign; the simulator does not
    /// require it, so it is verified there.
    public static let appGroupIdentifier = "group.com.fieldtap.app"
    public static let inboxFolderName = "Inbox"

    /// The shared container, or nil when the App Group is not provisioned (or off-device in tests).
    public static func containerURL(groupIdentifier: String = appGroupIdentifier) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    /// The shared Inbox folder, created if missing; nil when the App Group is not provisioned.
    public static func inboxURL(groupIdentifier: String = appGroupIdentifier) -> URL? {
        guard let container = containerURL(groupIdentifier: groupIdentifier) else { return nil }
        let inbox = container.appendingPathComponent(inboxFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Streams `source` into `directory/name` a chunk at a time, coordinated for the other process, with
    /// complete file protection and excluded from backup. Memory stays flat: at most `chunkSize` bytes are held
    /// at once, so the ~400 MB file never has to fit in the extension's ~120 MB budget. Returns the written URL.
    @discardableResult
    public static func streamCopy(from source: URL, name: String, into directory: URL,
                                  chunkSize: Int = 1 << 20, coordinate: Bool = true) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)

        func copy() throws {
            try? fm.removeItem(at: destination)
            guard let input = InputStream(url: source) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            #if os(iOS)
            fm.createFile(atPath: destination.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
            #else
            fm.createFile(atPath: destination.path, contents: nil, attributes: nil)
            #endif
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            input.open()
            defer { input.close() }
            let size = max(1, chunkSize)
            var buffer = [UInt8](repeating: 0, count: size)
            while true {
                let read = input.read(&buffer, maxLength: size)
                if read < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: source.path]) }
                if read == 0 { break }
                try output.write(contentsOf: Data(buffer[0..<read]))
            }
        }

        if coordinate {
            var coordError: NSError?
            var thrown: Error?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordError) { _ in
                do { try copy() } catch { thrown = error }
            }
            if let coordError { throw coordError }
            if let thrown { throw thrown }
        } else {
            try copy()
        }
        excludeFromBackup(destination)
        return destination
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}

/// Moving a sysdiagnose the extension left in the App Group Inbox into the app's own container, once. Kept out
/// of the view layer and free of App Group access so it can be unit-tested against temp folders.
public enum SharedInboxIngest {
    /// The archives waiting in `inbox` (a .tar.gz the extension wrote, never a partial `.importing` marker),
    /// newest first.
    public static func pending(in inbox: URL, fileManager fm: FileManager = .default) -> [URL] {
        guard let names = try? fm.contentsOfDirectory(atPath: inbox.path) else { return [] }
        return names
            .filter { ($0.hasSuffix(".tar.gz") || $0.hasSuffix(".gz")) && !$0.hasSuffix(".importing") }
            .map { inbox.appendingPathComponent($0) }
            .sorted { modified($0) > modified($1) }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Moves the newest pending sysdiagnose from the shared `inbox` into the app's own `documentsInbox`, where
    /// the normal import takes over (it deletes a Documents/Inbox copy when it finishes). Returns the moved
    /// file, or nil when there is nothing new.
    ///
    /// One capture is never imported twice: the file is claimed (renamed within the shared Inbox) and then moved
    /// out, so a later foreground finds nothing, and a name already waiting in `documentsInbox` (an import in
    /// flight) is left alone. Stale `.importing` markers and files older than `staleAfter` are swept, because
    /// each is ~400 MB.
    @discardableResult
    public static func claimNext(fromShared inbox: URL, into documentsInbox: URL,
                                 now: Date = Date(), staleAfter: TimeInterval = 24 * 60 * 60,
                                 fileManager fm: FileManager = .default) throws -> URL? {
        sweepStale(in: inbox, now: now, staleAfter: staleAfter, fileManager: fm)
        try fm.createDirectory(at: documentsInbox, withIntermediateDirectories: true)
        for source in pending(in: inbox, fileManager: fm) {
            let name = source.lastPathComponent
            let destination = documentsInbox.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { continue } // already handed to an import
            // Claim within the shared Inbox first, so a second foreground cannot also take it.
            let claim = source.appendingPathExtension("importing")
            do { try fm.moveItem(at: source, to: claim) } catch { continue }
            do {
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: claim, to: destination)
            } catch {
                try? fm.removeItem(at: claim)
                throw error
            }
            // Freshen the mtime so the app's 120 s Inbox sweep does not delete it before the import runs.
            try? fm.setAttributes([.modificationDate: now], ofItemAtPath: destination.path)
            return destination
        }
        return nil
    }

    /// Removes leftover `.importing` markers (an import that was interrupted after the claim) and anything older
    /// than `staleAfter`, so a forgotten ~400 MB archive does not sit in the App Group forever.
    static func sweepStale(in inbox: URL, now: Date, staleAfter: TimeInterval, fileManager fm: FileManager) {
        guard let names = try? fm.contentsOfDirectory(atPath: inbox.path) else { return }
        for name in names {
            let url = inbox.appendingPathComponent(name)
            if name.hasSuffix(".importing") || now.timeIntervalSince(modified(url)) >= staleAfter {
                try? fm.removeItem(at: url)
            }
        }
    }
}
