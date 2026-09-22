// What the capture screens ask the journey at the cursor: the serving cells and signal values for the sticky
// header, the next and previous marker, the ladder's move annotation, the segments under a time, and which
// cell a PHY carrier index meant then.

import FTCore
import FTModel
import FTPhy

public enum JourneyQuery {
    /// Staleness limits (ms): LTE serving values from 0xB193 and CSI, NR SS-RSRP, and the MCS median window.
    public static let servingMaxAgeMs = 500.0
    public static let nrRsrpMaxAgeMs = 2_000.0
    public static let mcsWindowMs = 1_000.0

    /// The sticky header's values at `tMs`: serving cells from the journey, signal values from the PHY series.
    /// A value with only older samples than its limit is nil and named in `stale`.
    public static func serving(at tMs: Double, journey: Journey, phy: PhyCapture) -> ServingSnapshot {
        var snap = ServingSnapshot(tMs: tMs)
        snap.state = state(at: tMs, in: journey)
        let here = segments(at: tMs, in: journey)
        snap.pcell = here.last { $0.lane == .pcell }
        snap.pscell = here.last { $0.lane == .pscell }
        snap.scells = here.filter { $0.lane == .scell }.sorted { $0.index < $1.index }

        let pcell = snap.pcell.map(\.cell)
        func latest(_ key: String, _ metric: PhyMetric, maxAge: Double, cell: Cell?) -> Double? {
            guard let s = phy.series[metric] else { return nil }
            switch SampleLookup.latest(s.samples, atOrBefore: tMs, maxAgeMs: maxAge, carrier: 0, cell: cell) {
            case .value(let v): return v
            case .stale: snap.stale.insert(key); return nil
            case .none: return nil
            }
        }
        func median(_ key: String, _ metric: PhyMetric, cell: Cell?) -> Int? {
            guard let s = phy.series[metric] else { return nil }
            switch SampleLookup.median(s.samples, window: (tMs - mcsWindowMs)...tMs, carrier: 0, cell: cell) {
            case .value(let v): return Int(v.rounded(.down))
            case .stale: snap.stale.insert(key); return nil
            case .none: return nil
            }
        }
        snap.rsrp = latest("rsrp", .lte_rsrp_filtered, maxAge: servingMaxAgeMs, cell: pcell)
        snap.rsrq = latest("rsrq", .lte_rsrq_filtered, maxAge: servingMaxAgeMs, cell: pcell)
        snap.rssi = latest("rssi", .lte_rssi, maxAge: servingMaxAgeMs, cell: pcell)
        snap.cqi = latest("cqi", .lte_cqi_wideband_cw0, maxAge: servingMaxAgeMs, cell: pcell).map { Int($0) }
        snap.ri = latest("ri", .lte_ri, maxAge: servingMaxAgeMs, cell: pcell).map { Int($0) }
        snap.dlMcs = median("dlMcs", .lte_dl_mcs, cell: pcell)
        snap.nrRsrp = latest("nrRsrp", .nr_ss_rsrp, maxAge: nrRsrpMaxAgeMs, cell: nil)
        snap.nrMcs = median("nrMcs", .nr_dl_mcs, cell: nil)
        return snap
    }

    /// The first marker after `tMs` (more than half a millisecond later, so repeated taps move on).
    public static func marker(after tMs: Double, in journey: Journey) -> Marker? {
        journey.markers.first { $0.tMs > tMs + 0.5 }
    }

    /// The last marker before `tMs`.
    public static func marker(before tMs: Double, in journey: Journey) -> Marker? {
        journey.markers.last { $0.tMs < tMs - 0.5 }
    }

