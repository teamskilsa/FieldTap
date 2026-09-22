import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTCapture

/// md5 parity with qdss_deframe.py on the capture-derived chunk subsets (Fixtures/local, git-ignored).
@Suite struct DeframerParityTests {
    static func chunkFiles(_ dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("chunks"), includingPropertiesForKeys: nil)
    }

    /// The deframer's stats as JSON objects, key by key, next to the Python's.
    static func expectStats(_ stats: DeframeStats, equal expected: [String: Any], keys: [String],
                            sourceLocation: SourceLocation = #_sourceLocation) throws {
        let mine = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stats)) as? [String: Any] ?? [:]
        for key in keys {
            let a = mine[key].map { $0 as AnyObject }
            let b = expected[key].map { $0 as AnyObject }
            #expect(a?.isEqual(b) == true, "stats.\(key): Swift \(String(describing: a)) vs Python \(String(describing: b))",
                    sourceLocation: sourceLocation)
        }
    }

    static func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    static func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ft-wp3-\(UUID().uuidString)-\(name)")
    }

    @Test(.fixture("qdss-first3/manifest.json")) func first3MatchesPython() throws {
        guard let dir = Fixtures.require("qdss-first3") else { return }
        let out = try Qdss.deframe(chunkFiles: Self.chunkFiles(dir))
        let qmdl = Self.temp("first3.qmdl")
        defer { try? FileManager.default.removeItem(at: qmdl) }
        let written = try Qdss.writeQmdl(out.records, to: qmdl)
        #expect(written.md5 == "8bee416586647da91511a952c527c272")
        #expect(written.bytes == 314_367)

        // The manifest's counters are the compared keys; stats.json adds the diagnostics.
        let manifest = try Self.json(dir.appendingPathComponent("manifest.json"))
        let counters = try #require(manifest["counters"] as? [String: Any])
        try Self.expectStats(out.stats, equal: counters, keys: DeframeStats.comparedKeys)
        let full = try Self.json(dir.appendingPathComponent("expected/stats.json"))
        try Self.expectStats(out.stats, equal: full, keys: ["incomplete_records", "targets", "top_codes"])

        #expect(out.stats.atid32Bytes == 2_885_648)
        #expect(out.stats.counters["u_start"] == 31_214 && out.stats.counters["u_cont"] == 115_144)
        #expect(out.stats.counters["u_chan"] == 31_220 && out.stats.counters["u_fill"] == 2_774)
        #expect(out.stats.counters["qshrink_f3"] == 22_672)
        #expect(out.stats.fits == ["exact": 31_213, "short": 1, "count_mismatch": 1])
        #expect(out.stats.packets["secure"] == 2_154 && out.stats.packets["log"] == 1_754)
        #expect(out.stats.packets["log_unterm"] == 26)
        #expect(out.stats.logRecords == 1_780 && out.stats.distinctCodes == 70)
        #expect(out.secure.count == 2_154)
    }

    @Test(.fixture("qdss-attach4/manifest.json")) func attach4MatchesPython() throws {
        guard let dir = Fixtures.require("qdss-attach4") else { return }
        let manifest = try Self.json(dir.appendingPathComponent("manifest.json"))
        let outputs = try #require(manifest["outputs"] as? [String: Any])
        let expectedMd5 = try #require((outputs["attach4.qmdl"] as? [String: Any])?["md5"] as? String)
        let out = try Qdss.deframe(chunkFiles: Self.chunkFiles(dir))
        let qmdl = Self.temp("attach4.qmdl")
        defer { try? FileManager.default.removeItem(at: qmdl) }
        let written = try Qdss.writeQmdl(out.records, to: qmdl)
        #expect(written.md5 == expectedMd5)
        #expect(out.records.count == 2_351)
        let counters = try #require(manifest["counters"] as? [String: Any])
        try Self.expectStats(out.stats, equal: counters, keys: DeframeStats.comparedKeys)
        #expect(out.stats.phase == 0)
    }

    /// The first three chunks fed in 50 random splits inside each chunk give exactly the same records and stats
    /// as whole chunks. Pieces are 1 byte to 64 KiB, with one in eight 1-17 bytes, so frames and units are cut
    /// at every offset without making the Debug run crawl.
    @Test(.fixture("qdss-first3/manifest.json")) func streamingSplitInvariance() throws {
        guard let dir = Fixtures.require("qdss-first3") else { return }
        let chunks = try Self.chunkFiles(dir)
            .filter { $0.lastPathComponent.hasPrefix("0x") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try [UInt8](Data(contentsOf: $0)) }
        var whole = QdssDeframer()
        for c in chunks { c.withUnsafeBytes { whole.feedChunk($0) } }
        let baseline = whole.finish()

        var rng = SplitMix64(seed: 0x5EED_F1E1_D7A9)
        for trial in 0..<50 {
            var d = QdssDeframer()
            for c in chunks {
                var i = 0
                while i < c.count {
                    let maxPiece: UInt64 = rng.next() % 8 == 0 ? 17 : 65_536
                    let n = min(c.count - i, 1 + Int(rng.next() % maxPiece))
                    c[i..<(i + n)].withUnsafeBytes { d.feed($0) }
                    i += n
                }
                d.endChunk()
            }
            let out = d.finish()
            #expect(out.stats == baseline.stats, "trial \(trial): stats differ")
            #expect(out.records == baseline.records, "trial \(trial): records differ")
            #expect(out.secure == baseline.secure, "trial \(trial): secure census differs")
            if out.records != baseline.records { break }
        }
    }
}

/// A small, seedable generator so a failing split can be replayed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
