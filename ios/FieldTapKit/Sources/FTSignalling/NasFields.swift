// Port of android/diag/src/main/kotlin/com/fieldtap/diag/NasFields.kt (contract v1: unchanged from repo main).

import FTCore
import FTModel

/// The fields of a plain NAS message an engineer reads first (TS 24.301, TS 24.501): who the phone said it
/// was, what it asked for, what the network gave it, and why anything was refused.
///
/// Not every IE of every message: the ones that answer "what happened", each pinned to Wireshark's reading of
/// the same bytes. A message shorter than its own definition yields the fields read before it ran out, never
/// an invented one. Identities stay as decoded here; masking is Redaction's job, at display and in goldens.
public enum NasFields {
    /// `pdu` starts at the NAS header; `uplink` is the direction the modem logged it in.
    public static func eps(sublayer: String, securityHeader: Int, messageType: Int?, pdu: [UInt8], uplink: Bool) -> [Field] {
        var out: [Field] = []
        do {
            if sublayer == "emm" && securityHeader == 12 {
                try serviceRequest(pdu, &out)
            } else if securityHeader != 0 || messageType == nil {
            } else if sublayer == "emm", let messageType {
                try emm(messageType, pdu, uplink, &out)
            } else if sublayer == "esm", let messageType {
                try esm(messageType, pdu, &out)
            }
        } catch {
            // Truncated: keep what was read.
        }
        return out
    }

    /// `pdu` starts at the 5GS NAS header (the extended protocol discriminator).
    public static func fiveGs(sublayer: String, securityHeader: Int, messageType: Int?, pdu: [UInt8],
                              uplink: Bool) -> [Field] {
        var out: [Field] = []
        guard securityHeader == 0, let messageType else { return out }
        do {
            switch sublayer {
            case "5gmm": try fiveGmm(messageType, pdu, &out)
            case "5gsm": try fiveGsm(messageType, pdu, &out)
            default: break
            }
        } catch {
            // Truncated: keep what was read.
        }
        return out
    }

    // MARK: - 5GMM

    private static func fiveGmm(_ type: Int, _ p: [UInt8], _ out: inout [Field]) throws {
        switch type {
        case 0x41: // Registration request
            let octet = try u8(p, 3)
            out.append(Field(label: "Registration type", value: REGISTRATION_TYPE[octet & 0x07] ?? "reserved"))
            if octet & 0x08 != 0 { out.append(Field(label: "Follow-on request", value: "pending")) }
            out.append(Field(label: "NAS key set", value: ksi(octet >> 4)))
            if let identity = try fiveGsIdentity(p, 6, (try u8(p, 4) << 8) | (try u8(p, 5))) { out.append(identity) }
        case 0x42: // Registration accept
            let result = try u8(p, 4)
            out.append(Field(label: "Registration result", value: REGISTRATION_RESULT[result & 0x07] ?? "reserved"))
            if result & 0x08 != 0 { out.append(Field(label: "SMS over NAS", value: "allowed")) }
        case 0x44, 0x4D: // Registration reject, Service reject: the cause is on the row
            try timers(p, 4, &out)
        case 0x45, 0x47: // Deregistration request
            let octet = try u8(p, 3)
            out.append(Field(label: "Deregistration", value: octet & 0x08 != 0 ? "switch off" : "normal"))
            out.append(Field(label: "Access", value: ACCESS_TYPE[octet & 0x03] ?? "reserved"))
            if uplinkDeregistration(type) { out.append(Field(label: "NAS key set", value: ksi(octet >> 4))) }
        case 0x4C: // Service request: the service type is the high half octet, the key set the low one
            let octet = try u8(p, 3)
            out.append(Field(label: "Service type", value: SERVICE_TYPE[(octet >> 4) & 0x0F] ?? "reserved"))
            out.append(Field(label: "NAS key set", value: ksi(octet)))
        case 0x5B:
            out.append(Field(label: "Identity requested", value: FIVE_GS_IDENTITY_TYPE[try u8(p, 3) & 0x07] ?? "reserved"))
        case 0x5D: // Security mode command
            let algorithms = try u8(p, 3)
            out.append(Field(label: "Ciphering", value: "5G-EA\((algorithms >> 4) & 0x07)"))
            out.append(Field(label: "Integrity", value: "5G-IA\(algorithms & 0x07)"))
            out.append(Field(label: "NAS key set", value: ksi(try u8(p, 4) & 0x0F)))
        case 0x67, 0x68: // UL/DL NAS transport: a session-management message inside a mobility one
            let container = try u8(p, 3) & 0x0F
            out.append(Field(label: "Payload", value: PAYLOAD_CONTAINER[container] ?? "type \(container)"))
            let length = (try u8(p, 4) << 8) | (try u8(p, 5))
            if container == 1 && 6 + length <= p.count {
                if let name = Nas.decodePdu(Array(p[6..<6 + length]), nr: true)?.name {
                    out.append(Field(label: "Carries", value: name))
                }
            }
        default:
            break
        }
    }

