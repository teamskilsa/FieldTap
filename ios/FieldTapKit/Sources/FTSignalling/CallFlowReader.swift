// Port of android/diag/src/main/kotlin/com/fieldtap/diag/CallFlow.kt at contract v1 (D1 in Reading.add, D3 in
// procedures(); see ios/Contract/CONTRACT.md). The model types it builds live in FTModel/Flow.swift. The
// structure and names follow the Kotlin (Reading, Draft, rrcDraft, nrDrafts, carriedNas, nasDraft, nasOf,
// pairProtectedCopies, pairCarriedCopies, nearestCell, summaryOf, RULES, procedures, journey, firstOnCell,
// connections), so a Kotlin change ports line for line.

import Foundation
import FTCore
import FTModel

/// A capture read the way an engineer reads one: RRC and NAS on one timeline, grouped into the procedures they
/// make up, with the cells the phone moved through.
///
/// - One row per message. The modem logs most NAS messages twice after security starts: as sent over the air
///   (with a MAC and a sequence number) and in plain text. The plain copy is the row; the protected copy gives
///   it its protection, and is matched on content rather than guessed at by time.
/// - Procedures, each from the message that starts it to the one that answers it, with how long that took and
///   whether it worked. A procedure the capture never saw answered says so.
/// - The cell journey: every RRC message carries the cell it was logged on, and what kind of change a new cell
///   was comes from what happened just before it.
public enum CallFlowReader {
    /// Unframes and decodes a whole .qmdl, as CallFlow.read does.
    public static func read(qmdl: Data) -> Flow {
        let read = DiagProtocol.readQmdl(qmdl)
        return self.read(records: read.records, crcErrors: read.crcErrors)
    }

    /// The same from records already parsed (the QDSS importer's output), numbered 1... in the order given.
    public static func read(records: [LogRecord], crcErrors: Int) -> Flow {
        var reading = Reading()
        reading.kept.reserveCapacity(min(records.count, 4096))
        for record in records { reading.add(record) }
        return reading.build(crcErrors: crcErrors)
    }

    /// Kotlin's `CallFlow.of(records)`: records already parsed, no CRC errors.
    static func of(_ records: [LogRecord]) -> Flow { read(records: records, crcErrors: 0) }

    /// Kotlin reads the raw timestamp as a signed Long, and every `> 0` test there is this.
    private static func positive(_ raw: UInt64) -> Bool { raw > 0 && raw < (1 << 63) }

    // MARK: - Reading

    /// Keeps only the signalling records of a file, numbered as they came, so a long capture is not held twice.
    private struct Reading {
        var kept: [(number: Int, record: LogRecord)] = []
        var count = 0
        var firstRaw: UInt64 = 0
        var lastRaw: UInt64 = 0
        var firstAny: UInt64 = 0
        var lastAny: UInt64 = 0
        var firstPlausible: UInt64 = 0
        var lastPlausible: UInt64 = 0

        mutating func add(_ record: LogRecord) {
            count += 1
            // Contract v1 (D1): iPhone captures begin with records stamped before the modem had network time.
            // Measure from the first plausible (post-2005) timestamp when there is one; otherwise, as before,
            // from the first non-zero one. TimeBase.of is the same rule for callers without a flow.
            if positive(record.timestampRaw) {
                if firstAny == 0 { firstAny = record.timestampRaw }
                lastAny = record.timestampRaw
                if TimeBase.utcMs(record.timestampRaw) != nil {
                    if firstPlausible == 0 { firstPlausible = record.timestampRaw }
                    lastPlausible = record.timestampRaw
                }
                firstRaw = firstPlausible != 0 ? firstPlausible : firstAny
                lastRaw = firstPlausible != 0 ? lastPlausible : lastAny
            }
            let category = LogCodes.of(record.code)?.category
            if category == .nas || category == .rrc || record.code == SERVING_CELL_INFO {
                kept.append((count, record))
            }
        }

        func build(crcErrors: Int) -> Flow {
            CallFlowReader.build(kept, count: count, crcErrors: crcErrors,
                                 timeBase: TimeBase(firstRaw: firstRaw, lastRaw: lastRaw))
        }
    }

    // MARK: - Building

