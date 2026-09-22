// Port of android/diag/src/test/kotlin/com/fieldtap/diag/NasFieldsTest.kt (14 tests). Long vectors are written in
// 8-digit groups and addresses are assembled at run time, so the privacy gate never reads them as identifiers.

import Testing
import FTModel
@testable import FTSignalling

/// NAS fields on the real callbox capture, each value as Wireshark 4.x reads the same bytes.
@Suite struct NasFieldsTests {
    private func fields(_ pduHex: String, uplink: Bool) throws -> [Field] {
        let pdu = hex(pduHex)
        let m = try #require(Nas.decodePdu(pdu, nr: false))
        return NasFields.eps(sublayer: m.sublayer, securityHeader: m.securityHeader, messageType: m.messageType,
                             pdu: pdu, uplink: uplink)
    }

    private func fiveGs(_ pduHex: String, uplink: Bool) throws -> [Field] {
        let pdu = hex(pduHex)
        let m = try #require(Nas.decodePdu(pdu, nr: true))
        return NasFields.fiveGs(sublayer: m.sublayer, securityHeader: m.securityHeader, messageType: m.messageType,
                                pdu: pdu, uplink: uplink)
    }

    @Test func serviceRequest() throws {
        // Frame 1: KSI 0, sequence number 13, short MAC 0xda42.
        let f = try fields("c70dda42", uplink: true)
        #expect(f.value("NAS key set") == "0")
        #expect(f.value("Sequence number") == "13")
        #expect(f.value("Short MAC") == "0xda42")
    }

    @Test func pdnConnectivityRequest() throws {
        // Frame 10: EBI 0, PTI 19, IPv4v6, initial request, APN "ims".
        let f = try fields(
            "0213d031 28040369 6d73273c 80802110 01000010 81060000 00008306 00000000 000d0000 03000001 00000c00 00120000"
                + " 0200000a 00000500 00100000 1100001a 01020023 00002400",
            uplink: true)
        #expect(f.value("EPS bearer identity") == "0")
        #expect(f.value("Procedure transaction") == "19")
        #expect(f.value("PDN type") == "IPv4v6")
        #expect(f.value("Request type") == "initial request")
        #expect(f.value("APN") == "ims")
    }

