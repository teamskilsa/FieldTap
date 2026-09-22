// DEBUG/Harness only (WP7). Where the harness files go: the app's Documents/ft-debug, which sim-shot.sh and
// sim-verify.sh read through `simctl get_app_container ... data`. Nothing here is compiled into Release.

#if DEBUG || FT_HARNESS
import Foundation
import FTApp

enum DebugFiles {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ft-debug", isDirectory: true)
    }

    /// Sorted keys and pretty printing, so two runs diff cleanly and the checker's messages point at a line.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Writes `value` as Documents/ft-debug/`name`, atomically, so a poller never reads half a file.
    /// Callable from any thread: the import log writes from the importer's progress callback.
    static func write(_ value: some Encodable, as name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            // Long enough to survive as a C string, so `strings` finds it in a Harness binary (README).
            print("FieldTap harness file \(name) not written: \(error)")
        }
    }

    /// Three decimals, as the goldens print them: a raw Double prints up to 17 significant digits, a digit run
    /// the privacy gate treats as an identifier, and nothing the harness reports needs more precision.
    static func r3(_ x: Double) -> Double { (x * 1_000).rounded() / 1_000 }

    static func r3(_ x: Double?) -> Double? { x.map { r3($0) } }

    static func r3(_ d: [String: Double]) -> [String: Double] { d.mapValues { r3($0) } }

    static func write(_ report: ScreenReport) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try report.encoded().write(to: directory.appendingPathComponent(report.fileName), options: .atomic)
        } catch {
            print("FieldTap screen report not written: \(error)")
        }
    }
}
#endif
