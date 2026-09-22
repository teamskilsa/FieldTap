import SwiftUI
import FTJourney
import FTModel

/// What the journey views share: the SF Symbol for each marker and finding (the glyph always carries the
/// meaning, colour only adds to it), the strip's lane geometry, and text colours that stay readable on the band
/// palette in light and dark mode.
enum JourneyStyle {
    static func symbol(_ kind: MarkerKind) -> String {
        switch kind {
        case .handover, .cellChange: "arrow.left.arrow.right"
        case .reselection, .reattach: "arrow.triangle.2.circlepath"
        case .redirect: "arrow.uturn.right"
        case .reestablishment: "arrow.clockwise"
        case .scgAdd: "plus.circle"
        case .scgModify: "pencil.circle"
        case .scgRelease: "minus.circle"
        case .attach: "checkmark.seal"
        case .detachSwitchOff: "power"
        case .detach: "minus.circle"
        case .rrcSetup: "arrow.up.circle"
        case .rrcRelease: "arrow.down.circle"
        case .rach: "dot.radiowaves.up.forward"
        case .scgFailure, .rrcReject, .procedureFailed, .connectionLost, .registrationReject: "xmark.octagon"
        case .procedureUnanswered, .noAnswer: "exclamationmark.triangle"
        }
    }

    static func symbol(_ kind: FindingKind) -> String {
        switch kind {
        case .switchedOff, .radioBack: "power"
        case .reattach, .attach: "checkmark.seal"
        case .pdnConnected: "phone.connection"
        case .scgAdded: "plus.circle"
        case .scgPhyOutlived, .warning: "exclamationmark.triangle.fill"
        case .handover: "arrow.left.arrow.right"
        case .carrierAggregation: "square.stack.3d.up"
        case .failure: "xmark.octagon.fill"
        case .noFailures: "checkmark.circle"
        case .encryptedRecords: "lock"
        case .traceWindow: "clock"
        case .other: "arrow.triangle.2.circlepath"
        }
    }

    /// RRC setup and release and RACH are drawn as small ticks, not full glyphs, so the moves stand out.
    static func isTick(_ kind: MarkerKind) -> Bool { kind == .rrcSetup || kind == .rrcRelease || kind == .rach }

    static func color(_ severity: Severity) -> Color {
        severity == .info ? Color.primary : Theme.severity(severity)
    }

    /// The state lane, lighter neutrals in dark mode so "connected" still reads darker than "idle" against it.
    static func state(_ s: RadioState, dark: Bool) -> Color {
        guard dark else { return Theme.state(s) }
        switch s {
        case .connected: return Color(hex: 0xB8_BFCC)
        case .idle: return Color(hex: 0x4A_505C)
        case .radioOff: return Color(hex: 0x6B_707A)
        case .unknown: return .clear
        }
    }

    /// The fill for a segment: the band's fixed colour. NR uses its candidate label ("n5/n26").
    static func fill(_ s: CellSegment) -> Color { Theme.bandColor(JourneyText.band(s)) }

    /// Black or white, whichever reads on `color`.
    static func ink(on color: Color, in env: EnvironmentValues) -> Color {
        let c = color.resolve(in: env)
        let luminance = 0.2126 * Double(c.linearRed) + 0.7152 * Double(c.linearGreen) + 0.0722 * Double(c.linearBlue)
        return luminance > 0.2 ? Color.black.opacity(0.85) : .white
    }

    /// "LTE" or "NR".
    static func rat(_ cell: Cell) -> String { cell.nr ? "NR" : "LTE" }
}

/// The strip's lanes in points from the top of the plot. Lanes the capture does not have are left out.
struct StripLanes: Equatable {
    struct Lane: Equatable {
        var top: Double
        var height: Double
        var bottom: Double { top + height }
        var mid: Double { top + height / 2 }
    }

    static let gap = 4.0
    var state: Lane
    var registration: Lane
    var pcell: Lane
    var nr: Lane?
    var scells: [Int: Lane]
    var markers: Lane
    var height: Double

    init(hasNr: Bool, scellIndexes: [Int]) {
        var y = 0.0
        state = Lane(top: y, height: 9)
        y += 9 + 1
        registration = Lane(top: y, height: 3)
        y += 3 + Self.gap
        pcell = Lane(top: y, height: 26)
        y += 26 + Self.gap
        if hasNr {
            nr = Lane(top: y, height: 18)
            y += 18 + Self.gap
        }
        var sc: [Int: Lane] = [:]
        for (n, index) in scellIndexes.sorted().enumerated() {
            sc[index] = Lane(top: y, height: 10)
            y += 10 + (n == scellIndexes.count - 1 ? Self.gap : 2)
        }
        scells = sc
        markers = Lane(top: y, height: 18)
        y += 18
        height = y
    }

    func lane(for s: CellSegment) -> Lane? {
        switch s.lane {
        case .pcell: pcell
        case .pscell: nr
        case .scell: scells[s.index]
        }
    }
}
