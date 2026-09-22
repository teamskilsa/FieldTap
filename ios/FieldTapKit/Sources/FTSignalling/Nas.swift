// Port of android/diag/src/main/kotlin/com/fieldtap/diag/Nas.kt (contract v1: unchanged from repo main).

/// NAS messages, and the cause when the network refuses something.
///
/// NAS is a protocol discriminator, a message type and type-length-value fields, so the message and its cause
/// can be read directly from the bytes. The PDU is found rather than assumed: the header in front of it differs
/// by modem generation, so `locate` tries the offsets those generations use and keeps the first one where a
/// valid NAS header starts, falling back to a short scan.
///
/// A ciphered message yields its sublayer and security header but no type: the type octet is inside the
/// encrypted part. That is reported as unknown rather than guessed.
public enum Nas {
    public static let EPD_5GMM = 0x7E
    public static let EPD_5GSM = 0x2E
    public static let PD_EMM = 0x07
    public static let PD_ESM = 0x02

    /// Header sizes seen in front of an LTE NAS PDU, most likely first.
    private static let LTE_OFFSETS = [4, 3, 5, 6, 8]

    /// Header sizes seen in front of an NR NAS PDU, most likely first.
    private static let NR_OFFSETS = [4, 7, 8, 5, 6, 12, 16]

    private static let ESM_TYPES = 0xC1...0xEB
    private static let FIVE_GSM_TYPES = 0xC1...0xD6

    /// How the PDU was found: straight from the table, by trying another offset, or by scanning.
    public enum Located: String, Hashable, Sendable {
        case TABLE, PROBED, SCANNED
    }

    public struct Message: Hashable, Sendable {
        /// "emm", "esm", "5gmm" or "5gsm".
        public var sublayer: String
        /// The security header type; 0 is plain.
        public var securityHeader: Int
        /// Nil when the message is ciphered, so the type octet cannot be read.
        public var messageType: Int?
        public var name: String?
        /// "ul", "dl", or nil when the type alone does not say.
        public var direction: String?
        public var cause: Int?
        public var causeName: String?
        /// Where the NAS PDU starts in the record body.
        public var offset: Int
        public var located: Located

        public init(sublayer: String, securityHeader: Int, messageType: Int?, name: String?, direction: String?,
                    cause: Int?, causeName: String?, offset: Int, located: Located = .TABLE) {
            self.sublayer = sublayer
            self.securityHeader = securityHeader
            self.messageType = messageType
            self.name = name
            self.direction = direction
            self.cause = cause
            self.causeName = causeName
            self.offset = offset
            self.located = located
        }

        /// True when the network refused something and said why.
        public var isReject: Bool { cause != nil }
    }

    private static func looksLikeEps(_ p: [UInt8], _ from: Int) -> Bool {
        if p.count - from < 2 { return false }
        let head = Int(p[from])
        let pd = head & 0x0F
        let sec = head >> 4
        switch pd {
        case PD_EMM: return [0, 1, 2, 3, 4, 12].contains(sec)
        case PD_ESM: return p.count - from >= 3 && ESM_TYPES.contains(Int(p[from + 2]))
        default: return false
        }
    }

    private static func looksLike5gs(_ p: [UInt8], _ from: Int) -> Bool {
        if p.count - from < 3 { return false }
        switch Int(p[from]) {
        case EPD_5GMM: return (0...4).contains(Int(p[from + 1]))
        case EPD_5GSM: return p.count - from >= 4 && FIVE_GSM_TYPES.contains(Int(p[from + 3]))
        default: return false
        }
    }

    /// Where the NAS PDU starts inside `body`, or nil when none is recognisable.
    private static func locate(_ body: [UInt8], nr: Bool) -> (offset: Int, located: Located)? {
        let offsets = nr ? NR_OFFSETS : LTE_OFFSETS
        func looks(_ p: [UInt8], _ from: Int) -> Bool { nr ? looksLike5gs(p, from) : looksLikeEps(p, from) }
        for (index, candidate) in offsets.enumerated() where candidate < body.count && looks(body, candidate) {
            return (candidate, index == 0 ? .TABLE : .PROBED)
        }
        for candidate in 1..<max(1, min(24, body.count)) where looks(body, candidate) {
            return (candidate, .SCANNED)
        }
        return nil
    }

