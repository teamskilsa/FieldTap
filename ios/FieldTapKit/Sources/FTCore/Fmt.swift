import FTModel

/// Number formatting that matches the Kotlin app character for character, so parity tests can compare the
/// strings the two apps show.
public enum Fmt {
    /// Java's `String.format(Locale.ROOT, "%.Nf", value)`: the shortest round-trip decimal, then half up.
    /// 0.125 gives "0.13" and 2.675 gives "2.68" (C's printf would give "0.12" and "2.67").
    public static func fixed(_ value: Double, _ digits: Int) -> String { JavaDecimal.fixed(value, digits) }

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
