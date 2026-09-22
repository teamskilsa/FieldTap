// The iPhone 17 capture and the contract fixtures, loaded once for every parity test (git-ignored, from
// ios/Fixtures/local; see ios/Contract/CONTRACT.md, PHY parity).

import Foundation
import FTCore
import FTModel
import FTTestSupport
@testable import FTPhy

enum RealCapture {
    static let qmdl = "iphone-recovered.qmdl"
    static let golden = "contract/phy-golden-v1.json"
    static let summary = "contract/phy-summary-v1.json"
    /// The reference extractor's own copy of the TS 36.213 tables (regen_phy_v1.py writes it from tbs.py).
    static let tbsReference = "reference-phy/lte-tbs-reference.json"
    static let census = EncryptedCensus(records: 23_764, codes: 61)

    struct Loaded: Sendable {
        var records: [LogRecord]
        var timeBase: TimeBase
        /// The extraction against the reference's TBS table, as the reference extractor ran.
        var run: PhyRun
    }

    /// Nil when the fixtures are missing (the test then fails through Fixtures.require).
    static let loaded: Loaded? = {
        guard let q = Fixtures.url(qmdl), let data = try? Data(contentsOf: q, options: .mappedIfSafe),
              let table = referenceTable() else { return nil }
        let read = DiagProtocol.readQmdl(data)
        let timeBase = TimeBase.of(read.records)
        let run = PhyExtractor.run(records: read.records, timeBase: timeBase, secure: census, tbs: table)
        return Loaded(records: read.records, timeBase: timeBase, run: run)
    }()

    static func referenceTable() -> LteTbsLookup? {
        guard let url = Fixtures.url(tbsReference), let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["tbs"] as? [[Int]] else { return nil }
        return LteTbsLookup(rows: rows.map { $0.map(Int32.init) })
    }

    static func json(_ relative: String) -> [String: Any]? {
        guard let url = Fixtures.url(relative), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
