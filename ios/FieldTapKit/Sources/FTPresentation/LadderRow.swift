// Port of FlowFilter and LadderRow in android/app/.../ui/signalling/CallFlowPresentation.kt (contract v1).

import FTModel

/// Which messages the ladder shows.
public enum FlowFilter: String, CaseIterable, Codable, Hashable, Sendable {
    case ALL, RRC, NAS

    /// Whether an event passes the filter.
    public func admits(_ event: Event) -> Bool {
        switch self {
        case .ALL: true
        case .RRC: event.layer == .RRC
        case .NAS: event.layer == .NAS
        }
    }
}

/// One line of the ladder.
public enum LadderRow: Hashable, Identifiable, Sendable {
    /// The phone moved to another cell here.
    case move(Step)
    /// A procedure starts at the next message.
    case procedureStart(Procedure, ordinal: Int)
    /// One message, or a run of broadcast messages folded into one line. An idle phone reads SIB1 and paging
    /// over and over, and a phone searching for service reads the system information of every cell it hears:
    /// one overnight capture held 40,000 of them around 400 messages that mattered.
    case message(Event, repeats: [Event])

    /// A stable key for the lazy list: "move-<event>", "procedure-<n>" or "event-<index>".
    public var id: String {
        switch self {
        case .move(let s): "move-\(s.event)"
        case .procedureStart(_, let ordinal): "procedure-\(ordinal)"
        case .message(let e, _): "event-\(e.index)"
        }
    }

    /// Messages on this line (1 for moves and banners).
    public var count: Int {
        if case .message(_, let repeats) = self { return 1 + repeats.count }
        return 1
    }

    /// More than one kind of message, or more than one cell, in a folded run.
    public var mixed: Bool {
        if case .message(let e, let repeats) = self { return repeats.contains { $0.key != e.key || $0.cell != e.cell } }
        return false
    }

    /// The first message of a message line; nil for moves and banners.
    public var event: Event? {
        if case .message(let e, _) = self { return e }
        return nil
    }

    /// Every message on a message line, the first one first; empty for moves and banners.
    public var events: [Event] {
        if case .message(let e, let repeats) = self { return [e] + repeats }
        return []
    }
}
