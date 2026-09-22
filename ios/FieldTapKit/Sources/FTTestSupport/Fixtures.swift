import Foundation
import FTModel
import Testing

/// Where the git-ignored, capture-derived fixtures are (ios/Fixtures/local, see ios/README.md).
///
/// test-kit.sh exports FT_FIXTURES, FT_SYSDIAGNOSE and FT_REQUIRE_FIXTURES=1. On the simulator xcodebuild
/// strips the TEST_RUNNER_ prefix, so the test process sees the same names; both spellings are read.
///
/// A parity test is written as
///
///     @Test(.fixture("contract/callflow-golden.json")) func parity() throws {
///         guard let url = Fixtures.require("contract/callflow-golden.json") else { return }
///         ...
///     }
///
/// Without FT_REQUIRE_FIXTURES a missing fixture skips the test (a machine without the capture). With it, the
/// trait lets the test run and `require` records an Issue, so a skipped parity test can't pass for a real one.
public enum Fixtures {
    static func env(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        let value = e[name] ?? e["TEST_RUNNER_" + name]
        return value?.isEmpty == false ? value : nil
    }

    /// The fixture folder, when one is configured and exists.
    public static var root: URL? {
        guard let path = env("FT_FIXTURES") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// True when FT_REQUIRE_FIXTURES=1: a missing fixture is a failure, not a skip.
    public static var required: Bool { env("FT_REQUIRE_FIXTURES") == "1" }

    /// `relative` under the fixture folder, or nil when it is not there.
    public static func url(_ relative: String) -> URL? {
        guard let url = root?.appendingPathComponent(relative) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The user's sysdiagnose (FT_SYSDIAGNOSE), read in place and never copied.
    public static var sysdiagnose: URL? {
        guard let path = env("FT_SYSDIAGNOSE"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `relative` (or the sysdiagnose, for "sysdiagnose"), recording an Issue when it is missing and fixtures are
    /// required. Returns nil for the caller to stop.
    public static func require(_ relative: String, sourceLocation: SourceLocation = #_sourceLocation) -> URL? {
        let found = relative == "sysdiagnose" ? sysdiagnose : url(relative)
        if found == nil && required {
            Issue.record("fixture \(relative) is missing (FT_FIXTURES=\(env("FT_FIXTURES") ?? "unset"))",
                         sourceLocation: sourceLocation)
        }
        return found
    }

    /// The bytes of a required fixture; throws when it is missing.
    public static func data(_ relative: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Data {
        guard let url = require(relative, sourceLocation: sourceLocation) else { throw Missing(path: relative) }
        return try Data(contentsOf: url)
    }

    public struct Missing: Error, CustomStringConvertible {
        public var path: String
        public var description: String { "missing fixture \(path)" }
    }

    /// True when the fixture is there, or when FT_REQUIRE_FIXTURES asks for the test to run (and fail) anyway.
    static func available(_ relative: String) -> Bool {
        required || (relative == "sysdiagnose" ? sysdiagnose != nil : url(relative) != nil)
    }
}

extension Trait where Self == ConditionTrait {
    /// Runs the test when `relative` exists under FT_FIXTURES ("sysdiagnose" for FT_SYSDIAGNOSE), or always when
    /// FT_REQUIRE_FIXTURES=1 (then `Fixtures.require` turns the missing file into a failure).
    public static func fixture(_ relative: String) -> Self {
        .enabled(if: Fixtures.available(relative), "needs fixture \(relative) (run ios/scripts/fixtures.sh)")
    }
}

/// JSON comparison with the contract's comparator (GoldenCodec.jsonDiff = Contract/tools/json_equal.py).
public enum JSONAssert {
    /// Records an Issue listing up to 20 differing paths when `data` and the JSON at `url` differ.
    @discardableResult
    public static func equal(_ data: Data, _ url: URL, tolerance: Double = 0.0015, ignoring: Set<String> = ["source.file"],
                             sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard let expected = try? Data(contentsOf: url) else {
            Issue.record("cannot read \(url.lastPathComponent)", sourceLocation: sourceLocation)
            return false
        }
        return equal(data, expected, name: url.lastPathComponent, tolerance: tolerance, ignoring: ignoring,
                     sourceLocation: sourceLocation)
    }

    @discardableResult
    public static func equal(_ data: Data, _ expected: Data, name: String = "expected", tolerance: Double = 0.0015,
                             ignoring: Set<String> = ["source.file"],
                             sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let diff = GoldenCodec.jsonDiff(data, expected, tolerance: tolerance, ignoring: ignoring)
        if !diff.isEmpty {
            Issue.record("\(diff.count) paths differ from \(name): \(diff.prefix(20).joined(separator: ", "))",
                         sourceLocation: sourceLocation)
        }
        return diff.isEmpty
    }
}
