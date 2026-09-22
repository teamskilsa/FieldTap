import SwiftUI
import Charts
import FTApp
import FTModel
import FTPhy

/// Which resource blocks the scheduler gave this phone, not just how many. 0xB126 carries a bit per PRB for each
/// of the last twenty subframes, so the strip below is the allocation itself: time across, PRB up, one mark per
/// allocated resource block. A scheduler that keeps this phone in one corner of the band, or a cell that only ever
/// hands out a narrow slice, is visible here and nowhere else in the app.
///
/// The bitmap is validated by counting it: popcount equals an N_RB that 0xB173 independently reports for the same
/// subframe, which is the self-check beside the title.
struct PrbAllocationStrip: View {
    @Bindable var session: CaptureSession
    /// At most this many (subframe, PRB) marks: one screen of marks, decimated by subframe, never by PRB.
    static let maxMarks = 4_000

    private var phy: PhyCapture { session.analysis.phy }

    struct Mark: Identifiable, Hashable {
        var id: Int
        var tMs: Double
        var prb: Int
    }

    var body: some View {
        let window = session.visibleWindow
        let samples = RadioData.series(phy, .lte_dl_prb_allocation)
        let marks = Self.marks(samples, window: window)
        let top = Double(Self.bandwidthPrb(phy, samples: samples))
        return VStack(alignment: .leading, spacing: 4) {
            PhyChart(title: "PRB allocation per subframe", unit: "PRB",
                     badges: RadioData.checkBadge(phy, "b126PrbBitmap", passed: "count matches 0xB173").map { [$0] } ?? [],
                     empty: samples.isEmpty ? RadioData.emptyReason(phy, .lte_dl_prb_allocation) : nil,
                     yDomain: 0...top, height: 150, session: session) {
                ForEach(marks) { m in
                    RectangleMark(x: .value("t", m.tMs), y: .value("PRB", m.prb), width: .fixed(2), height: .fixed(2))
                        .foregroundStyle(RadioStyle.lines[0].opacity(0.75))
                }
            }
            Text(caption(samples, window: window, marks: marks.count))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("prbAllocationStrip")
        .accessibilityLabel("PRB allocation per subframe, \(marks.count) allocated resource blocks in the visible window")
    }

    private func caption(_ samples: [PhySample], window: ClosedRange<Double>, marks: Int) -> String {
        let inWindow = PhyQuery.slice(samples, window)
        guard !inWindow.isEmpty else {
            return "One bit per resource block, twenty subframes per record (0xB126 v163)."
        }
        let counts = inWindow.compactMap(\.value)
        let mean = counts.isEmpty ? 0 : counts.reduce(0, +) / Double(counts.count)
        let widest = counts.max() ?? 0
        return "\(RadioFormat.count(inWindow.count)) subframes in the visible window, \(RadioFormat.value(mean, 1)) PRB "
            + "on average and \(RadioFormat.int(widest)) at the widest. One bit per resource block (0xB126 v163), "
            + "twenty subframes per record."
    }

    /// One mark per allocated PRB, decimated by subframe so a wide window stays inside `maxMarks`.
    static func marks(_ samples: [PhySample], window: ClosedRange<Double>) -> [Mark] {
        let inWindow = Array(PhyQuery.slice(samples, window))
        guard !inWindow.isEmpty else { return [] }
        let perSubframe = max(1, Int(inWindow.compactMap(\.value).max() ?? 1))
        let stride = max(1, inWindow.count * perSubframe / maxMarks)
        var out: [Mark] = []
        for (i, s) in inWindow.enumerated() where i % stride == 0 {
            guard let mask = s.prbMask else { continue }
            for prb in 0..<64 where mask >> UInt64(prb) & 1 == 1 {
                out.append(Mark(id: out.count, tMs: s.tMs, prb: prb))
            }
        }
        return out
    }

    /// The top of the PRB axis: the cell's bandwidth when the MIB gave one, else the widest allocation seen.
    static func bandwidthPrb(_ phy: PhyCapture, samples: [PhySample]) -> Int {
        let fromMib = RadioData.series(phy, .lte_dl_bandwidth_prb).compactMap(\.value).max().map { Int($0) }
        let widest = samples.compactMap(\.value).max().map { Int($0) } ?? 50
        return max(fromMib ?? 50, widest, 6)
    }
}
