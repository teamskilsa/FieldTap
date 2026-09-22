// Builds synthetic DIAG bodies field by field, so each decoder test states the layout it expects.

@testable import FTPhy
import FTModel

struct Packing {
    var bytes: [UInt8]

    init(_ count: Int) { bytes = Array(repeating: 0, count: count) }

    mutating func u8(_ o: Int, _ v: Int) { bytes[o] = UInt8(truncatingIfNeeded: v) }
    mutating func u16(_ o: Int, _ v: Int) { for i in 0..<2 { bytes[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    mutating func u32(_ o: Int, _ v: UInt32) { for i in 0..<4 { bytes[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    mutating func u64(_ o: Int, _ v: UInt64) { for i in 0..<8 { bytes[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    mutating func i16(_ o: Int, _ v: Int) { u16(o, Int(UInt16(bitPattern: Int16(v)))) }
}

/// `width` bits of `v` placed at bit `shift`.
func field(_ v: Int, _ shift: Int, _ width: Int) -> UInt32 { (UInt32(v) & ((1 << UInt32(width)) - 1)) << UInt32(shift) }

/// A raw modem timestamp `ms` after 2026-09-21T19:42:05Z (plausible network time).
func stamp(_ ms: Double) -> UInt64 {
    let utc = 1_790_019_725_000.0 + ms
    let modem = utc - Double(TimeBase.gpsEpochUtcMs)
    return UInt64(modem / 1.25) << 16
}

extension Decoded {
    var value: Value? { if case .value(let v) = self { v } else { nil } }
    var miss: String? { if case .versionMiss(let k) = self { k } else { nil } }
}
