import Foundation
import FTModel

/// One value in a screen report: what a screen shows, as counts, ids and flags, never decoded field values.
public enum ScreenValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case strings([String])
    case numbers([Double])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let n = try? c.decode([Double].self) { self = .numbers(n) }
        else { self = .strings(try c.decode([String].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .strings(let s): try c.encode(s)
        case .numbers(let n): try c.encode(n)
        }
    }
}

/// What a screen reported when it appeared, for sim-shot.sh and the harness (WP7) to wait on and check.
///
/// `ready` is set once the screen shows its real content (the capture is loaded, the launch plan applied), so a
/// screenshot is never taken of a half-loaded screen. The DEBUG/Harness writer in App/Debug puts it at
/// Documents/<debug dir>/`fileName`.
public struct ScreenReport: Codable, Hashable, Sendable {
    public var route: String
    /// Distinguishes several reports of one route ("82" for message 82, "nr" for the NR radio section).
    public var qualifier: String?
    public var rendered: Bool
    public var ready: Bool
    public var captureId: String?
    public var cursorMs: Double?
    /// Route-specific counts and ids (filled by WP7's DebugHooks).
    public var values: [String: ScreenValue]

    public init(route: Route, qualifier: String? = nil, rendered: Bool = true, ready: Bool = true,
                captureId: UUID? = nil, cursorMs: Double? = nil, values: [String: ScreenValue] = [:]) {
        self.route = route.rawValue
        self.qualifier = qualifier
        self.rendered = rendered
        self.ready = ready
        self.captureId = captureId?.uuidString
        self.cursorMs = cursorMs
        self.values = values
    }

    /// The common part of a report for a capture screen.
    @MainActor
    public init(route: Route, session: CaptureSession?, qualifier: String? = nil) {
        self.init(route: route, qualifier: qualifier, captureId: session?.id, cursorMs: session?.cursor.ms)
    }

    /// "screen-<route>.json", or "screen-<route>-<qualifier>.json".
    public var fileName: String {
        let q = qualifier.map { "-" + $0.replacingOccurrences(of: "/", with: "_") } ?? ""
        return "screen-\(route)\(q).json"
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
