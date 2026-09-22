import Testing
@testable import FTModel

/// Identifier-shaped test strings are built at run time, so no tracked file holds a digit run, an IP or a long
/// hex literal (privacy-gate.sh).
enum Synthetic {
    /// 15 digits, IMSI-shaped (test PLMN 001-01), built from pieces.
    static let imsiLike = "00101" + "0123" + "456789"
    static let ipv4 = ["10", "20", "30", "40"].joined(separator: ".")
    static let ipv6 = ["2001", "db8", "85a3", "0", "0", "8a2e", "370", "7334"].joined(separator: ":")
    static let ipv6Short = "fe80" + "::" + "1"
    static let hexId = "0x" + "C0FFEE" + "1234"
}

@Suite struct RedactionTests {
    @Test(arguments: ["IMSI", "IMEISV", "M-TMSI", "GUTI", "SUCI", "5G-S-TMSI", "Mobile identity", "UE identity",
                      "Identity", "Random value", "randomValue", "PDN address", "IP", "IPv4 address", "IPv6 prefix",
                      "DNS server", "P-CSCF address", "Interface identifier", "Cell identity", "NCI", "ECI", "MSISDN"])
    func identityLabelsAreMasked(_ label: String) {
        #expect(Redaction.isIdentityLabel(label), "\(label)")
    }

    @Test(arguments: ["PCI", "EARFCN", "Measurement ID", "Serving RSRP", "Detach type", "Switch off", "PLMN", "TAC",
                      "Identity type", "Ship", "Tip", "Establishment cause", "APN"])
    func otherLabelsAreNot(_ label: String) {
        // "Identity type" does not match ^identity$; "Ship"/"Tip" are not \bip\b.
        #expect(!Redaction.isIdentityLabel(label), "\(label)")
    }

    @Test func scrubReplacesIdentifierShapes() {
        #expect(Redaction.scrub("IMSI \(Synthetic.imsiLike) attached") == "IMSI <masked> attached")
        #expect(Redaction.scrub("addr \(Synthetic.ipv4)") == "addr <masked>")
        #expect(Redaction.scrub("v6 \(Synthetic.ipv6) end") == "v6 <masked> end")
        #expect(Redaction.scrub("link \(Synthetic.ipv6Short)").contains("<masked>"))
        #expect(Redaction.scrub("tmsi \(Synthetic.hexId)") == "tmsi <masked>")
        #expect(Redaction.scrub("+1 555 123 4567") == "<masked>")
        // What must survive: RSRP ranges, short numbers, PCI/EARFCN, times.
        #expect(Redaction.scrub("RSRP −113 to −112 dBm") == "RSRP −113 to −112 dBm")
        #expect(Redaction.scrub("B66 67086 PCI 80, 0x1F") == "B66 67086 PCI 80, 0x1F")
        #expect(Redaction.scrub(Optional<String>.none) == nil)
    }

    @Test func maskHidesIdentityFieldsAndEverythingUnderThem() {
        let guti = Field(label: "Identity", value: "GUTI", children: [
            Field(label: "PLMN", value: "310-410"),
            Field(label: "M-TMSI", value: Synthetic.hexId),
        ])
        let masked = Redaction.mask(guti)
        #expect(masked.value == "GUTI", "a masked parent keeps its own (scrubbed) value")
        #expect(masked.children.map(\.value) == ["<masked>", "<masked>"])

        let pdn = Redaction.mask(Field(label: "PDN address", value: Synthetic.ipv4))
        #expect(pdn.value == "<masked>")
        let plain = Redaction.mask(Field(label: "Summary", value: "to \(Synthetic.ipv4)"))
        #expect(plain.value == "to <masked>")
        #expect(Redaction.display(Field(label: "IMSI", value: Synthetic.imsiLike), reveal: true).value == Synthetic.imsiLike)
        #expect(Redaction.display(Field(label: "IMSI", value: Synthetic.imsiLike), reveal: false).value == "<masked>")
    }

    @Test func cellViewsAlsoMaskTacAndCellIdentity() {
        let info = ServingCellInfo(pci: 80, downlinkEarfcn: 67_086, uplinkEarfcn: 132_622, band: 66, plmn: "310-410",
                                   tac: 1_234, cellIdentity: 123_456, bandwidthMhz: 20)
        let masked = Dictionary(uniqueKeysWithValues: Redaction.displayCellInfo(info, reveal: false).map { ($0.label, $0.value) })
        #expect(masked["TAC"] == "<masked>" && masked["Cell identity"] == "<masked>")
        #expect(masked["PCI"] == "80" && masked["EARFCN"] == "67086")
        let shown = Dictionary(uniqueKeysWithValues: Redaction.displayCellInfo(info, reveal: true).map { ($0.label, $0.value) })
        #expect(shown["TAC"] == "1234" && shown["Cell identity"] == "123456")
    }
}
