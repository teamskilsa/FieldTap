// Port of the time rules in android/diag/src/main/kotlin/com/fieldtap/diag/CallFlow.kt at contract v1
// (rule D1, see ios/Contract/CONTRACT.md).

/// Where a capture's clock starts and ends, and how a raw modem timestamp reads as time.
///
/// iPhone captures begin with records stamped before the modem had network time (they count from the GPS
/// epoch of 1980). D1 measures from the first plausible, post-2005, timestamp when there is one and
/// otherwise, as before, from the first non-zero one, so "since start" means the same thing in both apps.
public struct TimeBase: Hashable, Codable, Sendable {
    public var firstRaw: UInt64
    public var lastRaw: UInt64

    public init(firstRaw: UInt64, lastRaw: UInt64) {
        self.firstRaw = firstRaw
        self.lastRaw = lastRaw
    }

    public static let empty = TimeBase(firstRaw: 0, lastRaw: 0)

    /// Rule D1 over records in file order: the same pass CallFlow.Reading.add makes.
    public static func of<S: Sequence>(_ records: S) -> TimeBase where S.Element == LogRecord {
        var firstAny: UInt64 = 0, lastAny: UInt64 = 0
        var firstPlausible: UInt64 = 0, lastPlausible: UInt64 = 0
        for record in records {
            let raw = record.timestampRaw
            guard isPositive(raw) else { continue }
            if firstAny == 0 { firstAny = raw }
            lastAny = raw
            if utcMs(raw) != nil {
                if firstPlausible == 0 { firstPlausible = raw }
                lastPlausible = raw
            }
        }
        return firstPlausible != 0
            ? TimeBase(firstRaw: firstPlausible, lastRaw: lastPlausible)
            : TimeBase(firstRaw: firstAny, lastRaw: lastAny)
    }

    /// Milliseconds since the GPS epoch, read the way fieldtap/diag/protocol.py and the Wireshark export read
    /// it: the upper 48 bits count 1.25 ms units, the lower 16 bits a 1/32 of that at 1.2288 MHz.
    public static func modemMs(_ raw: UInt64) -> Double {
        Double(raw >> 16) * 1.25 + Double(raw & 0xFFFF) / 39_321.6
    }

    /// 1980-01-06, the GPS epoch, in Unix milliseconds.
    public static let gpsEpochUtcMs: Int64 = 315_964_800_000

    /// 2005-01-01: a modem without network time counts from 1980, and that is not a date to show.
    public static let plausibleUtcMs: Int64 = 1_104_537_600_000

    /// Unix milliseconds of a raw timestamp, or nil when it is zero or before 2005.
    public static func utcMs(_ raw: UInt64) -> Int64? {
        guard isPositive(raw) else { return nil }
        let utc = gpsEpochUtcMs + Int64(modemMs(raw))
        return utc >= plausibleUtcMs ? utc : nil
    }

    /// Milliseconds since the start of the capture, or nil for an unstamped (zero) record.
    public func sinceStartMs(_ raw: UInt64) -> Double? {
        guard Self.isPositive(raw), firstRaw > 0 else { return nil }
        return Self.modemMs(raw) - Self.modemMs(firstRaw)
    }

    /// From the first counted record to the last; 0 for a capture with no stamped record.
    public var durationMs: Double {
        guard firstRaw > 0, lastRaw > 0 else { return 0 }
        return Self.modemMs(lastRaw) - Self.modemMs(firstRaw)
    }

    /// Wall-clock time of the first counted record, or nil when the modem had no network time.
    public var startUtcMs: Int64? { Self.utcMs(firstRaw) }

    /// Kotlin reads the timestamp as a signed Long and skips values <= 0; the same bits are skipped here.
    static func isPositive(_ raw: UInt64) -> Bool { raw > 0 && raw < (1 << 63) }
}
