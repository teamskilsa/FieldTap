// PhyExtractor.extract over the whole capture. The bound applies to release builds
// (test-kit.sh --release --filter 'FTPhyTests.*performance'); debug runs only report the time.

import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTPhy

@Suite(.serialized) struct PerformanceTests {
    @Test(.fixture(RealCapture.qmdl)) func performanceOfExtractOverTheCapture() throws {
        guard Fixtures.require(RealCapture.qmdl) != nil, let l = RealCapture.loaded else { return }
        #expect(l.records.count == 92_133)
        var times: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let capture = PhyExtractor.extract(records: l.records, timeBase: l.timeBase, secure: RealCapture.census)
            let d = ContinuousClock.now - start
            times.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            #expect(capture.series[.lte_dl_mcs]?.samples.count == 3_303)
        }
        let median = times.sorted()[times.count / 2]
        print("PhyExtractor.extract over \(l.records.count) records: median \(String(format: "%.3f", median)) s of \(times.map { String(format: "%.3f", $0) })")
        #if DEBUG
        #expect(median < 60, "debug build")
        #else
        #expect(median < 1.5, "median \(median) s")
        #endif
    }
}
