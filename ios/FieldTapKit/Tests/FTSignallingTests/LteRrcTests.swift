// Port of android/diag/src/test/kotlin/com/fieldtap/diag/LteRrcTest.kt (15 tests), plus the contract-v1 layout
// test WP1 adds there (D2: version 30 is header layout E). The real capture is FT_FIXTURES/oneplus.

import Testing
import FTCore
import FTModel
import FTTestSupport
@testable import FTSignalling

/// The LTE RRC decoder on a real SM8450 capture, held to Python's decode and Wireshark's reading of the same bytes.
@Suite struct LteRrcTests {
    private static let rrc: [LteRrc.Message]? = OnePlus.callbox.map { read in
        read.records.filter { $0.code == 0xB0C0 }.compactMap { LteRrc.decode($0.body) }
    }

    private func messages() -> [LteRrc.Message]? {
        Fixtures.require(OnePlus.callboxPath) != nil ? Self.rrc : nil
    }

    @Test(.fixture(OnePlus.callboxPath))
    func everyRrcPacketOfTheCaptureDecodesWithTheLengthConfirmingTheLayout() {
        guard let rrc = messages() else { return }
        // 13 LTE RRC packets; the 14th "RRC" record the old screen counted is an NR RRC packet (0xB821).
        #expect(OnePlus.callbox?.records.count { $0.code == 0xB0C0 } == 13)
        #expect(rrc.count == 13)
        #expect(rrc.allSatisfy { $0.packetVersion == 27 })
        #expect(rrc.allSatisfy { $0.asn1Name != nil && $0.channel != nil }, "every message named")
    }

