// Port of android/app/src/main/kotlin/com/fieldtap/ui/signalling/CallFlowPresentation.kt at contract v1 (D4:
// "NR cell pending"). Numbers go through Fmt.fixed, so every string equals the Kotlin one (presentation-golden).

import FTCore
import FTModel

/// Turns a Flow into what the call-flow screens draw, and formats the numbers on it. Kept apart from the views so
/// the row building (what folds, where banners go) is tested without a simulator.
public enum CallFlowPresentation {
    static let broadcast: Set<String> = ["BCCH-BCH", "BCCH-DL-SCH", "MCCH", "PCCH"]

    public static func rows(_ flow: Flow, _ filter: FlowFilter) -> [LadderRow] {
        let shown = flow.events.filter { filter.admits($0) }
        // Kotlin associateBy: the last step wins when two share an event.
        let moves: [Int: Step] = filter == .NAS ? [:] : Dictionary(
            flow.journey.filter { $0.move != .FIRST_SEEN }.map { ($0.event, $0) }, uniquingKeysWith: { _, last in last })
        var starts: [Int: [(offset: Int, element: Procedure)]] = [:]
        for (i, p) in flow.procedures.enumerated() where filter == .ALL || p.layer.rawValue == filter.rawValue {
            starts[p.first, default: []].append((i, p))
        }

        var rows: [LadderRow] = []
        var index = 0
        while index < shown.count {
            let event = shown[index]
            if let step = moves[event.index] { rows.append(.move(step)) }
            for start in starts[event.index] ?? [] { rows.append(.procedureStart(start.element, ordinal: start.offset)) }
            var end = index + 1
            if broadcast.contains(event.channel) {
                while end < shown.count, foldsInto(event, shown[end], moves: moves, starts: starts) { end += 1 }
            }
            rows.append(.message(event, repeats: Array(shown[(index + 1)..<end])))
            index = end
        }
        return rows
    }

    private static func foldsInto(_ first: Event, _ next: Event, moves: [Int: Step],
                                  starts: [Int: [(offset: Int, element: Procedure)]]) -> Bool {
        broadcast.contains(next.channel) && moves[next.index] == nil && starts[next.index] == nil
            // Paging is on the serving cell and says the phone is idle there; it does not join a search.
            && (next.channel == "PCCH") == (first.channel == "PCCH")
    }

    /// The ladder row a message is on, for scrolling to it. Folded messages land on their run.
    public static func rowOf(_ rows: [LadderRow], eventIndex: Int) -> Int? {
        rows.firstIndex { row in
            guard case .message(let e, let repeats) = row else { return false }
            return e.index == eventIndex || repeats.contains { $0.index == eventIndex }
        }
    }

    /// The cells of a folded run, in the order first heard: "B3 PCI 3, B7 PCI 2 +14".
    public static func cellsOf(_ event: Event, repeats: [Event], shown: Int = 2) -> String {
        let cells = distinctCells(event, repeats)
        let head = cells.prefix(shown).map { shortCell($0) }.joined(separator: ", ")
        return cells.count > shown ? "\(head) +\(cells.count - shown)" : head
    }

    public static func cellCount(_ event: Event, repeats: [Event]) -> Int { distinctCells(event, repeats).count }

    private static func distinctCells(_ event: Event, _ repeats: [Event]) -> [Cell] {
        var seen = Set<Cell>()
        return ([event] + repeats).compactMap(\.cell).filter { seen.insert($0).inserted }
    }

    // MARK: - Procedures

    /// Every attempt at one kind of procedure, and how they went.
    public struct ProcedureGroup: Hashable, Sendable {
        public var name: String
        public var layer: Layer
        public var items: [Procedure]
        public var succeeded: Int
        public var failed: Int
        public var unanswered: Int
        /// The median time of the ones that succeeded: what "how long does an attach take here" means.
        public var medianMs: Double?

        public init(name: String, layer: Layer, items: [Procedure], succeeded: Int, failed: Int, unanswered: Int,
                    medianMs: Double?) {
            self.name = name
            self.layer = layer
            self.items = items
            self.succeeded = succeeded
            self.failed = failed
            self.unanswered = unanswered
            self.medianMs = medianMs
        }

        /// Kotlin's ProcedureGroup(name, layer, items): the counts and the median come from the items.
        public init(name: String, layer: Layer, items: [Procedure]) {
            let times = items.filter { $0.outcome == .SUCCEEDED }.map(\.durationMs).sorted()
            let median: Double? = times.isEmpty ? nil : times.count % 2 == 1
                ? times[times.count / 2] : (times[times.count / 2 - 1] + times[times.count / 2]) / 2
            self.init(name: name, layer: layer, items: items,
                      succeeded: items.count { $0.outcome == .SUCCEEDED },
                      failed: items.count { $0.outcome == .FAILED },
                      unanswered: items.count { $0.outcome == .UNANSWERED },
                      medianMs: median)
        }

        /// The worst outcome in the group: failed, then unanswered, then succeeded.
        public var worst: Outcome { failed > 0 ? .FAILED : unanswered > 0 ? .UNANSWERED : .SUCCEEDED }
    }

    /// Procedures by kind, in the order each kind first happened.
    public static func procedureGroups(_ flow: Flow) -> [ProcedureGroup] {
        var order: [String] = []
        var byName: [String: [Procedure]] = [:]
        for p in flow.procedures {
            if byName[p.name] == nil { order.append(p.name) }
            byName[p.name, default: []].append(p)
        }
        return order.map { name in
            let items = byName[name]!
            return ProcedureGroup(name: name, layer: items[0].layer, items: items)
        }
    }

