// Turns what the decoders collected into the capture: the per-second bins, the NR BLER/throughput from the
// cumulative 0xB888 counters, the summary for FTJourney, the self-checks and the availability entries.

import Foundation
import FTModel

extension Extraction {
    mutating func finish(secure: EncryptedCensus) -> PhyRun {
        addBins()
        addNrCounterDeltas()
        inferRsrqIdentity()
        summariseB179Deltas()
        crossCheckAdded()

        var series: [PhyMetric: PhySeries] = [:]
        for m in PhyMetric.allCases {
            var s = m.emptySeries
            s.samples = samples[m] ?? []
            // The added decoders place their samples inside the record they came from (a sub-record is a subframe,
            // not the moment the record was written), and consecutive records overlap, so their samples need one
            // time order before PhyQuery's binary searches can use them.
            if m == .lte_cqi_wideband_cw0 || m == .lte_ri || m == .lte_pmi_wideband
                || PhyMetric.addedAfterReference.contains(m) {
                s.samples = s.samples.enumerated()
                    .sorted { ($0.element.tMs, $0.offset) < ($1.element.tMs, $1.offset) }.map(\.element)
            }
            series[m] = s
        }

        let summary = PhySummary(
            scellActivity: scells.keys.sorted().map { k in
                let v = scells[k]!
                return CarrierActivity(index: k.index, earfcn: k.earfcn, pci: k.pci, firstMs: v.first, lastMs: v.last,
                                       records: v.n, source: "0xB193 serving records with SCell index")
            },
            nrDlActivity: nrTimes.isEmpty ? nil
                : CarrierActivity(index: 0, earfcn: nil, pci: nrPcis.count == 1 ? nrPcis.first : nil,
                                  firstMs: nrTimes.min()!, lastMs: nrTimes.max()!, records: nrTimes.count,
                                  source: "0xB887"),
            rach: rach,
            txAntennasMib: txAntennas.sorted(),
            rxAntennasByEarfcn: Dictionary(uniqueKeysWithValues: rxByEarfcn.map { e, counts in
                (String(e), Dictionary(uniqueKeysWithValues: counts.map { (String($0.key), $0.value) }))
            }),
            encrypted: secure,
            antennas: measuredAntennas(),
            macDl: macDlAccounting(),
            traceGaps: stats.d1d0b.records > 0 ? traceGaps.sorted { $0.tMs < $1.tMs } : nil)

        let capture = PhyCapture(series: series, summary: summary,
                                 checks: PhyChecks.checks(stats, tbsAvailable: tbs.isAvailable) + PhyChecks.added(stats),
                                 versionMisses: versionMisses,
                                 availability: PhyCatalog.availability(recordsPerCode: recordsPerCode, secure: secure,
                                                                       tbsAvailable: tbs.isAvailable))
        return PhyRun(capture: capture, stats: stats)
    }

    /// DL BLER and PHY throughput (CRC-pass TBS) and UL scheduled TBS, per (second, carrier).
    mutating func addBins() {
        for key in dlBins.keys.sorted() {
            let b = dlBins[key]!
            let t = binCentre(key.second)
            add(.lte_dl_bler, t, 100 * Double(b.fail) / Double(b.n), carrier: key.carrier, tag: b.n)
            add(.lte_dl_phy_throughput, t, Double(b.bits) / 1e6, carrier: key.carrier)
        }
        for key in ulBins.keys.sorted() {
            add(.lte_ul_phy_throughput, binCentre(key.second), Double(ulBins[key]!) / 1e6, carrier: key.carrier)
        }
    }

    /// NR BLER and MAC throughput between 0xB888 records at least 50 ms apart whose decode counter grew, and the
    /// cross-check of the 0xB887 sums against the counter deltas over the 0xB887 window.
    mutating func addNrCounterDeltas() {
        var prev: (tMs: Double, c: B888.Counters)?
        for (t, c) in nrCounters {
            if let p = prev, c.decodes > p.c.decodes {
                let dt = t - p.tMs
                if dt > 50 {
                    let n = Double(c.decodes - p.c.decodes)
                    let fails = Double(Int64(bitPattern: c.crcFail &- p.c.crcFail))
                    add(.nr_dl_bler, t, 100 * fails / n, carrier: c.carrier, tag: Int(n))
                    let bytes = Double(Int64(bitPattern: c.passBytes &- p.c.passBytes))
                    add(.nr_dl_mac_throughput, t, bytes * 8 / (dt / 1000) / 1e6, carrier: c.carrier)
                    prev = (t, c)
                }
            } else if prev == nil || c.decodes < prev!.c.decodes {
                prev = (t, c)
            }
        }
        guard let first = nrTimes.min(), let last = nrTimes.max(), !nrCounters.isEmpty else { return }
        guard let a = nrCounters.last(where: { $0.tMs < first - 1 })?.c else { return }
        let z = (nrCounters.first { $0.tMs >= last } ?? nrCounters.last!).c
        stats.nr.deltaDecodes = Int(z.decodes) - Int(a.decodes)
        stats.nr.deltaCrcFail = Int(z.crcFail) - Int(a.crcFail)
        stats.nr.deltaPassBytes = Int(z.passBytes) - Int(a.passBytes)
    }

