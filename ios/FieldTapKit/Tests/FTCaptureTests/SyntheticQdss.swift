import Foundation
import zlib

/// Builds QDSS traces from scratch, the inverse of each deframer layer, so the tests need no capture:
/// DIAG packets -> fragments of 16-byte units (layer 2) -> CoreSight formatter frames on ATID 0x32 (layer 1).
enum SyntheticQdss {
    static let atid: UInt8 = 0x32

    // MARK: Layer 3

    /// A plain DIAG_LOG_F packet: 10 00, outer and inner length, code, timestamp, body.
    static func logPacket(code: UInt16, ts: UInt64, body: [UInt8], more: UInt8 = 0) -> [UInt8] {
        let inner = 12 + body.count
        return [0x10, more] + le16(inner) + le16(inner) + le16(Int(code)) + le64(ts) + body
    }

    /// A "secure" packet: 9e 01 c2 00, 16 bytes, then inner length, code and timestamp at offset 20.
    static func securePacket(code: UInt16, ts: UInt64, body: [UInt8]) -> [UInt8] {
        let total = 32 + body.count
        return [0x9E, 0x01, 0xC2, 0x00] + [UInt8](repeating: 0xAB, count: 16) + le16(total - 20) + le16(Int(code))
            + le64(ts) + body
    }

    /// A bare record: inner length (== the whole packet), code, timestamp, body.
    static func barePacket(code: UInt16, ts: UInt64, body: [UInt8]) -> [UInt8] {
        le16(12 + body.count) + le16(Int(code)) + le64(ts) + body
    }

    /// 98 01 00 00, a count, then the packets.
    static func multi(_ packets: [[UInt8]], count: Int? = nil) -> [UInt8] {
        [0x98, 0x01, 0x00, 0x00] + le32(count ?? packets.count) + packets.flatMap { $0 }
    }

    // MARK: Layer 2

    static func channelUnit(lane: Int, channel: UInt16) -> [UInt8] {
        [UInt8(0x02 | lane << 5)] + le16(Int(channel)) + [0, 0] + [UInt8](repeating: 0x01, count: 11)
    }

    static func fillUnit() -> [UInt8] { [0, 0, 0, 0, 0] + [UInt8](repeating: 0x01, count: 11) }

    /// The start unit and continuation units that assemble() turns back into `payload`.
    static func fragment(lane: Int, kind: Int, payload: [UInt8], pad: Int = 0) -> [[UInt8]] {
        let tag = UInt8(0x03 | lane << 5)
        let first = min(8 - pad, payload.count)
        var start: [UInt8] = [UInt8(0x13 | lane << 5), UInt8(kind | pad << 4)] + le16(payload.count) + [0x9D, 0x45, 0, 0]
        start += [UInt8](repeating: 0xEE, count: pad)
        start += payload[0..<first]
        start += [UInt8](repeating: 0, count: 16 - start.count)
        var units = [start]
        var rest = Array(payload[first...])
        while rest.count >= 240 {
            let burst = Array(rest[0..<240])
            rest.removeFirst(240)
            var displaced: [UInt8] = [tag]
            for j in 0..<15 {
                let line = Array(burst[(16 * j)..<(16 * j + 16)])
                units.append([tag] + line[1...])
                displaced.append(line[0])
            }
            units.append(displaced)
        }
        while !rest.isEmpty {
            if rest.count >= 12 {
                units.append([tag, 0, 0, 0] + rest[0..<12])
                rest.removeFirst(12)
            } else {
                // The last word unit carries its words in reverse order.
                let words = (rest.count + 3) / 4
                let padded = rest + [UInt8](repeating: 0, count: 4 * words - rest.count)
                var u: [UInt8] = [tag, 0, 0, 0]
                for w in stride(from: words - 1, through: 0, by: -1) { u += padded[(4 * w)..<(4 * w + 4)] }
                u += [UInt8](repeating: 0, count: 16 - u.count)
                units.append(u)
                rest = []
            }
        }
        return units
    }

    // MARK: Layer 1

