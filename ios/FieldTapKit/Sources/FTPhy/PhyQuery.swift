// Reading a series at the cursor, in bins, as a time share, and decimated for a chart. Samples are in time order
// (PhyExtractor guarantees it), so lookups are binary searches.

import FTModel

/// How `PhyQuery.bins` reduces the samples in one bin.
public enum BinReduce: String, CaseIterable, Hashable, Sendable {
    case mean, median, sum, count
}

/// One reduced bin: its centre and value.
public struct PhyBin: Hashable, Sendable {
    public var tMs: Double
    public var value: Double

    public init(tMs: Double, value: Double) {
        self.tMs = tMs
        self.value = value
    }
}

public enum PhyQuery {
    /// The newest sample at or before `tMs` that is at most `maxAgeMs` old, optionally on one carrier index.
    public static func latest(_ s: PhySeries, atOrBefore tMs: Double, maxAgeMs: Double, carrier: Int? = nil) -> PhySample? {
        latest(s.samples, atOrBefore: tMs, maxAgeMs: maxAgeMs) { carrier == nil || $0.carrier == carrier }
    }

    /// `latest` with any condition on the sample (a serving-cell tag, a PCI).
    public static func latest(_ samples: [PhySample], atOrBefore tMs: Double, maxAgeMs: Double,
                              where accept: (PhySample) -> Bool = { _ in true }) -> PhySample? {
        var i = upperBound(samples, tMs) - 1
        while i >= 0, samples[i].tMs >= tMs - maxAgeMs {
            if accept(samples[i]) { return samples[i] }
            i -= 1
        }
        return nil
    }

    /// Samples with `lo <= tMs <= hi`, by binary search.
    public static func slice(_ samples: [PhySample], _ window: ClosedRange<Double>) -> ArraySlice<PhySample> {
        samples[lowerBound(samples, window.lowerBound)..<upperBound(samples, window.upperBound)]
    }

    public static func bins(_ s: PhySeries, widthMs: Double, reduce: BinReduce) -> [PhyBin] {
        guard widthMs > 0 else { return [] }
        var groups: [(key: Int, values: [Double], n: Int)] = []
        for sample in s.samples {
            let key = Int((sample.tMs / widthMs).rounded(.down))
            if groups.last?.key != key { groups.append((key, [], 0)) }
            groups[groups.count - 1].n += 1
            if let v = sample.value, v.isFinite { groups[groups.count - 1].values.append(v) }
        }
        return groups.compactMap { g in
            let t = (Double(g.key) + 0.5) * widthMs
            switch reduce {
            case .count: return PhyBin(tMs: t, value: Double(g.n))
            case .sum: return PhyBin(tMs: t, value: g.values.reduce(0, +))
            case .mean: return g.values.isEmpty ? nil : PhyBin(tMs: t, value: g.values.reduce(0, +) / Double(g.values.count))
            case .median: return g.values.isEmpty ? nil : PhyBin(tMs: t, value: median(g.values))
            }
        }
    }

    /// Share of samples per value in the window (e.g. layers 1/2), summing to 1.
    public static func timeShare(_ s: PhySeries, window: ClosedRange<Double>) -> [Int: Double] {
        var counts: [Int: Int] = [:]
        var total = 0
        for sample in slice(s.samples, window) {
            guard let v = sample.value, v.isFinite else { continue }
            counts[Int(v.rounded()), default: 0] += 1
            total += 1
        }
        guard total > 0 else { return [:] }
        return counts.mapValues { Double($0) / Double(total) }
    }

    /// Min/max buckets so a chart never draws more than `maxPoints` points: each bucket keeps its first, lowest and
    /// highest sample (by `value`, or the first per-index value), in time order.
    public static func decimate(_ samples: [PhySample], window: ClosedRange<Double>, maxPoints: Int = 1500) -> [PhySample] {
        let inWindow = slice(samples, window)
        guard inWindow.count > maxPoints, maxPoints >= 3 else { return Array(inWindow) }
        let buckets = maxPoints / 3
        let span = max(window.upperBound - window.lowerBound, 1)
        var out: [PhySample] = []
        out.reserveCapacity(buckets * 3)
        var current = -1
        var picked: [PhySample] = []
        func flush() {
            let unique = picked.enumerated().filter { e in !picked[..<e.offset].contains(e.element) }.map(\.element)
            out.append(contentsOf: unique.sorted { $0.tMs < $1.tMs })
            picked.removeAll(keepingCapacity: true)
        }
        var first: PhySample?, low: PhySample?, high: PhySample?
        for s in inWindow {
            let b = min(buckets - 1, Int((s.tMs - window.lowerBound) / span * Double(buckets)))
            if b != current {
                if let first { picked = [first, low ?? first, high ?? first]; flush() }
                current = b
                first = s; low = nil; high = nil
            }
            if let v = level(s) {
                if low.flatMap(level).map({ v < $0 }) ?? true { low = s }
                if high.flatMap(level).map({ v > $0 }) ?? true { high = s }
            }
        }
        if let first { picked = [first, low ?? first, high ?? first]; flush() }
        return out
    }

    static func level(_ s: PhySample) -> Double? { s.value ?? s.perIndex?.compactMap { $0 }.first }

    /// The first index whose tMs >= t.
    static func lowerBound(_ samples: [PhySample], _ t: Double) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].tMs < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The first index whose tMs > t.
    static func upperBound(_ samples: [PhySample], _ t: Double) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].tMs <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
