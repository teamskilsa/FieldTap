// The absolute-TTI axis. Two things in FTPhy need it and neither can be done without it.
//
// 1. 0xB179 carries no DIAG timestamp at all (every record arrives stamped 0). Its own TTI (SFN x 10 + subframe)
//    says where it sits inside the 10.24 s frame cycle, and the cycle it belongs to comes from the records around
//    it in the file. That is enough to place it to about four subframes, which is what the research measured
//    (circular R = 1.00000 / 0.99999, spread 3.8 / 5.2 ms) — the record places itself in time.
// 2. The 10.24 s cycle aliases about 2.2 times in a 22 s capture, so a cross-code check keyed on the raw TTI
//    matches subframes that are seconds apart. Unwrapping the TTI into an absolute index first is what makes the
//    0xB126 / 0xB063 / 0xB16C checks against 0xB173 and 0xB139 mean anything.
//
// The axis is the constant offset between a record's timestamp and the frame it names (logging latency plus the
// capture's own frame phase). It is measured as a circular mean, so it needs no assumption about the latency, and
// its concentration R is reported with the checks that use it.

import Foundation

/// The capture's frame phase: `(timestamp - TTI) mod 10.24 s`, as a circular mean over every record that carries
/// both.
struct PhyTtiAxis: Sendable {
    /// One SFN cycle: 1,024 frames of 10 ms.
    static let cycleMs = 10_240.0

    private var sinSum = 0.0
    private var cosSum = 0.0
    private(set) var count = 0

    /// One record that carries a timestamp and its own TTI in ms.
    mutating func add(tMs: Double, tti: Int) {
        let residual = Self.wrap(tMs - Double(tti))
        let angle = residual / Self.cycleMs * 2 * .pi
        sinSum += sin(angle)
        cosSum += cos(angle)
        count += 1
    }

    var isEmpty: Bool { count == 0 }

    /// Circular concentration: 1 when every residual is the same, 0.5-0.8 for a field that is not a frame number.
    var concentration: Double {
        count == 0 ? 0 : (sinSum * sinSum + cosSum * cosSum).squareRoot() / Double(count)
    }

    /// The mean residual, in ms, in 0 ..< 10,240.
    var phaseMs: Double {
        guard count > 0 else { return 0 }
        return Self.wrap(atan2(sinSum, cosSum) / (2 * .pi) * Self.cycleMs)
    }

    /// The time of a record that names `tti`, taking the cycle from `anchorMs` (its neighbours' timestamps).
    func timeMs(tti: Int, near anchorMs: Double) -> Double {
        let target = Double(tti) + phaseMs
        return target + Self.cycleMs * ((anchorMs - target) / Self.cycleMs).rounded()
    }

    /// The unwrapped TTI of a record stamped `tMs` that names `tti`: a subframe index that does not alias, so two
    /// codes can be compared subframe by subframe across a whole capture.
    func absoluteTti(tti: Int, tMs: Double) -> Int {
        Int((timeMs(tti: tti, near: tMs) - phaseMs).rounded())
    }

    static func wrap(_ ms: Double) -> Double {
        let r = ms.truncatingRemainder(dividingBy: cycleMs)
        return r < 0 ? r + cycleMs : r
    }
}
