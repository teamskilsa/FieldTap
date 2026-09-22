// Port of PerBits in android/diag/src/main/kotlin/com/fieldtap/diag/LteRrc.kt (contract v1), plus the
// little-endian and bounds-checked byte reads the Kotlin objects each define privately.

/// Where Kotlin throws IndexOutOfBoundsException: a PDU or record shorter than its own structure. The decoders
/// catch it at the same places Kotlin does, so a truncated message yields exactly what it yields there.
struct OutOfBounds: Error {
    var reason: String
}

/// Unaligned PER bit reader, most significant bit first.
struct PerBits {
    private let data: [UInt8]
    private(set) var position: Int

    init(_ data: [UInt8], startBit: Int = 0) {
        self.data = data
        self.position = startBit
    }

    /// Kotlin's `readLong(n).toInt()`: the low 32 bits, sign-extended.
    mutating func read(_ n: Int) throws -> Int {
        Int(Int32(truncatingIfNeeded: try readLong(n)))
    }

    mutating func readLong(_ n: Int) throws -> Int64 {
        var value: Int64 = 0
        for _ in 0..<max(0, n) {
            let byte = position >> 3
            guard byte >= 0, byte < data.count else { throw OutOfBounds(reason: "PDU ends at bit \(data.count * 8)") }
            let bit = Int64((data[byte] >> UInt8(7 - (position & 7))) & 1)
            value = (value << 1) | bit
            position += 1
        }
        return value
    }

    /// An unaligned-PER length determinant: one bit for a length under 128, two for one under 16K. A fragmented
    /// length (the 16K-and-over form) is not read.
    mutating func readLength() throws -> Int {
        if try read(1) == 0 { return try read(7) }
        if try read(1) == 0 { return try read(14) }
        throw OutOfBounds(reason: "fragmented length determinant")
    }

    /// An OCTET STRING with an unconstrained length. Unaligned PER, so the content starts at the current bit.
    mutating func readOctetString() throws -> [UInt8] {
        let length = try readLength()
        if position + length * 8 > data.count * 8 { throw OutOfBounds(reason: "octet string runs past the PDU") }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        for _ in 0..<length { out.append(UInt8(truncatingIfNeeded: try read(8))) }
        return out
    }

    /// Skips a SEQUENCE's extension additions: a normally-small count, a presence bitmap, and each as an open type.
    mutating func skipExtensionAdditions() throws {
        guard try read(1) == 0 else { throw OutOfBounds(reason: "large extension count") }
        let count = try read(6) + 1
        var present = 0
        for _ in 0..<count {
            if try read(1) == 1 { present += 1 }
        }
        for _ in 0..<present {
            guard try read(1) == 0 else { throw OutOfBounds(reason: "long open type") }
            let length = try read(7)
            position += length * 8
        }
    }
}

/// The byte reads of the Kotlin decoders: unsigned, little-endian for record headers, and throwing where an
/// array index would.
enum Bytes {
    static func u8(_ b: [UInt8], _ i: Int) throws -> Int {
        guard i >= 0, i < b.count else { throw OutOfBounds(reason: "index \(i) of \(b.count)") }
        return Int(b[i])
    }

    /// Little-endian reads for headers whose size the caller has already checked.
    static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }

    static func le32(_ b: [UInt8], _ i: Int) -> Int64 { Int64(le16(b, i)) | Int64(le16(b, i + 2)) << 16 }

    /// Java's US_ASCII decoder: bytes of 0x80 and up become U+FFFD. Throws when the range runs past the array,
    /// as `String(bytes, offset, length, US_ASCII)` does.
    static func ascii(_ b: [UInt8], _ at: Int, _ length: Int) throws -> String {
        guard at >= 0, length >= 0, at + length <= b.count else {
            throw OutOfBounds(reason: "string \(at)+\(length) of \(b.count)")
        }
        var s = String.UnicodeScalarView()
        for byte in b[at..<at + length] {
            s.append(byte < 0x80 ? Unicode.Scalar(byte) : "\u{FFFD}")
        }
        return String(s)
    }
}