    /// A row before the protected and carried copies are folded; a class because folding edits the twin in place.
    private final class Draft {
        let record: Int
        let logCode: UInt16
        let timestampRaw: UInt64
        let layer: Layer
        let rat: String
        let uplink: Bool
        let key: String
        let name: String
        var cell: Cell?
        let channel: String
        let fields: [Field]
        let cause: Int?
        let causeName: String?
        var protection: Protection?
        let ciphered: Bool
        let pdu: [UInt8]
        /// For a security-protected copy: the message inside, to find its plain twin.
        let inner: [UInt8]?
        let plain: Bool
        var carrier: String?
        var dropped = false

        init(record: Int, logCode: UInt16, timestampRaw: UInt64, layer: Layer, rat: String, uplink: Bool, key: String,
             name: String, cell: Cell?, channel: String, fields: [Field], cause: Int?, causeName: String?,
             protection: Protection?, ciphered: Bool, pdu: [UInt8], inner: [UInt8]? = nil, plain: Bool = false,
             carrier: String? = nil) {
            self.record = record
            self.logCode = logCode
            self.timestampRaw = timestampRaw
            self.layer = layer
            self.rat = rat
            self.uplink = uplink
            self.key = key
            self.name = name
            self.cell = cell
            self.channel = channel
            self.fields = fields
            self.cause = cause
            self.causeName = causeName
            self.protection = protection
            self.ciphered = ciphered
            self.pdu = pdu
            self.inner = inner
            self.plain = plain
            self.carrier = carrier
        }

        /// Kotlin's `Draft.copyAs(protection, inner)`: the same row as a protected copy.
        func copyAs(protection: Protection, inner: [UInt8]) -> Draft {
            Draft(record: record, logCode: logCode, timestampRaw: timestampRaw, layer: layer, rat: rat, uplink: uplink,
                  key: key, name: name, cell: cell, channel: channel, fields: fields, cause: cause, causeName: causeName,
                  protection: protection, ciphered: ciphered, pdu: pdu, inner: inner, plain: false)
        }
    }

    private static let SERVING_CELL_INFO: UInt16 = 0xB0C2

    private static func build(_ records: [(number: Int, record: LogRecord)], count: Int, crcErrors: Int,
                              timeBase: TimeBase) -> Flow {
        var drafts: [Draft] = []
        var cellDetails: [CellDetail] = []
        var cellDetailIndex: [Cell: Int] = [:]
        var undecoded = 0
        for (number, record) in records {
            if record.code == SERVING_CELL_INFO {
                if let serving = CellInfo.serving(record.body) {
                    // Kotlin's LinkedHashMap: a cell seen again keeps its first place and takes the newer record.
                    let cell = Cell(earfcn: serving.downlinkEarfcn, pci: serving.pci)
                    if let at = cellDetailIndex[cell] {
                        cellDetails[at].info = serving
                    } else {
                        cellDetailIndex[cell] = cellDetails.count
                        cellDetails.append(CellDetail(cell: cell, info: serving))
                    }
                }
                continue
            }
            guard let info = LogCodes.of(record.code) else { continue }
            let made: [Draft]
            if record.code == 0xB0C0 {
                made = rrcDraft(number, record).map { [$0] } ?? []
            } else if record.code == 0xB821 {
                made = nrDrafts(number, record)
            } else if info.category == .rrc {
                made = []
            } else {
                made = nasDraft(number, record, info).map { [$0] } ?? []
            }
            if made.isEmpty { undecoded += 1 } else { drafts += made }
        }
        pairProtectedCopies(drafts)
        pairCarriedCopies(drafts)

        let kept = drafts.filter { !$0.dropped }
        var rrcCells: [(index: Int, cell: Cell)] = []
        for (i, d) in kept.enumerated() {
            if let cell = d.cell, SERVING_CHANNELS.contains(d.channel) { rrcCells.append((i, cell)) }
        }
        let events = kept.enumerated().map { i, d in
            Event(index: i, record: d.record, logCode: d.logCode, timestampRaw: d.timestampRaw,
                  sinceStartMs: timeBase.sinceStartMs(d.timestampRaw) ?? 0, layer: d.layer, rat: d.rat,
                  uplink: d.uplink, key: d.key, name: d.name, summary: summaryOf(d.fields, d.cause, d.causeName),
                  cell: d.cell ?? nearestCell(rrcCells, i, d.uplink), channel: d.channel, fields: d.fields,
                  cause: d.cause, causeName: d.causeName, protection: d.protection, ciphered: d.ciphered,
                  pdu: d.pdu, carrier: d.carrier)
        }
        let journey = journey(events).map { step in
            var s = step
            s.event = firstOnCell(events, step)
            return s
        }
        let visited = Set(journey.map(\.to))
        var searched: [Cell] = []
        var seen = Set<Cell>()
        for e in events where e.layer == .RRC && BROADCAST_CHANNELS.contains(e.channel) {
            if let cell = e.cell, !visited.contains(cell), seen.insert(cell).inserted { searched.append(cell) }
        }
        return Flow(events: events, procedures: procedures(events), journey: journey, searched: searched,
                    connections: connections(events), cellDetails: cellDetails, records: count,
                    undecoded: undecoded, crcErrors: crcErrors, durationMs: timeBase.durationMs,
                    startUtcMs: timeBase.startUtcMs)
    }

