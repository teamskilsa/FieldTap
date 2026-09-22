/// Java's `String.format(Locale.ROOT, "%.Nf", value)`, which the Kotlin code uses for every number it shows.
///
/// Java rounds the shortest decimal that round-trips the double, half up; C's printf rounds the exact binary
/// value, half even. They disagree on values like 0.125 ("0.13" in Java, "0.12" in C) and 2.675 ("2.68" vs
/// "2.67"), and the goldens hold Java's strings. FTCore's `Fmt.fixed` forwards here.
public enum JavaDecimal {
    public static func fixed(_ value: Double, _ digits: Int) -> String {
        precondition(digits >= 0, "digits must not be negative")
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }

        let (d, point) = shortestDigits(abs(value))
        // Keep `point + digits` digits of `d`, rounding half up on the first dropped digit.
        let keep = point + digits
        var kept: [UInt8]
        if keep < 0 {
            kept = []
        } else {
            kept = Array(d.prefix(keep))
            while kept.count < keep { kept.append(0) }
            let next = keep < d.count ? d[keep] : 0
            if next >= 5 { increment(&kept) }
        }
        while kept.count < digits + 1 { kept.insert(0, at: 0) }
        let whole = kept.prefix(kept.count - digits)
        let fraction = kept.suffix(digits)
        var s = value.sign == .minus ? "-" : ""
        s += whole.map { String($0) }.joined()
        if digits > 0 { s += "." + fraction.map { String($0) }.joined() }
        return s
    }

    /// The shortest round-trip decimal digits of a non-negative finite double and the position of the
    /// decimal point: 123.45 gives ([1,2,3,4,5], 3), 0.00012 gives ([1,2], -3).
    static func shortestDigits(_ v: Double) -> ([UInt8], Int) {
        if v == 0 { return ([0], 1) }
        let text = "\(v)"                          // Swift prints the shortest round-trip form
        let parts = text.lowercased().split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var digits: [UInt8] = []
        var point = 0
        var seenPoint = false
        for c in mantissa {
            if c == "." { seenPoint = true; continue }
            guard let n = c.wholeNumberValue else { continue }
            digits.append(UInt8(n))
            if !seenPoint { point += 1 }
        }
        // Strip leading zeros ("0.0012" -> [1,2], point -2).
        while digits.count > 1, digits.first == 0 {
            digits.removeFirst()
            point -= 1
        }
        return (digits, point + exponent)
    }

    private static func increment(_ digits: inout [UInt8]) {
        var i = digits.count - 1
        while i >= 0 {
            if digits[i] == 9 {
                digits[i] = 0
                i -= 1
            } else {
                digits[i] += 1
                return
            }
        }
        digits.insert(1, at: 0)
    }
}
