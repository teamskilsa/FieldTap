import Foundation
import Testing
import FTCore
import FTModel
@testable import FTCapture

/// The deframer's rules one at a time, on traces built by SyntheticQdss (no capture needed).
@Suite struct DeframerSyntheticTests {
    typealias S = SyntheticQdss

    static func deframe(_ chunks: [[UInt8]]) -> DeframeOutput {
        var d = QdssDeframer()
        for c in chunks { c.withUnsafeBytes { d.feedChunk($0) } }
        return d.finish()
    }

    /// Units -> one chunk of formatter frames on ATID 0x32.
    static func chunk(_ units: [[UInt8]]) -> [UInt8] { S.frames(Aligned.stream(units.flatMap { $0 }, firstFrame: true)) }

    static func log(_ code: UInt16, _ low: UInt32, _ body: [UInt8] = [1, 2, 3]) -> [UInt8] {
        S.logPacket(code: code, ts: S.ts(low), body: body)
    }

    static func bytes(_ n: Int, seed: UInt8 = 0) -> [UInt8] { (0..<n).map { UInt8(($0 &* 31 &+ Int(seed)) & 0xFF) } }

    @Test func wholeFragmentGivesOneRecord() {
        let body = Self.bytes(40)
        let out = Self.deframe([Self.chunk([S.channelUnit(lane: 0, channel: 7)] + S.fragment(lane: 0, kind: 1,
                                                                                            payload: Self.log(0xB0C0, 5, body)))])
        #expect(out.records == [LogRecord(code: 0xB0C0, timestampRaw: S.ts(5), body: body)])
        #expect(out.stats.counters["u_chan"] == 1 && out.stats.counters["u_start"] == 1)
        #expect(out.stats.fits == ["exact": 1])
        #expect(out.stats.packets == ["log": 1])
        #expect(out.stats.fragmentKinds == ["1": 1])
        #expect(out.stats.phase == 0)
    }

    /// Payload lengths across every burst and last-word case: the 240-byte bursts with displaced bytes, 12-byte
    /// word units, and the reversed last words (R % 12 from 1 to 11), with every pad value.
    @Test(arguments: [0, 1, 3, 7])
    func assemblyRoundTripsEveryLength(pad: Int) {
        for n in [0, 1, 5, 8, 9, 13, 20, 21, 31, 100, 239, 240, 247, 248, 251, 500, 731, 1_000] {
            let payload = Self.log(0x1375, 9, Self.bytes(n, seed: UInt8(n & 0xFF)))
            let units = S.fragment(lane: 2, kind: 1, payload: payload, pad: pad)
            let joined = units.flatMap { $0 }
            let data = joined.withUnsafeBufferPointer { QdssDeframer.assemble($0) }
            #expect(data == payload, "pad \(pad), body \(n)")
            let pieces = QdssDeframer.consumption(length: payload.count, pad: pad, conts: units.count - 1)
            #expect(pieces.complete && pieces.used == units.count - 1)
            #expect(QdssDeframer.expectedUnits(length: payload.count, pad: pad) == units.count - 1)
        }
    }

    @Test func syncFramesAreSkipped() {
        let units = [S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 1, payload: Self.log(0xB0C0, 1))
        let plain = Self.chunk(units)
        // A sync frame between every frame changes nothing.
        var synced: [UInt8] = []
        for i in stride(from: 0, to: plain.count, by: 16) { synced += S.syncFrame + plain[i..<(i + 16)] }
        let a = Self.deframe([plain]), b = Self.deframe([synced])
        #expect(a.records == b.records && a.stats == b.stats)
    }

    /// The fast path restores each even byte's low bit from the aux byte.
    @Test func auxBitsRestoreLowBits() {
        let body: [UInt8] = [0x01, 0x03, 0xFF, 0x11, 0x81, 0x7F, 0x01, 0x01, 0x55, 0xAB, 0x01]
        let out = Self.deframe([Self.chunk([S.channelUnit(lane: 0, channel: 1)]
            + S.fragment(lane: 0, kind: 1, payload: Self.log(0xB0C1, 3, body)))])
        #expect(out.records.first?.body == body)
    }