    private static func rrcDraft(_ number: Int, _ record: LogRecord) -> Draft? {
        guard let message = LteRrc.decode(record.body), let channel = message.channel,
              let asn1 = message.asn1Name else { return nil }
        return Draft(record: number, logCode: record.code, timestampRaw: record.timestampRaw, layer: .RRC, rat: "lte",
                     uplink: channel.uplink, key: asn1, name: LteRrc.readable(asn1),
                     cell: Cell(earfcn: message.earfcn, pci: message.pci), channel: channel.label, fields: message.fields,
                     cause: nil, causeName: nil, protection: nil, ciphered: false, pdu: message.payload)
    }

    /// An NR RRC message, and the 5G NAS message inside it when it carried one. The NAS row takes the RRC
    /// message's direction and cell, and says which message carried it.
    private static func nrDrafts(_ number: Int, _ record: LogRecord) -> [Draft] {
        guard let message = NrRrc.decode(record.body), let channel = message.channel,
              let asn1 = message.asn1Name else { return [] }
        let cell = Cell(earfcn: message.arfcn, pci: message.pci, nr: true)
        let rrc = Draft(record: number, logCode: record.code, timestampRaw: record.timestampRaw, layer: .RRC, rat: "nr",
                        uplink: channel.uplink, key: asn1, name: NrRrc.readable(asn1), cell: cell,
                        channel: channel.label, fields: message.fields, cause: nil, causeName: nil, protection: nil,
                        ciphered: false, pdu: message.payload)
        guard let nas = message.nas else { return [rrc] }
        return [rrc] + (carriedNas(number, record, nas, channel.uplink, cell, NrRrc.readable(asn1)).map { [$0] } ?? [])
    }

    /// 5G NAS as it went over the air. After security starts it is protected: EPD, security header, MAC (4) and
    /// sequence number, then the message: readable when only integrity-protected, ciphered otherwise.
    private static func carriedNas(_ number: Int, _ record: LogRecord, _ pdu: [UInt8], _ uplink: Bool, _ cell: Cell,
                                   _ carrier: String) -> Draft? {
        guard let outer = Nas.decodePdu(pdu, nr: true) else { return nil }
        var protection: Protection?
        var message = outer
        var body = pdu
        // Kotlin's `body.takeIf { it !== pdu }`: whether the inner message replaced the outer one.
        var replaced = false
        if outer.sublayer == "5gmm" && (1...4).contains(outer.securityHeader) && pdu.count > 7 {
            protection = Protection(headerType: outer.securityHeader, mac: mac(pdu, 2), sequence: Int(pdu[6]))
            let inner = Array(pdu[7...])
            if let it = Nas.decodePdu(inner, nr: true), it.securityHeader == 0, it.name != nil {
                message = it
                body = inner
                replaced = true
            }
        }
        let readable = message.securityHeader == 0 && message.messageType != nil
        let name: String
        if readable {
            name = message.name ?? "5GS message " + Fmt.hex(message.messageType ?? 0, width: 2)
        } else {
            name = "Ciphered \(outer.sublayer.uppercased()) message"
        }
        return Draft(record: number, logCode: record.code, timestampRaw: record.timestampRaw, layer: .NAS, rat: "nr",
                     uplink: uplink, key: readable ? message.name ?? "unnamed" : "ciphered", name: name, cell: cell,
                     channel: message.sublayer.uppercased(),
                     fields: readable ? NasFields.fiveGs(sublayer: message.sublayer, securityHeader: 0,
                                                         messageType: message.messageType, pdu: body, uplink: uplink) : [],
                     cause: message.cause, causeName: message.causeName, protection: protection, ciphered: !readable,
                     pdu: pdu, inner: replaced ? body : nil, carrier: carrier)
    }

