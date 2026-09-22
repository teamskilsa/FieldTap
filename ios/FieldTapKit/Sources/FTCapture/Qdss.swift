import CryptoKit
import Foundation
import FTCore
import FTModel

public enum Qdss {
    /// Deframes the chunk files, sorted by file name. Only 0x*.bin trace chunks count (header.qmdl2 describes the
    /// trace and is not stream data; AppleDouble "._" twins are never chunks).
    public static func deframe(chunkFiles: [URL]) throws -> DeframeOutput {
        try deframe(chunkFiles: chunkFiles, progress: nil)
    }

    /// The same, reporting (chunks done, chunk count) after each chunk and stopping when the task is cancelled.
    public static func deframe(chunkFiles: [URL], progress: ((Int, Int) -> Void)?) throws -> DeframeOutput {
        let chunks = chunkFiles
            .filter { isChunkName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var deframer = QdssDeframer()
        for (i, url) in chunks.enumerated() {
            try Task.checkCancellation()
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let sequence = Self.sequence(of: url.lastPathComponent)
            data.withUnsafeBytes { deframer.feedChunk($0, sequence: sequence) }
            progress?(i + 1, chunks.count)
        }
        return deframer.finish()
    }

    /// "0x0000006F.bin" (the Python's glob '0x*.bin').
    static func isChunkName(_ leaf: String) -> Bool { leaf.hasPrefix("0x") && leaf.hasSuffix(".bin") }

    /// The chunk's number in the ring ("0x000061D7.bin" -> 0x61D7), so the deframer sees a missing file as the
    /// gap in the stream it is. Nil when the name is not a plain hexadecimal chunk name.
    static func sequence(of leaf: String) -> Int? {
        guard isChunkName(leaf) else { return nil }
        return Int(leaf.dropFirst(2).dropLast(4), radix: 16)
    }

    /// Writes `records` as a .qmdl (one HDLC frame per log packet) and returns its size and md5.
    ///
    /// Each record is written as the plain log packet the Python writes: 0x10, 0, inner, inner, code, ts, body,
    /// with inner = 12 + body length, so 'bare' records come out in the same form as 'log' ones.
    public static func writeQmdl(_ records: [LogRecord], to url: URL) throws -> (bytes: Int, md5: String) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        var total = 0
        var buffer: [UInt8] = []
        buffer.reserveCapacity(1 << 20 + 70_000)
        func flush() throws {
            guard !buffer.isEmpty else { return }
            md5.update(data: buffer)
            try handle.write(contentsOf: buffer)
            total += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }
        for r in records {
            var plain = r
            plain.more = 0
            appendFrame(DiagProtocol.encodeLogPacket(plain), to: &buffer)
            if buffer.count >= 1 << 20 { try flush() }
        }
        try flush()
        return (total, md5.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Hdlc.encode into a shared buffer: escape(payload + crc16 little endian), then the 0x7E flag.
    static func appendFrame(_ payload: [UInt8], to out: inout [UInt8]) {
        let crc = payload.withUnsafeBufferPointer { Hdlc.crc16($0) }
        func put(_ b: UInt8) {
            if b == Hdlc.flag || b == Hdlc.escape {
                out.append(Hdlc.escape)
                out.append(b ^ 0x20)
            } else {
                out.append(b)
            }
        }
        payload.withUnsafeBufferPointer { p in
            for b in p { put(b) }
        }
        put(UInt8(crc & 0xFF))
        put(UInt8((crc >> 8) & 0xFF))
        out.append(Hdlc.flag)
    }

    /// The md5 of a file, as lowercase hex (for the summary and the parity tests).
    public static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { md5.update(data: data) }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
