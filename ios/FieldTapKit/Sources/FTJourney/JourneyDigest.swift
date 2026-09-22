// What a capture card shows without opening the capture: the PCell lane for the mini strip and a one-line
// digest ("B2 → B66 → B12 → B2, NR, 0 failures"). The importer (WP3) stores both in the CaptureSummary.

import FTModel

public enum JourneyDigest {
    /// Both, for a capture card; nil while the journey has no serving cell (nothing to draw yet).
    public static func of(_ journey: Journey) -> (digest: String, preview: JourneyPreview)? {
        guard journey.cells.contains(where: { $0.lane == .pcell }) else { return nil }
        return (text(of: journey), preview(of: journey))
    }

    public static func preview(of journey: Journey) -> JourneyPreview {
        JourneyPreview(segments: journey.cells.filter { $0.lane == .pcell }.map {
                           PreviewSegment(band: JourneyText.band($0), startMs: $0.startMs, endMs: $0.endMs)
                       },
                       nr: journey.cells.contains { $0.lane == .pscell || $0.cell.nr },
                       failures: failures(journey))
    }

    /// Failures as "What happened" tells them: a rejected registration is one failure, though J11 marks both
    /// the failed procedure and the reject.
    public static func failures(_ journey: Journey) -> Int { journey.findings.filter { $0.kind == .failure }.count }

    /// "B2 → B66 → B12 → B2, NR, 0 failures". Repeats of one band in a row (a radio off and back) read once.
    public static func text(of journey: Journey) -> String {
        var bands: [String] = []
        for s in journey.cells where s.lane == .pcell {
            let b = JourneyText.band(s)
            if bands.last != b { bands.append(b) }
        }
        var parts = [bands.isEmpty ? "No serving cell" : bands.joined(separator: " → ")]
        if journey.cells.contains(where: { $0.lane == .pscell }) { parts.append("NR") }
        if journey.cells.contains(where: { $0.lane == .scell }) { parts.append("CA") }
        let n = failures(journey)
        parts.append("\(n) failure\(n == 1 ? "" : "s")")
        return parts.joined(separator: ", ")
    }
}
