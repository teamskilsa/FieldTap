// Port of android/diag/src/test/kotlin/com/fieldtap/diag/CellInfoTest.kt (2 tests).

import Testing
import FTModel
@testable import FTSignalling

/// The serving-cell record of the lab callbox, read off a real capture.
@Suite struct CellInfoTests {
    private let callbox = hex("0308009c 180000ec 5e000064 6408d0a2 01010014 00000001 00020100 00")

    @Test func theCallboxCellIsReadWhole() throws {
        // The same record as `fieldtap/decode/cellinfo.py` reads: PCI 8 on B20, PLMN 001-01, TAC 1.
        let cell = try #require(CellInfo.serving(callbox))
        #expect(cell.pci == 8)
        #expect(cell.downlinkEarfcn == 6_300)
        #expect(cell.uplinkEarfcn == 24_300)
        #expect(cell.band == 20)
        #expect(cell.plmn == "001-01")
        #expect(cell.tac == 1)
        #expect(cell.cellIdentity == 27_447_304)
        #expect(cell.enb == 107_216)
        #expect(cell.sector == 8)
        // 100 resource blocks is 20 MHz.
        #expect(cell.bandwidthMhz == 20.0)
    }

    @Test func aRecordThatDoesNotFitTheLayoutIsRefusedRatherThanGuessedAt() {
        #expect(CellInfo.serving([]) == nil)
        #expect(CellInfo.serving(hex("03")) == nil)
        // A PCI of 4095 and band 0: the layout does not fit, so there is nothing honest to report.
        #expect(CellInfo.serving(hex("03ff0f9c 180000ec 5e000064 6408d0a2 01010000 00000001 00020100 00")) == nil)
    }
}