    // MARK: - Lanes

    /// The ladder's three columns: "UE | RAN | Core", "eNB/MME" for LTE-only, "gNB/AMF" for NR-only.
    public struct Lanes: Hashable, Sendable {
        public var phone: String
        public var ran: String
        public var core: String

        public init(phone: String, ran: String, core: String) {
            self.phone = phone
            self.ran = ran
            self.core = core
        }
    }

    public static func lanes(_ flow: Flow) -> Lanes {
        let rats = Set(flow.events.map(\.rat))
        if rats == ["nr"] { return Lanes(phone: "UE", ran: "gNB", core: "AMF") }
        if rats.contains("nr") { return Lanes(phone: "UE", ran: "RAN", core: "Core") }
        return Lanes(phone: "UE", ran: "eNB", core: "MME")
    }

    /// "UE → eNB" for an uplink RRC message, "MME → UE" for a downlink NAS one.
    public static func direction(_ event: Event, _ lanes: Lanes) -> String {
        let far = event.layer == .RRC ? lanes.ran : lanes.core
        return event.uplink ? "\(lanes.phone) → \(far)" : "\(far) → \(lanes.phone)"
    }

    // MARK: - Cells

    /// "B3" for an LTE cell, or nil when the EARFCN is in no band this app knows. Always nil for NR: NR bands
    /// overlap (n77 contains n78), so the ARFCN alone does not name one, and a guessed band would often be wrong.
    public static func band(_ cell: Cell) -> String? {
        cell.nr ? nil : Spectrum.lte(cell.earfcn).map { "B\($0.band)" }
    }

    /// Downlink centre frequency in MHz, one decimal: TS 36.101 for an EARFCN, the TS 38.104 raster for NR.
    public static func downlinkMhz(_ cell: Cell) -> String? {
        let mhz = cell.nr ? Spectrum.nrMhz(cell.earfcn) : Spectrum.lte(cell.earfcn)?.dlMhz
        return mhz.map { Fmt.fixed($0, 1) + " MHz" }
    }

    /// What the cell's channel number is called: EARFCN on LTE, NR-ARFCN on NR.
    public static func channelLabel(_ cell: Cell) -> String { cell.nr ? "NR-ARFCN" : "EARFCN" }

    /// "B3 PCI 3", "NR PCI 417", "EARFCN 70000 PCI 3" when an LTE band is unknown, and "NR cell pending" for an
    /// NR header logged before the SCG cell was assigned (D4), never its 0xFFFF placeholder as a PCI.
    public static func shortCell(_ cell: Cell) -> String {
        if cell.isPendingNr { return "NR cell pending" }
        if cell.nr { return "NR PCI \(cell.pci)" }
        return "\(band(cell) ?? "EARFCN \(cell.earfcn)") PCI \(cell.pci)"
    }

    // MARK: - Time

    /// Since the start of the capture, as a clock: "0:00.064", "1:58.338", "1:02:03.004". Tabular and sortable by
    /// eye, which a mix of "64 ms" and "2 min" is not.
    public static func sinceStart(_ ms: Double) -> String {
        // Java's Math.round: half up. For the non-negative values here that is half away from zero.
        let total = ms.isFinite ? Int64(max(ms, 0).rounded(.toNearestOrAwayFromZero)) : 0
        let millis = total % 1000
        let seconds = (total / 1000) % 60
        let minutes = (total / 60_000) % 60
        let hours = total / 3_600_000
        return hours > 0
            ? "\(hours):\(pad(minutes, 2)):\(pad(seconds, 2)).\(pad(millis, 3))"
            : "\(minutes):\(pad(seconds, 2)).\(pad(millis, 3))"
    }

    /// A span: "0.4 ms", "67.5 ms", "335 ms", "1.24 s", "12.3 s", "2 min 3 s", "1 h 5 min". The rule itself is
    /// `Fmt.duration`, which every other screen uses too.
    public static func duration(_ ms: Double) -> String { Fmt.duration(ms) }

    /// The gap to the message before, or nil for the first.
    public static func gap(_ events: [Event], _ index: Int) -> Double? {
        guard index > 0, index < events.count else { return nil }
        return events[index].sinceStartMs - events[index - 1].sinceStartMs
    }

    // MARK: - Bytes

    /// Eight bytes a line (what fits a phone in monospace) with the offset and the printable characters.
    public static func hexDump(_ bytes: [UInt8], perLine: Int = 8) -> String {
        guard perLine > 0 else { return "" }
        return stride(from: 0, to: bytes.count, by: perLine).map { start in
            let chunk = bytes[start..<min(start + perLine, bytes.count)]
            let hex = chunk.map { byteHex($0) }.joined(separator: " ")
            let padded = hex + String(repeating: " ", count: max(0, perLine * 3 - 1 - hex.count))
            let text = String(chunk.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return Fmt.hex(start, width: 4, prefix: false, uppercase: false) + "  " + padded + "  " + text
        }.joined(separator: "\n")
    }

    public static func hex(_ bytes: [UInt8]) -> String { bytes.map { byteHex($0) }.joined() }

    private static func byteHex(_ b: UInt8) -> String { Fmt.hex(b, width: 2, prefix: false, uppercase: false) }

    private static func pad(_ v: Int64, _ width: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
