// Port of android/diag/src/main/kotlin/com/fieldtap/diag/Protocol.kt (LogRecord itself lives in FTModel).

import Foundation
import FTModel

/// The DIAG packets FieldTap reads, and the containers a handset wraps them in.
///
/// Log packets are the only thing carrying RRC, NAS and PHY records, so this covers them and leaves requests,
/// responses and debug messages to the desktop tool. Every multi-byte field is little-endian.
public enum DiagProtocol {
    /// Asynchronous log packet, modem to host.
    public static let diagLogF: UInt8 = 0x10
    /// A qmdl2 container holding one or more `diagLogF` packets.
    public static let diagMultiLogF: UInt8 = 0x98
    /// cmd, more, outer length, inner length, log code, timestamp.
    public static let logHeaderLen = 16
    /// The entry header inside a log packet: length, code, timestamp.
    public static let logEntryHeaderLen = 12
    /// cmd, version, pad, packet count.
    public static let multiLogHeaderLen = 8

    /// The top nibble of a log code: which subsystem emitted it.
    public static func equipId(_ logCode: UInt16) -> Int { Int(logCode >> 12) & 0xF }

    /// The low 12 bits of a log code: its item within the equipment id.
    public static func logItem(_ logCode: UInt16) -> Int { Int(logCode) & 0xFFF }

    static func u16(_ d: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }

    static func u32(_ d: UnsafeBufferPointer<UInt8>, _ at: Int) -> UInt64 {
        UInt64(u16(d, at)) | UInt64(u16(d, at + 2)) << 16
    }

    static func u64(_ d: UnsafeBufferPointer<UInt8>, _ at: Int) -> UInt64 { u32(d, at) | u32(d, at + 4) << 32 }

    /// One log packet: its code, the modem's timestamp and the body the decoders read; nil when `payload` is
    /// not a log packet (Kotlin throws IllegalArgumentException there, which callers count as a bad packet).
    ///
    /// The inner length is trusted only when it agrees with the bytes that arrived: a packet cut short by a
    /// truncated capture keeps whatever it has, as the Python reader does.
    public static func parseLogPacket(_ payload: [UInt8]) -> LogRecord? {
        payload.withUnsafeBufferPointer { p in
            guard p.count >= logHeaderLen, p[0] == diagLogF else { return nil }
            let more = p[1]
            let innerLen = u16(p, 4)
            let code = UInt16(u16(p, 6))
            let timestampRaw = u64(p, 8)
            let bodyLen = innerLen - logEntryHeaderLen
            let available = p.count - logHeaderLen
            let end = (0...available).contains(bodyLen) ? logHeaderLen + bodyLen : p.count
            return LogRecord(code: code, timestampRaw: timestampRaw, body: Array(p[logHeaderLen..<end]), more: more)
        }
    }

    /// Every log packet inside a qmdl2 container, or nothing when `frame` is not one.
    ///
    /// The count is trusted only as far as the bytes allow and each packet is measured by its own length
    /// field, so a truncated file yields what it holds. A count of 0 means "read until the bytes end".
    public static func qmdl2LogPackets(_ frame: [UInt8]) -> [[UInt8]] {
        frame.withUnsafeBufferPointer { p in
            guard p.count >= multiLogHeaderLen, p[0] == diagMultiLogF else { return [] }
            let count = u32(p, 4)
            var out: [[UInt8]] = []
            var offset = multiLogHeaderLen
            while offset + logHeaderLen <= p.count && (count == 0 || UInt64(out.count) < count) {
                if p[offset] != diagLogF { return out }
                let innerLen = u16(p, offset + 4)
                if innerLen < logEntryHeaderLen { return out }
                // A packet spans its 16-byte header plus the body, and innerLen counts the 12-byte entry header
                // and the body, so the step is innerLen + 4.
                let end = min(offset + innerLen + 4, p.count)
                out.append(Array(p[offset..<end]))
                offset = end
            }
            return out
        }
    }

    /// The log packets in one unframed DIAG frame, whether a bare log packet or a qmdl2 container. Anything
    /// else (a response, a debug message, an event) yields nothing.
    public static func logPacketsOf(_ frame: [UInt8]) -> [[UInt8]] {
        guard let first = frame.first else { return [] }
        switch first {
        case diagLogF: return [frame]
        case diagMultiLogF: return qmdl2LogPackets(frame)
        default: return []
        }
    }

    /// `record` as the log packet the modem would send: 0x10, more, outer and inner length, code, timestamp,
    /// body. The inverse of `parseLogPacket`; the QDSS deframer (WP3) writes its .qmdl with it.
    public static func encodeLogPacket(_ record: LogRecord) -> [UInt8] {
        let inner = logEntryHeaderLen + record.body.count
        var out: [UInt8] = []
        out.reserveCapacity(logHeaderLen + record.body.count)
        out.append(diagLogF)
        out.append(record.more)
        for v in [inner, inner, Int(record.code)] {
            out.append(UInt8(v & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF))
        }
        for i in 0..<8 { out.append(UInt8((record.timestampRaw >> (8 * UInt64(i))) & 0xFF)) }
        out.append(contentsOf: record.body)
        return out
    }

    /// What reading a whole .qmdl gives: the records in file order and the counts GoldenDump.kt reports.
    public struct QmdlRead: Sendable {
        public var records: [LogRecord]
        /// HDLC frames that checked (GoldenDump's "hdlcFrames").
        public var frames: Int
        public var crcErrors: Int
        /// Log packets too short or not starting with 0x10.
        public var badPackets: Int

        public init(records: [LogRecord], frames: Int, crcErrors: Int, badPackets: Int) {
            self.records = records
            self.frames = frames
            self.crcErrors = crcErrors
            self.badPackets = badPackets
        }

        /// Records per log code, as the goldens' `recordsPerCode`.
        public var recordsPerCode: [UInt16: Int] {
            var out: [UInt16: Int] = [:]
            for r in records { out[r.code, default: 0] += 1 }
            return out
        }
    }

    /// Unframes and parses a whole .qmdl the way CallFlow.read and GoldenDump.kt do. Fed in 1 MiB slices so the
    /// frame buffer stays small; the Unframer returns the same frames for any split.
    public static func readQmdl(_ data: Data) -> QmdlRead {
        var unframer = Unframer()
        var records: [LogRecord] = []
        records.reserveCapacity(data.count / 400)
        var frames = 0, bad = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + (1 << 20), bytes.count)
                for frame in unframer.feed(UnsafeBufferPointer(rebasing: bytes[offset..<end])) {
                    frames += 1
                    for packet in logPacketsOf(frame) {
                        if let r = parseLogPacket(packet) { records.append(r) } else { bad += 1 }
                    }
                }
                offset = end
            }
        }
        return QmdlRead(records: records, frames: frames, crcErrors: unframer.crcErrors, badPackets: bad)
    }
}
