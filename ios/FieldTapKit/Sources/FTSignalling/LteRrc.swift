// Port of android/diag/src/main/kotlin/com/fieldtap/diag/LteRrc.kt at contract v1 (D2: packet version 30 is
// header layout E with PDU map D). Keep it line for line with the Kotlin so later changes port the same way.

import FTCore
import FTModel

/// 0xB0C0 LTE RRC OTA packets: which cell a message was on, which channel, what the message is, and the
/// handful of fields an engineer reads first.
///
/// Record body: packet version (u8), a header whose layout depends on the version, then the RRC PDU (UPER).
/// The version picks a layout and a PDU-number map, and the layout's trailing length (which must equal the
/// bytes after it) confirms or rejects the pick. An unknown version is probed rather than guessed.
///
/// Names come from the outer CHOICE, a few bits at the front of the PDU. Past that, only fields at fixed bit
/// positions are read (causes, identities), each checked against Wireshark's decode of the same bytes.
public enum LteRrc {
    public enum Channel: String, CaseIterable, Hashable, Sendable {
        case BCCH_BCH = "BCCH-BCH", BCCH_DL_SCH = "BCCH-DL-SCH", MCCH, PCCH, DL_CCCH = "DL-CCCH", DL_DCCH = "DL-DCCH"
        case UL_CCCH = "UL-CCCH", UL_DCCH = "UL-DCCH"

        public var label: String { rawValue }
        public var uplink: Bool { self == .UL_CCCH || self == .UL_DCCH }
    }

    /// One RRC message as the modem logged it.
    public struct Message: Hashable, Sendable {
        public var packetVersion: Int
        public var pci: Int
        public var earfcn: Int64
        public var sfn: Int
        public var subframe: Int
        /// Nil when the PDU number is one this decoder does not map.
        public var channel: Channel?
        public var pduNumber: Int
        /// The ASN.1 identifier, e.g. "rrcConnectionRequest"; nil when it could not be read.
        public var asn1Name: String?
        public var payload: [UInt8]
        /// Fields read from fixed positions, in display order.
        public var fields: [Field]

        public init(packetVersion: Int, pci: Int, earfcn: Int64, sfn: Int, subframe: Int, channel: Channel?,
                    pduNumber: Int, asn1Name: String?, payload: [UInt8], fields: [Field]) {
            self.packetVersion = packetVersion
            self.pci = pci
            self.earfcn = earfcn
            self.sfn = sfn
            self.subframe = subframe
            self.channel = channel
            self.pduNumber = pduNumber
            self.asn1Name = asn1Name
            self.payload = payload
            self.fields = fields
        }
    }

    // MARK: - Header

    private struct Raw {
        var pci: Int
        var earfcn: Int64
        var sfnSubfn: Int
        var pduNum: Int
        var length: Int
    }

    /// A header layout: its size after the version byte and where its fields sit (offset `o` is after it).
    private struct Layout: Sendable {
        var name: String
        var size: Int
        var read: @Sendable ([UInt8], Int) -> Raw
    }

