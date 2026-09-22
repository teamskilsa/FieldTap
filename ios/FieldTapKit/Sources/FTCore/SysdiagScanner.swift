// Generalised from the iOS foundation POC (wf-ios/ios-foundation/FieldTapPOC/.../SysdiagScanner.swift).

import Foundation
import zlib

/// What one pass over a sysdiagnose archive saw. Counts only: no file contents.
public struct SysdiagScanResult: Hashable, Codable, Sendable {
    public var compressedBytes = 0
    public var uncompressedBytes = 0
    /// Every tar entry, including directories, PAX headers and AppleDouble files.
    public var tarEntries = 0
    /// Regular files `select` accepted.
    public var selectedFiles = 0
    public var selectedBytes = 0
    /// Adler-32 over the selected files' bytes in archive order: a cheap fingerprint to compare two runs.
    public var adler32Hex = ""
    /// AppleDouble ("._name") leaves skipped before `select` was asked.
    public var appleDoubleSkipped = 0
    public var seconds = 0.0

    public init() {}
}

public enum SysdiagScanError: Error, Hashable, Sendable {
    case cannotOpen(String)
    case readFailed(String)
    /// The first bytes are not a gzip (or zlib) stream.
    case notGzip
    /// inflate failed part way: a damaged archive.
    case corrupt(Int32)
    /// The file ended before the gzip stream did: a copy that was cut short.
    case truncated
}

/// Streams a sysdiagnose `.tar.gz` with bounded memory (one 256 KiB input and output buffer, plus the
/// current tar header) and hands the bytes of the entries `select` accepts to `sink`, piece by piece.
///
/// Public SDK only: Foundation and zlib. A 408 MB archive scans in about 1.3 s on the simulator.
public enum SysdiagScanner {
    /// A piece of a selected entry: its path in the archive, the entry's full size, these bytes, and whether
    /// this is the entry's last piece (a zero-length entry gets one empty, last piece).
    public typealias Sink = (_ path: String, _ size: Int, _ bytes: UnsafeRawBufferPointer, _ isLast: Bool) throws -> Void

    /// Scans `url`, calling `sink` for every regular file whose archive path `select` accepts.
    ///
    /// AppleDouble leaves ("._0x0000006F.bin", written by macOS tar next to every file with extended
    /// attributes) are skipped before `select` is asked unless `skipAppleDouble` is false: the user's archive
    /// has 130 of them beside the 130 chunks, and feeding them to the deframer would change its output.
    /// Errors thrown by `sink` (cancellation, a full disk) end the scan and are rethrown.
    public static func scan(_ url: URL, skipAppleDouble: Bool = true, bufferSize: Int = 256 * 1024,
                            select: (String) -> Bool, sink: Sink) throws -> SysdiagScanResult {
        // The walker keeps both closures only for the duration of this call.
        try withoutActuallyEscaping(select) { select in
            try withoutActuallyEscaping(sink) { sink in
                try run(url, skipAppleDouble: skipAppleDouble, bufferSize: bufferSize, select: select, sink: sink)
            }
        }
    }

    private static func run(_ url: URL, skipAppleDouble: Bool, bufferSize: Int, select: @escaping (String) -> Bool,
                            sink: @escaping Sink) throws -> SysdiagScanResult {
        let t0 = Date()
        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: url)
        } catch {
            throw SysdiagScanError.cannotOpen(error.localizedDescription)
        }
        defer { try? fh.close() }

        var strm = z_stream()
        // 15 + 32: auto-detect a gzip or zlib header.
        guard inflateInit2_(&strm, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SysdiagScanError.corrupt(Z_STREAM_ERROR)
        }
        defer { inflateEnd(&strm) }

        var tar = TarWalker(skipAppleDouble: skipAppleDouble, select: select, sink: sink)
        var result = SysdiagScanResult()
        var out = [UInt8](repeating: 0, count: bufferSize)
        var status: Int32 = Z_OK
        var sawInput = false
        while status != Z_STREAM_END {
            let input: Data
            do {
                input = try fh.read(upToCount: bufferSize) ?? Data()
            } catch {
                throw SysdiagScanError.readFailed(error.localizedDescription)
            }
            if input.isEmpty { break }
            sawInput = true
            result.compressedBytes += input.count
            try input.withUnsafeBytes { (ip: UnsafeRawBufferPointer) in
                strm.next_in = UnsafeMutablePointer(mutating: ip.bindMemory(to: Bytef.self).baseAddress)
                strm.avail_in = uInt(input.count)
                repeat {
                    try out.withUnsafeMutableBufferPointer { op in
                        strm.next_out = op.baseAddress
                        strm.avail_out = uInt(op.count)
                        status = inflate(&strm, Z_NO_FLUSH)
                        let produced = op.count - Int(strm.avail_out)
                        result.uncompressedBytes += produced
                        if produced > 0 { try tar.feed(UnsafeBufferPointer(rebasing: op[0..<produced])) }
                    }
                } while strm.avail_out == 0 && status == Z_OK
            }
            if status == Z_DATA_ERROR && result.uncompressedBytes == 0 { throw SysdiagScanError.notGzip }
            if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
                throw SysdiagScanError.corrupt(status)
            }
        }
        if !sawInput { throw SysdiagScanError.notGzip }
        if status != Z_STREAM_END { throw SysdiagScanError.truncated }

        result.tarEntries = tar.entries
        result.selectedFiles = tar.selected
        result.selectedBytes = tar.selectedBytes
        result.appleDoubleSkipped = tar.appleDoubleSkipped
        result.adler32Hex = String(format: "%08lx", tar.adler)
        result.seconds = Date().timeIntervalSince(t0)
        return result
    }
}