    /// The four MAC octets at `at`, big-endian.
    private static func mac(_ pdu: [UInt8], _ at: Int) -> UInt32 {
        UInt32(pdu[at]) << 24 | UInt32(pdu[at + 1]) << 16 | UInt32(pdu[at + 2]) << 8 | UInt32(pdu[at + 3])
    }

    private static func nasDraft(_ number: Int, _ record: LogRecord, _ info: LogCodes.Info) -> Draft? {
        let nr = info.isNr
        guard let (message, pdu) = Nas.located(record.body, nr: nr) else { return nil }
        let logged = info.nasDirection ?? message.direction ?? "ul"

        // A protected copy: header, MAC (4), sequence number (1), then the message. 5GS puts the EPD first.
        let headerAt = nr ? 1 : 0
        let sec = message.securityHeader
        if info.nasProtected && (1...4).contains(sec) && pdu.count > headerAt + 6 {
            let macAt = headerAt + 1
            let protection = Protection(headerType: sec, mac: mac(pdu, macAt), sequence: Int(pdu[macAt + 4]))
            let inner = Array(pdu[(macAt + 5)...])
            // Qualcomm logs the protected copy after deciphering, so the message inside is usually readable.
            if let readable = Nas.decodePdu(inner, nr: nr), readable.name != nil, readable.securityHeader == 0 {
                return nasOf(number, record, info, readable, inner, logged, nr).copyAs(protection: protection, inner: inner)
            }
            return Draft(record: number, logCode: record.code, timestampRaw: record.timestampRaw, layer: .NAS,
                         rat: info.rat, uplink: logged == "ul", key: "ciphered",
                         name: "Ciphered \(message.sublayer.uppercased()) message", cell: nil,
                         channel: message.sublayer.uppercased(), fields: [], cause: nil, causeName: nil,
                         protection: protection, ciphered: true, pdu: pdu, inner: inner)
        }
        return nasOf(number, record, info, message, pdu, logged, nr)
    }

    private static func nasOf(_ number: Int, _ record: LogRecord, _ info: LogCodes.Info, _ message: Nas.Message,
                              _ pdu: [UInt8], _ logged: String, _ nr: Bool) -> Draft {
        let uplink = (message.direction ?? logged) == "ul"
        let fields = nr
            ? NasFields.fiveGs(sublayer: message.sublayer, securityHeader: message.securityHeader,
                               messageType: message.messageType, pdu: pdu, uplink: uplink)
            : NasFields.eps(sublayer: message.sublayer, securityHeader: message.securityHeader,
                            messageType: message.messageType, pdu: pdu, uplink: uplink)
        let name: String
        if let known = message.name {
            name = known
        } else if let type = message.messageType {
            name = "\(message.sublayer.uppercased()) message " + Fmt.hex(type, width: 2)
        } else {
            name = "Ciphered \(message.sublayer.uppercased()) message"
        }
        return Draft(record: number, logCode: record.code, timestampRaw: record.timestampRaw, layer: .NAS,
                     rat: info.rat, uplink: uplink, key: message.name ?? "unnamed", name: name, cell: nil,
                     channel: message.sublayer.uppercased(), fields: fields, cause: message.cause,
                     causeName: message.causeName, protection: nil,
                     ciphered: message.messageType == nil && message.securityHeader != 12, pdu: pdu,
                     plain: !info.nasProtected)
    }

