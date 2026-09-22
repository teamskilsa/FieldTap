import Foundation
import Testing
import FTTestSupport
@testable import FTModel

/// The shared types decode the contract fixtures as they are, and persist without loss.
@Suite struct ModelCodingTests {
    @Test func captureSummaryRoundTripsThroughJSON() throws {
        var s = GuideStateTests.summary(profile: GuideStateTests.profile(removalIn: 86_400 * 6),
                                        problems: [.profileExpired(GuideStateTests.now), .lowDiskSpace(needBytes: 600_000_000)])
        s.preview = JourneyPreview(segments: [PreviewSegment(band: "B66", startMs: 2415.5, endMs: 15_083.2)], nr: true, failures: 0)
        s.traceWindowAfterPressMs = TraceWindow(startMs: 19_000, endMs: 46_844)
        s.overwrittenFiles = 111
        s.secure = EncryptedCensus(records: 23_764, codes: 61, byCode: ["0xB8DD": 12])
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        #expect(try d.decode(CaptureSummary.self, from: e.encode(s)) == s)
        #expect(s.traceWindowAfterPressMs?.durationMs == 27_844)
    }

    @Test(.fixture("contract/phy-summary.json"))
    func phySummaryDecodesTheContractFixture() throws {
        let p = try JSONDecoder().decode(PhySummary.self, from: Fixtures.data("contract/phy-summary.json"))
        #expect(p.scellActivity.map(\.index) == [1, 2, 3])
        #expect(p.scellActivity.map(\.earfcn) == [650, 975, 67_086])
        #expect(p.nrDlActivity?.earfcn == 174_770 && p.nrDlActivity?.records == 497)
        #expect(p.rach.map(\.ta) == [18, 13, 19])
        #expect(p.rach.allSatisfy { $0.preambleTargetDbm == nil })
        #expect(p.txAntennasMib == [4])
        #expect(p.rxAntennasByEarfcn["67086"] == ["4": 780, "2": 99, "1": 17])
        #expect(p.encrypted == EncryptedCensus(records: 23_764, codes: 61))
        #expect(!p.isEmpty && PhySummary.empty.isEmpty)
    }

    /// The golden is the contract for the reference extractor's 48 KPIs, which are the first 48 metrics and keep
    /// their names; the series added after it (0xB126, 0xB12A, 0xB16C, 0xB179, 0xB063, 0x184C) are not in it.
    @Test(.fixture("contract/phy-golden.json"))
    func phyMetricsAreExactlyThePhyGoldenKeys() throws {
        let json = try JSONSerialization.jsonObject(with: Fixtures.data("contract/phy-golden.json")) as? [String: Any]
        let kpis = try #require(json?["kpis"] as? [String: Any])
        #expect(Set(kpis.keys) == Set(PhyMetric.referenceKpis.map(\.rawValue)))
        #expect(PhyMetric.referenceKpis.count == 48)
        #expect(Set(PhyMetric.addedAfterReference).isDisjoint(with: Set(PhyMetric.referenceKpis)))
        #expect(PhyMetric.addedAfterReference.count == 22)
        #expect(PhyMetric.allCases.count == 70)
    }

    @Test(.fixture("qdss-full-stats.json"))
    func deframeStatsDecodeThePythonStats() throws {
        let s = try JSONDecoder().decode(DeframeStats.self, from: Fixtures.data("qdss-full-stats.json"))
        #expect(s.atid32Bytes == 124_618_275 && s.chunks == 130 && s.phase == 8)
        #expect(s.logRecords == 92_133 && s.distinctCodes == 224)
        #expect(s.packets["secure"] == 23_764 && s.counters["u_start"] == 1_128_612)
        #expect(s.topCodes.first == DeframeStats.CodeCount(code: "0x1375", count: 10_934))
        // And writes the same keys back.
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]
        #expect(Set(DeframeStats.comparedKeys).isSubset(of: Set(back?.keys.map { $0 } ?? [])))
    }

    @Test func pendingNrCellsAndHashableModel() {
        #expect(Cell(earfcn: 174_770, pci: 0xFFFF, nr: true).isPendingNr)
        #expect(Cell(earfcn: 0xFFFF_FFFF, pci: 80, nr: true).isPendingNr)
        #expect(!Cell(earfcn: 0xFFFF_FFFF, pci: 80, nr: false).isPendingNr, "an LTE cell is never pending")
        let step = Step(move: .HANDOVER, from: Cell(earfcn: 67_086, pci: 80), to: Cell(earfcn: 5_110, pci: 235), event: 82,
                        sinceStartMs: 15_083.242)
        #expect(Set([step, step]).count == 1)
        #expect(Protection(headerType: 9, mac: 0, sequence: 0).headerName == "type 9")
    }

    @Test func journeyIdsAreUnique() {
        let m = [Marker(id: "handover-82", kind: .handover, tMs: 15_040, title: "Handover"),
                 Marker(id: "handover-95", kind: .handover, tMs: 21_600, title: "Handover")]
        #expect(Set(m.map(\.id)).count == 2)
        #expect(Severity.failure > Severity.warning && Severity.warning > Severity.info)
        #expect(Journey.empty.markers.isEmpty && PhyCapture.empty.series.isEmpty && Flow.empty.failures == 0)
    }
}
