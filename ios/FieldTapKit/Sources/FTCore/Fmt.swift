import FTModel

/// Number formatting that matches the Kotlin app character for character, so parity tests can compare the
/// strings the two apps show.
public enum Fmt {
    /// Java's `String.format(Locale.ROOT, "%.Nf", value)`: the shortest round-trip decimal, then half up.
    /// 0.125 gives "0.13" and 2.675 gives "2.68" (C's printf would give "0.12" and "2.67").
    public static func fixed(_ value: Double, _ digits: Int) -> String { JavaDecimal.fixed(value, digits) }

    /// A span: "0.4 ms", "67.5 ms", "335 ms", "1.24 s", "12.3 s", "2 min 3 s", "1 h 5 min".
    ///
    /// This is the contract's `CallFlowPresentation.duration` (Kotlin `CallFlowPresentation.duration`), and it
    /// lives here so that every screen says a length the same way: a KPI tile that rounded 34.9 ms to "35 ms"
    /// while the ladder and the procedure list said "34.9 ms" looked like two different measurements.
    public static func duration(_ ms: Double) -> String {
        guard ms.isFinite else { return "—" }
        if ms < 0 { return duration(0) }
        if ms < 100 { return fixed(ms, 1) + " ms" }
        if ms < 1000 { return fixed(ms, 0) + " ms" }
        if ms < 10_000 { return fixed(ms / 1000, 2) + " s" }
        if ms < 60_000 { return fixed(ms / 1000, 1) + " s" }
        if ms < 3_600_000 {
            return "\(Int64(ms / 60_000)) min \(Int64(ms.truncatingRemainder(dividingBy: 60_000) / 1000)) s"
        }
        return "\(Int64(ms / 3_600_000)) h \(Int64(ms.truncatingRemainder(dividingBy: 3_600_000) / 60_000)) min"
    }

    /// Kotlin's "0x%0NX": `hex(0xB0C0, width: 4)` is "0xB0C0". Negative values print as their two's
    /// complement in the type's width, as Java does.
    public static func hex(_ value: some BinaryInteger, width: Int, prefix: Bool = true, uppercase: Bool = true) -> String {
        let magnitude: String
        if value < 0 {
            let bits = value.bitWidth
            let unsigned = UInt64(truncatingIfNeeded: value) & (bits >= 64 ? .max : (UInt64(1) << UInt64(bits)) - 1)
            magnitude = String(unsigned, radix: 16, uppercase: uppercase)
        } else {
            magnitude = String(value, radix: 16, uppercase: uppercase)
        }
        let padded = String(repeating: "0", count: max(0, width - magnitude.count)) + magnitude
        return prefix ? "0x" + padded : padded
    }
}
