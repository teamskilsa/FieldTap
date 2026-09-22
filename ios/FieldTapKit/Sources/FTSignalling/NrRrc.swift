// Port of android/diag/src/main/kotlin/com/fieldtap/diag/NrRrc.kt at contract v1 (D2: packet version 26 is
// header layout E; PDU 11 is RRCReconfiguration and 12 RRCReconfigurationComplete).

import FTCore
import FTModel

/// 0xB821 NR RRC OTA packets: the cell, the channel, the message, and the 5G NAS carried inside it.
///
/// Same shape as `LteRrc` (packet version, a header whose layout the version picks, then the PDU), with the
/// header also confirmed by its trailing length, so a wrong table entry costs nothing and a new modem generation
/// is picked up by probing. 5G NAS travels inside it: `Message.nas` pulls `dedicatedNAS-Message` out of
/// RRCSetupComplete, ULInformationTransfer and DLInformationTransfer.
public enum NrRrc {
    public enum Channel: String, CaseIterable, Hashable, Sendable {
        case BCCH_BCH = "BCCH-BCH", BCCH_DL_SCH = "BCCH-DL-SCH", DL_CCCH = "DL-CCCH", DL_DCCH = "DL-DCCH", PCCH
        case UL_CCCH = "UL-CCCH", UL_CCCH1 = "UL-CCCH1", UL_DCCH = "UL-DCCH"
        /// EN-DC: an NR message the modem logs on its own, having carried it inside an LTE RRC message.
        case RRC_RECONFIGURATION = "RRCReconfiguration"
        case RRC_RECONFIGURATION_COMPLETE = "RRCReconfigurationComplete"

        public var label: String { rawValue }
        public var uplink: Bool {
            switch self {
            case .UL_CCCH, .UL_CCCH1, .UL_DCCH, .RRC_RECONFIGURATION_COMPLETE: true
            default: false
            }
        }
    }

    public struct Message: Hashable, Sendable {
        public var packetVersion: Int
        public var pci: Int
        public var arfcn: Int64
        /// SRB the message went on; nil when the header does not name one (broadcast and paging).
        public var bearerId: Int?
        public var channel: Channel?
        public var pduNumber: Int
        public var asn1Name: String?
        public var payload: [UInt8]
        public var fields: [Field]
        /// The NAS message this RRC message carried, when it carried one.
        public var nas: [UInt8]?

        public init(packetVersion: Int, pci: Int, arfcn: Int64, bearerId: Int?, channel: Channel?, pduNumber: Int,
                    asn1Name: String?, payload: [UInt8], fields: [Field], nas: [UInt8]?) {
            self.packetVersion = packetVersion
            self.pci = pci
            self.arfcn = arfcn
            self.bearerId = bearerId
            self.channel = channel
            self.pduNumber = pduNumber
            self.asn1Name = asn1Name
            self.payload = payload
            self.fields = fields
            self.nas = nas
        }
    }

    // MARK: - Header

    private struct Raw {
        var bearerId: Int
        var pci: Int
        var arfcn: Int64
        var pduNum: Int
        var length: Int
    }

    private struct Layout: Sendable {
        var name: String
        var size: Int
        var read: @Sendable ([UInt8], Int) -> Raw
    }

