// Carrier attribution from the records alone. 0xB173, 0xB139, the CSF records and 0xB064 carry only a carrier
// index; 0xB193 serving records carry the index together with the EARFCN and PCI, so the cell a carrier index
// was on at time t is the one its latest 0xB193 serving record names. The Radio page prefers FTJourney's cell
// segments for which carriers are active and falls back to this.

import FTModel

/// The cell one carrier index was on.
public struct CarrierCell: Hashable, Sendable {
    /// 0 = PCell, 1-3 = SCell index.
    public var index: Int
    public var earfcn: Int64
    public var pci: Int
    /// The 0xB193 record the attribution comes from.
    public var seenMs: Double

    public init(index: Int, earfcn: Int64, pci: Int, seenMs: Double) {
        self.index = index
        self.earfcn = earfcn
        self.pci = pci
        self.seenMs = seenMs
    }
}

public enum PhyCarriers {
    /// 0xB193 reports each serving cell about every 40 ms while connected; older than this, the carrier is idle
    /// (the same staleness limit the section headers use for 0xB193 values).
    public static let maxAgeMs = 500.0

    /// The cell carrier `index` was on at `tMs`, from its latest 0xB193 serving record at most `maxAgeMs` old.
    public static func cell(carrier index: Int, at tMs: Double, in capture: PhyCapture,
                            maxAgeMs: Double = maxAgeMs) -> CarrierCell? {
        guard let s = capture.series[.lte_rsrp],
              let sample = PhyQuery.latest(s, atOrBefore: tMs, maxAgeMs: maxAgeMs, carrier: index),
              let earfcn = sample.earfcn, let pci = sample.pci else { return nil }
        return CarrierCell(index: index, earfcn: earfcn, pci: pci, seenMs: sample.tMs)
    }

    /// Every carrier index active at `tMs` (PCell first), from the records.
    public static func cells(at tMs: Double, in capture: PhyCapture, maxAgeMs: Double = maxAgeMs) -> [CarrierCell] {
        (0...7).compactMap { cell(carrier: $0, at: tMs, in: capture, maxAgeMs: maxAgeMs) }
    }

    /// The NR carrier at `tMs` while the NR DL records are active: ARFCN from the latest 0xB97F serving
    /// measurement, PCI from the latest 0xB887 slot. Nil outside the NR DL window.
    public static func nrCell(at tMs: Double, in capture: PhyCapture, marginMs: Double = 500) -> (arfcn: Int64?, pci: Int?)? {
        guard let nr = capture.summary.nrDlActivity, tMs >= nr.firstMs - marginMs, tMs <= nr.lastMs + marginMs else { return nil }
        let measured = capture.series[.nr_ss_rsrp].flatMap {
            PhyQuery.latest($0.samples, atOrBefore: tMs, maxAgeMs: .infinity) { $0.tag == CellRole.serving }
        }
        let slot = capture.series[.nr_dl_mcs].flatMap {
            PhyQuery.latest($0, atOrBefore: max(tMs, nr.firstMs), maxAgeMs: .infinity)
        }
        return (measured?.earfcn ?? nr.earfcn, slot?.pci ?? nr.pci)
    }
}