    /// An ID byte with its aux bit set: the byte after it still belongs to the old ID (0x32).
    @Test func idChangeWithAuxBitKeepsNextByteOnOldId() {
        var f = [UInt8](repeating: 0, count: 16)
        f[0] = 0x32 << 1 | 1; f[1] = 0xA1               // switch to 0x32, f[1] on 0x32
        f[2] = 0x10 << 1 | 1; f[3] = 0xA2               // switch to 0x10 with aux bit 1 set: f[3] still on 0x32
        f[4] = 0x20; f[5] = 0x21                         // on 0x10: dropped
        f[15] = 1 << 1
        var d = QdssDeframer()
        f.withUnsafeBytes { d.feedChunk($0) }
        #expect(d.finish().stats.atid32Bytes == 2)
    }

    @Test func otherTraceIdsAreDropped() {
        let units = [S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 1, payload: Self.log(0xB0C0, 1))
        let stream = Aligned.stream(units.flatMap { $0 }, firstFrame: true)
        let other = S.frames(Self.bytes(300), atid: 0x10)
        let out = Self.deframe([other + S.frames(stream)])
        #expect(out.stats.atid32Bytes == stream.count)
        #expect(out.records.count == 1)
    }

    /// The formatter's ID and the unit stream carry across chunks: the second chunk has no ID byte at all.
    @Test func traceIdAndUnitsCarryAcrossChunks() {
        let fragment = S.fragment(lane: 0, kind: 1, payload: Self.log(0xB0C0, 1, Self.bytes(100))).flatMap { $0 }
        let all = S.channelUnit(lane: 0, channel: 1) + fragment
        // Cut the stream mid-unit, on a frame boundary of the first chunk.
        let first = Array(all[0..<(14 + 15 * 3)])
        let second = Aligned.stream(Array(all[(14 + 15 * 3)...]), firstFrame: false)
        let out = Self.deframe([S.frames(first), S.frames(second, switchID: false)])
        #expect(out.records.count == 1 && out.records[0].body == Self.bytes(100))
        #expect(out.stats.chunks == 2)
    }

    /// Frames are aligned to each chunk's start: a tail shorter than 16 bytes is dropped, not carried over.
    @Test func chunkTailShorterThanAFrameIsDropped() {
        let units = [S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 1, payload: Self.log(0xB0C0, 1))
        let c = Self.chunk(units)
        let next = S.frames(Aligned.stream(S.fragment(lane: 0, kind: 1, payload: Self.log(0xB0C1, 2)).flatMap { $0 },
                                           firstFrame: false), switchID: false)
        let clean = Self.deframe([c, next])
        let tailed = Self.deframe([c + [0x65, 1, 2, 3, 4, 5, 6], next])
        #expect(clean.records == tailed.records && clean.stats == tailed.stats)
        #expect(clean.records.count == 2)
    }

    /// The phase is found from the unit headers: 8 bytes of junk before the units give phase 8.
    @Test func phaseIsDetected() {
        let units = [S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 1, payload: Self.log(0xB0C0, 1))
            + [S.fillUnit()] + S.fragment(lane: 0, kind: 1, payload: Self.log(0xB0C2, 2))
        let stream = [UInt8](repeating: 0xFF, count: 8) + units.flatMap { $0 }
        let out = Self.deframe([S.frames(Aligned.stream(stream, firstFrame: true))])
        #expect(out.stats.phase == 8)
        #expect(out.records.map(\.code) == [0xB0C0, 0xB0C2])
        #expect(out.stats.counters["u_fill"] == 1)
    }

