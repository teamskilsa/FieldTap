import Foundation
import FTModel

/// Paths and names inside a sysdiagnose archive. Only file names and times are read from the trace metadata
/// (R2); the GUID, DiagID and hardware model in info.txt are never parsed or kept.
public enum BasebandArchive {
    /// The leaf of an archive path.
    static func leaf(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    /// A QDSS trace chunk: .../logs/Baseband/log-bb-*-qdss/0x....bin, never an AppleDouble "._" file.
    public static func isQdssFile(_ path: String) -> Bool {
        let leaf = leaf(path)
        return path.contains("/logs/Baseband/log-bb-") && path.contains("-qdss/") && leaf.hasPrefix("0x")
            && leaf.hasSuffix(".bin")
    }

    /// The trace directory's small files the importer keeps: header.qmdl2, info.txt and trace.info.
    static func isTraceMetadata(_ path: String) -> Bool {
        guard path.contains("/logs/Baseband/log-bb-"), traceDirName(path) != nil else { return false }
        return ["header.qmdl2", "info.txt", "trace.info"].contains(leaf(path))
    }

    /// logs/Baseband/ambtool_output.log: "Baseband logs are not enabled" when the profile was not on.
    static func isAmbtoolLog(_ path: String) -> Bool {
        path.hasSuffix("/logs/Baseband/ambtool_output.log") || path == "logs/Baseband/ambtool_output.log"
    }

    /// A configuration-profile stub: .../logs/MCState/Shared/profile-*.stub.
    public static func isProfileStub(_ path: String) -> Bool {
        let leaf = leaf(path)
        return path.contains("/logs/MCState/Shared/") && leaf.hasPrefix("profile-") && leaf.hasSuffix(".stub")
    }

    /// logs/MCState/Shared/MCProfileEvents.plist: install and remove events per profile.
    static func isProfileEvents(_ path: String) -> Bool {
        path.hasSuffix("/logs/MCState/Shared/MCProfileEvents.plist")
    }

    /// True for any path inside a sysdiagnose's logs/ tree.
    static func isInLogsTree(_ path: String) -> Bool { path.hasPrefix("logs/") || path.contains("/logs/") }

    /// "log-bb-2026-09-21-15-42-33-844-qdss" for any path inside that directory.
    public static func traceDirName(_ path: String) -> String? {
        path.split(separator: "/").map(String.init).first { $0.hasPrefix("log-bb-") && $0.hasSuffix("-qdss") }
    }

    /// When the user pressed the buttons, from the archive's name:
    /// sysdiagnose_YYYY.MM.DD_HH-MM-SS-ZZZZ_... (the zone is the phone's offset, e.g. -0400).
    public static func triggerDate(archiveName: String) -> Date? {
        guard let m = archiveName.firstMatch(of: /sysdiagnose_(\d{4})\.(\d{2})\.(\d{2})_(\d{2})-(\d{2})-(\d{2})[+-]\d{4}/),
              let offset = zoneOffsetSeconds(archiveName: archiveName),
              let local = date("\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)Z") else { return nil }
        return local.addingTimeInterval(TimeInterval(-offset))
    }

    /// The phone's UTC offset in the archive name, in seconds (info.txt times are local and carry no zone).
    public static func zoneOffsetSeconds(archiveName: String) -> Int? {
        guard let m = archiveName.firstMatch(of: /sysdiagnose_\d{4}\.\d{2}\.\d{2}_\d{2}-\d{2}-\d{2}([+-])(\d{2})(\d{2})/),
              let h = Int(m.2), let mi = Int(m.3) else { return nil }
        return (m.1 == "-" ? -1 : 1) * (h * 3_600 + mi * 60)
    }

    /// When the modem wrote the trace directory (the dump time in its name), in the archive's zone.
    public static func traceDirDate(_ traceDirName: String, archiveName: String) -> Date? {
        guard let offset = zoneOffsetSeconds(archiveName: archiveName),
              let m = traceDirName.firstMatch(of: /log-bb-(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{3})-qdss/),
              let d = date("\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)Z"), let ms = Double(m.7) else { return nil }
        return d.addingTimeInterval(TimeInterval(-offset) + ms / 1_000)
    }

    /// Every trace file info.txt lists ("File: 0x00000000.bin" then "Starting From: 2026-09-21-15-41-45"), in
    /// order, with its start as a date in the archive's zone.
    public static func traceListing(infoTxt: String, archiveName: String) -> [(name: String, start: Date)] {
        guard let offset = zoneOffsetSeconds(archiveName: archiveName) else { return [] }
        var out: [(name: String, start: Date)] = []
        var pending: String?
        for line in infoTxt.split(whereSeparator: \.isNewline) {
            if let m = line.firstMatch(of: /^File:\s*(\S+)/) {
                pending = String(m.1)
            } else if let name = pending,
                      let m = line.firstMatch(of: /^Starting From:\s*(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})/),
                      let d = date("\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)Z") {
                out.append((name, d.addingTimeInterval(TimeInterval(-offset))))
                pending = nil
            }
        }
        return out
    }

    /// The kept trace relative to the button press, and how many listed files the ring overwrote (R2).
    /// The window runs from the first kept file's start to the dump time in the trace directory's name
    /// (log-bb-YYYY-MM-DD-HH-MM-SS-mmm-qdss), or to the last kept file's start when there is no name.
    public static func traceTiming(infoTxt: String, archiveName: String, traceDirName: String?,
                                   keptChunks: Set<String>) -> TraceTiming? {
        let listing = traceListing(infoTxt: infoTxt, archiveName: archiveName)
        guard !listing.isEmpty else { return nil }
        let kept = listing.filter { keptChunks.contains($0.name) }
        var window: TraceWindow?
        if let trigger = triggerDate(archiveName: archiveName), let first = kept.first, let last = kept.last {
            var end = last.start
            if let dir = traceDirName, let dumped = traceDirDate(dir, archiveName: archiveName) { end = max(end, dumped) }
            window = TraceWindow(startMs: first.start.timeIntervalSince(trigger) * 1_000,
                                 endMs: end.timeIntervalSince(trigger) * 1_000)
        }
        return TraceTiming(listedFiles: listing.count, keptFiles: kept.count, windowAfterPressMs: window)
    }

    private static func date(_ iso: String) -> Date? {
        try? Date(iso, strategy: .iso8601)
    }
}
