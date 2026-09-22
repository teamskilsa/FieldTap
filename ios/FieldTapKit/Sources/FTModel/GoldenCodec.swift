import Foundation

/// The `source` object of a callflow golden: what the Kotlin reader saw in the file.
public struct GoldenSource: Hashable, Codable, Sendable {
    public var file: String
    public var bytes: Int
    public var hdlcFrames: Int
    public var crcErrors: Int
    public var logRecords: Int
    public var badPackets: Int

    public init(file: String, bytes: Int, hdlcFrames: Int, crcErrors: Int, logRecords: Int, badPackets: Int) {
        self.file = file
        self.bytes = bytes
        self.hdlcFrames = hdlcFrames
        self.crcErrors = crcErrors
        self.logRecords = logRecords
        self.badPackets = badPackets
    }
}

/// A callflow golden read back as a real Flow. Goldens carry no PDU bytes, so every `pdu` is empty and
/// `pduLengths` keeps what the Kotlin side saw; cell identities are masked, so they read as nil.
public struct GoldenFlow: Sendable {
    public var flow: Flow
    public var source: GoldenSource
    public var recordsPerCode: [UInt16: Int]
    /// `pduLength` of each event, in event order.
    public var pduLengths: [Int]
}

/// Reads and writes the callflow-golden.json schema of ios/Contract/tools/GoldenDump.kt, field for field and
/// in the same order, with the same masking (`Redaction`), so a Swift flow can be compared with the Kotlin
/// one. `jsonDiff` is the comparator every parity test uses (the same rules as Contract/tools/json_equal.py).
public enum GoldenCodec {
    public enum Failure: Error, Equatable {
        case notAGolden(String)
    }

    /// The `decoder` and `masking` strings GoldenDump.kt writes.
    public static let decoderNote =
        "FieldTap android/diag (Kotlin) + LteRrc v30 layout E + NrRrc v26 layout E (see lterrc_v30.diff, nrrrc_v26.diff)"
    public static let maskingNote =
        "field values whose label matches IDENTITY_LABEL (and all their children) -> <masked>; in every other string, "
        + "IPv4/IPv6, 10+ digit runs and 0x-hex of 8+ digits -> <masked>. pdu bytes are omitted (pduLength only)."

    // MARK: - Decoding

    public static func decodeFlow(_ data: Data) throws -> GoldenFlow {
        let g: GoldenFile
        do {
            g = try JSONDecoder().decode(GoldenFile.self, from: data)
        } catch {
            throw Failure.notAGolden("\(error)")
        }
        let events = try g.events.map { e -> Event in
            guard let code = UInt16(hex: e.logCode) else { throw Failure.notAGolden("logCode \(e.logCode)") }
            return Event(
                index: e.index, record: e.record, logCode: code, timestampRaw: e.timestampRaw,
                sinceStartMs: e.sinceStartMs, layer: e.layer, rat: e.rat, uplink: e.uplink, key: e.key,
                name: e.name, summary: e.summary, cell: e.cell, channel: e.channel, fields: e.fields.map(\.field),
                cause: e.cause, causeName: e.causeName,
                protection: e.protection.map { Protection(headerType: $0.headerType, mac: 0, sequence: $0.sequence) },
                ciphered: e.ciphered, pdu: [], carrier: e.carrier)
        }
        var perCode: [UInt16: Int] = [:]
        for (k, v) in g.recordsPerCode {
            guard let code = UInt16(hex: k) else { throw Failure.notAGolden("recordsPerCode \(k)") }
            perCode[code] = v
        }
        let flow = Flow(
            events: events, procedures: g.procedures, journey: g.journey, searched: g.searched,
            connections: g.connections.map(\.connection),
            cellDetails: g.cellDetails.map { CellDetail(cell: $0.cell, info: $0.info) },
            records: g.flow.records, undecoded: g.flow.undecoded, crcErrors: g.flow.crcErrors,
            durationMs: g.flow.durationMs,
            startUtcMs: g.flow.startUtcKnown ? startUtcMs(first: events.first) : nil)
        return GoldenFlow(flow: flow, source: g.source, recordsPerCode: perCode, pduLengths: g.events.map(\.pduLength))
    }