    private static func u8(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) }
    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Bytes.le16(b, i) }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int64 { Bytes.le32(b, i) }

    // Offsets are after the version byte. All little-endian, no padding.
    private static let A = Layout(name: "A", size: 12) { b, o in
        Raw(pci: u16(b, o + 3), earfcn: Int64(u16(b, o + 5)), sfnSubfn: u16(b, o + 7), pduNum: u8(b, o + 9), length: u16(b, o + 10))
    }
    private static let B = Layout(name: "B", size: 14) { b, o in
        Raw(pci: u16(b, o + 3), earfcn: u32(b, o + 5), sfnSubfn: u16(b, o + 9), pduNum: u8(b, o + 11), length: u16(b, o + 12))
    }
    private static let C = Layout(name: "C", size: 18) { b, o in
        Raw(pci: u16(b, o + 3), earfcn: u32(b, o + 5), sfnSubfn: u16(b, o + 9), pduNum: u8(b, o + 11), length: u16(b, o + 16))
    }

    /// HDR_D: C with three more bytes before the PCI (a release byte and an unexplained u16). SM8450, version 27.
    private static let D = Layout(name: "D", size: 20) { b, o in
        Raw(pci: u16(b, o + 5), earfcn: u32(b, o + 7), sfnSubfn: u16(b, o + 11), pduNum: u8(b, o + 13), length: u16(b, o + 18))
    }

    /// Contract v1 (D2), version 30 (iPhone 17 / M25 modem): D plus three trailing bytes.
    private static let E = Layout(name: "E", size: 23) { b, o in
        Raw(pci: u16(b, o + 5), earfcn: u32(b, o + 7), sfnSubfn: u16(b, o + 11), pduNum: u8(b, o + 13), length: u16(b, o + 18))
    }

    private static let LAYOUTS = [A, B, C, D, E]

    private static let MAP_A: [Int: Channel] = [1: .BCCH_BCH, 2: .BCCH_DL_SCH, 3: .MCCH, 4: .PCCH, 5: .DL_CCCH, 6: .DL_DCCH, 7: .UL_CCCH, 8: .UL_DCCH]
    private static let MAP_B: [Int: Channel] = [8: .BCCH_BCH, 9: .BCCH_DL_SCH, 10: .MCCH, 11: .PCCH, 12: .DL_CCCH, 13: .DL_DCCH, 14: .UL_CCCH, 15: .UL_DCCH]
    private static let MAP_C: [Int: Channel] = [1: .BCCH_BCH, 2: .BCCH_DL_SCH, 4: .MCCH, 5: .PCCH, 6: .DL_CCCH, 7: .DL_DCCH, 8: .UL_CCCH, 9: .UL_DCCH]
    private static let MAP_D: [Int: Channel] = [1: .BCCH_BCH, 3: .BCCH_DL_SCH, 6: .MCCH, 7: .PCCH, 8: .DL_CCCH, 9: .DL_DCCH, 10: .UL_CCCH, 11: .UL_DCCH]

    private static func preferred(_ version: Int) -> (layout: Layout?, map: [Int: Channel]) {
        switch version {
        case 2, 3, 4, 6, 7, 8, 13, 22: (A, MAP_A)
        case 9, 12: (B, MAP_B)
        case 14, 15, 16: (C, MAP_C)
        case 19, 26: (C, MAP_D)
        case 27: (D, MAP_D)
        case 30: (E, MAP_D)
        default: (nil, version >= 19 ? MAP_D : version >= 14 ? MAP_C : version >= 9 ? MAP_B : MAP_A)
        }
    }

    public static func decode(_ body: [UInt8]) -> Message? {
        if body.count < 1 + A.size { return nil }
        let version = u8(body, 0)
        let (layout, map) = preferred(version)
        let order = (layout.map { [$0] } ?? []) + LAYOUTS.filter { $0.name != layout?.name }
        var chosen: (Layout, Raw)?
        for candidate in order {
            if body.count < 1 + candidate.size { continue }
            let raw = candidate.read(body, 1)
            // The length that fits is the layout that is right; the first that parses is the fallback.
            if raw.length == body.count - 1 - candidate.size {
                chosen = (candidate, raw)
                break
            }
            if chosen == nil { chosen = (candidate, raw) }
        }
        guard let (fit, raw) = chosen else { return nil }
        let start = 1 + fit.size
        let payload = raw.length >= 1 && raw.length <= body.count - start
            ? Array(body[start..<start + raw.length]) : Array(body[start...])
        let channel = map[raw.pduNum]
        let name = channel.flatMap { outerName($0, payload) }
        let fields: [Field] = if let channel, let name { Details.of(channel, name, payload) } else { [] }
        return Message(packetVersion: version, pci: raw.pci, earfcn: raw.earfcn, sfn: raw.sfnSubfn >> 4,
                       subframe: raw.sfnSubfn & 0xF, channel: channel, pduNumber: raw.pduNum, asn1Name: name,
                       payload: payload, fields: fields)
    }

    // MARK: - Names

    private static let DL_DCCH = [
        "csfbParametersResponseCDMA2000", "dlInformationTransfer", "handoverFromEUTRAPreparationRequest",
        "mobilityFromEUTRACommand", "rrcConnectionReconfiguration", "rrcConnectionRelease", "securityModeCommand",
        "ueCapabilityEnquiry", "counterCheck", "ueInformationRequest", "loggedMeasurementConfiguration",
        "rnReconfiguration", "rrcConnectionResume", "spare3", "spare2", "spare1",
    ]
    private static let UL_DCCH = [
        "csfbParametersRequestCDMA2000", "measurementReport", "rrcConnectionReconfigurationComplete",
        "rrcConnectionReestablishmentComplete", "rrcConnectionSetupComplete", "securityModeComplete",
        "securityModeFailure", "ueCapabilityInformation", "ulHandoverPreparationTransfer", "ulInformationTransfer",
        "counterCheckResponse", "ueInformationResponse", "proximityIndication", "rnReconfigurationComplete",
        "mbmsCountingResponse", "interFreqRSTDMeasurementIndication",
    ]
    private static let DL_CCCH = ["rrcConnectionReestablishment", "rrcConnectionReestablishmentReject", "rrcConnectionReject", "rrcConnectionSetup"]
    private static let UL_CCCH = ["rrcConnectionReestablishmentRequest", "rrcConnectionRequest"]
    private static let BCCH_DL_SCH = ["systemInformation", "systemInformationBlockType1"]

    private static func outerName(_ channel: Channel, _ payload: [UInt8]) -> String? {
        if channel == .BCCH_BCH { return "masterInformationBlock" }
        if payload.isEmpty { return nil }
        var bits = PerBits(payload)
        do {
            if try bits.read(1) != 0 { return "messageClassExtension" }
            switch channel {
            case .DL_DCCH: return DL_DCCH[try bits.read(4)]
            case .UL_DCCH: return UL_DCCH[try bits.read(4)]
            case .DL_CCCH: return DL_CCCH[try bits.read(2)]
            case .UL_CCCH: return UL_CCCH[try bits.read(1)]
            case .BCCH_DL_SCH: return BCCH_DL_SCH[try bits.read(1)]
            case .PCCH: return "paging"
            case .MCCH: return "mbsfnAreaConfiguration"
            case .BCCH_BCH: return "masterInformationBlock"
            }
        } catch {
            return nil
        }
    }

    /// "rrcConnectionReconfigurationComplete" -> "RRC Connection Reconfiguration Complete"; unknown names are
    /// split at each lower-to-upper boundary, as Kotlin's `Regex("([a-z0-9])([A-Z])")` replacement does.
    public static func readable(_ asn1: String) -> String {
        if let known = READABLE[asn1] { return known }
        let chars = Array(asn1)
        var spaced = ""
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count, isLowerOrDigit(chars[i]), isUpper(chars[i + 1]) {
                spaced.append(chars[i])
                spaced.append(" ")
                spaced.append(chars[i + 1])
                i += 2
            } else {
                spaced.append(chars[i])
                i += 1
            }
        }
        return spaced.components(separatedBy: " ").map { word in
            switch word.lowercased() {
            case "rrc": "RRC"
            case "ue": "UE"
            case "ul": "UL"
            case "dl": "DL"
            default: word.prefix(1).uppercased() + word.dropFirst()
            }
        }.joined(separator: " ")
    }

    private static func isLowerOrDigit(_ c: Character) -> Bool { ("a"..."z").contains(c) || ("0"..."9").contains(c) }
    private static func isUpper(_ c: Character) -> Bool { ("A"..."Z").contains(c) }

    private static let READABLE: [String: String] = [
        "systemInformationBlockType1": "SIB1",
        "systemInformation": "System Information",
        "masterInformationBlock": "MIB",
        "ulInformationTransfer": "UL Information Transfer",
        "dlInformationTransfer": "DL Information Transfer",
        "ueCapabilityEnquiry": "UE Capability Enquiry",
        "ueCapabilityInformation": "UE Capability Information",
        "csfbParametersResponseCDMA2000": "CSFB Parameters Response CDMA2000",
        "csfbParametersRequestCDMA2000": "CSFB Parameters Request CDMA2000",
        "handoverFromEUTRAPreparationRequest": "Handover From EUTRA Preparation Request",
        "mobilityFromEUTRACommand": "Mobility From EUTRA Command",
        "interFreqRSTDMeasurementIndication": "Inter-Freq RSTD Measurement Indication",
    ]

    // MARK: - Fields at fixed positions

    /// The label of the field that marks an RRCConnectionReconfiguration as a handover command.
    public static let handover = Event.handoverFieldLabel

    /// Fields past the outer CHOICE. Each decode is pinned to Wireshark's reading of a real or constructed PDU.
    enum Details {
        private static let ESTABLISHMENT_CAUSE = [
            "emergency", "highPriorityAccess", "mt-Access", "mo-Signalling", "mo-Data", "delayTolerantAccess", "mo-VoiceCall", "spare1",
        ]
        private static let RELEASE_CAUSE = ["loadBalancingTAUrequired", "other", "cs-FallbackHighPriority", "rrc-Suspend"]
        private static let REESTABLISHMENT_CAUSE = ["reconfigurationFailure", "handoverFailure", "otherFailure", "spare1"]

        static func of(_ channel: Channel, _ name: String, _ payload: [UInt8]) -> [Field] {
            do {
                switch name {
                case "rrcConnectionRequest": return try connectionRequest(payload)
                case "rrcConnectionRelease": return try connectionRelease(payload)
                case "rrcConnectionReject": return try connectionReject(payload)
                case "rrcConnectionReestablishmentRequest": return try reestablishmentRequest(payload)
                case "measurementReport": return try measurementReport(payload)
                case "rrcConnectionReconfiguration": return try connectionReconfiguration(payload)
                default: return []
                }
            } catch {
                // A PDU shorter than its own structure is truncated or not what its CHOICE claims. Say nothing.
                return []
            }
        }

        /// UL-CCCH: c1, rrcConnectionRequest, r8, ue-Identity CHOICE, establishmentCause.
        private static func connectionRequest(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 2)
            if try b.read(1) != 0 { return [] } // criticalExtensionsFuture
            var fields: [Field] = []
            if try b.read(1) == 0 {
                let mmec = try b.read(8)
                let mTmsi = try b.readLong(32)
                fields.append(Field(label: "UE identity", value: "S-TMSI", children: [
                    Field(label: "MMEC", value: "\(mmec)"),
                    Field(label: "M-TMSI", value: Fmt.hex(mTmsi, width: 8, uppercase: false)),
                ]))
            } else {
                _ = try b.readLong(40)
                fields.append(Field(label: "UE identity", value: "random value"))
            }
            fields.append(Field(label: "Establishment cause", value: ESTABLISHMENT_CAUSE[try b.read(3)]))
            return fields
        }

        /// DL-DCCH: rrc-TransactionIdentifier, c1, r8, optional bitmap (3), releaseCause, then a redirect if present.
        private static func connectionRelease(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 5)
            _ = try b.read(2) // transaction id
            if try b.read(1) != 0 { return [] }
            if try b.read(2) != 0 { return [] } // not r8
            let redirect = try b.read(1) == 1
            _ = try b.read(1) // idleModeMobilityControlInfo
            _ = try b.read(1) // nonCriticalExtension
            var fields = [Field(label: "Release cause", value: RELEASE_CAUSE[try b.read(2)])]
            if redirect {
                // RedirectedCarrierInfo: extensible CHOICE of six; eutra carries a 16-bit EARFCN.
                let extended = try b.read(1) == 1
                let index = extended ? -1 : try b.read(3)
                if index == 0 {
                    fields.append(Field(label: "Redirected to", value: "EUTRA EARFCN \(try b.read(16))"))
                } else {
                    let rats = ["EUTRA", "GERAN", "UTRA-FDD", "UTRA-TDD", "CDMA2000 HRPD", "CDMA2000 1xRTT"]
                    fields.append(Field(label: "Redirected to", value: rats.indices.contains(index) ? rats[index] : "another RAT"))
                }
            }
            return fields
        }

        /// DL-DCCH: transaction id, c1, r8, then the r8 presence bitmap: measConfig, mobilityControlInfo,
        /// dedicatedInfoNASList, radioResourceConfigDedicated, securityConfigHO, nonCriticalExtension.
        ///
        /// The one with mobilityControlInfo is a handover command. Its target sits at a fixed place only when
        /// no measConfig comes before it; otherwise the target is the cell the next message is logged on.
        private static func connectionReconfiguration(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 5)
            _ = try b.read(2) // transaction id
            if try b.read(1) != 0 { return [] }
            if try b.read(3) != 0 { return [] } // not r8
            let meas = try b.read(1) == 1
            let mobility = try b.read(1) == 1
            let nas = try b.read(1) == 1
            let radio = try b.read(1) == 1
            let securityHo = try b.read(1) == 1
            _ = try b.read(1) // nonCriticalExtension
            var fields: [Field] = []
            if mobility { fields.append(Field(label: handover, value: meas ? "command" : try mobilityTarget(&b))) }
            let carries = [
                meas ? "measurement config" : nil,
                nas ? "NAS" : nil,
                radio ? "radio resources" : nil,
                securityHo ? "handover security" : nil,
            ].compactMap { $0 }
            if !carries.isEmpty { fields.append(Field(label: "Carries", value: carries.joined(separator: ", "))) }
            return fields
        }

        /// MobilityControlInfo: extension bit, four optionals, targetPhysCellId (9), then carrierFreq if present.
        private static func mobilityTarget(_ b: inout PerBits) throws -> String {
            _ = try b.read(1)
            let carrier = try b.read(1) == 1
            _ = try b.read(3) // carrierBandwidth, additionalSpectrumEmission, rach-ConfigDedicated
            let pci = try b.read(9)
            if !carrier { return "to PCI \(pci), same EARFCN" }
            _ = try b.read(1) // ul-CarrierFreq
            return "to PCI \(pci), EARFCN \(try b.read(16))"
        }

        /// DL-CCCH: c1, rrcConnectionReject, r8, optional bitmap (1), waitTime 1..16 s.
        private static func connectionReject(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 3)
            if try b.read(1) != 0 { return [] }
            if try b.read(2) != 0 { return [] }
            _ = try b.read(1) // nonCriticalExtension
            return [Field(label: "Wait time", value: "\(try b.read(4) + 1) s")]
        }

        /// UL-CCCH: c1, reestablishment request, r8, C-RNTI (16), PCI (9), shortMAC-I (16), cause.
        private static func reestablishmentRequest(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 2)
            if try b.read(1) != 0 { return [] }
            let cRnti = try b.read(16)
            let pci = try b.read(9)
            _ = try b.read(16)
            return [
                Field(label: "Cause", value: REESTABLISHMENT_CAUSE[try b.read(2)]),
                Field(label: "Previous cell PCI", value: "\(pci)"),
                Field(label: "C-RNTI", value: Fmt.hex(cRnti, width: 4, uppercase: false)),
            ]
        }

        /// UL-DCCH: c1, measurementReport, r8 (1 + 3 bits), the r8 bitmap (1), then MeasResults: extension bit,
        /// neighbour-present bit, measId (1..32), PCell RSRP and RSRQ, and an EUTRA neighbour list when present.
        /// RSRP is reported as 0..97 for -140..-44 dBm; RSRQ as 0..34 for -19.5..-3 dB.
        private static func measurementReport(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 5)
            if try b.read(1) != 0 { return [] }
            if try b.read(3) != 0 { return [] }
            _ = try b.read(1) // nonCriticalExtension
            _ = try b.read(1) // MeasResults extension
            let neighbours = try b.read(1) == 1
            let measId = try b.read(5) + 1
            var fields = [
                Field(label: "Measurement ID", value: "\(measId)"),
                Field(label: "Serving RSRP", value: rsrp(try b.read(7))),
                Field(label: "Serving RSRQ", value: rsrq(try b.read(6))),
            ]
            if try neighbours && b.read(1) == 0 && b.read(2) == 0 {
                let count = try b.read(3) + 1
                var cells: [Field] = []
                for _ in 1...count {
                    let cgi = try b.read(1) == 1
                    let pci = try b.read(9)
                    if cgi {
                        return fields + [Field(label: "Neighbours", value: "\(count) reported, with cell identity (not decoded)")]
                    }
                    let ext = try b.read(1) == 1
                    let hasRsrp = try b.read(1) == 1
                    let hasRsrq = try b.read(1) == 1
                    let r = hasRsrp ? rsrp(try b.read(7)) : "—"
                    let q = hasRsrq ? rsrq(try b.read(6)) : "—"
                    if ext { try b.skipExtensionAdditions() }
                    cells.append(Field(label: "PCI \(pci)", value: "\(r) · \(q)"))
                }
                fields.append(Field(label: "Neighbours", value: "\(count)", children: cells))
            }
            return fields
        }

        /// A reported RSRP index is a 1 dB bin, not a value: n means n-141 <= RSRP < n-140 (TS 36.133). Quoting
        /// n-140 alone reads one dB high on every report, so the bin is shown, as Wireshark shows it.
        static func rsrp(_ v: Int) -> String {
            switch v {
            case 0: "< −140 dBm"
            case 97: "≥ −44 dBm"
            default: "\(v - 141) to \(v - 140) dBm".replacingOccurrences(of: "-", with: "−")
            }
        }

        /// RSRQ index n: -20 + n/2 <= RSRQ < -19.5 + n/2 dB.
        static func rsrq(_ v: Int) -> String {
            switch v {
            case 0: "< −19.5 dB"
            case 34: "≥ −3 dB"
            default: "\(Fmt.fixed(-20 + Double(v) * 0.5, 1)) to \(Fmt.fixed(-19.5 + Double(v) * 0.5, 1)) dB"
                .replacingOccurrences(of: "-", with: "−")
            }
        }
    }
}
