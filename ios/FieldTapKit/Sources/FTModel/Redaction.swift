import Foundation

/// Identifier masking: the rules of ios/Contract/tools/GoldenDump.kt, so a golden fixture and the app hide
/// exactly the same things, plus stricter display rules for the cell views (TAC and cell identity).
///
/// A field is masked when its label names an identity (IMSI, GUTI, an IP address, a cell identity...);
/// every child of a masked field is masked too. In every other string, IPv6, IPv4, runs of 10 or more
/// digits and 0x-hex of 8 or more digits are replaced, because an identifier can hide in a summary line.
public enum Redaction {
    public static let masked = "<masked>"

    // Java's \d is ASCII-only; [0-9] keeps ICU from matching other scripts' digits.
    private static let identityLabel = regex(
        "(?i)(^identity$|imsi|imei|tmsi|guti|suci|supi|msisdn|mobile identity|ue identity|i-rnti|s-tmsi|random ?value|"
            + "address|\\bip\\b|ipv4|ipv6|dns|p-cscf|pcscf|interface identifier|cell identity|\\bnci\\b|\\beci\\b)")
    private static let ipv6 = regex("(?i)\\b([0-9a-f]{1,4}:){2,7}[0-9a-f:]{1,4}\\b|::[0-9a-f]{1,4}")
    private static let ipv4 = regex("\\b[0-9]{1,3}(\\.[0-9]{1,3}){3}\\b")
    private static let digits = regex("\\+?[0-9][0-9 ]{8,}[0-9]")
    private static let hexId = regex("(?i)0x[0-9a-f]{8,}")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo is a programming error caught by RedactionTests.
        try! NSRegularExpression(pattern: pattern)
    }

    /// True when a field with this label carries an identity and must be masked with all its children.
    public static func isIdentityLabel(_ label: String) -> Bool {
        identityLabel.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
    }

    /// `s` with IPv6, IPv4, 10+ digit runs and 0x-hex of 8+ digits replaced by `<masked>`, in that order.
    public static func scrub(_ s: String) -> String {
        var t = s
        for r in [ipv6, ipv4, digits, hexId] {
            t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: masked)
        }
        return t
    }

    public static func scrub(_ s: String?) -> String? { s.map { scrub($0) } }

    /// GoldenDump.maskField: identity-labelled fields (and everything under them) become `<masked>`; a masked
    /// field with children keeps its own value scrubbed, so "Identity: GUTI" still says which identity it was.
    public static func mask(_ f: Field, parentMasked: Bool = false) -> Field {
        let isMasked = parentMasked || isIdentityLabel(f.label)
        let value = isMasked && f.children.isEmpty ? masked : scrub(f.value)
        return Field(label: f.label, value: value, children: f.children.map { mask($0, parentMasked: isMasked) })
    }

    /// What a screen shows: the field as decoded when the user chose to reveal identifiers, masked otherwise.
    public static func display(_ f: Field, reveal: Bool) -> Field {
        reveal ? f : mask(f)
    }

    /// The serving-cell rows for a cell view. Stricter than the golden: TAC and cell identity are masked
    /// unless revealed, because together with the PLMN they locate the phone.
    public static func displayCellInfo(_ info: ServingCellInfo, reveal: Bool) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            ("PCI", "\(info.pci)"),
            ("EARFCN", "\(info.downlinkEarfcn)"),
            ("Uplink EARFCN", "\(info.uplinkEarfcn)"),
            ("Band", "\(info.band)"),
            ("PLMN", info.plmn),
            ("TAC", reveal ? "\(info.tac)" : masked),
            ("Cell identity", reveal ? info.cellIdentity.map { "\($0)" } ?? "unknown" : masked),
        ]
        if let mhz = info.bandwidthMhz { rows.append(("Bandwidth", "\(mhz) MHz")) }
        return rows
    }
}