    /// The golden has no start time, only whether one was known. It is recovered the way reduce_phy.py does:
    /// the first event's modem time less its time since start (to within the golden's 0.001 ms rounding).
    static func startUtcMs(first: Event?) -> Int64? {
        guard let e = first, e.timestampRaw > 0 else { return nil }
        let startModemMs = TimeBase.modemMs(e.timestampRaw) - e.sinceStartMs
        return TimeBase.gpsEpochUtcMs + Int64(startModemMs.rounded(.down))
    }

    // MARK: - Encoding

    /// `flow` as GoldenDump.kt writes it. `pduLengths` stands in for the PDUs when the flow came from a
    /// golden itself (its events have no bytes); otherwise each event's own `pdu.count` is written.
    public static func encodeFlow(_ flow: Flow, source: GoldenSource, recordsPerCode: [UInt16: Int],
                                  pduLengths: [Int]? = nil) -> Data {
        var s = "{\n"
        s += "\"source\":{\"file\":\(q(source.file)),\"bytes\":\(source.bytes),\"hdlcFrames\":\(source.hdlcFrames),"
        s += "\"crcErrors\":\(source.crcErrors),\"logRecords\":\(source.logRecords),\"badPackets\":\(source.badPackets)},\n"
        s += "\"decoder\":\(q(decoderNote)),\n"
        s += "\"masking\":\(q(maskingNote)),\n"
        s += "\"flow\":{\"records\":\(flow.records),\"undecoded\":\(flow.undecoded),\"crcErrors\":\(flow.crcErrors),"
        s += "\"durationMs\":\(num(flow.durationMs)),\"startUtcKnown\":\(flow.startUtcMs != nil),\"failures\":\(flow.failures)},\n"
        s += "\"events\":[\n"
        s += flow.events.enumerated().map { i, e in
            let fields = e.fields.map { fieldJson(Redaction.mask($0)) }.joined(separator: ",")
            let prot = e.protection.map {
                "{\"headerType\":\($0.headerType),\"headerName\":\(q($0.headerName)),\"sequence\":\($0.sequence)}"
            } ?? "null"
            let pduLength = pduLengths.flatMap { i < $0.count ? $0[i] : nil } ?? e.pdu.count
            var line = "{\"index\":\(e.index),\"record\":\(e.record),\"logCode\":\"\(hex4(e.logCode))\","
            line += "\"timestampRaw\":\(e.timestampRaw),\"sinceStartMs\":\(num(e.sinceStartMs)),\"layer\":\"\(e.layer.rawValue)\","
            line += "\"rat\":\(q(e.rat)),\"uplink\":\(e.uplink),"
            line += "\"channel\":\(q(e.channel)),\"key\":\(q(e.key)),\"name\":\(q(e.name)),"
            line += "\"summary\":\(q(Redaction.scrub(e.summary))),\"cell\":\(cellJson(e.cell)),"
            line += "\"cause\":\(e.cause.map { "\($0)" } ?? "null"),\"causeName\":\(q(e.causeName)),\"protection\":\(prot),"
            line += "\"ciphered\":\(e.ciphered),\"isFailure\":\(e.isFailure),"
            line += "\"isHandoverCommand\":\(e.isHandoverCommand),\"carrier\":\(q(e.carrier)),\"pduLength\":\(pduLength),"
            line += "\"fields\":[\(fields)]}"
            return line
        }.joined(separator: ",\n")
        s += "\n],\n\"procedures\":[\n"
        s += flow.procedures.map { p in
            "{\"name\":\(q(p.name)),\"layer\":\"\(p.layer.rawValue)\",\"detail\":\(q(Redaction.scrub(p.detail))),"
                + "\"first\":\(p.first),\"last\":\(p.last),\"outcome\":\"\(p.outcome.rawValue)\","
                + "\"durationMs\":\(num(p.durationMs)),\"refusal\":\(q(Redaction.scrub(p.refusal)))}"
        }.joined(separator: ",\n")
        s += "\n],\n\"journey\":[\n"
        s += flow.journey.map { st in
            "{\"move\":\"\(st.move.rawValue)\",\"from\":\(cellJson(st.from)),\"to\":\(cellJson(st.to)),"
                + "\"event\":\(st.event),\"sinceStartMs\":\(num(st.sinceStartMs))}"
        }.joined(separator: ",\n")
        s += "\n],\n\"searched\":[" + flow.searched.map { cellJson($0) }.joined(separator: ",") + "],\n"
        s += "\"connections\":[\n"
        s += flow.connections.map { c in
            "{\"first\":\(c.first),\"last\":\(c.last.map { "\($0)" } ?? "null"),"
                + "\"establishmentCause\":\(q(c.establishmentCause)),\"releaseCause\":\(q(c.releaseCause)),"
                + "\"outcome\":\"\(c.outcome.rawValue)\",\"startMs\":\(num(c.startMs)),"
                + "\"endMs\":\(c.endMs.map { num($0) } ?? "null"),\"established\":\(c.established)}"
        }.joined(separator: ",\n")
        s += "\n],\n\"cellDetails\":[\n"
        s += flow.cellDetails.map { d in
            let i = d.info
            return "{\"cell\":\(cellJson(d.cell)),\"pci\":\(i.pci),\"downlinkEarfcn\":\(i.downlinkEarfcn),"
                + "\"uplinkEarfcn\":\(i.uplinkEarfcn),\"band\":\(i.band),\"plmn\":\(q(i.plmn)),\"tac\":\(i.tac),"
                + "\"cellIdentity\":\"\(Redaction.masked)\",\"bandwidthMhz\":\(i.bandwidthMhz.map { "\($0)" } ?? "null")}"
        }.joined(separator: ",\n")
        s += "\n],\n\"recordsPerCode\":{"
        s += recordsPerCode.keys.sorted().map { "\"\(hex4($0))\":\(recordsPerCode[$0]!)" }.joined(separator: ",")
        s += "}\n}\n"
        return Data(s.utf8)
    }

