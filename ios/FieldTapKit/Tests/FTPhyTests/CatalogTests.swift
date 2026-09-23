import Testing
import FTModel
@testable import FTPhy

@Suite struct CatalogTests {
    @Test func catalogueListsEveryImpossibleAndPendingItem() {
        let ids = Set(PhyCatalog.entries.map(\.id))
        #expect(ids.count == PhyCatalog.entries.count, "ids are unique")
        for id in ["nrSinr", "nrFirmwareCsi", "nrPhyEncrypted", "lteSinr", "nrPerAntennaRsrp", "liveValues", "actualTxPower",
                   "continuousTa", "nrUlSchedule", "nrUlPower", "nrDci", "nrCsf", "nrLl1", "lteRxAgc", "lteDciPhich",
                   "lteDelaySpread", "lteUlAgcPower", "b134", "bsr", "gnssPosition"] {
            #expect(ids.contains(id), "\(id)")
        }
        // The codes that now decode have left the catalogue: 0xB126, 0xB179, 0xB063, 0xB12A and 0xB16C.
        for id in ["pdschDemapper", "intraFreqNeighbours", "lteDlMac"] { #expect(!ids.contains(id), "\(id)") }
        let decoded: Set<UInt16> = [0xB126, 0xB179, 0xB12A, 0xB16C, 0x184C, 0x1D0B]
        for e in PhyCatalog.entries where e.status == .notDecodedYet {
            #expect(Set(e.codes).isDisjoint(with: decoded), "\(e.id) lists a code that decodes")
        }
        func codes(_ id: String) -> [UInt16] { PhyCatalog.entries.first { $0.id == id }?.codes ?? [] }
        #expect(codes("nrSinr") == [0xB8DD] && codes("nrFirmwareCsi") == [0xB8E2])
        #expect(codes("nrUlSchedule") == [0xB883] && codes("nrUlPower") == [0xB884] && codes("nrDci") == [0xB885])
        #expect(codes("nrCsf") == [0xB8A7] && codes("lteDciPhich") == [0xB16B])
        // Every 5G uplink entry says what it needs: the payloads failed their checks, the timing did not.
        for id in ["nrUlSchedule", "nrUlPower", "nrDci", "nrCsf"] {
            let e = PhyCatalog.entries.first { $0.id == id }
            #expect(e?.reason.contains("sustained 5G upload") == true, "\(id)")
        }
        #expect(codes("gnssPosition") == CapturePrivacy.excludedCodeList)
        #expect(PhyCatalog.entries.allSatisfy { !$0.reason.isEmpty && $0.status != .available })
        #expect(PhyCatalog.entries.filter { $0.status == .encryptedByModem }.count == 3)
        #expect(PhyCatalog.entries.filter { $0.status == .excludedForPrivacy }.count == 1)
    }

    @Test func availabilityCountsThisCapture() {
        let a = PhyCatalog.availability(recordsPerCode: [0xB883: 633, 0x1476: 22],
                                        secure: EncryptedCensus(records: 23_764, codes: 61), tbsAvailable: false)
        #expect(a.first { $0.id == "nrUlSchedule" }?.reason.hasSuffix("This capture: 633 records.") == true)
        #expect(a.first { $0.id == "nrDci" }?.reason.hasSuffix("None in this capture.") == true)
        #expect(a.first { $0.id == "nrPhyEncrypted" }?.reason.contains("23,764 encrypted records across 61 codes") == true)
        #expect(a.contains { $0.id == "lteTbsTable" })
        #expect(!PhyCatalog.availability(recordsPerCode: [:], secure: .empty, tbsAvailable: true).contains { $0.id == "lteTbsTable" })
        // The location entry counts what it dropped, and says so either way.
        #expect(a.first { $0.id == "gnssPosition" }?.reason.hasSuffix("22 such records, counted and dropped.") == true)
        let none = PhyCatalog.availability(recordsPerCode: [:], secure: .empty, tbsAvailable: true)
        #expect(none.first { $0.id == "gnssPosition" }?.reason.hasSuffix("None are in what this capture kept.") == true)
    }
}
