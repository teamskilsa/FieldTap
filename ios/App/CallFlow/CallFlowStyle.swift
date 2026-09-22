import SwiftUI
import UIKit
import FTModel
import FTPresentation

/// The call-flow screens' geometry and colours, from android/app/.../ui/signalling/CallFlowLadder.kt: a 70 pt time
/// gutter, lanes 18 pt in from the edges of the lane area, 14 pt clear of the screen edge. Colour says the layer
/// (indigo RRC, teal NAS); the outcome colours come with a symbol and a word, never alone.
enum CallFlowStyle {
    static let gutter: CGFloat = 70
    static let laneInset: CGFloat = 18
    static let endPadding: CGFloat = 14

    static func layer(_ layer: Layer) -> Color { layer == .RRC ? Theme.accent : nas }

    static let nas = dynamic(light: 0x0F_766E, dark: 0x5E_EAD4)
    /// Not the signal scale's green (#1a9641): a succeeded procedure is not a strong signal.
    static let success = dynamic(light: 0x04_7857, dark: 0x34_D399)
    static let failure = Theme.severity(.failure)
    static let unanswered = Theme.severity(.warning)
    static let lane = Color(uiColor: .separator)

    /// The symbol, colour and word for a procedure outcome.
    static func outcome(_ o: Outcome) -> (symbol: String, color: Color, word: String) {
        switch o {
        case .SUCCEEDED: ("checkmark.circle.fill", success, "Succeeded")
        case .FAILED: ("xmark.octagon.fill", failure, "Failed")
        case .UNANSWERED: ("clock.badge.questionmark", unanswered, "No answer in this capture")
        }
    }

    /// The colour a move banner takes: the destination band's, as on the journey strip.
    static func moveColor(_ cell: Cell) -> Color {
        Theme.bandColor(CallFlowPresentation.band(cell) ?? (cell.nr ? "NR" : "LTE"))
    }

    static func moveName(_ move: Move) -> String {
        switch move {
        case .HANDOVER: "Handover"
        case .RESELECTION: "Reselection"
        case .REDIRECT: "Redirect"
        case .REESTABLISHMENT: "Re-establishment"
        case .CELL_CHANGE, .FIRST_SEEN: "Cell change"
        }
    }

    /// Named apart from other packages' helpers: every App/ file shares one module.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
