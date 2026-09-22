import Foundation

/// Cleans up after an import that was killed part way (the app suspended and terminated, a crash): its scratch
/// folder holds 130 MB of modem trace, and a share-sheet copy in Documents/Inbox is the whole sysdiagnose with
/// messages, location and identifiers. Run once at launch.
public enum ImportLeftovers {
    /// Documents/Inbox, where "Share > FieldTap" and "Open in" put their copies.
    public static var inboxURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Removes scratch folders named import-* and Inbox files, except `keep` (an import about to start) and
    /// anything modified in the last `grace` seconds (an import that has just begun, or a file iOS is still
    /// handing over). Returns how many items were removed.
    @discardableResult
    public static func sweep(scratch: URL, inbox: URL = inboxURL, keep: URL? = nil, grace: TimeInterval = 120,
                             now: Date = Date()) -> Int {
        let fm = FileManager.default
        let keepPath = keep?.resolvingSymlinksInPath().standardizedFileURL.path
        var removed = 0
        func sweep(_ dir: URL, _ match: (String) -> Bool) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names where match(name) {
                let url = dir.appendingPathComponent(name)
                if url.resolvingSymlinksInPath().standardizedFileURL.path == keepPath { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                guard now.timeIntervalSince(modified) >= grace else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        sweep(scratch) { $0.hasPrefix("import-") }
        sweep(inbox) { _ in true }
        return removed
    }
}