    /// find_phase's exact bounds: i in [p, min(len - 16, p + 320_000)). The unit at len - 16 never counts, and the
    /// first maximum wins, so phase 3's extra header in the last unit does not beat phase 0.
    @Test func findPhaseExcludesTheLastUnit() {
        var s = [UInt8](repeating: 0xFF, count: 35)
        s[0] = 0x13; s[1] = 0x01; s[2] = 0x20; s[3] = 0x03      // p = 0 and p = 3 each see one header inside
        s[19] = 0x13                                              // the header at len - 16, for p = 3
        #expect(s.withUnsafeBufferPointer { QdssDeframer.findPhase($0) } == 0)
        // With one more byte the unit at 19 is inside the range and phase 3 wins.
        s.append(0xFF)
        #expect(s.withUnsafeBufferPointer { QdssDeframer.findPhase($0) } == 3)
        // Too short for any unit: phase 0.
        #expect([UInt8](repeating: 0x13, count: 16).withUnsafeBufferPointer { QdssDeframer.findPhase($0) } == 0)
        #expect(QdssDeframer.phaseBytes == 320_031)
    }

    /// First, middle and last fragments on one channel make one message.
    @Test func firstMiddleLastAreGathered() {
        let packet = Self.log(0xB821, 4, Self.bytes(90))
        let parts = [Array(packet[0..<30]), Array(packet[30..<70]), Array(packet[70...])]
        let units = [S.channelUnit(lane: 1, channel: 9)] + S.fragment(lane: 1, kind: 3, payload: parts[0])
            + S.fragment(lane: 1, kind: 4, payload: parts[1]) + S.fragment(lane: 1, kind: 5, payload: parts[2])
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.records.count == 1 && out.records[0].body == Self.bytes(90))
        #expect(out.stats.counters["messages"] == 1)
        #expect(out.stats.fragmentKinds == ["3": 1, "4": 1, "5": 1])
    }

    /// A new first or whole fragment while a run is open emits the run as it stands ("unterminated").
    @Test func openRunIsFlushedUnterminated() {
        let units = [S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 3, payload: Self.log(0xB0C0, 1))
            + S.fragment(lane: 0, kind: 1, payload: Self.log(0xB0C1, 2))
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.stats.counters["gather_flushed_unterminated"] == 1)
        #expect(out.stats.counters["messages_unterm"] == 1 && out.stats.counters["messages"] == 1)
        #expect(out.stats.packets == ["log_unterm": 1, "log": 1])
        #expect(out.records.map(\.code) == [0xB0C0, 0xB0C1])
    }

    /// A run still open at the end is emitted after the stream, counted as left open.
    @Test func runLeftOpenAtTheEnd() {
        let units = [S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 3, payload: Self.log(0xB0C0, 1))
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.stats.counters["gather_left_open"] == 1 && out.stats.counters["messages_unterm"] == 1)
        #expect(out.records.count == 1)
    }

    @Test func orphansAreCounted() {
        let units = [S.channelUnit(lane: 0, channel: 1), [0x03] + [UInt8](repeating: 0, count: 15)]
            + S.fragment(lane: 0, kind: 4, payload: Self.log(0xB0C0, 1)).prefix(1)
            + [[0x0F] + [UInt8](repeating: 0, count: 15)]
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.stats.counters["u_cont_orphan"] == 1)
        #expect(out.stats.counters["gather_orphan_kind4"] == 1)
        #expect(out.stats.counters["u_badtype"] == 1)
        #expect(out.records.isEmpty)
    }

    /// QShrink F3 fragments (kind 2) are counted and never decoded.
    @Test func qshrinkIsSkipped() {
        let units = [S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 2, payload: Self.bytes(30))
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.stats.counters["qshrink_f3"] == 1 && out.records.isEmpty && out.stats.packets.isEmpty)
    }

    /// 98 01 00 00 containers are split into their log packets.
    @Test func multiContainersAreSplit() {
        let msg = S.multi([Self.log(0xB0C0, 1), Self.log(0xB0C1, 2, Self.bytes(20))])
        let out = Self.deframe([Self.chunk([S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 1, payload: msg))])
        #expect(out.records.map(\.code) == [0xB0C0, 0xB0C1])
        #expect(out.stats.packets == ["log": 2])
    }

    /// classify(): secure packets go to the census only, bare records are kept, and messages, QSR4, events and
    /// commands are counted by name.
    @Test func packetsAreClassified() {
        let msgs: [[UInt8]] = [
            S.securePacket(code: 0xB8DD, ts: S.ts(1), body: Self.bytes(10)),
            S.barePacket(code: 0xB193, ts: S.ts(2), body: [9, 9]),
            [0x79, 1, 2, 3], [0x99, 0, 0], [0x60, 5], [0x9D, 1],
            [0x10, 0, 1, 2],                                     // a log packet too short: log_bad
            [0x42, 0, 0],                                        // other_0x42
        ]
        var units = [S.channelUnit(lane: 0, channel: 1)]
        for m in msgs { units += S.fragment(lane: 0, kind: 1, payload: m) }
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.secure == [SecureRecord(code: 0xB8DD, timestampRaw: S.ts(1))])
        #expect(out.records == [LogRecord(code: 0xB193, timestampRaw: S.ts(2), body: [9, 9])])
        #expect(out.stats.packets == ["secure": 1, "bare": 1, "extmsg_0x79": 1, "qsr4_0x99": 1, "event_0x60": 1,
                                      "cmd_0x9d": 1, "log_bad": 1, "other_0x42": 1])
        #expect(out.census == EncryptedCensus(records: 1, codes: 1, byCode: ["0xB8DD": 1]))
    }

    /// Records sort by effective timestamp; one without a plausible timestamp inherits its channel's last one,
    /// and ties keep emission order.
    @Test func effectiveTimestampOrder() {
        let units = [S.channelUnit(lane: 0, channel: 1), S.channelUnit(lane: 1, channel: 2)]
            + S.fragment(lane: 0, kind: 1, payload: Self.log(0xA000, 500))
            + S.fragment(lane: 1, kind: 1, payload: Self.log(0xB000, 100))
            + S.fragment(lane: 0, kind: 1, payload: S.logPacket(code: 0xA001, ts: 0, body: [1]))  // inherits 500
            + S.fragment(lane: 1, kind: 1, payload: Self.log(0xB001, 600))
            + S.fragment(lane: 1, kind: 1, payload: S.logPacket(code: 0xB002, ts: 7, body: [1]))  // implausible: 600
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.records.map(\.code) == [0xB000, 0xA000, 0xA001, 0xB001, 0xB002])
        #expect(out.stats.ts == ["2026": 3, "zero": 1, "other": 1])
    }

    /// Lanes bound to different channels interleave without mixing; a lane rebound to a channel continues it.
    @Test func channelsDemuxIndependently() {
        let a = S.fragment(lane: 0, kind: 1, payload: Self.log(0xA000, 1, Self.bytes(60, seed: 1)))
        let b = S.fragment(lane: 1, kind: 1, payload: Self.log(0xB000, 2, Self.bytes(60, seed: 2)))
        var units = [S.channelUnit(lane: 0, channel: 1), S.channelUnit(lane: 1, channel: 2), a[0], b[0]]
        for i in 1..<max(a.count, b.count) {
            if i < a.count { units.append(a[i]) }
            if i < b.count { units.append(b[i]) }
        }
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.records.map(\.body) == [Self.bytes(60, seed: 1), Self.bytes(60, seed: 2)])
    }

    /// A start on a key that is still open closes the open fragment first (short when it had too few units).
    @Test func newStartClosesTheOpenFragment() {
        let long = S.fragment(lane: 0, kind: 1, payload: Self.log(0xA000, 1, Self.bytes(100)))
        let units = [S.channelUnit(lane: 0, channel: 1)] + long.prefix(3) + S.fragment(lane: 0, kind: 1, payload: Self.log(0xB000, 2))
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.stats.fits["short"] == 1 && out.stats.fits["exact"] == 1)
        #expect(out.stats.fits["count_mismatch"] == 1)
        #expect(out.stats.counters["messages_incomplete"] == 1)
        // The cut packet's length fields no longer match its bytes: counted as log_bad, not kept.
        #expect(out.stats.packets == ["log_bad": 1, "log": 1])
        #expect(out.records.map(\.code) == [0xB000])
    }

    /// Extra continuation units beyond the length: fits 'extra_units' and a count mismatch.
    @Test func extraUnitsAreCounted() {
        let units = [S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 1, payload: Self.log(0xA000, 1))
            + [[0x03] + [UInt8](repeating: 0x44, count: 15)]
        let out = Self.deframe([Self.chunk(units)])
        #expect(out.stats.fits == ["extra_units": 1, "count_mismatch": 1])
        #expect(out.records.count == 1)
    }

    /// The stats encode with qdss_deframe.py's snake_case keys.
    @Test func statsUseThePythonKeys() throws {
        let out = Self.deframe([Self.chunk([S.channelUnit(lane: 0, channel: 1)] + S.fragment(lane: 0, kind: 1,
                                                                                            payload: Self.log(0xB0C0, 1)))])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(out.stats)) as? [String: Any] ?? [:]
        #expect(Set(json.keys) == ["atid32_bytes", "chunks", "stats", "fits", "fragment_kinds", "packets", "log_records",
                                   "distinct_codes", "ts", "incomplete_records", "targets", "top_codes"])
        #expect((json["stats"] as? [String: Int])?["u_start"] == 1)
        #expect((json["top_codes"] as? [[Any]])?.first?.first as? String == "0xB0C0")
        #expect((json["targets"] as? [String: Int])?["0xB0C0"] == 1)
    }

    /// writeQmdl frames each record as HDLC (escaping 7E and 7D) and reads back to the same records.
    @Test func qmdlRoundTrips() throws {
        let records = [LogRecord(code: 0xB0C0, timestampRaw: S.ts(1), body: [0x7E, 0x7D, 0x00, 0x7E]),
                       LogRecord(code: 0xB821, timestampRaw: S.ts(2), body: Self.bytes(300), more: 1)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-wp3-\(UUID().uuidString).qmdl")
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try Qdss.writeQmdl(records, to: url)
        let data = try Data(contentsOf: url)
        let md5 = try Qdss.md5(of: url)
        #expect(written.bytes == data.count && written.md5 == md5)
        let read = DiagProtocol.readQmdl(data)
        #expect(read.crcErrors == 0)
        // 'more' is always written as 0, as the Python does.
        #expect(read.records == records.map { var r = $0; r.more = 0; return r })
        var expected: [UInt8] = []
        for r in records {
            var p = r
            p.more = 0
            expected += Hdlc.encode(DiagProtocol.encodeLogPacket(p))
        }
        #expect([UInt8](data) == expected)
    }

    /// Only 0x*.bin chunk files are fed, in name order; header.qmdl2 and AppleDouble twins are not.
    @Test func deframeReadsOnlyChunksInNameOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-wp3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let chunks = Archives.chunks()
        try Data(chunks[1]).write(to: dir.appendingPathComponent("0x00000002.bin"))
        try Data(chunks[0]).write(to: dir.appendingPathComponent("0x00000001.bin"))
        try Data([UInt8](repeating: 0x13, count: 204)).write(to: dir.appendingPathComponent("._0x00000001.bin"))
        try Data([UInt8](repeating: 0x13, count: 77)).write(to: dir.appendingPathComponent("header.qmdl2"))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let out = try Qdss.deframe(chunkFiles: files)
        #expect(out.stats.chunks == 2)
        #expect(out.records.map(\.code) == [0xB0C0, 0xB0C1, 0xB821])
        #expect(out == Self.deframe(chunks))
    }
}