    private static func uplinkDeregistration(_ type: Int) -> Bool { type == 0x45 }

    /// GPRS timers a reject can carry: T3346 (0x5F) and T3502 (0x16), both one octet of value.
    private static func timers(_ p: [UInt8], _ from: Int, _ out: inout [Field]) throws {
        var i = from
        while i + 2 < p.count {
            let tag = try u8(p, i)
            let length = try u8(p, i + 1)
            if tag == 0x5F && length == 1 {
                out.append(Field(label: "T3346", value: gprsTimer(try u8(p, i + 2))))
            } else if tag == 0x16 && length == 1 {
                out.append(Field(label: "T3502", value: gprsTimer(try u8(p, i + 2))))
            } else if tag >= 0x80 {
                i += 1
                continue
            }
            i += 2 + length
        }
    }

    /// 5GS mobile identity (TS 24.501): a SUCI, which carries the subscriber's own MSIN in the clear
    /// under the null scheme, or a 5G-GUTI the network handed out.
    private static func fiveGsIdentity(_ p: [UInt8], _ at: Int, _ length: Int) throws -> Field? {
        if length < 1 || at + length > p.count { return nil }
        switch try u8(p, at) & 0x07 {
        case 1: // SUCI
            // Type octet, PLMN (3), routing indicator (2), protection scheme, public key id, then the MSIN.
            let scheme = try u8(p, at + 6) & 0x0F
            var children = [
                Field(label: "PLMN", value: try plmn(p, at + 1)),
                Field(label: "Routing indicator", value: try bcd(p, at + 4, 2)),
                Field(label: "Protection scheme", value: SUCI_SCHEME[scheme] ?? "scheme \(scheme)"),
            ]
            // Only the null scheme leaves the MSIN readable; the others are the whole point of SUCI.
            if scheme == 0 { children.append(Field(label: "MSIN", value: try bcd(p, at + 8, length - 8))) }
            return Field(label: "Identity", value: "SUCI", children: children)
        case 2:
            let tmsi = (Int64(try u8(p, at + 7)) << 24) | (Int64(try u8(p, at + 8)) << 16)
                | (Int64(try u8(p, at + 9)) << 8) | Int64(try u8(p, at + 10))
            return Field(label: "Identity", value: "5G-GUTI", children: [
                Field(label: "PLMN", value: try plmn(p, at + 1)),
                Field(label: "AMF region", value: "\(try u8(p, at + 4))"),
                Field(label: "AMF set", value: "\(((try u8(p, at + 5) << 8) | (try u8(p, at + 6))) >> 6)"),
                Field(label: "AMF pointer", value: "\(try u8(p, at + 6) & 0x3F)"),
                Field(label: "5G-TMSI", value: Fmt.hex(tmsi, width: 8, uppercase: false)),
            ])
        case 3: return Field(label: "Identity", value: "IMEI \(try bcdDigits(p, at, length))")
        case 4: return Field(label: "Identity", value: "5G-S-TMSI")
        case 5: return Field(label: "Identity", value: "IMEISV \(try bcdDigits(p, at, length))")
        default: return nil
        }
    }