    /// Formatter frames carrying `stream` on `atid`: the first frame switches the ID, every later one is a plain
    /// data frame of 15 bytes. The last frame is padded with zeros (a partial unit the deframer drops).
    static func frames(_ stream: [UInt8], atid: UInt8 = atid, switchID: Bool = true) -> [UInt8] {
        var out: [UInt8] = []
        var s = stream[...]
        func take() -> UInt8 { s.isEmpty ? 0 : s.removeFirst() }
        if switchID {
            var f = [UInt8](repeating: 0, count: 16)
            var aux: UInt8 = 0
            f[0] = atid << 1 | 1                      // aux bit 0 clear: f[1] is on the new ID
            f[1] = take()
            for i in 1..<7 {
                let x = take()
                f[2 * i] = x & 0xFE
                aux |= (x & 1) << UInt8(i)
                f[2 * i + 1] = take()
            }
            let x = take()
            f[14] = x & 0xFE
            aux |= (x & 1) << 7
            f[15] = aux
            out += f
        }
        while !s.isEmpty {
            out += dataFrame((0..<15).map { _ in take() })
        }
        return out
    }

    /// A frame with no ID byte: 15 data bytes whose even bytes' low bits travel in the aux byte.
    static func dataFrame(_ d: [UInt8]) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 16)
        var aux: UInt8 = 0
        for i in 0..<7 {
            f[2 * i] = d[2 * i] & 0xFE
            aux |= (d[2 * i] & 1) << UInt8(i)
            f[2 * i + 1] = d[2 * i + 1]
        }
        f[14] = d[14] & 0xFE
        aux |= (d[14] & 1) << 7
        f[15] = aux
        return f
    }

    static let syncFrame: [UInt8] = [0xFF, 0xFF, 0xFF, 0x7F] + [UInt8](repeating: 0x5A, count: 12)

    // MARK: Helpers

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    /// A plausible modem timestamp (the 2026 range) with `low` in the low 32 bits.
    static func ts(_ low: UInt32, hi: UInt64 = 0x0112_3456) -> UInt64 { hi << 32 | UInt64(low) }
}

/// Builds small synthetic sysdiagnose archives: ustar entries (with AppleDouble twins when asked) and gzip.
enum SyntheticArchive {
    struct Entry {
        var path: String
        var bytes: [UInt8]
    }

    static func header(_ name: String, size: Int) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ off: Int) { for (i, c) in s.utf8.enumerated() { h[off + i] = c } }
        var path = name
        if path.utf8.count > 100, let cut = path.lastIndex(of: "/") {
            // ustar: the directory part goes into the 155-byte prefix field.
            put(String(path[..<cut]), 345)
            path = String(path[path.index(after: cut)...])
        }
        put(path, 0)
        put("0000644", 100); put("0000000", 108); put("0000000", 116)
        put(String(format: "%011o", size), 124); put(String(repeating: "0", count: 11), 136)
        h[156] = UInt8(ascii: "0")
        put("ustar", 257); put("00", 263)
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), 148)
        h[154] = 0; h[155] = 0x20
        return h
    }

    static func tar(_ entries: [Entry], appleDouble: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        for e in entries {
            if appleDouble {
                // macOS tar writes "._name" next to every file with extended attributes.
                var parts = e.path.split(separator: "/").map(String.init)
                parts[parts.count - 1] = "._" + parts[parts.count - 1]
                let twin = [UInt8](repeating: 0x00, count: 204)
                out += header(parts.joined(separator: "/"), size: twin.count) + twin + padding(twin.count)
            }
            out += header(e.path, size: e.bytes.count) + e.bytes + padding(e.bytes.count)
        }
        return out + [UInt8](repeating: 0, count: 1024)
    }

    static func padding(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: (512 - n % 512) % 512) }

    static func gzip(_ input: [UInt8]) -> [UInt8] {
        var s = z_stream()
        deflateInit2_(&s, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        var out = [UInt8](repeating: 0, count: input.count + 1024)
        var inp = input
        let n: Int = inp.withUnsafeMutableBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                s.next_in = ip.baseAddress; s.avail_in = uInt(ip.count)
                s.next_out = op.baseAddress; s.avail_out = uInt(op.count)
                deflate(&s, Z_FINISH)
                return op.count - Int(s.avail_out)
            }
        }
        deflateEnd(&s)
        return Array(out[0..<n])
    }
}
