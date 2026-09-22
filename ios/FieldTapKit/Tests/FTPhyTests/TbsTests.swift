// The TS 36.213 and TS 38.214 transport block sizes.

import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTPhy

@Suite struct TbsTests {
    /// The committed table against the reference extractor's copy, cell by cell (I_TBS 0-26 and the Rel-12 rows
    /// 27-33, N_PRB 1-110). Until LteTbsTable.swift has been generated from TS 36.213 this is a known issue.
    @Test(.fixture(RealCapture.tbsReference)) func lteTbsTableEqualsReference() throws {
        guard Fixtures.require(RealCapture.tbsReference) != nil, let reference = RealCapture.referenceTable() else { return }
        #expect(reference.rows.count == 34 && reference.rows.allSatisfy { $0.count == 110 })
        guard LteTbs.isAvailable else {
            withKnownIssue("LteTbsTable.swift is not generated yet: run gen_lte_tbs.py on the TS 36.213 .docx") {
                Issue.record("no committed TS 36.213 table")
            }
            return
        }
        var differing: [String] = []
        for i in 0..<34 {
            for n in 1...110 where LteTbs.bits(iTbs: i, nPrb: n) != reference.bits(iTbs: i, nPrb: n) {
                differing.append("(\(i), \(n))")
            }
        }
        #expect(differing.isEmpty, "\(differing.count) cells differ: \(differing.prefix(10))")
    }

    @Test(.fixture(RealCapture.tbsReference)) func lteLookupsFollowTheMcsTables() throws {
        guard Fixtures.require(RealCapture.tbsReference) != nil, let t = RealCapture.referenceTable() else { return }
        #expect(t.bits(iTbs: 20, nPrb: 50) == 22_920)
        #expect(t.bits(iTbs: 0, nPrb: 3) == 56)
        #expect(t.bits(iTbs: 0, nPrb: 0) == nil && t.bits(iTbs: 34, nPrb: 1) == nil && t.bits(iTbs: 0, nPrb: 111) == nil)
        // MCS 28 on the 64QAM table is I_TBS 26; MCS 27 on the 256QAM table is I_TBS 33.
        #expect(t.dl(mcs: 28, nPrb: 50, layers: 1, table256: false) == t.bits(iTbs: 26, nPrb: 50))
        #expect(t.dl(mcs: 27, nPrb: 25, layers: 1, table256: true) == t.bits(iTbs: 33, nPrb: 25))
        // Two layers read the 2 x N_PRB column up to 55 PRB, and nothing beyond.
        #expect(t.dl(mcs: 10, nPrb: 50, layers: 2, table256: false) == t.bits(iTbs: 9, nPrb: 100))
        #expect(t.dl(mcs: 10, nPrb: 56, layers: 2, table256: false) == nil)
        #expect(t.dl(mcs: 29, nPrb: 50, layers: 1, table256: false) == nil)
        // PUSCH: MCS 10 (QPSK) and 11 (16QAM) share I_TBS 10, so the modulation picks one.
        let size = t.bits(iTbs: 10, nPrb: 20)!
        #expect(t.ulMcs(bits: size, nPrb: 20, qm: 2).mcs == [10])
        #expect(t.ulMcs(bits: size, nPrb: 20, qm: 4).mcs == [11])
        #expect(t.ulMcs(bits: size + 8, nPrb: 20, qm: 2).matchesTable == false)
    }

    @Test func lteMcsTablesAreTheSpecifications() {
        #expect(LteTbs.dlMcsToITbs.count == 29 && LteTbs.dlMcs256ToITbs.count == 28 && LteTbs.ulMcsToITbs.count == 29)
        #expect(LteTbs.dlMcsToITbs[9] == 9 && LteTbs.dlMcsToITbs[10] == 9 && LteTbs.dlMcsToITbs[17] == 15)
        #expect(LteTbs.dlMcs256ToITbs[20] == 25 && LteTbs.dlMcs256ToITbs[21] == 27)
        #expect(LteTbs.ulMcsToITbs[10] == 10 && LteTbs.ulMcsToITbs[11] == 10 && LteTbs.ulMcsToITbs[21] == 19)
        #expect(LteTbs.ulQm(mcs: 10) == 2 && LteTbs.ulQm(mcs: 11) == 4 && LteTbs.ulQm(mcs: 21) == 6 && LteTbs.ulQm(mcs: 29) == nil)
    }

    @Test func nrTbsFollows38214() {
        // Worked through 5.1.3.2: the small-size table path, the quantised path, and code-block segmentation.
        #expect(NrTbs.bytes(mcs: 0, table: .qam256, nPrb: 52, layers: 1, nRePerPrb: 150) == 1_864 / 8)
        #expect(NrTbs.bytes(mcs: 5, table: .qam256, nPrb: 4, layers: 1, nRePerPrb: 120) == 704 / 8)
        #expect(NrTbs.bytes(mcs: 9, table: .qam256, nPrb: 1, layers: 1, nRePerPrb: 144) == 352 / 8)
        #expect(NrTbs.bytes(mcs: 13, table: .qam256, nPrb: 52, layers: 1, nRePerPrb: 132) == 22_536 / 8)
        #expect(NrTbs.bytes(mcs: 19, table: .qam256, nPrb: 45, layers: 2, nRePerPrb: 138) == 63_528 / 8)
        #expect(NrTbs.bytes(mcs: 20, table: .qam256, nPrb: 52, layers: 2, nRePerPrb: 156) == 86_040 / 8)
        #expect(NrTbs.bytes(mcs: 27, table: .qam256, nPrb: 52, layers: 2, nRePerPrb: 144) == 110_632 / 8)
        #expect(NrTbs.bytes(mcs: 28, table: .qam64, nPrb: 273, layers: 4, nRePerPrb: 144) == 868_584 / 8)
        #expect(NrTbs.bytes(mcs: 0, table: .qam64LowSe, nPrb: 10, layers: 1, nRePerPrb: 144) == 80 / 8)
        // N'RE above 156 counts as 156; reserved MCS indexes have no size.
        #expect(NrTbs.bytes(mcs: 20, table: .qam256, nPrb: 52, layers: 2, nRePerPrb: 168) == 86_040 / 8)
        #expect(NrTbs.bytes(mcs: 28, table: .qam256, nPrb: 52, layers: 1, nRePerPrb: 144) == nil)
        #expect(NrMcsTable.qam256.qm(mcs: 28) == 2 && NrMcsTable.qam256.qm(mcs: 31) == 8 && NrMcsTable.qam64.qm(mcs: 31) == 6)
        #expect(NrMcsTable.qam256.qm(mcs: 32) == nil)
        #expect(NrTbs.smallSizes.count == 93 && NrTbs.table1.count == 29 && NrTbs.table2.count == 28 && NrTbs.table3.count == 29)
    }
}