    // MARK: - 5GSM

    private static func fiveGsm(_ type: Int, _ p: [UInt8], _ out: inout [Field]) throws {
        out.append(Field(label: "PDU session", value: "\(try u8(p, 1))"))
        out.append(Field(label: "Procedure transaction", value: "\(try u8(p, 2))"))
        switch type {
        case 0xC1: // PDU session establishment request
            var i = 6 // after the integrity protection maximum data rate
            while i < p.count {
                let tag = try u8(p, i)
                if tag >> 4 == 0x9 {
                    out.append(Field(label: "PDU session type", value: FIVE_GS_PDN_TYPE[tag & 0x0F] ?? "reserved"))
                    i += 1
                } else if tag >> 4 == 0xA {
                    out.append(Field(label: "SSC mode", value: "\(tag & 0x0F)"))
                    i += 1
                } else if tag >= 0x80 {
                    i += 1
                } else {
                    i += 2 + (try u8(p, i + 1))
                }
            }
        case 0xC2: // PDU session establishment accept
            out.append(Field(label: "PDU session type", value: FIVE_GS_PDN_TYPE[try u8(p, 4) & 0x0F] ?? "reserved"))
            out.append(Field(label: "SSC mode", value: "\((try u8(p, 4) >> 4) & 0x07)"))
        default:
            break
        }
    }

    // MARK: - EMM

    private static func emm(_ type: Int, _ p: [UInt8], _ uplink: Bool, _ out: inout [Field]) throws {
        switch type {
        case 0x41: // Attach request
            out.append(Field(label: "Attach type", value: ATTACH_TYPE[try u8(p, 2) & 0x07] ?? "reserved"))
            out.append(Field(label: "NAS key set", value: ksi(try u8(p, 2) >> 4)))
            if let identity = try identityLv(p, 3) { out.append(identity) }
        case 0x42: // Attach accept
            out.append(Field(label: "Attach result", value: ATTACH_RESULT[try u8(p, 2) & 0x07] ?? "reserved"))
            out.append(Field(label: "T3412", value: gprsTimer(try u8(p, 3))))
            let taiLength = try u8(p, 4)
            if let tai = try firstTai(p, 5, taiLength) { out.append(tai) }
        case 0x44, 0x4B, 0x4E: // Rejects: the cause is shown on the row already.
            break
        case 0x45: // Detach request
            let octet = try u8(p, 2)
            if uplink {
                // Switch-off bit and a detach type, then the identity.
                out.append(Field(label: "Detach type", value: DETACH_TYPE_UL[octet & 0x07] ?? "reserved"))
                out.append(Field(label: "Switch off", value: octet & 0x08 != 0 ? "yes" : "no"))
                out.append(Field(label: "NAS key set", value: ksi(octet >> 4)))
                if let identity = try identityLv(p, 3) { out.append(identity) }
            } else {
                out.append(Field(label: "Detach type", value: DETACH_TYPE_DL[octet & 0x07] ?? "reserved"))
            }
        case 0x48: // Tracking area update request
            out.append(Field(label: "Update type", value: UPDATE_TYPE[try u8(p, 2) & 0x07] ?? "reserved"))
            out.append(Field(label: "Active flag", value: try u8(p, 2) & 0x08 != 0 ? "set" : "not set"))
            if var identity = try identityLv(p, 3) {
                identity.label = "Old GUTI"
                out.append(identity)
            }
        case 0x49:
            out.append(Field(label: "Update result", value: UPDATE_RESULT[try u8(p, 2) & 0x07] ?? "reserved"))
        case 0x52: // Authentication request
            out.append(Field(label: "NAS key set", value: ksi(try u8(p, 2) & 0x0F)))
            out.append(Field(label: "RAND", value: try hex(p, 3, 16)))
        case 0x55:
            out.append(Field(label: "Identity requested", value: IDENTITY_TYPE[try u8(p, 2) & 0x07] ?? "reserved"))
        case 0x5D: // Security mode command
            let algorithms = try u8(p, 2)
            out.append(Field(label: "Ciphering", value: "EEA\((algorithms >> 4) & 0x07)"))
            out.append(Field(label: "Integrity", value: "EIA\(algorithms & 0x07)"))
            out.append(Field(label: "NAS key set", value: ksi(try u8(p, 3) & 0x0F)))
        default:
            break
        }
    }