    /// Kotlin's `q()`: JSON string with `"`, `\`, newline, CR, tab and control characters escaped, and every
    /// other character (including "−" and "·") written as is.
    static func q(_ s: String?) -> String {
        guard let s else { return "null" }
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += "\\u" + String(format: "%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    static func num(_ d: Double) -> String { JavaDecimal.fixed(d, 3) }

    static func hex4(_ code: UInt16) -> String {
        let h = String(code, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - h.count)) + h
    }

    static func cellJson(_ c: Cell?) -> String {
        guard let c else { return "null" }
        return "{\"earfcn\":\(c.earfcn),\"pci\":\(c.pci),\"nr\":\(c.nr)}"
    }

    static func fieldJson(_ f: Field) -> String {
        let kids = f.children.isEmpty ? "" : ",\"children\":[" + f.children.map { fieldJson($0) }.joined(separator: ",") + "]"
        return "{\"label\":\(q(f.label)),\"value\":\(q(f.value))\(kids)}"
    }

    // MARK: - Comparison

    /// Structural comparison: objects by key set and value, arrays by length and position, strings and
    /// booleans exactly, numbers within `tolerance` (integers too, so equal 17-digit timestamps compare
    /// exactly). `ignoring` holds dotted paths without array indexes ("source.file", "events.cell").
    /// Returns the paths that differ; empty means equal. Unparseable input returns ["<root>"].
    public static func jsonDiff(_ a: Data, _ b: Data, tolerance: Double = 0.0015,
                                ignoring: Set<String> = ["source.file"]) -> [String] {
        guard let x = try? JSONSerialization.jsonObject(with: a, options: [.fragmentsAllowed]),
              let y = try? JSONSerialization.jsonObject(with: b, options: [.fragmentsAllowed]) else {
            return ["<root>"]
        }
        var out: [String] = []
        diff(x, y, path: "", bare: "", tolerance: tolerance, ignoring: ignoring, out: &out)
        return out
    }

    private static func diff(_ a: Any, _ b: Any, path: String, bare: String, tolerance: Double,
                             ignoring: Set<String>, out: inout [String]) {
        if ignoring.contains(bare) { return }
        switch (a, b) {
        case let (x as NSNumber, y as NSNumber):
            let xb = CFGetTypeID(x) == CFBooleanGetTypeID(), yb = CFGetTypeID(y) == CFBooleanGetTypeID()
            if xb || yb {
                if xb != yb || x.boolValue != y.boolValue { out.append(path) }
            } else if isInteger(x) && isInteger(y) {
                if x != y && abs(x.doubleValue - y.doubleValue) > tolerance { out.append(path) }
            } else if abs(x.doubleValue - y.doubleValue) > tolerance {
                out.append(path)
            }
        case let (x as String, y as String):
            if x != y { out.append(path) }
        case (is NSNull, is NSNull):
            break
        case let (x as [String: Any], y as [String: Any]):
            for k in Set(x.keys).union(y.keys).sorted() {
                let p = path.isEmpty ? k : "\(path).\(k)"
                let bp = bare.isEmpty ? k : "\(bare).\(k)"
                guard let xv = x[k], let yv = y[k] else {
                    if !ignoring.contains(bp) { out.append(p) }
                    continue
                }
                diff(xv, yv, path: p, bare: bp, tolerance: tolerance, ignoring: ignoring, out: &out)
            }
        case let (x as [Any], y as [Any]):
            if x.count != y.count { out.append("\(path).length") }
            for i in 0..<min(x.count, y.count) {
                diff(x[i], y[i], path: "\(path)[\(i)]", bare: bare, tolerance: tolerance, ignoring: ignoring, out: &out)
            }
        default:
            out.append(path)
        }
    }

    private static func isInteger(_ n: NSNumber) -> Bool {
        switch String(cString: n.objCType) {
        case "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q": true
        default: false
        }
    }
}

// MARK: - Golden file shape (decoding only)

private struct GoldenFile: Decodable {
    struct FlowHead: Decodable {
        var records, undecoded, crcErrors: Int
        var durationMs: Double
        var startUtcKnown: Bool
    }
    struct GField: Decodable {
        var label, value: String
        var children: [GField]?
        var field: Field { Field(label: label, value: value, children: (children ?? []).map(\.field)) }
    }
    struct GProtection: Decodable {
        var headerType, sequence: Int
    }
    struct GEvent: Decodable {
        var index, record: Int
        var logCode: String
        var timestampRaw: UInt64
        var sinceStartMs: Double
        var layer: Layer
        var rat: String
        var uplink: Bool
        var channel, key, name: String
        var summary: String?
        var cell: Cell?
        var cause: Int?
        var causeName: String?
        var protection: GProtection?
        var ciphered: Bool
        var carrier: String?
        var pduLength: Int
        var fields: [GField]
    }
    struct GConnection: Decodable {
        var first: Int
        var last: Int?
        var establishmentCause, releaseCause: String?
        var outcome: ConnectionOutcome
        var startMs: Double
        var endMs: Double?
        var connection: Connection {
            Connection(first: first, last: last, establishmentCause: establishmentCause, releaseCause: releaseCause,
                       outcome: outcome, startMs: startMs, endMs: endMs)
        }
    }
    struct GCellDetail: Decodable {
        var cell: Cell
        var pci: Int
        var downlinkEarfcn, uplinkEarfcn: Int64
        var band: Int
        var plmn: String
        var tac: Int
        var cellIdentity: Int64?
        var bandwidthMhz: Double?

