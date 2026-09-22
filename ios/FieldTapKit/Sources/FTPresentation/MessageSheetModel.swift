// What the message sheet shows for one event (android/app/.../ui/signalling/CallFlowLadder.kt, MessageSheet), with
// the iOS display rules of ios/Contract/CONTRACT.md: identifiers masked unless revealed, TAC and cell identity
// masked in the cell section, and the bytes hidden while masked (an Identity response carries the IMEISV there).

import Foundation
import FTCore
import FTModel

/// What the message sheet shows for one event, already masked unless `reveal` is set.
public struct MessageSheetModel: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        public var label: String
        public var value: String
        /// Nesting of a decoded field (0 for top-level lines).
        public var depth: Int

        public init(label: String, value: String, depth: Int = 0) {
            self.label = label
            self.value = value
            self.depth = depth
        }
    }

    public struct Section: Hashable, Sendable {
        public var title: String
        public var lines: [Line]
        /// A sentence under the lines, when there is something to explain ("Ciphered, and ...").
        public var note: String?

        public init(title: String, lines: [Line], note: String? = nil) {
            self.title = title
            self.lines = lines
            self.note = note
        }
    }

    public var sections: [Section]
    /// The hex dump is shown only when identifiers are revealed.
    public var bytesVisible: Bool
    /// What Copy and Share put on the pasteboard (masked unless revealed).
    public var copyText: String

    /// The message name, e.g. "RRC Connection Reconfiguration".
    public var title: String
    /// The one line under the name (a cause, an APN, a handover target), masked unless revealed.
    public var summary: String?
    /// "LTE RRC", the channel, and the direction ("RAN → UE").
    public var tags: [String]
    /// For NAS pulled out of an RRC message: "Carried in UL Information Transfer".
    public var carriedIn: String?
    /// "Bytes · 12", or "Bytes" when the flow came from a golden fixture and kept none.
    public var bytesTitle: String
    /// The hex dump, 8 bytes a line; nil while identifiers are masked or when there are no bytes.
    public var hexDump: String?
    /// Why no dump is shown.
    public var bytesNote: String?
    /// "Log 0xB0C0 · record 1234".
    public var source: String
    public var isFailure: Bool

    static let bytesHidden = "Bytes hidden while identifiers are masked. They can carry the IMSI or IMEI."
    static let noBytes = "No bytes were kept for this message."
    static let ciphered = "Ciphered, and the modem logged no plain copy, so what it was cannot be read."
    static let nothingDecoded = "Nothing more is decoded from this message."
    static let bytesElsewhere = "Its bytes are hidden while identifiers are masked."
    static let nearby = "From the RRC messages around it."
    static let pendingNr = "Logged before the 5G cell was assigned."

    public init(event: Event, flow: Flow, reveal: Bool) {
        self.init(event: event, flow: flow, reveal: reveal, lanes: CallFlowPresentation.lanes(flow))
    }

    /// With the flow's lanes already known: the audit builds a sheet for every event of a 40,000-event capture.
    init(event: Event, flow: Flow, reveal: Bool, lanes: CallFlowPresentation.Lanes) {
        // Decoder text can hide an identifier anywhere; what this file computes itself (times, PCI, MHz) cannot.
        func text(_ s: String) -> String { reveal ? s : Redaction.scrub(s) }

        title = text(event.name)
        summary = event.summary.map(text)
        tags = ["\(event.rat.uppercased()) \(event.layer.rawValue)", text(event.channel),
                CallFlowPresentation.direction(event, lanes)]
        carriedIn = event.carrier.map { "Carried in " + text($0) }
        isFailure = event.isFailure
        source = "Log \(Fmt.hex(event.logCode, width: 4)) · record \(event.record)"

        var sections: [Section] = []

        var when: [Line] = []
        if let utc = TimeBase.utcMs(event.timestampRaw) {
            when.append(Line(label: "Modem time (UTC)", value: Self.utcText(utc)))
        }
        when.append(Line(label: "Since start", value: CallFlowPresentation.sinceStart(event.sinceStartMs)))
        if let gap = CallFlowPresentation.gap(flow.events, event.index) {
            when.append(Line(label: "After previous", value: "+" + CallFlowPresentation.duration(gap)))
        }
        sections.append(Section(title: "When", lines: when))

        if let cell = event.cell {
            sections.append(Self.cellSection(event, cell, flow.cellInfo(for: cell), reveal: reveal))
        }

        var decoded: [Line] = []
        if let cause = event.cause {
            decoded.append(Line(label: "Cause", value: event.causeName.map { "#\(cause) " + text($0) } ?? "#\(cause)"))
        }
        func add(_ fields: [Field], _ depth: Int) {
            for f in fields {
                decoded.append(Line(label: text(f.label), value: f.value, depth: depth))
                add(f.children, depth + 1)
            }
        }
        add(event.fields.map { Redaction.display($0, reveal: reveal) }, 0)
        var decodedNote: String? = !event.fields.isEmpty ? nil
            : event.ciphered ? Self.ciphered : event.cause == nil ? Self.nothingDecoded : nil
        // With nothing decoded the bytes are all there is (an Identity response's IMEISV): say where they went.
        if let note = decodedNote, !reveal { decodedNote = note + " " + Self.bytesElsewhere }
        sections.append(Section(title: "Decoded", lines: decoded, note: decodedNote))

        if let p = event.protection {
            var lines = [Line(label: "Header", value: p.headerName)]
            // A golden fixture keeps no MAC (0); 0x-hex of 8 digits is masked like any identifier-shaped hex.
            if p.mac != 0 { lines.append(Line(label: "MAC", value: text(Fmt.hex(p.mac, width: 8, uppercase: false)))) }
            lines.append(Line(label: "Sequence number", value: "\(p.sequence)"))
            sections.append(Section(title: "Security", lines: lines))
        }
        self.sections = sections

        bytesVisible = reveal
        bytesTitle = event.pdu.isEmpty ? "Bytes" : "Bytes · \(event.pdu.count)"
        if !reveal {
            hexDump = nil
            bytesNote = Self.bytesHidden
        } else if event.pdu.isEmpty {
            hexDump = nil
            bytesNote = Self.noBytes
        } else {
            hexDump = CallFlowPresentation.hexDump(event.pdu)
            bytesNote = nil
        }

        var out = [title, tags.joined(separator: " · ")]
        if let summary { out.append(summary) }
        if let carriedIn { out.append(carriedIn) }
        for s in sections {
            out.append("")
            out.append(s.title.uppercased())
            for l in s.lines { out.append(String(repeating: "  ", count: l.depth) + "\(l.label): \(l.value)") }
            if let note = s.note { out.append(note) }
        }
        out.append("")
        out.append(bytesTitle.uppercased())
        if let hexDump { out.append(hexDump) }
        if let bytesNote { out.append(bytesNote) }
        out.append("")
        out.append(source)
        copyText = out.joined(separator: "\n")
    }

    private static func cellSection(_ event: Event, _ cell: Cell, _ info: ServingCellInfo?, reveal: Bool) -> Section {
        var lines: [Line] = []
        if cell.isPendingNr {
            lines.append(Line(label: "PCI", value: "pending"))
            lines.append(Line(label: CallFlowPresentation.channelLabel(cell), value: "pending"))
        } else {
            lines.append(Line(label: "PCI", value: "\(cell.pci)"))
            lines.append(Line(label: CallFlowPresentation.channelLabel(cell), value: "\(cell.earfcn)"))
            if let band = CallFlowPresentation.band(cell) { lines.append(Line(label: "Band", value: band)) }
            if let mhz = CallFlowPresentation.downlinkMhz(cell) { lines.append(Line(label: "Downlink", value: mhz)) }
        }
        if let info {
            // TAC and cell identity come masked from Redaction.displayCellInfo: with the PLMN they locate the phone.
            let shown = Dictionary(Redaction.displayCellInfo(info, reveal: reveal).map { ($0.label, $0.value) },
                                   uniquingKeysWith: { first, _ in first })
            lines.append(Line(label: "PLMN", value: info.plmn))
            lines.append(Line(label: "Tracking area", value: shown["TAC"] ?? Redaction.masked))
            lines.append(Line(label: "Cell identity", value: shown["Cell identity"] ?? Redaction.masked))
            if reveal, !cell.nr, let id = Spectrum.lteCellId(info.cellIdentity) {
                lines.append(Line(label: "eNB · cell", value: "\(id.enb) · \(id.cell)"))
            }
            if let mhz = info.bandwidthMhz { lines.append(Line(label: "Bandwidth", value: Fmt.fixed(mhz, 0) + " MHz")) }
        }
        let note: String? = cell.isPendingNr ? pendingNr
            : event.layer == .NAS && event.carrier == nil ? nearby : nil
        return Section(title: "Cell", lines: lines, note: note)
    }

    /// "2026-09-21 19:42:21.024" from Unix ms, in UTC, independent of the device's calendar and locale.
    static func utcText(_ ms: Int64) -> String {
        let days = ms >= 0 ? ms / 86_400_000 : (ms - 86_399_999) / 86_400_000
        let msOfDay = ms - days * 86_400_000
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func p(_ v: Int64, _ w: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        return "\(p(year, 4))-\(p(month, 2))-\(p(day, 2)) \(p(msOfDay / 3_600_000, 2)):\(p(msOfDay / 60_000 % 60, 2))"
            + ":\(p(msOfDay / 1000 % 60, 2)).\(p(msOfDay % 1000, 3))"
    }

    // MARK: - One line and the masking audit

    /// What a long press on a ladder row copies: "0:15.040 · RAN → UE · RRC Connection Reconfiguration · handover
    /// to PCI 235, EARFCN 5110", masked unless revealed.
    public static func oneLine(_ event: Event, lanes: CallFlowPresentation.Lanes, reveal: Bool) -> String {
        let parts = [CallFlowPresentation.sinceStart(event.sinceStartMs), CallFlowPresentation.direction(event, lanes),
                     event.name, event.summary].compactMap { $0 }
        let line = parts.joined(separator: " · ")
        return reveal ? line : Redaction.scrub(line)
    }

    /// Every place a masked sheet (or its one-line copy) still shows something identifier-shaped: a run of 10 or
    /// more digits, an IPv4 or IPv6 address, 0x-hex of 8 or more digits, or visible bytes. Entries name the
    /// event, the place and the kind, never the text. Empty means the masking held for the whole flow.
    public static func maskingAudit(_ flow: Flow) -> [String] { audit(flow, reveal: false) }

    /// The audit over sheets built with `reveal`; with true it lists every identifier, which tests that it can fail.
    static func audit(_ flow: Flow, reveal: Bool) -> [String] {
        let lanes = CallFlowPresentation.lanes(flow)
        var leaks: [String] = []
        for event in flow.events {
            let m = MessageSheetModel(event: event, flow: flow, reveal: reveal, lanes: lanes)
            if m.bytesVisible || m.hexDump != nil { leaks.append("event \(event.index) bytes: visible") }
            var places: [(String, String)] = [("title", m.title), ("copyText", m.copyText), ("source", m.source),
                                              ("oneLine", oneLine(event, lanes: lanes, reveal: reveal))]
            places += m.tags.map { ("tag", $0) }
            if let s = m.summary { places.append(("summary", s)) }
            if let c = m.carriedIn { places.append(("carriedIn", c)) }
            for s in m.sections {
                places.append((s.title, s.title))
                if let n = s.note { places.append(("\(s.title) note", n)) }
                for l in s.lines { places.append(("\(s.title)/\(l.label)", l.label + " " + l.value)) }
            }
            for (place, value) in places {
                for kind in IdentifierShape.kinds(in: value) { leaks.append("event \(event.index) \(place): \(kind)") }
            }
        }
        return leaks
    }
}

/// The identifier shapes Redaction masks, for checking that nothing got through. The clocks this module prints
/// ("0:15.040", "1:02:03.004", "19:42:21.024") are taken out first: the golden's loose IPv6 pattern matches them.
enum IdentifierShape {
    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let clock = regex("\\b[0-9]{1,6}(:[0-9]{2}){1,2}\\.[0-9]{3}\\b")
    private static let shapes: [(String, NSRegularExpression)] = [
        ("IPv6", regex("(?i)\\b([0-9a-f]{1,4}:){2,7}[0-9a-f:]{1,4}\\b|::[0-9a-f]{1,4}")),
        ("IPv4", regex("\\b[0-9]{1,3}(\\.[0-9]{1,3}){3}\\b")),
        ("10+ digits", regex("\\+?[0-9][0-9 ]{8,}[0-9]")),
        ("0x-hex", regex("(?i)0x[0-9a-f]{8,}")),
    ]

    static func kinds(in s: String) -> [String] {
        let t = clock.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "T")
        let range = NSRange(t.startIndex..., in: t)
        return shapes.filter { $0.1.firstMatch(in: t, range: range) != nil }.map(\.0)
    }
}