    /// SERVICE REQUEST: KSI and short sequence number, then a 2-octet short MAC.
    private static func serviceRequest(_ p: [UInt8], _ out: inout [Field]) throws {
        let ksiSeq = try u8(p, 1)
        out.append(Field(label: "NAS key set", value: ksi(ksiSeq >> 5)))
        out.append(Field(label: "Sequence number", value: "\(ksiSeq & 0x1F)"))
        out.append(Field(label: "Short MAC", value: Fmt.hex((try u8(p, 2) << 8) | (try u8(p, 3)), width: 4, uppercase: false)))
    }

    // MARK: - ESM

    private static func esm(_ type: Int, _ p: [UInt8], _ out: inout [Field]) throws {
        out.append(Field(label: "EPS bearer identity", value: "\(try u8(p, 0) >> 4)"))
        out.append(Field(label: "Procedure transaction", value: "\(try u8(p, 1))"))
        switch type {
        case 0xD0: // PDN connectivity request
            out.append(Field(label: "PDN type", value: PDN_TYPE[try u8(p, 3) >> 4] ?? "reserved"))
            out.append(Field(label: "Request type", value: REQUEST_TYPE[try u8(p, 3) & 0x0F] ?? "reserved"))
            try optional(p, 4) { tag, at, length in
                if tag == 0x28 { out.append(Field(label: "APN", value: try apn(p, at, length))) }
            }
        case 0xC1: // Activate default EPS bearer context request
            var at = 3
            let qosLength = try u8(p, at)
            out.append(Field(label: "QCI", value: "\(try u8(p, at + 1))"))
            at += 1 + qosLength
            let apnLength = try u8(p, at)
            out.append(Field(label: "APN", value: try apn(p, at + 1, apnLength)))
            at += 1 + apnLength
            if let address = try pdnAddress(p, at + 1, try u8(p, at)) { out.append(address) }
            at += 1 + (try u8(p, at))
            try optional(p, at) { tag, valueAt, length in
                if tag == 0x27 || tag == 0x7B { out.append(contentsOf: try pco(p, valueAt, length)) }
            }
        case 0xC5: // Activate dedicated EPS bearer context request
            out.append(Field(label: "Linked bearer", value: "\(try u8(p, 3) & 0x0F)"))
            out.append(Field(label: "QCI", value: "\(try u8(p, 5))"))
        case 0xDA:
            try optional(p, 3) { tag, at, length in
                if tag == 0x28 { out.append(Field(label: "APN", value: try apn(p, at, length))) }
            }
        default:
            break
        }
    }

    // MARK: - Information elements

    /// EPS mobile identity, LV at `at`: IMSI, GUTI or IMEI.
    private static func identityLv(_ p: [UInt8], _ at: Int) throws -> Field? {
        let length = try u8(p, at)
        let start = at + 1
        switch try u8(p, start) & 0x07 {
        case 6: // GUTI
            let plmn = try plmn(p, start + 1)
            let mmeGroup = (try u8(p, start + 4) << 8) | (try u8(p, start + 5))
            let mmeCode = try u8(p, start + 6)
            let mTmsi = (Int64(try u8(p, start + 7)) << 24) | (Int64(try u8(p, start + 8)) << 16)
                | (Int64(try u8(p, start + 9)) << 8) | Int64(try u8(p, start + 10))
            return Field(label: "Identity", value: "GUTI", children: [
                Field(label: "PLMN", value: plmn),
                Field(label: "MME group", value: "\(mmeGroup)"),
                Field(label: "MME code", value: "\(mmeCode)"),
                Field(label: "M-TMSI", value: Fmt.hex(mTmsi, width: 8, uppercase: false)),
            ])
        case 1: return Field(label: "Identity", value: "IMSI \(try bcdDigits(p, start, length))")
        case 2, 3: return Field(label: "Identity", value: "IMEI \(try bcdDigits(p, start, length))")
        default: return nil
        }
    }