/// Minimal ustar/pax/GNU-longname walker fed with arbitrary splits of the uncompressed stream.
struct TarWalker {
    private enum State { case header, body(Int), pad(Int) }
    private var state = State.header
    private var hdr: [UInt8] = []
    private var meta: [UInt8] = []
    /// 'x' (pax) or 'L' (GNU long name) while one is being collected; 0 otherwise.
    private var metaKind: UInt8 = 0
    private var nextName: String?
    private var keep = false
    private var name = ""
    private var size = 0
    private var padAfter = 0
    private let skipAppleDouble: Bool
    private let select: (String) -> Bool
    private let sink: SysdiagScanner.Sink

    private(set) var entries = 0
    private(set) var selected = 0
    private(set) var selectedBytes = 0
    private(set) var appleDoubleSkipped = 0
    private(set) var adler: UInt = zlib.adler32(0, nil, 0)

    init(skipAppleDouble: Bool, select: @escaping (String) -> Bool, sink: @escaping SysdiagScanner.Sink) {
        self.skipAppleDouble = skipAppleDouble
        self.select = select
        self.sink = sink
        hdr.reserveCapacity(512)
    }

    mutating func feed(_ p: UnsafeBufferPointer<UInt8>) throws {
        var i = 0
        while i < p.count {
            switch state {
            case .header:
                let n = min(512 - hdr.count, p.count - i)
                hdr.append(contentsOf: p[i..<(i + n)])
                i += n
                if hdr.count == 512 {
                    try startEntry()
                    hdr.removeAll(keepingCapacity: true)
                }
            case .body(let remaining):
                let n = min(remaining, p.count - i)
                let slice = UnsafeBufferPointer(rebasing: p[i..<(i + n)])
                i += n
                let left = remaining - n
                if keep {
                    selectedBytes += n
                    adler = zlib.adler32(adler, slice.baseAddress, uInt(n))
                    try sink(name, size, UnsafeRawBufferPointer(slice), left == 0)
                } else if metaKind != 0 {
                    meta.append(contentsOf: slice)
                }
                if left == 0 { endEntry() } else { state = .body(left) }
            case .pad(let need):
                let n = min(need, p.count - i)
                i += n
                state = need - n == 0 ? .header : .pad(need - n)
            }
        }
    }

    private func str(_ off: Int, _ len: Int) -> String {
        String(decoding: hdr[off..<(off + len)].prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The size field: octal text, or GNU base-256 when the top bit of the first byte is set.
    private func entrySize() -> Int {
        if hdr[124] & 0x80 != 0 {
            return hdr[125..<136].reduce(0) { ($0 << 8) | Int($1) }
        }
        return Int(str(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
    }

    private mutating func startEntry() throws {
        if hdr.allSatisfy({ $0 == 0 }) { return }                 // end-of-archive blocks
        size = entrySize()
        let type = hdr[156]
        var n = str(0, 100)
        let prefix = str(345, 155)
        if !prefix.isEmpty { n = prefix + "/" + n }
        if let long = nextName { n = long; nextName = nil }
        name = n
        entries += 1
        metaKind = (type == UInt8(ascii: "x") || type == UInt8(ascii: "L")) ? type : 0
        meta.removeAll(keepingCapacity: true)
        let regular = type == 0 || type == UInt8(ascii: "0") || type == UInt8(ascii: "7")
        keep = false
        if metaKind == 0 && regular {
            let leaf = n.split(separator: "/").last.map(String.init) ?? n
            if skipAppleDouble && leaf.hasPrefix("._") {
                appleDoubleSkipped += 1
            } else if select(n) {
                keep = true
                selected += 1
            }
        }
        padAfter = (512 - size % 512) % 512
        if size == 0 {
            if keep { try sink(name, 0, UnsafeRawBufferPointer(start: nil, count: 0), true) }
            endEntry()
        } else {
            state = .body(size)
        }
    }

    private mutating func endEntry() {
        if metaKind == UInt8(ascii: "L") {
            nextName = String(decoding: meta.prefix { $0 != 0 }, as: UTF8.self)
        } else if metaKind == UInt8(ascii: "x") {
            for line in String(decoding: meta, as: UTF8.self).split(separator: "\n") {
                if let r = line.range(of: " path=") { nextName = String(line[r.upperBound...]) }
            }
        }
        metaKind = 0
        keep = false
        state = padAfter > 0 ? .pad(padAfter) : .header
    }
}
