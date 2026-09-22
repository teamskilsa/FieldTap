// Port of android/diag/src/main/kotlin/com/fieldtap/diag/LogCodes.kt (contract v1: the 0xB80C/0xB80D labels
// are kept as they are; relabelling them as 5GMM state records is on the v2 backlog).

/// The DIAG log codes that carry signalling, and what each one is.
///
/// For NAS the code also says what the modem claims the record is (sublayer, direction, ciphered on the air).
/// That claim is kept apart from what the PDU says, because a disagreement between the two is a decoding bug
/// worth seeing. Only the signalling codes are listed; the PHY codes belong to FTPhy's dispatch table.
public enum LogCodes {
    public enum Category: String, Hashable, Sendable {
        case rrc, nas, cell
    }

    /// What the log code says a record is, before the body is read.
    public struct Info: Hashable, Sendable {
        public var code: UInt16
        public var name: String
        /// "lte" or "nr".
        public var rat: String
        public var category: Category
        /// For NAS: the sublayer the code claims.
        public var nasSublayer: String?
        /// For NAS: "ul" when the modem sent it, "dl" when it received it.
        public var nasDirection: String?
        /// For NAS: true when the message was security protected on the air.
        public var nasProtected: Bool

        public init(code: UInt16, name: String, rat: String, category: Category, nasSublayer: String? = nil,
                    nasDirection: String? = nil, nasProtected: Bool = false) {
            self.code = code
            self.name = name
            self.rat = rat
            self.category = category
            self.nasSublayer = nasSublayer
            self.nasDirection = nasDirection
            self.nasProtected = nasProtected
        }

        public var isNr: Bool { rat == "nr" }
    }

    private static func rrc(_ code: UInt16, _ name: String, _ rat: String) -> Info {
        Info(code: code, name: name, rat: rat, category: .rrc)
    }

    private static func cell(_ code: UInt16, _ name: String, _ rat: String) -> Info {
        Info(code: code, name: name, rat: rat, category: .cell)
    }

    private static func nas(_ code: UInt16, _ name: String, _ rat: String, _ sub: String, _ dir: String,
                            _ prot: Bool) -> Info {
        Info(code: code, name: name, rat: rat, category: .nas, nasSublayer: sub, nasDirection: dir, nasProtected: prot)
    }

    /// Every signalling code, in the Kotlin order (the log mask is built from it).
    public static let all: [Info] = [
        // LTE RRC and cell identity
        rrc(0xB0C0, "LTE RRC OTA Packet", "lte"),
        cell(0xB0C1, "LTE RRC MIB Message Log Packet", "lte"),
        cell(0xB0C2, "LTE RRC Serving Cell Info Log Packet", "lte"),
        // LTE NAS. "Incoming" is from the network, so downlink.
        nas(0xB0E0, "LTE NAS ESM Security Protected Incoming Msg", "lte", "esm", "dl", true),
        nas(0xB0E1, "LTE NAS ESM Security Protected Outgoing Msg", "lte", "esm", "ul", true),
        nas(0xB0E2, "LTE NAS ESM Plain OTA Incoming Msg", "lte", "esm", "dl", false),
        nas(0xB0E3, "LTE NAS ESM Plain OTA Outgoing Msg", "lte", "esm", "ul", false),
        nas(0xB0EA, "LTE NAS EMM Security Protected Incoming Msg", "lte", "emm", "dl", true),
        nas(0xB0EB, "LTE NAS EMM Security Protected Outgoing Msg", "lte", "emm", "ul", true),
        nas(0xB0EC, "LTE NAS EMM Plain OTA Incoming Msg", "lte", "emm", "dl", false),
        nas(0xB0ED, "LTE NAS EMM Plain OTA Outgoing Msg", "lte", "emm", "ul", false),
        // NR NAS
        nas(0xB800, "NR NAS SM5G Plain OTA Incoming Msg", "nr", "5gsm", "dl", false),
        nas(0xB801, "NR NAS SM5G Plain OTA Outgoing Msg", "nr", "5gsm", "ul", false),
        nas(0xB808, "NR NAS SM5G Security Protected Incoming Msg", "nr", "5gsm", "dl", true),
        nas(0xB809, "NR NAS SM5G Security Protected Outgoing Msg", "nr", "5gsm", "ul", true),
        nas(0xB80A, "NR NAS MM5G Plain OTA Incoming Msg", "nr", "5gmm", "dl", false),
        nas(0xB80B, "NR NAS MM5G Plain OTA Outgoing Msg", "nr", "5gmm", "ul", false),
        nas(0xB80C, "NR NAS MM5G Security Protected Incoming Msg", "nr", "5gmm", "dl", true),
        nas(0xB80D, "NR NAS MM5G Security Protected Outgoing Msg", "nr", "5gmm", "ul", true),
        // NR RRC and cell identity
        rrc(0xB821, "NR RRC OTA Packet", "nr"),
        cell(0xB822, "NR RRC MIB Info", "nr"),
        cell(0xB823, "NR RRC Serving Cell Info", "nr"),
    ]

    private static let byCode: [UInt16: Info] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    /// What `code` is, or nil when it is not a signalling code.
    public static func of(_ code: UInt16) -> Info? { byCode[code] }

    /// The codes a signalling capture should enable.
    public static var signallingCodes: [UInt16] { all.map(\.code) }
}
