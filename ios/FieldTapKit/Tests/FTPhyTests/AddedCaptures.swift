// Both iPhone 17 captures, loaded once, for the decoders added after the reference extractor. The stationary
// capture (iphone-recovered.qmdl) is the one the contract goldens come from; the driving one
// (capture2/capture2.qmdl) is the second, independent capture every layout in
// docs/research/iphone-named-log-codes.md was validated against. Both are git-ignored fixtures.

import Foundation
import FTCore
import FTModel
import FTTestSupport
@testable import FTPhy

enum AddedCaptures {
    static let stationary = "iphone-recovered.qmdl"
    static let driving = "capture2/capture2.qmdl"

    struct Loaded: Sendable {
        var name: String
        var records: [LogRecord]
        var timeBase: TimeBase
        var run: PhyRun
        var stats: PhyStats { run.stats }
        var capture: PhyCapture { run.capture }

        func check(_ id: String) -> PhyCheck? { capture.checks.first { $0.id == id } }
        func samples(_ m: PhyMetric) -> [PhySample] { capture.series[m]?.samples ?? [] }
    }

    static func load(_ relative: String) -> Loaded? {
        guard let url = Fixtures.url(relative), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        let read = DiagProtocol.readQmdl(data)
        let timeBase = TimeBase.of(read.records)
        let run = PhyExtractor.run(records: read.records, timeBase: timeBase, secure: .empty, tbs: .builtIn)
        return Loaded(name: relative, records: read.records, timeBase: timeBase, run: run)
    }

    static let both: [Loaded] = [load(stationary), load(driving)].compactMap { $0 }
    static let stationaryRun: Loaded? = both.first { $0.name == stationary }
    static let drivingRun: Loaded? = both.first { $0.name == driving }
}
