// The modem's position records must not leave the phone. This proves it where it matters: a capture becomes a file
// exactly once, in CaptureStore.save, and that file is the only thing an export or a share can carry.
//
// 0x1476 is publicly named "GNSS Position Report" and the reference capture holds 105 of them at a steady 5 Hz
// across a 22 s drive — a position track, which is more identifying than the IMSI. It is dropped by log code, with
// the rest of that block and the two QMI links beside it, and only counted.

import Foundation
import Testing
import FTCore
import FTModel
import FTTestSupport
@testable import FTCapture

@Suite struct PrivacyExportTests {
    /// A body of `count` bytes that is recognisable in the written file.
    static func body(_ count: Int, fill: UInt8) -> [UInt8] { Array(repeating: fill, count: count) }

    static func records() -> [LogRecord] {
        var out: [LogRecord] = []
        var raw: UInt64 = 1
        func add(_ code: UInt16, _ fill: UInt8, _ n: Int = 1) {
            for _ in 0..<n {
                out.append(LogRecord(code: code, timestampRaw: raw << 16, body: body(40, fill: fill)))
                raw += 1
            }
        }
        // The codes the app decodes, interleaved with every excluded one (five of each, as a 5 Hz position report
        // would arrive).
        add(0xB193, 0x11, 3)
        for code in CapturePrivacy.excludedCodeList { add(code, 0x99, 5) }
        add(0xB173, 0x22, 3)
        add(0xB0C0, 0x33, 2)
        return out
    }

    func store() throws -> (CaptureStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-privacy-\(UUID().uuidString)", isDirectory: true)
        return (try CaptureStore(root: root), root)
    }

    /// Nothing of an excluded code is in the file the store writes, and everything else is.
    @Test func noExcludedRecordReachesTheCaptureFile() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = Self.records()
        let summary = CaptureSummary(importedAt: .now, sourceName: "test.tar.gz")
        let url = try store.save(records: all, summary: summary)

        // Read the file back the way the app does, and the way anything exporting it would.
        let written = DiagProtocol.readQmdl(try Data(contentsOf: url)).records
        let writtenCodes = Set(written.map(\.code))
        #expect(writtenCodes.isDisjoint(with: CapturePrivacy.excludedCodes), "\(writtenCodes.sorted())")
        for code in CapturePrivacy.excludedCodeList {
            #expect(!writtenCodes.contains(code), "\(Fmt.hex(code, width: 4)) is in the capture file")
        }
        // The excluded bodies are not in the bytes either, under any framing.
        let bytes = try Data(contentsOf: url)
        #expect(!bytes.contains(0x99), "an excluded record's body reached the file")
        // And nothing else was lost: every record of every other code is there.
        let kept = all.filter { !CapturePrivacy.isExcluded($0.code) }
        #expect(written.count == kept.count)
        #expect(written.map(\.code) == kept.map(\.code))
        #expect(written.map(\.timestampRaw) == kept.map(\.timestampRaw))
        // The same holds for what the store hands back, which is what every screen and every share text reads.
        let readBack = try store.records(for: summary.id)
        #expect(Set(readBack.map(\.code)).isDisjoint(with: CapturePrivacy.excludedCodes))
        #expect(readBack.count == kept.count)
    }

    /// A capture that is nothing but position records writes no capture file at all.
    @Test func aCaptureOfNothingButPositionRecordsWritesNoFile() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let only = CapturePrivacy.excludedCodeList.map {
            LogRecord(code: $0, timestampRaw: 1 << 16, body: Self.body(40, fill: 0x99))
        }
        let summary = CaptureSummary(importedAt: .now, sourceName: "test.tar.gz")
        let url = try store.save(records: only, summary: summary)
        #expect(!FileManager.default.fileExists(atPath: url.path), "no records to keep, so no capture file")
        #expect(try store.records(for: summary.id).isEmpty)
    }

    /// The filter itself: what it drops, what it counts, and the order it keeps.
    @Test func theFilterCountsWhatItDrops() {
        let all = Self.records()
        let (kept, dropped) = CapturePrivacy.filter(all)
        #expect(dropped == Dictionary(uniqueKeysWithValues: CapturePrivacy.excludedCodeList.map { ($0, 5) }))
        #expect(kept.count == all.count - 5 * CapturePrivacy.excludedCodeList.count)
        #expect(kept.map(\.code) == all.filter { !CapturePrivacy.isExcluded($0.code) }.map(\.code))
        // The list is the one the research names, and the GNSS position report itself is in it.
        #expect(CapturePrivacy.excludedCodes.contains(0x1476), "0x1476 is the GNSS position report")
        #expect(CapturePrivacy.excludedCodeList == [0x1391, 0x1476, 0x147C, 0x147D, 0x147E, 0x1544])
        #expect(CapturePrivacy.statement.contains("position"))
        // And nothing that is decoded is excluded by accident.
        #expect(CapturePrivacy.excludedCodeList.allSatisfy { LogCodes.of($0) == nil }, "none of them is a signalling code")
    }
}