    /// Plain BCD digits, low nibble first, stopping at the 0xF filler.
    static func bcd(_ p: [UInt8], _ at: Int, _ octets: Int) throws -> String {
        var s = ""
        for i in 0..<max(0, octets) {
            let o = try u8(p, at + i)
            let low = o & 0x0F
            if low == 0x0F { break }
            s += "\(low)"
            let high = o >> 4
            if high == 0x0F { break }
            s += "\(high)"
        }
        return s
    }

    /// Digits of an odd/even BCD identity: the first digit in the high nibble of the type octet.
    private static func bcdDigits(_ p: [UInt8], _ start: Int, _ length: Int) throws -> String {
        let odd = try u8(p, start) & 0x08 != 0
        var s = "\(try u8(p, start) >> 4)"
        if length > 1 {
            for i in 1..<length {
                let o = try u8(p, start + i)
                s += "\(o & 0x0F)"
                if i < length - 1 || odd { s += "\(o >> 4)" }
            }
        }
        return s
    }

    /// Three octets of BCD MCC and MNC, as "001-01".
    static func plmn(_ p: [UInt8], _ at: Int) throws -> String {
        let o1 = try u8(p, at)
        let o2 = try u8(p, at + 1)
        let o3 = try u8(p, at + 2)
        let mcc = "\(o1 & 0x0F)\(o1 >> 4)\(o2 & 0x0F)"
        let mnc3 = o2 >> 4
        let mnc = "\(o3 & 0x0F)\(o3 >> 4)" + (mnc3 == 0x0F ? "" : "\(mnc3)")
        return "\(mcc)-\(mnc)"
    }

    private static func firstTai(_ p: [UInt8], _ at: Int, _ length: Int) throws -> Field? {
        if length < 6 { return nil }
        // All three list types put the first PLMN and TAC straight after the type-and-count octet.
        let tac = (try u8(p, at + 4) << 8) | (try u8(p, at + 5))
        return Field(label: "Tracking area", value: "\(try plmn(p, at + 1)) TAC \(tac)")
    }

    /// APN: length-prefixed labels, shown dotted.
    static func apn(_ p: [UInt8], _ at: Int, _ length: Int) throws -> String {
        var labels: [String] = []
        var i = at
        while i < at + length {
            let n = try u8(p, i)
            labels.append(try Bytes.ascii(p, i + 1, n))
            i += 1 + n
        }
        return labels.joined(separator: ".")
    }

    /// PDN address: a PDN type, then IPv4 (4), an IPv6 interface identifier (8), or both.
    private static func pdnAddress(_ p: [UInt8], _ at: Int, _ length: Int) throws -> Field? {
        let type = try u8(p, at) & 0x07
        var children = [Field(label: "PDN type", value: PDN_TYPE[type] ?? "reserved")]
        switch type {
        case 1:
            children.append(Field(label: "IPv4", value: try ipv4(p, at + 1)))
        case 2:
            children.append(Field(label: "IPv6 interface ID", value: try ipv6Iid(p, at + 1)))
        case 3:
            children.append(Field(label: "IPv6 interface ID", value: try ipv6Iid(p, at + 1)))
            children.append(Field(label: "IPv4", value: try ipv4(p, at + 9)))
        default:
            break
        }
        if length < 5 { return nil }
        // The row shows the IPv4 address when there is one: it is the one people ping.
        let shown = (children.first { $0.label == "IPv4" } ?? children[children.count - 1]).value
        return Field(label: "PDN address", value: shown, children: children)
    }

