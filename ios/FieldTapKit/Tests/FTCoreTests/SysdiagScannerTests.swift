import Foundation
import Testing
import zlib
import FTTestSupport
@testable import FTCore

/// Builds small synthetic sysdiagnose archives in memory: ustar headers, optional PAX and GNU long-name
/// entries, AppleDouble twins, gzip.
enum SyntheticTar {
    static func header(_ name: String, size: Int, type: UInt8 = UInt8(ascii: "0")) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ off: Int) { for (i, c) in s.utf8.enumerated() { h[off + i] = c } }
        put(String(name.prefix(100)), 0)
        put("0000644", 100); put("0000000", 108); put("0000000", 116)
        put(String(format: "%011o", size), 124); put(String(repeating: "0", count: 11), 136)
        h[156] = type
        put("ustar", 257); put("00", 263)
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), 148)
        h[154] = 0; h[155] = 0x20
        return h
    }

    static func entry(_ name: String, _ body: [UInt8], type: UInt8 = UInt8(ascii: "0")) -> [UInt8] {
        header(name, size: body.count, type: type) + body + [UInt8](repeating: 0, count: (512 - body.count % 512) % 512)
    }

    static func pax(path: String) -> [UInt8] {
        let record = " path=\(path)\n"
        var len = record.utf8.count + 2
        while "\(len)\(record)".utf8.count != len { len += 1 }
        return entry("PaxHeaders/x", Array("\(len)\(record)".utf8), type: UInt8(ascii: "x"))
    }

    static func gnuLong(_ path: String) -> [UInt8] {
        entry("././@LongLink", Array(path.utf8) + [0], type: UInt8(ascii: "L"))
    }

    static let end = [UInt8](repeating: 0, count: 1024)

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

    static func write(_ bytes: [UInt8], name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(name).tar.gz")
        try Data(bytes).write(to: url)
        return url
    }
}

private func isBaseband(_ path: String) -> Bool { path.contains("/logs/Baseband/") }

@Suite struct SysdiagScannerTests {
    /// Collects every selected entry's bytes.
    final class Collector: @unchecked Sendable {
        var files: [String: [UInt8]] = [:]
        var lastFlags: [String: Int] = [:]
        func sink(_ path: String, _ size: Int, _ bytes: UnsafeRawBufferPointer, _ isLast: Bool) {
            files[path, default: []] += Array(bytes)
            if isLast { lastFlags[path, default: 0] += 1 }
        }
    }

    @Test func keepsSelectedEntriesAndSkipsAppleDouble() throws {
        let chunk = (0..<700).map { UInt8($0 & 0xFF) }
        let dir = "sysdiagnose_x/logs/Baseband/log-bb-2026-01-01-00-00-00-000-qdss"
        let tar = SyntheticTar.entry("\(dir)/0x00000000.bin", chunk)
            + SyntheticTar.entry("\(dir)/._0x00000000.bin", [1, 2, 3])
            + SyntheticTar.entry("sysdiagnose_x/logs/Baseband/", [], type: UInt8(ascii: "5"))
            + SyntheticTar.entry("sysdiagnose_x/other.txt", Array("hello".utf8))
            + SyntheticTar.entry("\(dir)/info.txt", [])
            + SyntheticTar.end
        let url = try SyntheticTar.write(SyntheticTar.gzip(tar))
        defer { try? FileManager.default.removeItem(at: url) }
        let c = Collector()
        let r = try SysdiagScanner.scan(url, bufferSize: 97, select: isBaseband, sink: c.sink)   // odd size: every split
        #expect(r.tarEntries == 5)
        #expect(r.appleDoubleSkipped == 1)
        #expect(r.selectedFiles == 2, "the chunk and the empty info.txt; not the ._ twin or the directory")
        #expect(r.selectedBytes == 700)
        #expect(c.files["\(dir)/0x00000000.bin"] == chunk)
        #expect(c.lastFlags["\(dir)/0x00000000.bin"] == 1 && c.lastFlags["\(dir)/info.txt"] == 1)
        #expect(c.files.keys.allSatisfy { !$0.contains("/._") })
        #expect(r.uncompressedBytes == tar.count)
    }