    @Test(.fixture(OnePlus.callboxPath))
    func theCellAndChannelMatchWhatPythonReads() {
        guard let rrc = messages() else { return }
        // fieldtap/decode/lte_rrc.py on the same file: every message on PCI 3, EARFCN 1575.
        #expect(rrc.allSatisfy { $0.pci == 3 && $0.earfcn == 1575 })
        let named = rrc.map { "\($0.channel?.label ?? "?") \($0.asn1Name ?? "?")" }
        #expect(named == [
            "UL-CCCH rrcConnectionRequest", "DL-CCCH rrcConnectionSetup", "UL-DCCH rrcConnectionSetupComplete",
            "DL-DCCH securityModeCommand", "UL-DCCH securityModeComplete", "DL-DCCH rrcConnectionReconfiguration",
            "UL-DCCH rrcConnectionReconfigurationComplete", "UL-DCCH ulInformationTransfer",
            "DL-DCCH rrcConnectionReconfiguration", "UL-DCCH rrcConnectionReconfigurationComplete",
            "UL-DCCH ulInformationTransfer", "UL-DCCH ulInformationTransfer", "DL-DCCH rrcConnectionRelease",
        ])
        #expect(named.first == "UL-CCCH rrcConnectionRequest")
        #expect(named.last == "DL-DCCH rrcConnectionRelease")
    }

    @Test(.fixture(OnePlus.callboxPath))
    func theConnectionRequestFieldsAreWiresharks() throws {
        guard let rrc = messages() else { return }
        // Wireshark: s-TMSI mmec 01, m-TMSI f51a62ad, establishmentCause mo-Data (4).
        let request = try #require(rrc.first)
        let identity = try #require(request.fields.first { $0.label == "UE identity" })
        #expect(identity.value == "S-TMSI")
        #expect(identity.children.value("MMEC") == "1")
        #expect(identity.children.value("M-TMSI") == "0x" + "f51a62ad")
        #expect(request.fields.value("Establishment cause") == "mo-Data")
    }

    @Test(.fixture(OnePlus.callboxPath))
    func theReleaseCauseIsWiresharks() {
        guard let rrc = messages() else { return }
        // Wireshark: RRCConnectionRelease [cause=other].
        #expect(rrc.last?.fields == [Field(label: "Release cause", value: "other")])
    }

    // The PDUs below have no real sample yet. Each was built bit by bit and then decoded by Wireshark 4.x
    // (exported-PDU, lte-rrc.* dissectors); the expectations are Wireshark's reading, not this decoder's.

    @Test func aMeasurementReportGivesServingAndNeighboursAsWiresharkReadsThem() throws {
        // Wireshark: measId 1; PCell -98..-97 dBm (43), -6.5..-6 dB (27); EUTRA PCI 3 -94..-93 (47) -7.5..-7 (25);
        // PCI 5 -99..-98 (42) -15..-14.5 (10).
        let fields = LteRrc.Details.of(.UL_DCCH, "measurementReport", hex("08102b6c 100daf64 056a8a"))
        #expect(fields.value("Measurement ID") == "1")
        #expect(fields.value("Serving RSRP") == "−98 to −97 dBm")
        #expect(fields.value("Serving RSRQ") == "−6.5 to −6.0 dB")
        let neighbours = try #require(fields.first { $0.label == "Neighbours" })
        #expect(neighbours.children.map(\.label) == ["PCI 3", "PCI 5"])
        #expect(neighbours.children[0].value == "−94 to −93 dBm · −7.5 to −7.0 dB")
        #expect(neighbours.children[1].value == "−99 to −98 dBm · −15.0 to −14.5 dB")
    }

    @Test func aConnectionRejectGivesItsWaitTime() {
        // Wireshark: rrcConnectionReject-r8, waitTime: 10s.
        #expect(LteRrc.Details.of(.DL_CCCH, "rrcConnectionReject", hex("4120")) == [Field(label: "Wait time", value: "10 s")])
    }

    @Test func aReestablishmentRequestGivesTheFailureAndTheCellItHappenedOn() {
        // Wireshark: c-RNTI 1234, physCellId 2, reestablishmentCause handoverFailure (1).
        let fields = LteRrc.Details.of(.UL_CCCH, "rrcConnectionReestablishmentRequest", hex("0246802abcd4"))
        #expect(fields.value("Cause") == "handoverFailure")
        #expect(fields.value("Previous cell PCI") == "2")
        #expect(fields.value("C-RNTI") == "0x1234")
    }

    @Test func aReleaseWithARedirectGivesTheTargetCarrier() {
        // Wireshark: releaseCause other (1), redirectedCarrierInfo eutra (0): 1300.
        #expect(LteRrc.Details.of(.DL_DCCH, "rrcConnectionRelease", hex("282200a280")) == [
            Field(label: "Release cause", value: "other"), Field(label: "Redirected to", value: "EUTRA EARFCN 1300"),
        ])
    }

    @Test func aHandoverCommandWithoutMeasConfigNamesItsTarget() {
        // Constructed; Wireshark: mobilityControlInfo, targetPhysCellId 2, dl-CarrierFreq 2850, t304 ms500.
        #expect(LteRrc.Details.of(.DL_DCCH, "rrcConnectionReconfiguration", hex("22082004 0b228246 80000000 0000"))
            == [Field(label: LteRrc.handover, value: "to PCI 2, EARFCN 2850")])
    }

    @Test func aHandoverCommandBehindAMeasConfigIsStillAHandover() {
        // Constructed; Wireshark: measConfig then mobilityControlInfo present.
        #expect(LteRrc.Details.of(.DL_DCCH, "rrcConnectionReconfiguration", hex("221800")) == [
            Field(label: LteRrc.handover, value: "command"), Field(label: "Carries", value: "measurement config"),
        ])
    }

    @Test(.fixture(OnePlus.callboxPath))
    func theRealReconfigurationSaysWhatItCarries() {
        guard let rrc = messages() else { return }
        // Frame 13; Wireshark: dedicatedInfoNASList (1 item) and radioResourceConfigDedicated, no mobilityControlInfo.
        let reconfigurations = rrc.filter { $0.asn1Name == "rrcConnectionReconfiguration" }
        #expect(reconfigurations.count == 2)
        #expect(reconfigurations.last?.fields == [Field(label: "Carries", value: "NAS, radio resources")])
        #expect(reconfigurations.allSatisfy { m in !m.fields.contains { $0.label == LteRrc.handover } })
    }

    @Test func theEdgesOfTheReportingRangesAreOpenEnded() {
        #expect(LteRrc.Details.rsrp(0) == "< −140 dBm")
        #expect(LteRrc.Details.rsrp(97) == "≥ −44 dBm")
        #expect(LteRrc.Details.rsrq(0) == "< −19.5 dB")
    }

    @Test func namesReadLikeTheSpec() {
        #expect(LteRrc.readable("rrcConnectionReconfigurationComplete") == "RRC Connection Reconfiguration Complete")
        #expect(LteRrc.readable("securityModeCommand") == "Security Mode Command")
        #expect(LteRrc.readable("ulInformationTransfer") == "UL Information Transfer")
        #expect(LteRrc.readable("systemInformationBlockType1") == "SIB1")
    }

    @Test func aTruncatedPduNamesTheMessageButClaimsNoFields() {
        #expect(LteRrc.Details.of(.UL_CCCH, "rrcConnectionRequest", [0x40]).isEmpty)
    }

    @Test(.fixture(OnePlus.callboxPath))
    func aRecordTooShortForAnyHeaderIsNotDecoded() {
        #expect(LteRrc.decode([UInt8](repeating: 0, count: 5)) == nil)
        guard let rrc = messages() else { return }
        #expect(rrc.first?.payload.isEmpty == false)
    }

    // MARK: - Contract v1 (D2), with the inputs of WP1's Kotlin test of the same name

    @Test func version30HeaderIsLayoutE() throws {
        // iPhone 17 (M25 modem): the version-27 header plus three bytes after the length, 24 bytes with the version.
        // Read as layout D, those three bytes would lead the PDU and the message would not be named.
        let pdu = hex("2801")
        var body = [UInt8](repeating: 0, count: 24) + pdu
        body[0] = 30
        func put(_ at: Int, _ v: Int64, _ width: Int) {
            for i in 0..<width { body[1 + at + i] = UInt8(truncatingIfNeeded: v >> (8 * Int64(i))) }
        }
        put(5, 235, 2)
        put(7, 5110, 4)
        put(13, 9, 1)
        put(18, Int64(pdu.count), 2)
        put(20, 0xA5_A5A5, 3)
        let message = try #require(LteRrc.decode(body))
        #expect(message.packetVersion == 30)
        #expect(message.pci == 235)
        #expect(message.earfcn == 5110)
        #expect(message.channel == .DL_DCCH)
        #expect(message.asn1Name == "rrcConnectionRelease")
        #expect(message.payload == pdu)
        // Swift only: a version with no table row is probed, and only layout E's trailing length fits these bytes.
        body[0] = 31
        let probed = try #require(LteRrc.decode(body))
        #expect(probed.pci == 235 && probed.earfcn == 5110 && probed.asn1Name == "rrcConnectionRelease")
    }
}