    private static func ipv4(_ p: [UInt8], _ at: Int) throws -> String {
        var parts: [String] = []
        for i in 0..<4 { parts.append("\(try u8(p, at + i))") }
        return parts.joined(separator: ".")
    }

    /// Wireshark writes the 64-bit interface identifier as "::" and four hex groups; so does this.
    private static func ipv6Iid(_ p: [UInt8], _ at: Int) throws -> String {
        var groups: [String] = []
        for i in 0..<4 {
            groups.append(String((try u8(p, at + 2 * i) << 8) | (try u8(p, at + 2 * i + 1)), radix: 16))
        }
        return "::" + groups.joined(separator: ":")
    }

    /// Walks optional IEs from `at`. Tags 0x80 and up are one-octet (type 1 and 2) IEs; ESM cause (0x58) and
    /// LLC SAPI (0x32) are two-octet TVs; the extended PCO (0x7B) and extended QoS-like containers (0x78) have
    /// a two-octet length; the rest are TLVs with one length octet.
    private static func optional(_ p: [UInt8], _ at: Int,
                                 _ each: (_ tag: Int, _ valueAt: Int, _ length: Int) throws -> Void) throws {
        var i = at
        while i < p.count {
            let tag = try u8(p, i)
            if tag >= 0x80 {
                i += 1
                continue
            }
            if tag == 0x58 || tag == 0x32 {
                i += 2
                continue
            }
            if tag == 0x7B || tag == 0x78 { // LV-E: two-octet length
                let length = (try u8(p, i + 1) << 8) | (try u8(p, i + 2))
                try each(tag, i + 3, length)
                i += 3 + length
                continue
            }
            let length = try u8(p, i + 1)
            try each(tag, i + 2, length)
            i += 2 + length
        }
    }

    /// Protocol configuration options (TS 24.008), network to phone: the DNS servers and P-CSCFs.
    /// The rest (IPCP, slices, QoS rules) is Wireshark's to show. Containers 0x0023 and 0x0024 carry a
    /// two-octet length; everything else one.
    private static func pco(_ p: [UInt8], _ at: Int, _ length: Int) throws -> [Field] {
        let end = min(at + length, p.count)
        var out: [Field] = []
        var i = at + 1 // configuration protocol octet
        while i + 3 <= end {
            let id = (try u8(p, i) << 8) | (try u8(p, i + 1))
            let wide = id == 0x0023 || id == 0x0024
            let size = wide ? (try u8(p, i + 2) << 8) | (try u8(p, i + 3)) : try u8(p, i + 2)
            let valueAt = i + (wide ? 4 : 3)
            if valueAt + size > end { break }
            if id == 0x000D && size == 4 {
                out.append(Field(label: "DNS server", value: try ipv4(p, valueAt)))
            } else if id == 0x0003 && size == 16 {
                out.append(Field(label: "DNS server", value: try ipv6(p, valueAt)))
            } else if id == 0x000C && size == 4 {
                out.append(Field(label: "P-CSCF", value: try ipv4(p, valueAt)))
            } else if id == 0x0001 && size == 16 {
                out.append(Field(label: "P-CSCF", value: try ipv6(p, valueAt)))
            }
            i = valueAt + size
        }
        return out
    }

    /// An IPv6 address the way Wireshark and RFC 5952 write it: the longest run of zero groups as "::".
    static func ipv6(_ p: [UInt8], _ at: Int) throws -> String {
        var groups: [Int] = []
        for i in 0..<8 { groups.append((try u8(p, at + 2 * i) << 8) | (try u8(p, at + 2 * i + 1))) }
        var bestStart = -1
        var bestLength = 1
        var i = 0
        while i < 8 {
            if groups[i] == 0 {
                var j = i
                while j < 8 && groups[j] == 0 { j += 1 }
                if j - i > bestLength {
                    bestStart = i
                    bestLength = j - i
                }
                i = j
            } else {
                i += 1
            }
        }
        func hex(_ range: Range<Int>) -> String { range.map { String(groups[$0], radix: 16) }.joined(separator: ":") }
        return bestStart < 0 ? hex(0..<8) : hex(0..<bestStart) + "::" + hex((bestStart + bestLength)..<8)
    }