    @Test func appleDoubleCanBeKeptWhenAsked() throws {
        let tar = SyntheticTar.entry("s/logs/Baseband/._a.bin", [9]) + SyntheticTar.end
        let url = try SyntheticTar.write(SyntheticTar.gzip(tar))
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try SysdiagScanner.scan(url, skipAppleDouble: false, select: isBaseband) { _, _, _, _ in }
        #expect(r.selectedFiles == 1 && r.appleDoubleSkipped == 0)
    }

    @Test func paxAndGnuLongNamesName() throws {
        let long = "sysdiagnose_y/logs/Baseband/" + String(repeating: "d", count: 120) + "/0x00000001.bin"
        let pax = "sysdiagnose_y/logs/Baseband/" + String(repeating: "p", count: 110) + "/0x00000002.bin"
        let tar = SyntheticTar.gnuLong(long) + SyntheticTar.entry("truncated-name", [1, 2])
            + SyntheticTar.pax(path: pax) + SyntheticTar.entry("also-truncated", [3])
            + SyntheticTar.end
        let url = try SyntheticTar.write(SyntheticTar.gzip(tar))
        defer { try? FileManager.default.removeItem(at: url) }
        let c = Collector()
        let r = try SysdiagScanner.scan(url, select: isBaseband, sink: c.sink)
        #expect(r.selectedFiles == 2)
        #expect(c.files[long] == [1, 2])
        #expect(c.files[pax] == [3])
    }

    @Test func aCutShortArchiveThrowsTruncated() throws {
        let tar = SyntheticTar.entry("s/logs/Baseband/a.bin", (0..<5000).map { UInt8($0 % 251) }) + SyntheticTar.end
        let gz = SyntheticTar.gzip(tar)
        let url = try SyntheticTar.write(Array(gz.prefix(gz.count / 2)))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SysdiagScanError.truncated) {
            try SysdiagScanner.scan(url, select: isBaseband) { _, _, _, _ in }
        }
    }

    @Test func aFileThatIsNotGzipThrowsNotGzip() throws {
        let url = try SyntheticTar.write(Array("this is not an archive at all".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SysdiagScanError.notGzip) {
            try SysdiagScanner.scan(url, select: isBaseband) { _, _, _, _ in }
        }
        let empty = try SyntheticTar.write([])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: SysdiagScanError.notGzip) {
            try SysdiagScanner.scan(empty, select: isBaseband) { _, _, _, _ in }
        }
    }

    @Test func aThrowingSinkEndsTheScan() throws {
        struct Stop: Error {}
        let tar = SyntheticTar.entry("s/logs/Baseband/a.bin", [1]) + SyntheticTar.end
        let url = try SyntheticTar.write(SyntheticTar.gzip(tar))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: Stop.self) { try SysdiagScanner.scan(url, select: isBaseband) { _, _, _, _ in throw Stop() } }
    }

    /// The user's 408 MB sysdiagnose, read in place: the POC's numbers (135 Baseband files, 130 qdss chunks,
    /// 134,161,706 bytes, adler32 a0e39d83), and the 130 AppleDouble twins of the chunks skipped.
    @Test(.fixture("sysdiagnose"))
    func sysdiagScanReal() throws {
        guard let url = Fixtures.require("sysdiagnose") else { return }
        var qdssChunks = 0
        let r = try SysdiagScanner.scan(url, select: isBaseband) { path, _, _, isLast in
            let leaf = path.split(separator: "/").last ?? ""
            if isLast, path.contains("-qdss/"), leaf.hasSuffix(".bin") { qdssChunks += 1 }
        }
        #expect(r.selectedFiles == 135)
        #expect(qdssChunks == 130)
        #expect(r.selectedBytes == 134_161_706)
        #expect(r.adler32Hex == "a0e39d83")
        #expect(r.appleDoubleSkipped >= 130)
        #expect(r.compressedBytes == 408_450_455)
    }
}
