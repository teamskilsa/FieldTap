import Testing
import FTModel
@testable import FTPhy

@Suite struct CatalogTests {
    @Test func catalogueListsEveryImpossibleAndPendingItem() {
        let ids = Set(PhyCatalog.entries.map(\.id))
        #expect(ids.count == PhyCatalog.entries.count, "ids are unique")
        for id in ["nrSinr", "nrFirmwareCsi", "nrPhyEncrypted", "lteSinr", "nrPerAntennaRsrp", "liveValues", "actualTxPower",
                   "continuousTa", "nrUlSchedule", "nrUlPower", "nrDci", "nrCsf", "nrLl1", "lteDlMac", "pdschDemapper",
                   "lteRxAgc", "lteDciPhich", "intraFreqNeighbours", "b134", "bsr"] {
            #expect(ids.contains(id), "\(id)")
        }
        func codes(_ id: String) -> [UInt16] { PhyCatalog.entries.first { $0.id == id }?.codes ?? [] }
        #expect(codes("nrSinr") == [0xB8DD] && codes("nrFirmwareCsi") == [0xB8E2])
        #expect(codes("nrUlSchedule") == [0xB883] && codes("nrUlPower") == [0xB884] && codes("nrDci") == [0xB885])
        #expect(codes("nrCsf") == [0xB8A7] && codes("lteDlMac") == [0xB063] && codes("pdschDemapper") == [0xB126])
        #expect(PhyCatalog.entries.allSatisfy { !$0.reason.isEmpty && $0.status != .available })
        #expect(PhyCatalog.entries.filter { $0.status == .encryptedByModem }.count == 3)
    }

    @Test func availabilityCountsThisCapture() {
        let a = PhyCatalog.availability(recordsPerCode: [0xB883: 633], secure: EncryptedCensus(records: 23_764, codes: 61),
                                        tbsAvailable: false)
        #expect(a.first { $0.id == "nrUlSchedule" }?.reason.hasSuffix("This capture: 633 records.") == true)
        #expect(a.first { $0.id == "nrDci" }?.reason.hasSuffix("None in this capture.") == true)
        #expect(a.first { $0.id == "nrPhyEncrypted" }?.reason.contains("23,764 encrypted records across 61 codes") == true)
        #expect(a.contains { $0.id == "lteTbsTable" })
        #expect(!PhyCatalog.availability(recordsPerCode: [:], secure: .empty, tbsAvailable: true).contains { $0.id == "lteTbsTable" })
    }
}