    /// GPRS timer (TS 24.008): 3-bit unit, 5-bit value.
    static func gprsTimer(_ octet: Int) -> String {
        let value = octet & 0x1F
        switch octet >> 5 {
        case 0: return "\(value * 2) s"
        case 1: return "\(value) min"
        case 2: return "\(value * 6) min"
        case 7: return "deactivated"
        default: return "\(value) min"
        }
    }

    private static func ksi(_ value: Int) -> String { value & 0x07 == 7 ? "no key available" : "\(value & 0x07)" }

    private static func hex(_ p: [UInt8], _ at: Int, _ length: Int) throws -> String {
        var s = ""
        for i in 0..<max(0, length) { s += Fmt.hex(try u8(p, at + i), width: 2, prefix: false, uppercase: false) }
        return s
    }

    private static func u8(_ p: [UInt8], _ i: Int) throws -> Int { try Bytes.u8(p, i) }

    private static let ATTACH_TYPE = [1: "EPS attach", 2: "combined EPS/IMSI attach", 3: "EPS RLOS attach", 6: "EPS emergency attach"]
    private static let ATTACH_RESULT = [1: "EPS only", 2: "combined EPS/IMSI"]
    private static let DETACH_TYPE_UL = [1: "EPS detach", 2: "IMSI detach", 3: "combined EPS/IMSI detach"]
    private static let DETACH_TYPE_DL = [1: "re-attach required", 2: "re-attach not required", 3: "IMSI detach"]
    private static let UPDATE_TYPE = [0: "TA updating", 1: "combined TA/LA updating", 2: "combined TA/LA with IMSI attach", 3: "periodic updating"]
    private static let UPDATE_RESULT = [0: "TA updated", 1: "combined TA/LA updated", 4: "TA updated, ISR activated", 5: "combined TA/LA updated, ISR activated"]
    private static let IDENTITY_TYPE = [1: "IMSI", 2: "IMEI", 3: "IMEISV", 4: "TMSI"]
    private static let PDN_TYPE = [1: "IPv4", 2: "IPv6", 3: "IPv4v6", 5: "non-IP", 6: "Ethernet"]
    private static let REQUEST_TYPE = [1: "initial request", 2: "handover", 4: "emergency"]
    private static let REGISTRATION_TYPE = [
        1: "initial registration", 2: "mobility registration updating", 3: "periodic registration updating",
        4: "emergency registration", 7: "SNPN onboarding registration",
    ]
    private static let REGISTRATION_RESULT = [1: "3GPP access", 2: "non-3GPP access", 3: "3GPP and non-3GPP access"]
    private static let ACCESS_TYPE = [1: "3GPP access", 2: "non-3GPP access", 3: "3GPP and non-3GPP access"]
    private static let SERVICE_TYPE = [
        0: "signalling", 1: "data", 2: "mobile terminated services", 3: "emergency services",
        4: "emergency services fallback", 5: "high priority access", 6: "elevated signalling",
    ]
    private static let FIVE_GS_IDENTITY_TYPE = [1: "SUCI", 2: "5G-GUTI", 3: "IMEI", 4: "5G-S-TMSI", 5: "IMEISV"]
    private static let SUCI_SCHEME = [0: "null scheme", 1: "Profile A", 2: "Profile B"]
    private static let FIVE_GS_PDN_TYPE = [1: "IPv4", 2: "IPv6", 3: "IPv4v6", 4: "unstructured", 5: "Ethernet"]
    private static let PAYLOAD_CONTAINER = [
        1: "N1 SM information", 2: "SMS", 3: "LTE positioning protocol", 4: "SOR transparent container",
        5: "UE policy container", 6: "UE parameters update", 8: "CIoT user data container",
    ]
}
