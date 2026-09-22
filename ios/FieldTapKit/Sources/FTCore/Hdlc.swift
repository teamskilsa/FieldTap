// Port of android/diag/src/main/kotlin/com/fieldtap/diag/Hdlc.kt.

import Foundation

/// The framing Qualcomm's DIAG protocol uses on the wire and in a `.qmdl` file.
///
/// A frame is its payload, then a 16-bit CRC, then 0x7E. Inside, 0x7D and 0x7E are escaped as 0x7D 0x5D and
/// 0x7D 0x5E. The CRC is CRC-16/X-25 (reflected, init 0xFFFF, final XOR 0xFFFF), so a frame including its own
/// CRC checks to `goodCrc`. Must stay byte-compatible with fieldtap/diag/hdlc.py and the Kotlin port: the
/// same capture has to decode identically everywhere.
public enum Hdlc {
    public static let flag: UInt8 = 0x7E
    public static let escape: UInt8 = 0x7D
    static let escapeMask: UInt8 = 0x20

    /// What `crc16` returns for a buffer that already ends in its own correct CRC.
    public static let goodCrc = 0x0F47

    static let table: [UInt16] = (0..<256).map { byte in
        var crc = UInt16(byte)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        return crc
    }

    /// CRC-16/X-25 over `data`.
    public static func crc16<C: Collection>(_ data: C) -> Int where C.Element == UInt8 {
        if let crc = data.withContiguousStorageIfAvailable({ crc16($0) }) { return crc }
        return Array(data).withUnsafeBufferPointer { crc16($0) }
    }

    /// The non-generic loop every overload ends in (a Debug build does not specialise generics).
    public static func crc16(_ p: UnsafeBufferPointer<UInt8>) -> Int {
        var crc: UInt16 = 0xFFFF
        table.withUnsafeBufferPointer { t in
            for i in 0..<p.count { crc = (crc >> 8) ^ t[Int((crc ^ UInt16(p[i])) & 0xFF)] }
        }
        return Int(~crc)
    }

    /// `payload` as a complete frame: payload, CRC, trailing flag, with escaping applied.
    public static func encode(_ payload: [UInt8]) -> [UInt8] {
        let crc = crc16(payload)
        var out: [UInt8] = []
        out.reserveCapacity(payload.count + 8)
        for b in payload + [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)] {
            if b == flag || b == escape {
                out.append(escape)
                out.append(b ^ escapeMask)
            } else {
                out.append(b)
            }
        }
        out.append(flag)
        return out
    }

    /// `data` with escape sequences resolved. A trailing lone escape is dropped.
    public static func unescape<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8 {
        if let out = data.withContiguousStorageIfAvailable({ unescape($0) }) { return out }
        return Array(data).withUnsafeBufferPointer { unescape($0) }
    }

    public static func unescape(_ p: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: p.count) { out, n in
            var i = 0
            n = 0
            while i < p.count {
                let b = p[i]
                if b == escape {
                    if i + 1 >= p.count { break }
                    out[n] = p[i + 1] ^ escapeMask
                    i += 2
                } else {
                    out[n] = b
                    i += 1
                }
                n += 1
            }
        }
    }
}

/// Splits a byte stream into frames, keeping whatever is incomplete until more arrives.
///
/// `feed` may be called with any split of the stream, one byte at a time or a whole file, and returns the
/// same frames either way. Frames whose CRC fails are counted in `crcErrors` and dropped rather than thrown,
/// because one corrupt frame must not end a capture. Contiguous input is scanned for flags with memchr, so
/// a 40 MB capture unframes in well under a second even in a Debug build.
public struct Unframer: Sendable {
    private var buffer: [UInt8] = []

    /// Frames dropped because their CRC did not check.
    public private(set) var crcErrors = 0

    /// Bytes held for a frame that has not ended yet.
    public var pending: Int { buffer.count }

    public init() { buffer.reserveCapacity(4096) }

    public mutating func feed<C: Collection>(_ data: C) -> [[UInt8]] where C.Element == UInt8 {
        if let frames = data.withContiguousStorageIfAvailable({ feedBuffer($0) }) { return frames }
        return Array(data).withUnsafeBufferPointer { feedBuffer($0) }
    }

    private mutating func feedBuffer(_ p: UnsafeBufferPointer<UInt8>) -> [[UInt8]] {
        guard let base = p.baseAddress, !p.isEmpty else { return [] }
        var frames: [[UInt8]] = []
        var start = 0
        while start < p.count {
            guard let hit = memchr(base + start, Int32(Hdlc.flag), p.count - start) else {
                buffer.append(contentsOf: UnsafeBufferPointer(rebasing: p[start...]))
                break
            }
            let flagAt = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            if buffer.isEmpty {
                if flagAt > start, let f = decodeOrNil(UnsafeBufferPointer(rebasing: p[start..<flagAt])) {
                    frames.append(f)
                }
            } else {
                buffer.append(contentsOf: UnsafeBufferPointer(rebasing: p[start..<flagAt]))
                let held = buffer
                buffer.removeAll(keepingCapacity: true)
                if let f = held.withUnsafeBufferPointer({ decodeOrNil($0) }) { frames.append(f) }
            }
            start = flagAt + 1
        }
        return frames
    }

    /// The payload of one escaped frame body, or nil when its CRC does not check.
    private mutating func decodeOrNil(_ escaped: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        var raw = Hdlc.unescape(escaped)
        guard raw.count >= 3, Hdlc.crc16(raw) == Hdlc.goodCrc else {
            crcErrors += 1
            return nil
        }
        raw.removeLast(2)
        return raw
    }
}
