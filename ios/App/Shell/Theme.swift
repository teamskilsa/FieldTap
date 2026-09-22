import SwiftUI
import FTModel

/// Colour tokens, mirroring android/app/.../ui/theme/DESIGN.md ("Momentum"): one indigo accent, the frozen
/// signal scale (data, not branding), a fixed categorical palette for bands, and severity colours that are
/// deliberately not the signal scale's red, so "poor signal" and "failure" never look the same.
enum Theme {
    /// Indigo #4F46E5 (light) / #AEB6FF (dark), from Assets.xcassets/AccentColor.
    static let accent = Color.accentColor

    /// The signal scale's levels (SignalScale.kt): the same thresholds for LTE and NR.
    enum SignalLevel: String, CaseIterable, Sendable {
        case excellent, good, fair, poor

        static func rsrp(_ dBm: Double?) -> SignalLevel? { level(dBm, -85, -95, -105) }
        static func rsrq(_ dB: Double?) -> SignalLevel? { level(dB, -10, -15, -20) }
        static func sinr(_ dB: Double?) -> SignalLevel? { level(dB, 20, 13, 0) }

        private static func level(_ v: Double?, _ excellent: Double, _ good: Double, _ fair: Double) -> SignalLevel? {
            guard let v, v.isFinite else { return nil }
            if v >= excellent { return .excellent }
            if v >= good { return .good }
            if v >= fair { return .fair }
            return .poor
        }

        /// The word that goes with the colour (colour is never the only cue).
        var word: String { rawValue.capitalized }
    }

    /// The report's route colours, exactly: #1a9641 / #a6d96a / #fdae61 / #d7191c. Unknown is neutral.
    static func signal(_ level: SignalLevel?) -> Color {
        switch level {
        case .excellent: Color(hex: 0x1A_9641)
        case .good: Color(hex: 0xA6_D96A)
        case .fair: Color(hex: 0xFD_AE61)
        case .poor: Color(hex: 0xD7_191C)
        case nil: Color.secondary
        }
    }

    /// A stable colour per band, app-wide (B2, B12 and B66 each keep theirs on every screen). Blues, purples,
    /// teals and neutrals only: never a signal-scale green, orange or red.
    static func bandColor(_ band: String) -> Color {
        // Slot 7 was grey 0x8C8C99, next to the radio-off grey 0x8A8F99, so the NR leg (n5/n26) read as radio off.
        let palette: [UInt32] = [0x4E_79A7, 0xB0_7AA1, 0x76_B7B2, 0x2F_4B7C, 0x9C_755F, 0xED_C948, 0xFF_9DA7, 0x59_A14F]
        let fixed: [String: Int] = ["B2": 0, "B66": 1, "B12": 2, "B4": 3, "B71": 4, "B41": 5, "n41": 5, "n77": 6, "n78": 6,
                                    "B5": 7, "n5": 7, "n5/n26": 7]
        if let i = fixed[band] { return Color(hex: palette[i]) }
        // djb2 over the name: stable across launches, unlike hashValue.
        let h = band.unicodeScalars.reduce(UInt32(5_381)) { ($0 &* 33) &+ $1.value }
        return Color(hex: palette[Int(h % UInt32(palette.count))])
    }

    /// The journey strip's state lane: connected dark neutral, idle light neutral, radio off grey (WP5 hatches
    /// it), unknown clear.
    static func state(_ s: RadioState) -> Color {
        switch s {
        case .connected: Color(hex: 0x3A_4252)
        case .idle: Color(hex: 0xC9_CED8)
        case .radioOff: Color(hex: 0x8A_8F99)
        case .unknown: Color.clear
        }
    }

    /// Marker and finding severity; the SF Symbol next to it carries the meaning too.
    static func severity(_ s: Severity) -> Color {
        switch s {
        case .info: accent
        case .warning: Color(hex: 0xB4_5309)
        case .failure: Color(hex: 0x9F_1239)
        }
    }

    /// Tabular digits for every changing number.
    static let numeric = Font.body.monospacedDigit()
}

extension Color {
    /// 0xRRGGBB in sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
