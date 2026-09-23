import SwiftUI
import FTJourney
import FTModel

/// Colours, SF Symbols and short labels for the Security screen. Verdict and severity colours reuse the app's
/// theme (never the signal scale's red, so "poor signal" and "suspicious" never look the same), and the icon
/// always carries the meaning alongside the colour.
enum SecurityStyle {
    struct VerdictStyle {
        var word: String
        var symbol: String
        var color: Color
    }

    static func verdict(_ v: SecurityVerdict) -> VerdictStyle {
        switch v {
        case .trusted:
            VerdictStyle(word: "Looks clean", symbol: "checkmark.shield.fill", color: Theme.accent)
        case .warning:
            VerdictStyle(word: "Worth a look", symbol: "exclamationmark.shield.fill", color: Theme.severity(.warning))
        case .suspicious:
            VerdictStyle(word: "Suspicious signatures", symbol: "exclamationmark.shield.fill", color: Theme.severity(.failure))
        }
    }

    static func severity(_ s: SecuritySeverity) -> Color {
        switch s {
        case .info: Theme.accent
        case .warning: Theme.severity(.warning)
        case .suspicious: Theme.severity(.failure)
        }
    }

    static func symbol(_ check: SecurityCheckId) -> String {
        switch check {
        case .nullCipher: "lock.open"
        case .noSecurityEstablished: "lock.slash"
        case .imsiRequestedInClear: "person.text.rectangle"
        case .ratDowngrade: "arrow.down.right.circle"
        case .acceptedWithoutAuth: "key.slash"
        case .abnormalReject: "hand.raised.slash"
        case .implausibleSignal: "antenna.radiowaves.left.and.right"
        case .orphanCell: "questionmark.circle"
        }
    }

    static func checkName(_ check: SecurityCheckId) -> String {
        switch check {
        case .nullCipher: "Null cipher"
        case .noSecurityEstablished: "Security setup"
        case .imsiRequestedInClear: "IMSI in clear"
        case .ratDowngrade: "2G/3G downgrade"
        case .acceptedWithoutAuth: "Authentication"
        case .abnormalReject: "Reject cause"
        case .implausibleSignal: "Signal strength"
        case .orphanCell: "Cell mobility"
        }
    }

    static func gapName(_ check: String) -> String {
        switch check {
        case "sibNeighbourList": "SIB neighbour list"
        case "asSecurityAlgorithm": "AS security algorithm"
        case "sibAuthenticity": "SIB authenticity"
        default: check
        }
    }

    /// A cell without its (masked) TAC / cell identity: the RAT, ARFCN and PCI, as the rest of the app shows them.
    static func cellLabel(_ cell: Cell) -> String {
        if cell.isPendingNr { return "NR cell pending" }
        let space = cell.nr ? "NR ARFCN" : "EARFCN"
        return "\(space) \(cell.earfcn) · PCI \(cell.pci)"
    }

    static func clock(_ tMs: Double) -> String { JourneyText.clock(tMs) }
}
