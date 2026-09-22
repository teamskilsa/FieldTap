import Foundation
import FTApp
import FTJourney
import FTModel
import FTPhy

/// One chart point: time, value, the series it belongs to and the line segment (a new segment starts after a
/// gap, so a line never bridges radio off or a carrier that was idle).
struct TimePoint: Identifiable, Hashable {
    var id: Int
    var t: Double
    var y: Double
    var series: String
    var segment: Int
    /// A category drawn by colour or shape (modulation, PCI, source record).
    var group: String = ""
    var hollow = false
}

/// Chart data and cursor values from the capture's PHY series. Pure functions of the capture and the window, so
/// the sections recompute them only when the window or a toggle changes, never when the cursor moves.
enum RadioData {
    static let maxPoints = 1500

    static func series(_ phy: PhyCapture, _ m: PhyMetric) -> [PhySample] { phy.series[m]?.samples ?? [] }

    /// Decimated points of `samples` in `window`, split into segments at gaps longer than `gapMs` and where the
    /// cell changes (a handover keeps the carrier index but is not a continuous line).
    static func points(_ samples: [PhySample], window: ClosedRange<Double>, series: String, gapMs: Double = 500,
                       maxPoints: Int = maxPoints, group: (PhySample) -> String = { _ in "" },
                       value: (PhySample) -> Double? = { $0.value }) -> [TimePoint] {
        var out: [TimePoint] = []
        var segment = 0
        var last: PhySample?
        for s in PhyQuery.decimate(samples, window: window, maxPoints: maxPoints) {
            guard let y = value(s), y.isFinite else { continue }
            if let last, s.tMs - last.tMs > gapMs || last.earfcn != s.earfcn || last.pci != s.pci { segment += 1 }
            last = s
            out.append(TimePoint(id: out.count, t: s.tMs, y: y, series: series, segment: segment, group: group(s)))
        }
        return out
    }

    /// Serving-cell samples of one carrier (0xB193 series carry neighbours too).
    static func serving(_ samples: [PhySample], carrier: Int) -> [PhySample] {
        samples.filter { $0.carrier == carrier && $0.tag != CellRole.neighbour }
    }

    /// Renumbers ids after several point arrays were concatenated.
    static func joined(_ parts: [[TimePoint]]) -> [TimePoint] {
        var out: [TimePoint] = []
        for part in parts { for var p in part { p.id = out.count; out.append(p) } }
        return out
    }

    // MARK: cursor values

    /// The newest value of `m` on `carrier` at or before `t`, at most `maxAge` old.
    static func latest(_ phy: PhyCapture, _ m: PhyMetric, at t: Double, maxAge: Double = 500, carrier: Int? = 0,
                       servingOnly: Bool = true) -> PhySample? {
        PhyQuery.latest(series(phy, m), atOrBefore: t, maxAgeMs: maxAge) {
            (carrier == nil || $0.carrier == carrier) && (!servingOnly || $0.tag != CellRole.neighbour)
        }
    }

    /// The 1 s bin (second + 0.5 s) that holds `t`.
    static func bin(_ phy: PhyCapture, _ m: PhyMetric, at t: Double, carrier: Int?) -> Double? {
        let hits = PhyQuery.slice(series(phy, m), (t - 500)...(t + 500)).filter {
            (carrier == nil || $0.carrier == carrier) && $0.tMs - 500 <= t && t < $0.tMs + 500
        }
        guard !hits.isEmpty else { return nil }
        return hits.compactMap(\.value).reduce(0, +)
    }

    /// Median of `m` on `carrier` over the second before `t` ("DL MCS, median of the last 1 s").
    static func median1s(_ phy: PhyCapture, _ m: PhyMetric, at t: Double, carrier: Int?) -> Double? {
        let v = PhyQuery.slice(series(phy, m), (t - 1000)...t).filter { carrier == nil || $0.carrier == carrier }
            .compactMap(\.value).sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    /// "2", "TxD" (4 layers with one transport block is transmit diversity), "3 (unverified)".
    static func layersLabel(_ s: PhySample?) -> String {
        guard let s, let v = s.value else { return "–" }
        return layersCategory(layers: Int(v), transportBlocks: s.tag ?? 0)
    }

    static func layersCategory(layers: Int, transportBlocks: Int) -> String {
        if layers == 4 && transportBlocks == 1 { return "TxD" }
        if layers == 3 { return "3 (unverified)" }
        return String(layers)
    }

    // MARK: carriers

    struct ActiveCarriers {
        var lte: [CarrierCell]
        var nr: (arfcn: Int64?, pci: Int?)?
        /// "journey" when FTJourney's segments said which carriers are active, else "records".
        var source: String
    }

    /// Which carriers are active at `t`: FTJourney's cell segments when it has them, else the 0xB193 records.
    @MainActor static func active(at t: Double, session: CaptureSession) -> ActiveCarriers {
        let a = session.analysis
        let snap = JourneyQuery.serving(at: t, journey: a.journey, phy: a.phy)
        if let pcell = snap.pcell {
            var lte = [CarrierCell(index: 0, earfcn: pcell.cell.earfcn, pci: pcell.cell.pci, seenMs: t)]
            lte += snap.scells.sorted { $0.index < $1.index }
                .map { CarrierCell(index: $0.index, earfcn: $0.cell.earfcn, pci: $0.cell.pci, seenMs: t) }
            let nr = snap.pscell.map { (arfcn: Optional($0.cell.earfcn), pci: $0.cell.isPendingNr ? nil : Optional($0.cell.pci)) }
            return ActiveCarriers(lte: lte, nr: nr ?? PhyCarriers.nrCell(at: t, in: a.phy), source: "journey")
        }
        return ActiveCarriers(lte: PhyCarriers.cells(at: t, in: a.phy), nr: PhyCarriers.nrCell(at: t, in: a.phy),
                              source: "records")
    }

    /// Why a series is empty: the catalogue's reason when one applies, else that the capture has no such records.
    static func emptyReason(_ phy: PhyCapture, _ m: PhyMetric) -> String {
        if m == .lte_ul_mcs_derived, let e = phy.availability.first(where: { $0.id == "lteTbsTable" }) { return e.reason }
        let info = m.info
        let miss = phy.versionMisses.filter { $0.key.hasPrefix(RadioFormat.hex(info.code)) }
        if let k = miss.keys.sorted().first {
            return "\(RadioFormat.count(miss[k]!)) records of \(k) are a version this app has not validated, so they are not decoded."
        }
        return "No \(RadioFormat.hex(info.code)) records in this capture."
    }

    /// A warning when the decoder behind a section fails its self-check.
    static func warning(_ phy: PhyCapture, checks ids: [String]) -> String? {
        let failed = phy.checks.filter { ids.contains($0.id) && !$0.passed }
        guard !failed.isEmpty else { return nil }
        return "Self-check failed (\(failed.map(\.id).joined(separator: ", "))): these values may be wrong. See Not available."
    }

    /// The badge that says whether a decoder's self-check held.
    static func checkBadge(_ phy: PhyCapture, _ id: String, passed text: String) -> RadioBadge? {
        guard let c = phy.checks.first(where: { $0.id == id }) else { return nil }
        return c.passed ? RadioBadge(text: text) : RadioBadge(text: "check failed", kind: .warning)
    }
}
