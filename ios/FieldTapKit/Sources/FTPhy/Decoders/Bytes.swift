// Little-endian reads over a DIAG log body. Every decoder checks the length it needs before reading, so these
// never trap on the capture's own records; a short or garbled record is counted as malformed instead.

extension Array where Element == UInt8 {
    @inline(__always) func u8(_ o: Int) -> Int { Int(self[o]) }

    @inline(__always) func u16(_ o: Int) -> Int { Int(self[o]) | Int(self[o + 1]) << 8 }

    @inline(__always) func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(o)))) }

    @inline(__always) func u32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }

    @inline(__always) func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }

    /// True when `count` bytes starting at `o` are inside the body.
    @inline(__always) func has(_ o: Int, _ count: Int) -> Bool { o >= 0 && count >= 0 && o + count <= self.count }
}

extension UInt32 {
    /// `width` bits starting at bit `shift`, as an Int.
    @inline(__always) func bits(_ shift: UInt32, _ width: UInt32) -> Int { Int((self >> shift) & ((1 << width) - 1)) }
}

/// What a decoder made of one record: its values, a record version it has not been validated for (counted in
/// `PhyCapture.versionMisses` under the given key, never guessed at), or a body too short for its own layout.
enum Decoded<Value> {
    case value(Value)
    case versionMiss(String)
    case malformed
}
