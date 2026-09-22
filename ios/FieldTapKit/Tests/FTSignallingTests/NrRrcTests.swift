// Port of android/diag/src/test/kotlin/com/fieldtap/diag/NrRrcTest.kt (10 tests), plus the contract-v1 tests WP1
// adds there (D2: version 26 is layout E, PDU 11 and 12 are RRCReconfiguration and its complete).

import Testing
import FTCore
import FTModel
import FTTestSupport
@testable import FTSignalling

/// The NR RRC decoder on a real SM8450 capture (a 5G standalone registration attempt on a commercial n77 cell),
/// held to Wireshark's reading of the same bytes.
@Suite struct NrRrcTests {
    private static let nr: [NrRrc.Message]? = OnePlus.fiveG.map { read in
        read.records.filter { $0.code == 0xB821 }.compactMap { NrRrc.decode($0.body) }
    }

    private func messages() -> [NrRrc.Message]? {
        Fixtures.require(OnePlus.fiveGPath) != nil ? Self.nr : nil
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func theHeaderThisModemWritesIsNotTheOneTheTableExpects() {
        guard let nr = messages() else { return }
        // Packet version 17 with a 27-byte header. The Python table maps 17 to the 20-byte layout, which made
        // every record here read as an unmapped PDU type; the trailing length picks the right one instead.
        #expect(!nr.isEmpty)
        #expect(nr.count == OnePlus.fiveG?.records.count { $0.code == 0xB821 })
        #expect(nr.allSatisfy { $0.packetVersion == 17 })
        #expect(nr.allSatisfy { $0.asn1Name != nil && $0.channel != nil }, "every message named")
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func theCellsAndMessagesAreWiresharks() throws {
        guard let nr = messages() else { return }
        #expect(nr.map { "\($0.channel?.label ?? "?") \($0.asn1Name ?? "?")" } == [
            "BCCH-BCH mib", "BCCH-DL-SCH systemInformationBlockType1", "UL-CCCH rrcSetupRequest",
            "DL-CCCH rrcSetup", "UL-DCCH rrcSetupComplete", "DL-DCCH dlInformationTransfer",
            "DL-DCCH rrcRelease", "PCCH paging", "PCCH paging",
        ])
        // The registration was attempted on PCI 417, NR-ARFCN 647328 (n77); the paging came on another cell.
        #expect(nr.prefix(7).allSatisfy { $0.pci == 417 && $0.arfcn == 647_328 })
        #expect(nr.last?.pci == 152)
        #expect(nr.last?.arfcn == 501_390)
        // SRB1 for the dedicated messages, none for broadcast.
        #expect(nr.first { $0.asn1Name == "rrcSetupComplete" }?.bearerId == 1)
        let first = try #require(nr.first)
        #expect(first.bearerId == nil)
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func theSetupRequestFieldsAreWiresharks() throws {
        guard let nr = messages() else { return }
        // Wireshark: ue-Identity randomValue 0fe8e748c4, establishmentCause mo-Signalling (3).
        let request = try #require(nr.first { $0.asn1Name == "rrcSetupRequest" })
        let identity = try #require(request.fields.first { $0.label == "UE identity" })
        #expect(identity.value == "random value")
        #expect(identity.children.map(\.value) == ["0x" + "0fe8e748c4"])
        #expect(request.fields.value("Establishment cause") == "mo-Signalling")
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func theNasInsideTheRrcIsTheOnlyCopyAndComesOutWhole() throws {
        guard let nr = messages() else { return }
        // Wireshark: RRC Setup Complete carries dedicatedNAS-Message 7e004179...f070, a registration request.
        let complete = try #require(nr.first { $0.asn1Name == "rrcSetupComplete" })
        #expect(complete.fields.value("Selected PLMN") == "1")
        let carried = try #require(complete.nas)
        #expect(hexString(carried) == hexString(hex("7e004179 000d0100 f110f0ff 00001032 5476982e 04f070f0 70")))
        // And DL Information Transfer carries the registration reject.
        let transfer = try #require(nr.first { $0.asn1Name == "dlInformationTransfer" })
        let reject = try #require(transfer.nas)
        #expect(hexString(reject) == "7e00441b16012c")
        #expect(nr.first { $0.asn1Name == "rrcRelease" }?.nas == nil)
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func theNasReadsAsTheRegistrationItIs() throws {
        guard let nr = messages() else { return }
        let complete = try #require(nr.first { $0.asn1Name == "rrcSetupComplete" })
        let requestPdu = try #require(complete.nas)
        let request = try #require(Nas.decodePdu(requestPdu, nr: true))
        #expect(request.name == "Registration request")
        #expect(request.sublayer == "5gmm")
        let transfer = try #require(nr.first { $0.asn1Name == "dlInformationTransfer" })
        let rejectPdu = try #require(transfer.nas)
        let reject = try #require(Nas.decodePdu(rejectPdu, nr: true))
        #expect(reject.name == "Registration reject")
        #expect(reject.cause == 27)
        #expect(reject.causeName == "N1 mode not allowed")
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func aReleaseWithNoOptionsSaysNothingRatherThanGuessing() throws {
        guard let nr = messages() else { return }
        // Wireshark shows rrcRelease with no IEs at all.
        let release = try #require(nr.first { $0.asn1Name == "rrcRelease" })
        #expect(release.fields.isEmpty)
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func thePagedIdentityIsWiresharks() throws {
        guard let nr = messages() else { return }
        // Wireshark: one paging record, ue-Identity ng-5G-S-TMSI 400cc6e89880.
        let paging = try #require(nr.first { $0.asn1Name == "paging" })
        let paged = try #require(paging.fields.first { $0.label == "Paged" })
        #expect(paged.value == "1")
        #expect(paged.children == [Field(label: "5G-S-TMSI", value: "0x" + "400cc6e89880")])
    }

    @Test func aSuspendingReleaseAndARejectAreReadFromConstructedBytes() {
        // Constructed; Wireshark: rrcRelease with suspendConfig, and rrcReject waitTime 4.
        #expect(NrRrc.Details.of("rrcRelease", hex("1020")) == [Field(label: "Carries", value: "suspend (RRC inactive)")])
        #expect(NrRrc.Details.of("rrcReject", hex("0860")) == [Field(label: "Wait time", value: "4 s")])
    }

    @Test func namesReadLikeTheSpec() {
        #expect(NrRrc.readable("rrcSetupComplete") == "RRC Setup Complete")
        #expect(NrRrc.readable("dlInformationTransfer") == "DL Information Transfer")
        #expect(NrRrc.readable("mib") == "MIB")
        #expect(NrRrc.readable("systemInformationBlockType1") == "SIB1")
        #expect(NrRrc.readable("mobilityFromNRCommand") == "Mobility From NR Command")
    }

    @Test func aRecordTooShortForAnyHeaderIsNotDecoded() {
        #expect(NrRrc.decode([UInt8](repeating: 0, count: 8)) == nil)
    }

    // MARK: - Contract v1 (D2), with the inputs of WP1's Kotlin tests of the same names

    /// A version-26 (iPhone 17) record: 4-byte version, then layout E, 31 bytes: rb, PCI, eight bytes before the
    /// NR-ARFCN, the PDU number, the length, and four reserved bytes after it.
    private func v26(_ pdu: Int, _ payload: [UInt8]) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 4 + 31)
        body[0] = 26
        func put(_ at: Int, _ v: Int64, _ width: Int) {
            for i in 0..<width { body[4 + at + i] = UInt8(truncatingIfNeeded: v >> (8 * Int64(i))) }
        }
        put(2, 1, 1)
        put(3, 80, 2)
        put(13, 174_770, 4)
        put(20, Int64(pdu), 1)
        put(25, Int64(payload.count), 2)
        put(27, 0xA5A5_A5A5, 4)
        return body + payload
    }

    @Test func version26HeaderIsLayoutE() throws {
        // The table used to send version 26 to layout B, which read the length from the wrong place.
        let pdu = hex("1000")
        let message = try #require(NrRrc.decode(v26(4, pdu)))
        #expect(message.packetVersion == 26)
        #expect(message.pci == 80)
        #expect(message.arfcn == 174_770)
        #expect(message.bearerId == 1)
        #expect(message.channel == .DL_DCCH)
        #expect(message.asn1Name == "rrcRelease")
        #expect(message.payload == pdu)
        // Swift only: a DL Information Transfer behind the same header gives up its NAS (c1, index 5, transaction
        // id, r15, dedicatedNAS-Message present, no extensions, then the 7-octet reject as an octet string), and
        // under version 25 (layout B in the table) the trailing length still picks E.
        let nas = hex("7e00441b16012c")
        let transfer = bits("0 0101 00 0 1 00 0 0000111 " + nas.map { byte in
            String(repeating: "0", count: 8 - String(byte, radix: 2).count) + String(byte, radix: 2)
        }.joined(separator: " "))
        let carried = try #require(NrRrc.decode(v26(4, transfer)))
        #expect(carried.asn1Name == "dlInformationTransfer")
        #expect(carried.nas == nas)
        var v25 = v26(4, transfer)
        v25[0] = 25
        let probed = try #require(NrRrc.decode(v25))
        #expect(probed.pci == 80 && probed.arfcn == 174_770 && probed.nas == nas)
    }

    @Test func pdu11And12AreReconfigurationAndComplete() throws {
        // Version 26 numbers the EN-DC containers 11 and 12 where earlier modems used 9 and 10.
        let reconfiguration = try #require(NrRrc.decode(v26(11, hex("0800"))))
        #expect(reconfiguration.channel == .RRC_RECONFIGURATION)
        #expect(reconfiguration.asn1Name == "rrcReconfiguration")
        let complete = try #require(NrRrc.decode(v26(12, hex("0000"))))
        #expect(complete.channel == .RRC_RECONFIGURATION_COMPLETE)
        #expect(complete.asn1Name == "rrcReconfigurationComplete")
        #expect(complete.channel?.uplink == true)
        // PDU 36 (RadioBearerConfig) is contract v2: still unmapped, so it is counted as undecoded, not guessed.
        let bearerConfig = try #require(NrRrc.decode(v26(36, hex("0800"))))
        #expect(bearerConfig.channel == nil)
    }
}