        enum CodingKeys: String, CodingKey {
            case cell, pci, downlinkEarfcn, uplinkEarfcn, band, plmn, tac, cellIdentity, bandwidthMhz
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cell = try c.decode(Cell.self, forKey: .cell)
            pci = try c.decode(Int.self, forKey: .pci)
            downlinkEarfcn = try c.decode(Int64.self, forKey: .downlinkEarfcn)
            uplinkEarfcn = try c.decode(Int64.self, forKey: .uplinkEarfcn)
            band = try c.decode(Int.self, forKey: .band)
            plmn = try c.decode(String.self, forKey: .plmn)
            tac = try c.decode(Int.self, forKey: .tac)
            // "<masked>" in every golden; a number only in an unmasked local dump.
            cellIdentity = try? c.decodeIfPresent(Int64.self, forKey: .cellIdentity)
            bandwidthMhz = try c.decodeIfPresent(Double.self, forKey: .bandwidthMhz)
        }

        var info: ServingCellInfo {
            ServingCellInfo(pci: pci, downlinkEarfcn: downlinkEarfcn, uplinkEarfcn: uplinkEarfcn, band: band,
                            plmn: plmn, tac: tac, cellIdentity: cellIdentity, bandwidthMhz: bandwidthMhz)
        }
    }

    var source: GoldenSource
    var flow: FlowHead
    var events: [GEvent]
    var procedures: [Procedure]
    var journey: [Step]
    var searched: [Cell]
    var connections: [GConnection]
    var cellDetails: [GCellDetail]
    var recordsPerCode: [String: Int]
}

extension UInt16 {
    /// "0xB0C0" or "B0C0".
    init?(hex: String) {
        let digits = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        self.init(digits, radix: 16)
    }
}