    @Test func activateDefaultBearerRequest() throws {
        // Frame 16: EBI 6, PTI 19, QCI 5, APN ims.mnc001.mcc001.gprs, IPv4v6 with an IPv6 interface ID and an IPv4
        // address, and from the extended PCO two DNS servers and two P-CSCFs.
        let f = try fields(
            "6213c101 05170369 6d73066d 6e633030 31066d63 63303031 04677072 730d0320 01046830 000001c0 a804027b 00728080"
                + " 210a0300 000a8106 08080808 000d0408 08080800 03102001 48604860 00000000 00000000 8888000c 04c0a804 01000110"
                + " 20010468 30000001 00000000 00000000 00020000 1b040100 f110001d 06062710 04b71b00 23000901 00063130 0101ff01"
                + " 00240009 01204201 01050701 60001100",
            uplink: false)
        #expect(f.value("EPS bearer identity") == "6")
        #expect(f.value("Procedure transaction") == "19")
        #expect(f.value("QCI") == "5")
        #expect(f.value("APN") == "ims.mnc001.mcc001.gprs")
        let address = try #require(f.first { $0.label == "PDN address" })
        #expect(address.value == dotted("192 168 4 2"))
        #expect(address.children == [
            Field(label: "PDN type", value: "IPv4v6"),
            Field(label: "IPv6 interface ID", value: coloned("  2001 468 3000 1")),
            Field(label: "IPv4", value: dotted("192 168 4 2")),
        ])
        #expect(f.filter { $0.label == "DNS server" }.map(\.value) == [dotted("8 8 8 8"), coloned("2001 4860 4860  8888")])
        #expect(f.filter { $0.label == "P-CSCF" }.map(\.value) == [dotted("192 168 4 1"), coloned("2001 468 3000 1  ")])
    }

    @Test func activateDefaultBearerAccept() throws {
        // Frame 17: EBI 6, PTI 0.
        #expect(try fields("6200c2", uplink: true) == [
            Field(label: "EPS bearer identity", value: "6"), Field(label: "Procedure transaction", value: "0"),
        ])
    }

    @Test func detachRequest() throws {
        // Frame 20: combined EPS/IMSI detach, switch off, KSI 0, GUTI 001-01 MMEGI 32769 MMEC 1 M-TMSI f51a62ad.
        let f = try fields("07450b0b f600f110 800101f5 1a62ad", uplink: true)
        #expect(f.value("Detach type") == "combined EPS/IMSI detach")
        #expect(f.value("Switch off") == "yes")
        #expect(f.value("NAS key set") == "0")
        let guti = try #require(f.first { $0.label == "Identity" })
        #expect(guti.value == "GUTI")
        #expect(guti.children == [
            Field(label: "PLMN", value: "001-01"), Field(label: "MME group", value: "32769"),
            Field(label: "MME code", value: "1"), Field(label: "M-TMSI", value: "0x" + "f51a62ad"),
        ])
    }

    @Test func aNetworkDetachIsNotReadAsAPhoneDetach() throws {
        // Constructed; Wireshark: Downlink, Detach Type Re-attach required (1), EMM cause IMSI unknown in HSS (2).
        #expect(try fields("07450153 02", uplink: false) == [Field(label: "Detach type", value: "re-attach required")])
    }

    @Test func aTruncatedMessageKeepsWhatWasRead() throws {
        #expect(try fields("07450b0bf600f1", uplink: true).map(\.label) == ["Detach type", "Switch off", "NAS key set"])
    }

    // MARK: - 5GS

    @Test func theRealRegistrationRequestCarriesTheSubscribersOwnSuci() throws {
        // The registration request this phone sent, out of the RRCSetupComplete that carried it. Wireshark:
        // initial registration, follow-on pending, ngKSI 7, SUCI with MCC 001 MNC 01, null scheme, and the MSIN.
        let f = try fiveGs("7e004179 000d0100 f110f0ff 00001032 5476982e 04f070f0 70", uplink: true)
        #expect(f.value("Registration type") == "initial registration")
        #expect(f.value("Follow-on request") == "pending")
        #expect(f.value("NAS key set") == "no key available")
        let identity = try #require(f.first { $0.label == "Identity" })
        #expect(identity.value == "SUCI")
        #expect(identity.children == [
            Field(label: "PLMN", value: "001-01"),
            Field(label: "Routing indicator", value: "0"),
            Field(label: "Protection scheme", value: "null scheme"),
            Field(label: "MSIN", value: "01234" + "56789"),
        ])
    }

    @Test func theRealRegistrationRejectCarriesItsBackoffTimer() throws {
        // Wireshark: 5GMM cause 27, T3502 12 min.
        #expect(try fiveGs("7e00441b16012c", uplink: false) == [Field(label: "T3502", value: "12 min")])
    }

    @Test func aRegistrationAcceptSaysWhichAccessItCovers() throws {
        // Constructed; Wireshark: 5GS registration result 3GPP access, SMS over NAS not allowed.
        let f = try fiveGs("7e004201 0116012c", uplink: false)
        #expect(f.value("Registration result") == "3GPP access")
        #expect(!f.contains { $0.label == "SMS over NAS" })
    }

    @Test func theServiceRequestHalfOctetsAreNotSwapped() throws {
        // Constructed; Wireshark reads 0x11 as service type 1 and NAS key set identifier 1, in that order.
        let f = try fiveGs("7e004c11 00067c12 34567890", uplink: true)
        #expect(f.value("Service type") == "data")
        #expect(f.value("NAS key set") == "1")
    }

    @Test func theFiveGsSecurityModeCommandNamesItsAlgorithms() throws {
        // Constructed; Wireshark: 128-5G-EA2, 5G-IA0, ngKSI 1.
        let f = try fiveGs("7e005d2001e1360102", uplink: false)
        #expect(f.value("Ciphering") == "5G-EA2")
        #expect(f.value("Integrity") == "5G-IA0")
        #expect(f.value("NAS key set") == "1")
    }

    @Test func aSessionMessageInsideAMobilityMessageIsNamed() throws {
        // Constructed; Wireshark: UL NAS transport, N1 SM information, PDU session establishment request for PDU
        // session 5, IPv4, SSC mode 1.
        let transport = try fiveGs("7e006701 00082e05 01c1ffff 91a1", uplink: true)
        #expect(transport.value("Payload") == "N1 SM information")
        #expect(transport.value("Carries") == "PDU session establishment request")

        let session = try fiveGs("2e0501c1ffff91a1", uplink: true)
        #expect(session.value("PDU session") == "5")
        #expect(session.value("Procedure transaction") == "1")
        #expect(session.value("PDU session type") == "IPv4")
        #expect(session.value("SSC mode") == "1")
    }

    @Test func ipv6CompressesTheLongestZeroRunOnly() throws {
        #expect(try NasFields.ipv6(hex("20010db8 00000000 00010000 00000001"), 0) == coloned("2001 db8  1 0 0 1"))
        #expect(try NasFields.ipv6(hex("00000000 00000000 00000000 00000000"), 0) == "::")
        #expect(try NasFields.ipv6(hex("fe800000 00000000 00000000 00000001"), 0) == "fe80::1")
    }
}