    /// (sublayer, security header, message type) for an EPS PDU.
    private static func classifyEps(_ p: [UInt8]) -> (String, Int, Int?) {
        let head = Int(p[0])
        let pd = head & 0x0F
        let sec = head >> 4
        if pd == PD_ESM { return ("esm", 0, p.count > 2 ? Int(p[2]) : nil) }
        if sec == 0 { return ("emm", 0, p.count > 1 ? Int(p[1]) : nil) }
        // Service request carries a short header and no type octet.
        if sec == 12 { return ("emm", 12, nil) }
        let innerAt = 6
        if sec == 1 || sec == 3, p.count - innerAt >= 2 {
            let ih = Int(p[innerAt])
            if ih & 0x0F == PD_EMM && ih >> 4 == 0 { return ("emm", sec, Int(p[innerAt + 1])) }
            if p.count - innerAt >= 3 && ih & 0x0F == PD_ESM { return ("esm", sec, Int(p[innerAt + 2])) }
        }
        return ("emm", sec, nil)
    }

    /// (sublayer, security header, message type) for a 5GS PDU.
    private static func classify5gs(_ p: [UInt8]) -> (String, Int, Int?) {
        if Int(p[0]) == EPD_5GSM { return ("5gsm", 0, p.count > 3 ? Int(p[3]) : nil) }
        let sec = Int(p[1])
        if sec == 0 { return ("5gmm", 0, p.count > 2 ? Int(p[2]) : nil) }
        let innerAt = 7
        if sec == 1 || sec == 3, p.count - innerAt >= 3 {
            let ih = Int(p[innerAt])
            if ih == EPD_5GMM && Int(p[innerAt + 1]) == 0 { return ("5gmm", sec, Int(p[innerAt + 2])) }
            if p.count - innerAt >= 4 && ih == EPD_5GSM { return ("5gsm", sec, Int(p[innerAt + 3])) }
        }
        return ("5gmm", sec, nil)
    }

    /// The cause carried by a plain reject, or nil.
    ///
    /// In every message below the cause is the mandatory octet straight after the message type, so it is read
    /// from a fixed place rather than by walking the IEs: EMM and ESM put the type second in the PDU, 5GMM and
    /// 5GSM third and fourth. A ciphered message has no readable type and so no readable cause.
    private static func causeOf(_ sublayer: String, _ securityHeader: Int, _ msgType: Int?, _ pdu: [UInt8]) -> Int? {
        guard securityHeader == 0, let msgType else { return nil }
        let at: Int
        switch sublayer {
        case "emm" where [0x44, 0x4B, 0x4E].contains(msgType): at = 2
        case "esm" where [0xC3, 0xC7, 0xCB, 0xD1, 0xD3, 0xD5, 0xD7].contains(msgType): at = 3
        case "5gmm" where [0x44, 0x4D].contains(msgType): at = 3
        case "5gsm" where [0xC5, 0xC7, 0xCA].contains(msgType): at = 4
        default: return nil
        }
        return at < pdu.count ? Int(pdu[at]) : nil
    }

    /// Reads the NAS PDU out of a log record `body`, or nil when there is none. `nr` selects the 5GS reading;
    /// false reads EPS.
    public static func decode(_ body: [UInt8], nr: Bool) -> Message? { located(body, nr: nr)?.message }

    /// `decode` plus the PDU it found, so the call flow keeps that one copy instead of cutting the body again.
    static func located(_ body: [UInt8], nr: Bool) -> (message: Message, pdu: [UInt8])? {
        guard let (offset, located) = locate(body, nr: nr) else { return nil }
        let pdu = Array(body[offset...])
        return (decodePdu(pdu, nr: nr, offset: offset, located: located), pdu)
    }

    /// Reads a PDU that is already known to start at its NAS header, such as the message inside a
    /// security-protected one. Nil when it does not look like NAS.
    public static func decodePdu(_ pdu: [UInt8], nr: Bool) -> Message? {
        let looks = nr ? looksLike5gs(pdu, 0) : looksLikeEps(pdu, 0)
        return looks ? decodePdu(pdu, nr: nr, offset: 0, located: .TABLE) : nil
    }

    private static func decodePdu(_ pdu: [UInt8], nr: Bool, offset: Int, located: Located) -> Message {
        let (sublayer, sec, msgType) = nr ? classify5gs(pdu) : classifyEps(pdu)
        let named: (name: String?, direction: String?) = sublayer == "emm" && sec == 12
            ? ("Service request", "ul")
            : NasNames.message(sublayer: sublayer, messageType: msgType)
        let cause = causeOf(sublayer, sec, msgType, pdu)
        return Message(sublayer: sublayer, securityHeader: sec, messageType: msgType, name: named.name,
                       direction: named.direction, cause: cause,
                       causeName: cause.flatMap { NasNames.cause(sublayer: sublayer, value: $0) },
                       offset: offset, located: located)
    }
}
