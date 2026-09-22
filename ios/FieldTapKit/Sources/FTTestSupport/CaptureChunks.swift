import Foundation
import Testing

/// The QDSS trace directories of the user's two iPhone captures, for the tests that need the real stream.
///
/// The `.tar.gz` archives are not always on this Mac (they are big, and the disk is small); what survives of a
/// capture is its extracted `logs/Baseband/log-bb-*-qdss` folder, which is all the deframer needs. These tests
/// read those chunk files in place and never copy them. Either capture can be pointed somewhere else with
/// FT_CAPTURE1_CHUNKS / FT_CAPTURE2_CHUNKS (a trace directory, or any folder holding one).
///
/// A test that needs one is written as
///
///     @Test(.chunks(CaptureChunks.second, "the 2026-09-22 capture")) func secondCapture() throws {
///         guard let dir = CaptureChunks.second else { return }
///
/// so it names what is missing instead of failing, the way the archive-level tests do.
public enum CaptureChunks {
    static func env(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        let value = e[name] ?? e["TEST_RUNNER_" + name]
        return value?.isEmpty == false ? value : nil
    }

    /// 2026-09-21 15:41:47, the settled-phone capture the goldens and `qdss-full-stats.json` come from.
    public static let firstName = "sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84"
    /// 2026-09-22 08:57:25, taken while moving; three chunk files are missing from it.
    public static let secondName = "sysdiagnose_2026.09.22_08-57-25-0400_iPhone-OS_iPhone_23F84"

    /// True in a test process on the simulator, where a 124 MB Debug deframe takes minutes and the macOS run
    /// (swift test) has already covered the same code.
    public static var onSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    public static var first: URL? { locate(env: "FT_CAPTURE1_CHUNKS", name: firstName) }
    public static var second: URL? { locate(env: "FT_CAPTURE2_CHUNKS", name: secondName) }

    /// The trace directory itself, when the environment names one, else the newest trace directory under any of
    /// the places a capture of that name is kept: the extracted sysdiagnose next to FT_SYSDIAGNOSE or in
    /// ~/Downloads, and the research scratch (FT_SCRATCH/iphone/bb).
    static func locate(env name: String, name capture: String) -> URL? {
        if let path = env(name) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return traceDir(in: url) ?? (isTraceDir(url) ? url : nil)
        }
        var roots: [URL] = []
        if let sysdiagnose = env("FT_SYSDIAGNOSE") {
            roots.append(URL(fileURLWithPath: sysdiagnose).deletingLastPathComponent().appendingPathComponent(capture))
        }
        // The Mac's ~/Downloads. `homeDirectoryForCurrentUser` is unavailable in iOS, and on the simulator HOME
        // is the app's own container, where this path simply does not exist.
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            roots.append(URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Downloads/" + capture))
        }
        if let scratch = env("FT_SCRATCH") {
            roots.append(URL(fileURLWithPath: scratch).appendingPathComponent("iphone/bb/" + capture))
        }
        return roots.lazy.compactMap { traceDir(in: $0) }.first
    }

    /// The newest log-bb-*-qdss directory under `root`, looking at `root`, `root/logs/Baseband` and one level in.
    static func traceDir(in root: URL) -> URL? {
        let fm = FileManager.default
        let candidates = [root, root.appendingPathComponent("logs/Baseband")]
        for base in candidates {
            let entries = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            let traces = entries.filter { isTraceDir($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let newest = traces.last { return newest }
        }
        return nil
    }

    static func isTraceDir(_ url: URL) -> Bool {
        let leaf = url.lastPathComponent
        guard leaf.hasPrefix("log-bb-"), leaf.hasSuffix("-qdss") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The 0x*.bin chunk files in a trace directory, in name order.
    public static func files(_ dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all
            .filter { $0.lastPathComponent.hasPrefix("0x") && $0.lastPathComponent.hasSuffix(".bin") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

extension Trait where Self == ConditionTrait {
    /// Runs the test when that capture's trace directory is on this Mac, and names it when it is not.
    public static func chunks(_ dir: URL?, _ what: String) -> Self {
        .enabled(if: dir != nil, "needs the trace chunks of \(what) (FT_CAPTURE1_CHUNKS / FT_CAPTURE2_CHUNKS)")
    }
}
