// The words and numbers the journey screens and findings share, so the strip, the header, the popovers and
// "What happened" say the same thing the same way.

import FTCore
import FTModel

public enum JourneyText {
    /// "0:15.040": minutes, then seconds to the millisecond, since the capture start.
    public static func clock(_ ms: Double) -> String {
        let total = Int(max(0, ms.isFinite ? ms : 0).rounded())
        let minutes = total / 60_000, rest = total % 60_000
        return "\(minutes):\(pad(rest / 1_000, 2)).\(pad(rest % 1_000, 3))"
    }

    /// "0:19": whole seconds, for times the user reads against a stopwatch (R2's window after the press).
    public static func shortClock(_ ms: Double) -> String {
        let total = Int(max(0, ms.isFinite ? ms : 0) / 1_000)
        return "\(total / 60):\(pad(total % 60, 2))"
    }

    /// "44 ms", "12.7 s", "1:05".
    public static func duration(_ ms: Double) -> String {
        let v = max(0, ms)
        if v < 1_000 { return "\(Int(v.rounded())) ms" }
        if v < 60_000 { return Fmt.fixed(v / 1_000, 1) + " s" }
        return shortClock(v)
    }

    /// "0.56 s" (two decimals under 10 s, else one).
    public static func seconds(_ ms: Double) -> String {
        Fmt.fixed(ms / 1_000, abs(ms) < 10_000 ? 2 : 1) + " s"
    }

    /// "2175.0 MHz", "873.85 MHz": as the 3GPP raster gives it, no grouping.
    public static func mhz(_ v: Double) -> String {
        let two = Fmt.fixed(v, 2)
        return (two.hasSuffix("0") ? Fmt.fixed(v, 1) : two) + " MHz"
    }

    /// "1.4 km", "780 m".
    public static func distance(_ metres: Double) -> String {
        metres >= 1_000 ? Fmt.fixed(metres / 1_000, 1) + " km" : "\(Int(metres.rounded())) m"
    }

    /// "23,764".
    public static func count(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// The time part of a PHY-derived marker id ("rach-2659.6").
    public static func idTime(_ ms: Double) -> String { Fmt.fixed(ms, 1) }

    /// "B66"; "n5/n26" for NR (every candidate band); "NR" when no band fits.
    public static func band(_ s: CellSegment) -> String {
        if let b = s.band { return b }
        if s.cell.nr { return s.bandCandidates.isEmpty ? "NR" : s.bandCandidates.map { "n\($0)" }.joined(separator: "/") }
        return "LTE"
    }

    /// "B66 67086/80"; "NR 174770/80".
    public static func cell(_ s: CellSegment) -> String {
        (s.cell.nr ? "NR" : band(s)) + " \(s.cell.earfcn)/\(s.cell.pci)"
    }

    /// "B66 PCI 80"; "n5/n26 PCI 80".
    public static func shortCell(_ s: CellSegment) -> String { "\(band(s)) PCI \(s.cell.pci)" }

    /// "EARFCN" or "NR-ARFCN".
    public static func channelName(_ cell: Cell) -> String { cell.nr ? "NR-ARFCN" : "EARFCN" }

    /// What a marker is called on its own ("Handover B66 → B12").
    public static func markerTitle(_ m: Marker, journey: Journey) -> String {
        switch m.kind {
        case .handover, .reselection, .reattach, .redirect, .reestablishment, .cellChange:
            let from = m.from.flatMap { segment(for: $0, before: m.tMs, in: journey) }.map(shortCell)
            let to = m.to.flatMap { segment(for: $0, after: m.tMs, in: journey) }.map(shortCell)
            if let from, let to { return "\(m.title) \(from) → \(to)" }
            return m.title
        default:
            return m.title
        }
    }

    /// The PCell segment of `cell` that ends at or just before `t` (the cell a move left).
    static func segment(for cell: Cell, before t: Double, in journey: Journey) -> CellSegment? {
        journey.cells.filter { $0.lane == .pcell && $0.cell == cell && $0.startMs <= t + 0.5 }.last
            ?? journey.cells.first { $0.cell == cell }
    }

    /// The PCell segment of `cell` that starts at or after `t` - 1 s (the cell a move reached).
    static func segment(for cell: Cell, after t: Double, in journey: Journey) -> CellSegment? {
        journey.cells.first { $0.lane == .pcell && $0.cell == cell && $0.endMs >= t - 0.5 }
            ?? journey.cells.first { $0.cell == cell }
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