    /// RSRQ = RSRP - RSSI + 10log10(N_RB) per Rx antenna, with N_RB inferred per EARFCN by snapping the median of
    /// RSRQ - RSRP + RSSI to the nearest 10log10 of an LTE bandwidth (no cell table).
    mutating func inferRsrqIdentity() {
        var byEarfcn: [Int64: [Double]] = [:]
        for x in rsrqTerms { byEarfcn[x.earfcn, default: []].append(x.rsrq - x.rsrp + x.rssi) }
        stats.inferredPrb = byEarfcn.mapValues { PhyBandwidth.snap(median($0)) }
        var residuals: [Int: [Double]] = [:]
        for x in rsrqTerms {
            let prb = Double(stats.inferredPrb[x.earfcn] ?? 50)
            let r = x.rsrq - (x.rsrp - x.rssi + 10 * log10(prb))
            residuals[x.rx, default: []].append(r)
            stats.rsrqResiduals += 1
            if abs(r) <= 0.25 { stats.rsrqWithinQuarterDb += 1 }
        }
        stats.rsrqResidual = residuals.mapValues { v in
            let mean = v.reduce(0, +) / Double(v.count)
            let sd = (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)).squareRoot()
            return (mean, sd, v.count)
        }
    }
}

extension Extraction {
    /// 0xB126's measured antenna configuration, or nil when the capture has no 0xB126 record.
    func measuredAntennas() -> MeasuredAntennas? {
        guard stats.b126.subRecords > 0 else { return nil }
        let byCell = Dictionary(uniqueKeysWithValues: txPortsByCell.map { cell, counts in
            (cell, Dictionary(uniqueKeysWithValues: counts.map { (String($0.key), $0.value) }))
        })
        return MeasuredAntennas(txPortsByCell: byCell,
                                rxAntennas: Dictionary(uniqueKeysWithValues: rxAntennaCounts.map { (String($0.key), $0.value) }),
                                rank: Dictionary(uniqueKeysWithValues: rankCounts.map { (String($0.key), $0.value) }),
                                subRecords: stats.b126.subRecords,
                                source: "0xB126 v163 PDSCH demapper configuration, 20 subframes per record")
    }

    /// 0xB063's MAC downlink accounting with its coverage, or nil when the capture has no 0xB063 record.
    func macDlAccounting() -> MacDlAccounting? {
        let b = stats.b063
        guard b.records > 0 else { return nil }
        return MacDlAccounting(records: b.records, declaredBlocks: b.declared, foundBlocks: b.found,
                               exactWalks: b.exactWalks, macBytes: b.macBytes, paddingBytes: b.paddingBytes,
                               signallingBytes: b.signallingBytes, dataBytes: b.dataBytes,
                               controlElements: Dictionary(uniqueKeysWithValues: b.controlElements.map { (String($0.key), $0.value) }),
                               source: "0xB063 v50 MAC DL transport block")
    }

    /// The mean and spread of 0xB179's serving values against 0xB193's, which is what fixes its scales.
    mutating func summariseB179Deltas() {
        guard !b179RsrpDeltas.isEmpty else { return }
        let mean = b179RsrpDeltas.reduce(0, +) / Double(b179RsrpDeltas.count)
        let variance = b179RsrpDeltas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(b179RsrpDeltas.count)
        stats.b179.rsrpMeanDb = mean
        stats.b179.rsrpSdDb = variance.squareRoot()
        if !b179RsrqDeltas.isEmpty {
            stats.b179.rsrqMeanDb = b179RsrqDeltas.reduce(0, +) / Double(b179RsrqDeltas.count)
        }
    }
}

func median(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