    /// How many markers lie at or before `tMs`: changes exactly when the cursor crosses one (haptic ticks).
    public static func markersPassed(at tMs: Double, in journey: Journey) -> Int {
        var lo = 0, hi = journey.markers.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if journey.markers[mid].tMs <= tMs { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The journey's reading of a parity Move row ("Reselection, after switch-off detach").
    public static func annotation(forStepEvent event: Int, in journey: Journey) -> String? {
        guard let m = journey.markers.first(where: { isMove($0.kind) && ($0.endEvent == event || ($0.event == event && $0.endEvent == nil)) })
        else { return nil }
        switch m.kind {
        case .handover:
            var s = "Handover" + (m.durationMs.map { " in \(JourneyText.duration($0))" } ?? "")
            if let release = journey.markers.first(where: { $0.kind == .scgRelease && $0.event == m.event }) {
                s += release.inferred ? ", NR leg released (inferred)" : ", NR leg released"
            }
            return s
        case .reattach: return "Reselection, after switch-off detach"
        case .reselection: return "Reselection (idle)"
        default: return m.detail ?? m.title
        }
    }

    /// Every cell segment (any lane) that covers `tMs`.
    public static func segments(at tMs: Double, in journey: Journey) -> [CellSegment] {
        journey.cells.filter { s in
            guard tMs >= s.startMs else { return false }
            // Half-open, so a handover instant belongs to the new cell; the last segment also holds the end.
            return tMs < s.endMs || (tMs == s.endMs && (s.openAtEnd || s.endMs >= journey.durationMs))
        }
    }

    /// The RRC state at `tMs`.
    public static func state(at tMs: Double, in journey: Journey) -> RadioState {
        journey.states.first { tMs >= $0.startMs && tMs < $0.endMs }?.state ?? journey.states.last.flatMap {
            tMs >= $0.endMs ? $0.state : nil
        } ?? .unknown
    }

    /// Carrier attribution (contract amendment): PHY records such as 0xB173, 0xB139, CSF and 0xB064 carry only a
    /// carrier index. Index 0 is the PCell at that moment, index k the SCell of that index.
    public static func cell(carrier: Int, at tMs: Double, in journey: Journey) -> CellSegment? {
        let here = segments(at: tMs, in: journey)
        return carrier == 0 ? here.last { $0.lane == .pcell } : here.first { $0.lane == .scell && $0.index == carrier }
    }

    static func isMove(_ k: MarkerKind) -> Bool {
        [.handover, .reselection, .reattach, .redirect, .reestablishment, .cellChange].contains(k)
    }
}

/// Newest-sample and median lookups over time-ordered PHY samples. FTJourney keeps its own (binary search, then
/// a short walk back) so the header's staleness rules do not depend on how PhyQuery evolves.
enum SampleLookup {
    enum Result: Equatable {
        case value(Double)
        /// Samples exist, but only older than the limit.
        case stale
        case none
    }

    /// Index of the last sample with tMs <= t, assuming samples are in time order.
    static func lastIndex(_ samples: [PhySample], atOrBefore t: Double) -> Int? {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].tMs <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// A sample belongs to the serving cell when it is on carrier 0 and, where it names its cell, names this one.
    static func matches(_ s: PhySample, carrier: Int?, cell: Cell?) -> Bool {
        if let carrier, s.carrier != carrier { return false }
        if let cell {
            if let e = s.earfcn, e != cell.earfcn { return false }
            if let p = s.pci, p != cell.pci { return false }
        }
        return s.value != nil
    }

    static func latest(_ samples: [PhySample], atOrBefore t: Double, maxAgeMs: Double, carrier: Int?, cell: Cell?) -> Result {
        guard var i = lastIndex(samples, atOrBefore: t) else { return .none }
        while i >= 0 {
            let s = samples[i]
            if matches(s, carrier: carrier, cell: cell), let v = s.value {
                return t - s.tMs <= maxAgeMs ? .value(v) : .stale
            }
            i -= 1
        }
        return .none
    }

    /// The median of the matching samples in `window` (lower middle for an even count, as an index is).
    static func median(_ samples: [PhySample], window: ClosedRange<Double>, carrier: Int?, cell: Cell?) -> Result {
        guard var i = lastIndex(samples, atOrBefore: window.upperBound) else { return .none }
        var values: [Double] = []
        var older = false
        while i >= 0 {
            let s = samples[i]
            if s.tMs < window.lowerBound {
                if matches(s, carrier: carrier, cell: cell) { older = true; break }
            } else if matches(s, carrier: carrier, cell: cell), let v = s.value {
                values.append(v)
            }
            i -= 1
        }
        guard !values.isEmpty else { return older ? .stale : .none }
        values.sort()
        return .value(values[(values.count - 1) / 2])
    }
}