    /// The modem logs a protected copy and a plain copy of the same message, in either order and a few records
    /// apart. The plain copy stays and takes the protection; the protected copy goes. A protected copy with no
    /// plain twin stays as its own row.
    private static func pairProtectedCopies(_ drafts: [Draft]) {
        for (i, secured) in drafts.enumerated() {
            guard let inner = secured.inner, !secured.plain else { continue }
            let window = max(0, i - WINDOW)..<min(drafts.count, i + WINDOW + 1)
            guard let twin = window.lazy.map({ drafts[$0] }).first(where: { plain in
                plain.plain && plain.protection == nil && plain.uplink == secured.uplink && plain.pdu == inner
                    && closeInTime(plain, secured)
            }) else { continue }
            twin.protection = secured.protection
            secured.dropped = true
        }
    }

    private static let WINDOW = 8

    /// 5G NAS pulled out of an RRC message is usually also logged plain (0xB80A/0xB80B) a record or two away.
    /// The plain copy stays (after security starts it is the only readable one) and takes from the carried copy
    /// what only it knows: which RRC message carried it, on which cell, and its protection. A carried copy with
    /// no plain twin stays as its own row.
    private static func pairCarriedCopies(_ drafts: [Draft]) {
        for (i, carried) in drafts.enumerated() {
            if carried.carrier == nil || carried.plain || carried.dropped { continue }
            let window = max(0, i - WINDOW)..<min(drafts.count, i + WINDOW + 1)
            guard let twin = window.lazy.map({ drafts[$0] }).first(where: { plain in
                plain !== carried && plain.plain && plain.carrier == nil && plain.uplink == carried.uplink
                    && (plain.pdu == carried.pdu || plain.pdu == (carried.inner ?? []))
                    && closeInTime(plain, carried)
            }) else { continue }
            twin.carrier = carried.carrier
            twin.cell = carried.cell
            if twin.protection == nil { twin.protection = carried.protection }
            carried.dropped = true
        }
    }

    private static func closeInTime(_ a: Draft, _ b: Draft) -> Bool {
        !positive(a.timestampRaw) || !positive(b.timestampRaw)
            || abs(TimeBase.modemMs(a.timestampRaw) - TimeBase.modemMs(b.timestampRaw)) <= 2_000
    }

