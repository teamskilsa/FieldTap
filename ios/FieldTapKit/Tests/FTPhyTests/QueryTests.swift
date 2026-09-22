import Testing
import FTModel
@testable import FTPhy

@Suite struct QueryTests {
    static func series(_ points: [(Double, Double?, Int)]) -> PhySeries {
        var s = PhyMetric.lte_rsrp.emptySeries
        s.samples = points.map { PhySample(tMs: $0.0, value: $0.1, carrier: $0.2) }
        return s
    }

    @Test func latestRespectsAgeAndCarrier() {
        let s = Self.series([(100, -100, 0), (140, -90, 2), (180, -101, 0), (600, -99, 0)])
        #expect(PhyQuery.latest(s, atOrBefore: 190, maxAgeMs: 500)?.value == -101)
        #expect(PhyQuery.latest(s, atOrBefore: 190, maxAgeMs: 500, carrier: 2)?.value == -90)
        #expect(PhyQuery.latest(s, atOrBefore: 180, maxAgeMs: 500)?.tMs == 180, "at or before includes t")
        #expect(PhyQuery.latest(s, atOrBefore: 700, maxAgeMs: 50) == nil)
        #expect(PhyQuery.latest(s, atOrBefore: 90, maxAgeMs: 500) == nil)
        #expect(PhyQuery.latest(s, atOrBefore: 1_000, maxAgeMs: 500, carrier: 2) == nil)
    }

    @Test func binsReduceEachSecond() {
        let s = Self.series([(100, 1, 0), (900, 3, 0), (1_100, 10, 0), (1_200, nil, 0), (2_950, 4, 0)])
        #expect(PhyQuery.bins(s, widthMs: 1_000, reduce: .mean) == [PhyBin(tMs: 500, value: 2), PhyBin(tMs: 1_500, value: 10),
                                                                     PhyBin(tMs: 2_500, value: 4)])
        #expect(PhyQuery.bins(s, widthMs: 1_000, reduce: .sum).map(\.value) == [4, 10, 4])
        #expect(PhyQuery.bins(s, widthMs: 1_000, reduce: .count).map(\.value) == [2, 2, 1])
        #expect(PhyQuery.bins(s, widthMs: 1_000, reduce: .median).map(\.value) == [2, 10, 4])
    }

    @Test func timeShareSumsToOne() {
        let s = Self.series([(0, 1, 0), (10, 2, 0), (20, 2, 0), (30, 2, 0), (40, 1, 0), (5_000, 4, 0)])
        let share = PhyQuery.timeShare(s, window: 0...100)
        #expect(share == [1: 0.4, 2: 0.6])
        #expect(PhyQuery.timeShare(s, window: 200...300).isEmpty)
    }

    @Test func decimateKeepsExtremesAndOrder() {
        var points: [(Double, Double?, Int)] = []
        for i in 0..<10_000 {
            let v: Double = i % 97 == 0 ? -140 : Double(-100 - i % 7)
            points.append((Double(i), v, 0))
        }
        let s = Self.series(points)
        let d = PhyQuery.decimate(s.samples, window: 0...9_999, maxPoints: 1_500)
        #expect(d.count <= 1_500 && d.count > 900)
        #expect(zip(d, d.dropFirst()).allSatisfy { $0.tMs < $1.tMs })
        #expect(d.filter { $0.value == -140 }.count >= 90, "the dips survive")
        #expect(PhyQuery.decimate(s.samples, window: 10...19).count == 10, "a small window is returned as is")
    }
}