    private static func u8(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) }
    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Bytes.le16(b, i) }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int64 { Bytes.le32(b, i) }

    // Offsets are after the 4-byte packet version. All little-endian.
    /// rel, ver, rb, pci, arfcn, sfn/subframe (u16), pdu, sib mask, length.
    private static let A = Layout(name: "A", size: 18) { b, o in
        Raw(bearerId: u8(b, o + 2), pci: u16(b, o + 3), arfcn: u32(b, o + 5), pduNum: u8(b, o + 11), length: u16(b, o + 16))
    }

    /// A with a 32-bit frame field.
    private static let B = Layout(name: "B", size: 20) { b, o in
        Raw(bearerId: u8(b, o + 2), pci: u16(b, o + 3), arfcn: u32(b, o + 9 + 4), pduNum: u8(b, o + 13), length: u16(b, o + 18))
    }

    /// SM8450, packet version 17: five bytes of cell identity before the ARFCN, and a wider tail.
    private static let C = Layout(name: "C", size: 27) { b, o in
        Raw(bearerId: u8(b, o + 2), pci: u16(b, o + 3), arfcn: u32(b, o + 13), pduNum: u8(b, o + 20), length: u16(b, o + 25))
    }

    /// Contract v1 (D2), version 26 (iPhone 17 / M25 modem): C plus four trailing reserved bytes (35-byte header
    /// including the version).
    private static let E = Layout(name: "E", size: 31) { b, o in
        Raw(bearerId: u8(b, o + 2), pci: u16(b, o + 3), arfcn: u32(b, o + 13), pduNum: u8(b, o + 20), length: u16(b, o + 25))
    }

    private static let LAYOUTS = [E, C, B, A]

    private static let VERSIONS: [Int: Layout] = [
        7: A, 9: A, 12: A, 14: A,
        15: B, 19: B, 23: B, 25: B, 26: E,
        17: C, 27: C,
    ]

    private static let PDU_MAP: [Int: Channel] = [
        1: .BCCH_BCH, 2: .BCCH_DL_SCH, 3: .DL_CCCH, 4: .DL_DCCH,
        5: .PCCH, 6: .UL_CCCH, 7: .UL_CCCH1, 8: .UL_DCCH,
        9: .RRC_RECONFIGURATION, 10: .RRC_RECONFIGURATION_COMPLETE,
        11: .RRC_RECONFIGURATION, 12: .RRC_RECONFIGURATION_COMPLETE,
    ]

    private static let VERSION_SIZE = 4

    public static func decode(_ body: [UInt8]) -> Message? {
        if body.count < VERSION_SIZE + A.size { return nil }
        // Kotlin's `u32(body, 0).toInt()`.
        let version = Int(Int32(truncatingIfNeeded: u32(body, 0)))
        let preferred = VERSIONS[version]
        let order = (preferred.map { [$0] } ?? []) + LAYOUTS.filter { $0.name != preferred?.name }
        var chosen: (Layout, Raw)?
        for candidate in order {
            if body.count < VERSION_SIZE + candidate.size { continue }
            let raw = candidate.read(body, VERSION_SIZE)
            // The length that fits is the layout that is right; the first that parses is the fallback.
            if raw.length == body.count - VERSION_SIZE - candidate.size {
                chosen = (candidate, raw)
                break
            }
            if chosen == nil { chosen = (candidate, raw) }
        }
        guard let (fit, raw) = chosen else { return nil }
        let start = VERSION_SIZE + fit.size
        let payload = raw.length >= 1 && raw.length <= body.count - start
            ? Array(body[start..<start + raw.length]) : Array(body[start...])
        let channel = PDU_MAP[raw.pduNum]
        let name = channel.flatMap { outerName($0, payload) }
        let fields: [Field] = if channel != nil, let name { Details.of(name, payload) } else { [] }
        return Message(packetVersion: version, pci: raw.pci, arfcn: raw.arfcn,
                       bearerId: raw.bearerId != 0xFF ? raw.bearerId : nil, channel: channel,
                       pduNumber: raw.pduNum, asn1Name: name, payload: payload, fields: fields,
                       nas: name.flatMap { Details.nas($0, payload) })
    }

    // MARK: - Names

    private static let DL_DCCH = [
        "rrcReconfiguration", "rrcResume", "rrcRelease", "rrcReestablishment", "securityModeCommand",
        "dlInformationTransfer", "ueCapabilityEnquiry", "counterCheck", "mobilityFromNRCommand",
        "dlDedicatedMessageSegment", "ueInformationRequest", "dlInformationTransferMRDC",
        "loggedMeasurementConfiguration", "spare3", "spare2", "spare1",
    ]
    private static let UL_DCCH = [
        "measurementReport", "rrcReconfigurationComplete", "rrcSetupComplete", "rrcReestablishmentComplete",
        "rrcResumeComplete", "securityModeComplete", "securityModeFailure", "ulInformationTransfer",
        "locationMeasurementIndication", "ueCapabilityInformation", "counterCheckResponse",
        "ueAssistanceInformation", "failureInformation", "ulInformationTransferMRDC",
        "scgFailureInformation", "scgFailureInformationEUTRA",
    ]
    private static let DL_CCCH = ["rrcReject", "rrcSetup", "spare2", "spare1"]
    private static let UL_CCCH = ["rrcSetupRequest", "rrcResumeRequest", "rrcReestablishmentRequest", "rrcSystemInfoRequest"]
    private static let UL_CCCH1 = ["rrcResumeRequest1", "spare3", "spare2", "spare1"]
    private static let BCCH_DL_SCH = ["systemInformation", "systemInformationBlockType1"]

    private static func outerName(_ channel: Channel, _ payload: [UInt8]) -> String? {
        if payload.isEmpty { return nil }
        if channel == .RRC_RECONFIGURATION { return "rrcReconfiguration" }
        if channel == .RRC_RECONFIGURATION_COMPLETE { return "rrcReconfigurationComplete" }
        var bits = PerBits(payload)
        do {
            // BCCH-BCH is a SEQUENCE holding a CHOICE of two, with no c1 level above it.
            if channel == .BCCH_BCH { return try bits.read(1) == 0 ? "mib" : "messageClassExtension" }
            if try bits.read(1) != 0 { return "messageClassExtension" }
            switch channel {
            case .DL_DCCH: return DL_DCCH[try bits.read(4)]
            case .UL_DCCH: return UL_DCCH[try bits.read(4)]
            case .DL_CCCH: return DL_CCCH[try bits.read(2)]
            case .UL_CCCH: return UL_CCCH[try bits.read(2)]
            case .UL_CCCH1: return UL_CCCH1[try bits.read(2)]
            case .BCCH_DL_SCH: return BCCH_DL_SCH[try bits.read(1)]
            case .PCCH: return "paging"
            default: return nil
            }
        } catch {
            return nil
        }
    }

    /// "rrcSetupComplete" -> "RRC Setup Complete".
    public static func readable(_ asn1: String) -> String { READABLE[asn1] ?? LteRrc.readable(asn1) }

    private static let READABLE: [String: String] = [
        "mib": "MIB",
        "systemInformationBlockType1": "SIB1",
        "systemInformation": "System Information",
        "paging": "Paging",
        "ulInformationTransfer": "UL Information Transfer",
        "dlInformationTransfer": "DL Information Transfer",
        "ueCapabilityEnquiry": "UE Capability Enquiry",
        "ueCapabilityInformation": "UE Capability Information",
        "mobilityFromNRCommand": "Mobility From NR Command",
        "ulInformationTransferMRDC": "UL Information Transfer MRDC",
        "dlInformationTransferMRDC": "DL Information Transfer MRDC",
        "scgFailureInformationEUTRA": "SCG Failure Information EUTRA",
    ]

    // MARK: - Fields at fixed positions

    enum Details {
        /// TS 38.331 EstablishmentCause.
        private static let ESTABLISHMENT_CAUSE = [
            "emergency", "highPriorityAccess", "mt-Access", "mo-Signalling", "mo-Data", "mo-VoiceCall",
            "mo-VideoCall", "mo-SMS", "mps-PriorityAccess", "mcs-PriorityAccess",
            "spare6", "spare5", "spare4", "spare3", "spare2", "spare1",
        ]
        private static let REESTABLISHMENT_CAUSE = ["reconfigurationFailure", "handoverFailure", "otherFailure", "spare1"]

        static func of(_ name: String, _ payload: [UInt8]) -> [Field] {
            do {
                switch name {
                case "rrcSetupRequest": return try setupRequest(payload)
                case "rrcReestablishmentRequest": return try reestablishmentRequest(payload)
                case "rrcReject": return try reject(payload)
                case "rrcRelease": return try release(payload)
                case "paging": return try paging(payload)
                case "rrcSetupComplete": return try setupComplete(payload).fields
                default: return []
                }
            } catch {
                return []
            }
        }

        /// The `dedicatedNAS-Message` of the messages that carry one, or nil.
        static func nas(_ name: String, _ payload: [UInt8]) -> [UInt8]? {
            do {
                switch name {
                case "rrcSetupComplete": return try setupComplete(payload).nas
                case "ulInformationTransfer", "dlInformationTransfer": return try informationTransfer(payload)
                default: return nil
                }
            } catch {
                return nil
            }
        }

        /// UL-CCCH: c1, rrcSetupRequest, ue-Identity CHOICE (39 bits either way), establishmentCause, spare.
        private static func setupRequest(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 3)
            let random = try b.read(1) == 1
            // Wireshark prints a BIT STRING left-aligned in whole octets; 39 bits carry one pad bit.
            let identity = try b.readLong(39) << 1
            var fields = [
                Field(label: "UE identity", value: random ? "random value" : "5G-S-TMSI part 1",
                      children: [Field(label: "Value", value: Fmt.hex(identity, width: 10, uppercase: false))]),
            ]
            fields.append(Field(label: "Establishment cause", value: ESTABLISHMENT_CAUSE[try b.read(4)]))
            return fields
        }

        /// UL-CCCH: c1, rrcReestablishmentRequest, c-RNTI (16), physCellId (10), shortMAC-I (16), cause.
        private static func reestablishmentRequest(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 3)
            let cRnti = try b.read(16)
            let pci = try b.read(10)
            _ = try b.read(16)
            return [
                Field(label: "Cause", value: REESTABLISHMENT_CAUSE[try b.read(2)]),
                Field(label: "Previous cell PCI", value: "\(pci)"),
                Field(label: "C-RNTI", value: Fmt.hex(cRnti, width: 4, uppercase: false)),
            ]
        }

        /// DL-CCCH: c1, rrcReject, extension marker, three optionals, waitTime 1..16 s.
        private static func reject(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 3)
            if try b.read(1) != 0 { return [] } // criticalExtensionsFuture
            let waitTime = try b.read(1) == 1
            _ = try b.read(2) // lateNonCriticalExtension, nonCriticalExtension
            return waitTime ? [Field(label: "Wait time", value: "\(try b.read(4) + 1) s")] : []
        }

        /// DL-DCCH: transaction id, then RRCRelease-IEs: redirectedCarrierInfo, cellReselectionPriorities,
        /// suspendConfig, deprioritisationReq and the two extension slots. A release with suspendConfig leaves the
        /// phone in RRC inactive rather than idle, which is a different thing to see.
        private static func release(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 5)
            _ = try b.read(2) // transaction id
            if try b.read(1) != 0 { return [] }
            let redirect = try b.read(1) == 1
            _ = try b.read(1) // cellReselectionPriorities
            let suspend = try b.read(1) == 1
            let deprioritise = try b.read(1) == 1
            let carries = [
                redirect ? "redirect" : nil,
                suspend ? "suspend (RRC inactive)" : nil,
                deprioritise ? "deprioritisation" : nil,
            ].compactMap { $0 }
            return carries.isEmpty ? [] : [Field(label: "Carries", value: carries.joined(separator: ", "))]
        }

        /// PCCH: c1, paging, extension marker, optionals, then the paging records.
        private static func paging(_ p: [UInt8]) throws -> [Field] {
            var b = PerBits(p, startBit: 2)
            let records = try b.read(1) == 1
            _ = try b.read(2) // lateNonCriticalExtension, nonCriticalExtension
            if !records { return [] }
            let count = try b.read(5) + 1
            var identities: [Field] = []
            for _ in 1...count {
                // PagingRecord and PagingUE-Identity are both extensible, so each opens with an extension bit.
                if try b.read(1) != 0 { continue }
                let accessType = try b.read(1) == 1
                if try b.read(1) != 0 { continue }
                let fiveGsTmsi = try b.read(1) == 0
                let value = fiveGsTmsi ? try b.readLong(48) : (try b.readLong(44) << 4)
                if accessType { _ = try b.read(1) }
                identities.append(Field(label: fiveGsTmsi ? "5G-S-TMSI" : "I-RNTI", value: Fmt.hex(value, width: 12, uppercase: false)))
            }
            return [Field(label: "Paged", value: "\(count)", children: identities)]
        }

        /// UL-DCCH: transaction id, then RRCSetupComplete-IEs: four optionals, the selected PLMN, and the NAS
        /// message. The NAS is the point: on some modems it is the only copy of the registration request there is.
        private static func setupComplete(_ p: [UInt8]) throws -> (fields: [Field], nas: [UInt8]?) {
            var b = PerBits(p, startBit: 5)
            _ = try b.read(2) // transaction id
            if try b.read(1) != 0 { return ([], nil) }
            let registeredAmf = try b.read(1) == 1
            let guamiType = try b.read(1) == 1
            let nssai = try b.read(1) == 1
            let tmsi = try b.read(1) == 1
            _ = try b.read(2) // lateNonCriticalExtension, nonCriticalExtension
            let plmn = try b.read(4) + 1 // selectedPLMN-Identity, INTEGER (1..12)
            var fields = [Field(label: "Selected PLMN", value: "\(plmn)")]
            // Anything before the NAS message that this decoder cannot walk means the NAS cannot be trusted.
            if registeredAmf || guamiType || nssai { return (fields, nil) }
            let nas = try b.readOctetString()
            if tmsi { fields.append(Field(label: "5G-S-TMSI", value: "included")) }
            return (fields, nas)
        }

        /// DL-DCCH / UL-DCCH: transaction id, then a NAS message and nothing else that moves.
        private static func informationTransfer(_ p: [UInt8]) throws -> [UInt8]? {
            var b = PerBits(p, startBit: 5)
            _ = try b.read(2) // transaction id
            if try b.read(1) != 0 { return nil }
            let nas = try b.read(1) == 1
            _ = try b.read(2) // lateNonCriticalExtension, nonCriticalExtension
            return nas ? try b.readOctetString() : nil
        }
    }
}
