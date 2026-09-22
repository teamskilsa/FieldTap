// Port of android/diag/src/test/kotlin/com/fieldtap/diag/NasTest.kt (10 tests).

import Testing
import FTModel
@testable import FTSignalling

/// The reject vectors below are the real bytes a OnePlus 10 Pro produced on 2026-09-14 when a SIM that is not
/// provisioned tried to register. They carry a message type and a cause and nothing else (no identity, no
/// subscriber data), so they can live in the repository where the capture they came from cannot.
@Suite struct NasTests {
    @Test func theLteAttachRejectFromTheHandsetGivesCauseSeven() throws {
        // 0xB0EC body: a 4-byte header, then the EMM PDU 07 44 07.
        let m = try #require(Nas.decode(hex("01090500 074407"), nr: false))
        #expect(m.offset == 4)
        #expect(m.located == .TABLE)
        #expect(m.sublayer == "emm")
        #expect(m.securityHeader == 0)
        #expect(m.messageType == 0x44)
        #expect(m.name == "Attach reject")
        #expect(m.direction == "dl")
        #expect(m.cause == 7)
        #expect(m.causeName == "EPS services not allowed")
        #expect(m.isReject)
    }

    @Test func theFiveGRegistrationRejectFromTheHandsetGivesCauseTwentySeven() throws {
        // 0xB80A body: a 7-byte header, then the 5GMM PDU 7e 00 44 1b ...
        let m = try #require(Nas.decode(hex("010000000f04007e00441b16012c"), nr: true))
        #expect(m.offset == 7)
        #expect(m.sublayer == "5gmm")
        #expect(m.messageType == 0x44)
        #expect(m.name == "Registration reject")
        #expect(m.cause == 27)
        #expect(m.causeName == "N1 mode not allowed")
    }

    @Test func theFiveGRegistrationRequestFromTheHandsetIsReadAsUplink() throws {
        let m = try #require(Nas.decode(hex("01000000 0f04007e 00417900 36011300 6200"), nr: true))
        #expect(m.sublayer == "5gmm")
        #expect(m.messageType == 0x41)
        #expect(m.name == "Registration request")
        #expect(m.direction == "ul")
        #expect(m.cause == nil, "a request carries no cause")
        #expect(!m.isReject)
    }

    @Test func anLteAttachRequestIsReadAsUplinkWithNoCause() throws {
        let m = try #require(Nas.decode(hex("01090500 07417208 39016250 940143"), nr: false))
        #expect(m.sublayer == "emm")
        #expect(m.messageType == 0x41)
        #expect(m.name == "Attach request")
        #expect(m.direction == "ul")
        #expect(m.cause == nil)
    }

    @Test func aCipheredMessageReportsItsSecurityHeaderAndNoType() throws {
        // Security header 1, and the type octet is inside the ciphered part.
        let m = try #require(Nas.decode(hex("01090500") + hex("17010203 04050607 080910"), nr: false))
        #expect(m.sublayer == "emm")
        #expect(m.securityHeader == 1)
        #expect(m.messageType == nil, "the type is not guessed")
        #expect(m.name == nil)
        #expect(m.cause == nil, "and so no cause is claimed")
    }

    @Test func theServiceRequestShortHeaderIsNamedWithoutATypeOctet() throws {
        let m = try #require(Nas.decode(hex("01090500") + hex("c7a1b2"), nr: false))
        #expect(m.sublayer == "emm")
        #expect(m.securityHeader == 12)
        #expect(m.name == "Service request")
        #expect(m.direction == "ul")
    }

    @Test func aPduBehindAnUnexpectedHeaderLengthIsStillFound() throws {
        // Offset 6 is not the first candidate, so this is a probe rather than the table.
        let m = try #require(Nas.decode(hex("01090500 1122") + hex("074407"), nr: false))
        #expect(m.offset == 6)
        #expect(m.located == .PROBED)
        #expect(m.cause == 7)
    }

    @Test func aBodyWithNoNasPduIsNull() {
        #expect(Nas.decode([UInt8](repeating: 0, count: 8), nr: false) == nil)
        #expect(Nas.decode([], nr: false) == nil)
    }

    @Test func causesAreNamedPerSublayerAndUnknownOnesAreNotInvented() {
        #expect(NasNames.cause(sublayer: "esm", value: 27) == "Missing or unknown APN")
        #expect(NasNames.cause(sublayer: "5gmm", value: 27) == "N1 mode not allowed")
        #expect(NasNames.cause(sublayer: "emm", value: 24) == "Security mode rejected, unspecified")
        #expect(NasNames.cause(sublayer: "emm", value: 200) == nil)
        #expect(NasNames.cause(sublayer: "nonsense", value: 7) == nil)
    }

    @Test func everyRejectMessageWeNameHasACauseTable() throws {
        // A reject whose cause we read must be one we can also name, or the screen says a number.
        for (layer, type, pdu) in [("emm", 0x44, "074407"), ("5gmm", 0x44, "7e00441b")] {
            let m = try #require(Nas.decode(hex("01090500") + hex(pdu), nr: layer.hasPrefix("5")),
                                 "\(layer) 0x\(String(type, radix: 16)) did not decode")
            #expect(m.sublayer == layer)
            #expect(m.causeName != nil, "cause is named for \(layer)")
        }
    }
}