    /// The cell a NAS message went over. The modem logs an uplink NAS message just before the RRC message that
    /// carries it, and a downlink one just after, so uplink looks forward and downlink back. Looking back for an
    /// uplink message put the tracking area update that followed a reselection on the cell the phone had left.
    private static func nearestCell(_ cells: [(index: Int, cell: Cell)], _ index: Int, _ uplink: Bool) -> Cell? {
        // `cells` is in index order: the first entry past `index` splits it into before and after.
        var lo = 0, hi = cells.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cells[mid].index <= index { lo = mid + 1 } else { hi = mid }
        }
        let after = lo < cells.count ? cells[lo].cell : nil
        var b = lo - 1
        while b >= 0 && cells[b].index >= index { b -= 1 }
        let before = b >= 0 ? cells[b].cell : nil
        return uplink ? after ?? before : before ?? after
    }

    // MARK: - The line under the name

    private static func summaryOf(_ fields: [Field], _ cause: Int?, _ causeName: String?) -> String? {
        if let cause { return ["#\(cause)", causeName].compactMap { $0 }.joined(separator: " ") }
        let parts = fields.compactMap { f -> String? in
            switch f.label {
            case "Establishment cause", "Release cause", "Attach type", "Detach type", "Update type",
                 "Identity requested", "APN", "PDN address", "Wait time", "Cause", "Ciphering", "Integrity",
                 "Carries", "Registration type", "Registration result", "Service type", "Deregistration",
                 "PDU session type":
                return f.value
            case "T3502", "T3346":
                return "\(f.label) \(f.value)"
            case "Redirected to":
                return "redirect to \(f.value)"
            case LteRrc.handover:
                return f.value == "command" ? "handover command" : "handover \(f.value)"
            case "Serving RSRP":
                return "RSRP \(f.value)"
            case "Neighbours":
                return "\(f.value.prefix { $0 != " " }) neighbours"
            case "QCI":
                return "QCI \(f.value)"
            case "Switch off":
                return f.value == "yes" ? "switch off" : nil
            default:
                return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Procedures

    private final class Rule: Sendable {
        let name: String
        let starts: Set<String>
        let succeeds: Set<String>
        let fails: Set<String>

        init(_ name: String, _ starts: Set<String>, _ succeeds: Set<String>, _ fails: Set<String> = []) {
            self.name = name
            self.starts = starts
            self.succeeds = succeeds
            self.fails = fails
        }
    }

    // The same moments of a connection under their LTE and NR names.
    private static let REQUESTS: Set = ["rrcConnectionRequest", "rrcSetupRequest", "rrcResumeRequest", "rrcResumeRequest1"]
    private static let SETUPS: Set = ["rrcConnectionSetup", "rrcSetup", "rrcResume"]
    private static let RELEASES: Set = ["rrcConnectionRelease", "rrcRelease"]
    private static let REJECTS: Set = ["rrcConnectionReject", "rrcReject"]
    private static let REESTABLISHMENT_REQUESTS: Set = ["rrcConnectionReestablishmentRequest", "rrcReestablishmentRequest"]
    private static let REESTABLISHMENTS: Set = ["rrcConnectionReestablishment", "rrcReestablishment"]

    private static let RECONFIGURATION = "RRC reconfiguration"

    private static let RULES: [Rule] = [
        Rule("RRC connection setup", ["rrcConnectionRequest", "rrcSetupRequest"],
             ["rrcConnectionSetupComplete", "rrcSetupComplete"], ["rrcConnectionReject", "rrcReject"]),
        Rule("RRC re-establishment", REESTABLISHMENT_REQUESTS,
             ["rrcConnectionReestablishmentComplete", "rrcReestablishmentComplete"],
             ["rrcConnectionReestablishmentReject"]),
        Rule("RRC resume", ["rrcResumeRequest", "rrcResumeRequest1"], ["rrcResumeComplete"], ["rrcReject"]),
        Rule("AS security", ["securityModeCommand"], ["securityModeComplete"], ["securityModeFailure"]),
        Rule("UE capability", ["ueCapabilityEnquiry"], ["ueCapabilityInformation"]),
        Rule(RECONFIGURATION, ["rrcConnectionReconfiguration", "rrcReconfiguration"],
             ["rrcConnectionReconfigurationComplete", "rrcReconfigurationComplete"], REESTABLISHMENT_REQUESTS),
        Rule("Attach", ["Attach request"], ["Attach accept"], ["Attach reject"]),
        // An EPS service request is answered by the RAN starting security, not by a NAS accept.
        Rule("Service request", ["Service request", "Extended service request"],
             ["Service accept", "securityModeCommand"], ["Service reject"]),
        Rule("Tracking area update", ["Tracking area update request"], ["Tracking area update accept"],
             ["Tracking area update reject"]),
        Rule("Detach", ["Detach request"], ["Detach accept"]),
        Rule("Authentication", ["Authentication request"], ["Authentication response"],
             ["Authentication failure", "Authentication reject"]),
        Rule("NAS security", ["Security mode command"], ["Security mode complete"], ["Security mode reject"]),
        Rule("Identity", ["Identity request"], ["Identity response"]),
        Rule("PDN connectivity", ["PDN connectivity request"], ["Activate default EPS bearer context accept"],
             ["PDN connectivity reject", "Activate default EPS bearer context reject"]),
        Rule("Dedicated bearer", ["Activate dedicated EPS bearer context request"],
             ["Activate dedicated EPS bearer context accept"], ["Activate dedicated EPS bearer context reject"]),
        Rule("Bearer modification", ["Modify EPS bearer context request"], ["Modify EPS bearer context accept"],
             ["Modify EPS bearer context reject"]),
        Rule("Bearer deactivation", ["Deactivate EPS bearer context request"], ["Deactivate EPS bearer context accept"]),
        Rule("PDN disconnect", ["PDN disconnect request"], ["Deactivate EPS bearer context accept"],
             ["PDN disconnect reject"]),
        Rule("ESM information", ["ESM information request"], ["ESM information response"]),
        Rule("Registration", ["Registration request"], ["Registration accept"], ["Registration reject"]),
        Rule("Deregistration",
             ["Deregistration request (UE originating)", "Deregistration request (UE terminated)"],
             ["Deregistration accept (UE originating)", "Deregistration accept (UE terminated)"]),
        Rule("PDU session establishment", ["PDU session establishment request"], ["PDU session establishment accept"],
             ["PDU session establishment reject"]),
        Rule("PDU session release", ["PDU session release request"], ["PDU session release command"]),
    ]

    private final class Open {
        let rule: Rule
        let name: String
        let start: Event

        init(_ rule: Rule, _ name: String, _ start: Event) {
            self.rule = rule
            self.name = name
            self.start = start
        }
    }

    private static func procedures(_ events: [Event]) -> [Procedure] {
        var done: [Procedure] = []
        var open: [Open] = []
        func close(_ o: Open, _ end: Event, _ outcome: Outcome) {
            if let at = open.firstIndex(where: { $0 === o }) { open.remove(at: at) }
            done.append(Procedure(name: o.name, layer: o.start.layer, detail: o.start.summary, first: o.start.index,
                                  last: end.index, outcome: outcome, durationMs: end.sinceStartMs - o.start.sinceStartMs,
                                  refusal: outcome == .FAILED ? end.summary ?? end.name : nil))
        }
        for event in events {
            for o in open {
                // Contract v1 (D3): a procedure is answered only on the RAT it started on. On EN-DC the NR
                // RRCReconfiguration rides inside the LTE one; without this it closed the LTE one as unanswered.
                if o.start.rat != event.rat { continue }
                if o.rule.succeeds.contains(event.key) {
                    close(o, event, .SUCCEEDED)
                } else if o.rule.fails.contains(event.key) {
                    close(o, event, .FAILED)
                }
            }
            guard let rule = RULES.first(where: { $0.starts.contains(event.key) }) else { continue }
            // A second start before the first was answered: the first never was.
            for o in open where o.rule === rule && o.start.rat == event.rat { close(o, o.start, .UNANSWERED) }
            let name = rule.name == RECONFIGURATION && event.isHandoverCommand ? "Handover" : rule.name
            let started = Open(rule, name, event)
            open.append(started)
            // A phone switching off does not wait to be told it may.
            if rule.name == "Detach" && event.uplink && event.fields.contains(where: { $0.label == "Switch off" && $0.value == "yes" }) {
                close(started, event, .SUCCEEDED)
            }
        }
        for o in open { close(o, o.start, .UNANSWERED) }
        return stableSorted(done) { $0.first }
    }

    /// Kotlin's `sortedBy`: stable, so procedures that start on one event keep the order they closed in.
    private static func stableSorted<T>(_ items: [T], by key: (T) -> Int) -> [T] {
        items.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Cells and connections

    private static let CONNECTED_CHANNELS: Set = ["UL-DCCH", "DL-DCCH"]

    /// Channels a phone only uses on the cell it is camped on or connected to. System information is not one: a
    /// phone searching for service reads SIB1 from every cell it can hear, and counting those as cells it was on
    /// turned one lost-coverage minute into forty "cell changes".
    private static let SERVING_CHANNELS: Set = ["UL-CCCH", "DL-CCCH", "UL-DCCH", "DL-DCCH", "PCCH"]

    private static let BROADCAST_CHANNELS: Set = ["BCCH-BCH", "BCCH-DL-SCH", "MCCH"]

    /// A step starts at the RRC message that showed the new cell; the NAS messages just before it were on that
    /// cell too.
    private static func firstOnCell(_ events: [Event], _ step: Step) -> Int {
        var first = step.event
        while first > 0 && events[first - 1].layer == .NAS && events[first - 1].cell == step.to { first -= 1 }
        return first
    }

    private static func journey(_ events: [Event]) -> [Step] {
        var steps: [Step] = []
        var current: Cell?
        var connected = false
        var handoverPending = false
        var redirectPending = false
        for event in events {
            if event.layer != .RRC || !SERVING_CHANNELS.contains(event.channel) { continue }
            guard let cell = event.cell else { continue }
            if let from = current {
                if cell != from {
                    let move: Move
                    if REESTABLISHMENT_REQUESTS.contains(event.key) {
                        move = .REESTABLISHMENT
                    } else if handoverPending {
                        move = .HANDOVER
                    } else if redirectPending {
                        move = .REDIRECT
                    } else if !connected || REQUESTS.contains(event.key) || event.channel == "PCCH" {
                        // A phone asks for a connection, and listens for paging, only when it has none, whatever
                        // the log last showed. Connections end without a logged release more often than not.
                        move = .RESELECTION
                    } else {
                        move = .CELL_CHANGE
                    }
                    steps.append(Step(move: move, from: from, to: cell, event: event.index, sinceStartMs: event.sinceStartMs))
                    handoverPending = false
                    redirectPending = false
                    // A request on a new cell after an unanswered one on the old: the phone was idle all along.
                    if move == .RESELECTION || move == .REDIRECT { connected = false }
                }
            } else {
                steps.append(Step(move: .FIRST_SEEN, from: nil, to: cell, event: event.index, sinceStartMs: event.sinceStartMs))
            }
            current = cell
            if RELEASES.contains(event.key) {
                connected = false
                handoverPending = false
                redirectPending = event.fields.contains { $0.label == "Redirected to" }
            } else if REJECTS.contains(event.key) || event.channel == "PCCH" {
                connected = false
            } else if event.isHandoverCommand {
                handoverPending = true
            } else if SETUPS.contains(event.key) || REESTABLISHMENTS.contains(event.key)
                        || CONNECTED_CHANNELS.contains(event.channel) {
                // A request alone is not a connection: plenty go unanswered.
                connected = true
            }
        }
        return steps
    }

    private static func connections(_ events: [Event]) -> [Connection] {
        var out: [Connection] = []
        var request: Event?
        var requestCause: String?
        var open: Event?
        var openCause: String?
        var lastOfOpen: Event?

        func causeOf(_ e: Event) -> String? { e.fields.first { $0.label == "Establishment cause" }?.value }
        func unanswered() {
            if let it = request {
                out.append(Connection(first: it.index, last: it.index, establishmentCause: requestCause, releaseCause: nil,
                                      outcome: .NO_ANSWER, startMs: it.sinceStartMs, endMs: it.sinceStartMs))
            }
            request = nil
        }
        func lost() {
            guard let start = open else { return }
            let end = lastOfOpen ?? start
            out.append(Connection(first: start.index, last: end.index, establishmentCause: openCause, releaseCause: nil,
                                  outcome: .LOST, startMs: start.sinceStartMs, endMs: end.sinceStartMs))
            open = nil
        }

        for event in events where event.layer == .RRC {
            if REQUESTS.contains(event.key) {
                unanswered()
                lost()
                request = event
                requestCause = causeOf(event)
            } else if SETUPS.contains(event.key) {
                lost()
                open = request ?? event
                openCause = request != nil ? requestCause : nil
                lastOfOpen = event
                request = nil
            } else if REJECTS.contains(event.key) {
                if let it = request {
                    out.append(Connection(first: it.index, last: event.index, establishmentCause: requestCause,
                                          releaseCause: nil, outcome: .REJECTED, startMs: it.sinceStartMs,
                                          endMs: event.sinceStartMs))
                    request = nil
                }
            } else if RELEASES.contains(event.key) {
                let start = open ?? event
                out.append(Connection(first: start.index, last: event.index,
                                      establishmentCause: open != nil ? openCause : nil,
                                      releaseCause: event.fields.first { $0.label == "Release cause" }?.value,
                                      outcome: .RELEASED, startMs: start.sinceStartMs, endMs: event.sinceStartMs))
                open = nil
            } else if CONNECTED_CHANNELS.contains(event.channel) {
                // Connected-mode traffic with no setup seen: the connection began before the capture did.
                if open == nil {
                    open = event
                    openCause = nil
                }
                lastOfOpen = event
            }
        }
        unanswered()
        if let it = open {
            out.append(Connection(first: it.index, last: nil, establishmentCause: openCause, releaseCause: nil,
                                  outcome: .OPEN_AT_END, startMs: it.sinceStartMs, endMs: nil))
        }
        return stableSorted(out) { $0.first }
    }
}
