// FTPhy against the reference extractor on the real capture: the 48 KPIs of phy-golden-v1.json, the summary
// FTJourney reads, and the self-check numbers of the reference's validation.

import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTPhy

@Suite(.serialized) struct ParityTests {
    static let traits: [String] = [RealCapture.qmdl, RealCapture.golden, RealCapture.summary, RealCapture.tbsReference]

    func loaded() -> RealCapture.Loaded? {
        for f in Self.traits where Fixtures.require(f) == nil { return nil }
        guard let l = RealCapture.loaded else { Issue.record("the capture did not load"); return nil }
        return l
    }

    @Test(.fixture(RealCapture.qmdl), .fixture(RealCapture.golden))
    func phyGoldenParity() throws {
        guard let l = loaded(), let golden = RealCapture.json(RealCapture.golden),
              let kpis = golden["kpis"] as? [String: [String: Any]] else { return }
        #expect(kpis.count == 48)
        #expect(Set(kpis.keys) == Set(PhyMetric.allCases.map(\.rawValue)))
        for metric in PhyMetric.allCases {
            guard let g = kpis[metric.rawValue], let series = l.run.capture.series[metric] else {
                Issue.record("\(metric.rawValue) missing"); continue
            }
            let name = metric.rawValue
            #expect(series.unit == g["unit"] as? String, "\(name) unit")
            #expect(String(format: "0x%04X", series.code) == g["code"] as? String, "\(name) code")
            #expect(series.samples.count == g["samples"] as? Int, "\(name) sample count")
            if let perIndex = g["perIndex"] as? [[String: Any]] {
                for (i, want) in perIndex.enumerated() {
                    let v = series.samples.compactMap { $0.perIndex.flatMap { i < $0.count ? $0[i] : nil } }
                    Stats.expect(v, want, "\(name)[\(i)]")
                }
            } else {
                Stats.expect(series.samples.compactMap(\.value), g, name)
            }
            // The reference appends 0xB14D's CSI samples after 0xB14E's; FTPhy keeps one time order.
            var ordered = series.samples
            if [.lte_cqi_wideband_cw0, .lte_ri, .lte_pmi_wideband].contains(metric) {
                ordered = ordered.filter { $0.tag == CsfSource.pusch } + ordered.filter { $0.tag == CsfSource.pucch }
            }
            Stats.expectEnds(Array(ordered.prefix(3)), g["first"] as? [[String: Any]] ?? [], "\(name) first")
            Stats.expectEnds(Array(ordered.suffix(3)), g["last"] as? [[String: Any]] ?? [], "\(name) last")
        }
        #expect(l.run.capture.versionMisses.isEmpty, "\(l.run.capture.versionMisses)")
        #expect(l.run.stats.malformed.isEmpty, "\(l.run.stats.malformed)")
    }

    @Test(.fixture(RealCapture.qmdl), .fixture(RealCapture.summary))
    func phySummaryParity() throws {
        guard let l = loaded(), let url = Fixtures.require(RealCapture.summary) else { return }
        let want = try JSONDecoder().decode(PhySummary.self, from: Data(contentsOf: url))
        let got = l.run.capture.summary
        #expect(got.scellActivity.count == want.scellActivity.count)
        for (a, b) in zip(got.scellActivity, want.scellActivity) {
            #expect(a.index == b.index && a.earfcn == b.earfcn && a.pci == b.pci && a.records == b.records, "\(a) vs \(b)")
            #expect(abs(a.firstMs - b.firstMs) <= 1.0 && abs(a.lastMs - b.lastMs) <= 1.0, "\(a) vs \(b)")
        }
        let nr = try #require(got.nrDlActivity), wantNr = try #require(want.nrDlActivity)
        #expect(nr.earfcn == nil && wantNr.earfcn == nil, "the NR DL earfcn is left to FTJourney")
        #expect(nr.pci == wantNr.pci && nr.records == wantNr.records && nr.index == wantNr.index)
        #expect(abs(nr.firstMs - wantNr.firstMs) <= 1.0 && abs(nr.lastMs - wantNr.lastMs) <= 1.0)
        #expect(got.rach.count == want.rach.count)
        for (a, b) in zip(got.rach, want.rach) {
            #expect(a.ta == b.ta && a.ulEarfcn == b.ulEarfcn && a.preambleTargetDbm == b.preambleTargetDbm, "\(a) vs \(b)")
            #expect(abs(a.tMs - b.tMs) <= 1.0)
            // Spectrum.lteTimingAdvanceMetres uses 78.12 m per step (as J10 and Kotlin do); the reference 78.125.
            #expect(abs((a.distanceM ?? 0) - (b.distanceM ?? 0)) <= 0.15, "\(a.distanceM ?? 0) vs \(b.distanceM ?? 0)")
        }
        #expect(got.rxAntennasByEarfcn == want.rxAntennasByEarfcn)
        #expect(got.txAntennasMib == [4])
        #expect(got.encrypted == RealCapture.census)
    }

    @Test(.fixture(RealCapture.qmdl), .fixture(RealCapture.tbsReference))
    func selfChecksReproduceReference() throws {
        guard let l = loaded() else { return }
        let s = l.run.stats
        for rx in 0..<4 {
            let r = try #require(s.rsrqResidual[rx])
            #expect(abs(r.mean) < 0.01 && r.sd < 0.1, "Rx\(rx): mean \(r.mean) sd \(r.sd) n \(r.n)")
        }
        #expect(s.inferredPrb == [650: 50, 975: 25, 5110: 50, 67086: 50])
        #expect(s.dlTbs.table64 == 2632 && s.dlTbs.table256 == 644 && s.dlTbs.retx == 27 && s.dlTbs.unexplained == 0,
                "\(s.dlTbs)")
        #expect(s.ul.unique == 5270 && s.ul.ambiguous == 28 && s.ul.uciOnly == 67 && s.ul.noMatch == 0, "\(s.ul)")
        #expect(s.nr.b887Records == 497 && s.nr.b887CrcFail == 27 && s.nr.b887PassBytes == 653_592, "\(s.nr)")
        #expect(s.nr.deltaDecodes == 497 && s.nr.deltaCrcFail == 27 && s.nr.deltaPassBytes == 653_592, "\(s.nr)")
        #expect(s.nrTbs.matched == 472 && s.nrTbs.retx == 25 && s.nrTbs.unexplained == 0, "\(s.nrTbs)")
        // Every one of the 497 transport blocks is accounted for, and none of them needs the wider fields the
        // second capture forced on 0xB887 (FTAppTests covers that side): 497 -> 497 either way.
        #expect(s.nrTbs.matched + s.nrTbs.retx == s.nr.b887Records, "\(s.nrTbs) of \(s.nr.b887Records)")
        #expect(s.macSamples == 4537 && s.macConsistent == 4537)
        let checks = l.run.capture.checks
        #expect(Set(checks.map(\.id)) == ["b193RsrqIdentity", "b173TbsTable", "b139TbsModulation", "b887TbsFormula",
                                          "b887VsB888", "b064HeaderAccounting"])
        for c in checks { #expect(c.passed, "\(c.id): \(c.measured)") }
    }

    /// The shipped extractor, with the build's own TBS table: until LteTbsTable.swift is generated from TS 36.213 the
    /// two table checks and the derived UL MCS are absent and the catalogue says why; everything else is the same.
    @Test(.fixture(RealCapture.qmdl))
    func builtInExtractionMatchesTheReferenceRunApartFromTheTable() throws {
        guard let l = loaded() else { return }
        let shipped = PhyExtractor.extract(records: l.records, timeBase: l.timeBase, secure: RealCapture.census)
        for m in PhyMetric.allCases where m != .lte_ul_mcs_derived {
            #expect(shipped.series[m] == l.run.capture.series[m], "\(m.rawValue)")
        }
        #expect(shipped.summary == l.run.capture.summary)
        if LteTbs.isAvailable {
            #expect(shipped.checks == l.run.capture.checks)
        } else {
            #expect(shipped.series[.lte_ul_mcs_derived]?.samples.isEmpty == true)
            #expect(Set(shipped.checks.map(\.id)) == ["b193RsrqIdentity", "b887TbsFormula", "b887VsB888", "b064HeaderAccounting"])
            #expect(shipped.availability.contains { $0.id == "lteTbsTable" })
        }
    }

    @Test(.fixture(RealCapture.qmdl))
    func carriersAreAttributedFromTheRecords() throws {
        guard let l = loaded() else { return }
        let c = l.run.capture
        func cell(_ i: Int, _ t: Double) -> String? {
            PhyCarriers.cell(carrier: i, at: t, in: c).map { "\($0.earfcn)/\($0.pci)" }
        }
        #expect(cell(0, 1000) == "650/80")
        #expect(cell(0, 10_000) == "67086/80")
        #expect(cell(0, 18_000) == "5110/235")
        #expect(cell(0, 24_000) == "650/80")
        #expect(cell(1, 15_600) == "650/235")
        #expect(cell(2, 18_000) == "975/235")
        #expect(cell(3, 18_000) == "67086/235")
        #expect(cell(1, 18_000) == nil, "SCell 1 was released at about 16.1 s")
        #expect(cell(0, 2_400) == nil, "radio off: no 0xB193 record for more than 500 ms")
        #expect(PhyCarriers.cells(at: 18_000, in: c).map(\.index) == [0, 2, 3])
        let nr = try #require(PhyCarriers.nrCell(at: 14_500, in: c))
        #expect(nr.arfcn == 174_770 && nr.pci == 80)
        #expect(PhyCarriers.nrCell(at: 20_000, in: c) == nil)
        #expect(PhyBandwidth.inferredPrb(c) == [650: 50, 975: 25, 5110: 50, 67086: 50])
    }
}

/// The contract's comparison of one KPI: counts exactly, min/max within 0.01, mean within 0.01 or 1e-4 relative,
/// the first and last samples within 1.0 ms and 0.01.
enum Stats {
    static func expect(_ values: [Double], _ want: [String: Any], _ name: String,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let count = want["count"] as? Int ?? 0
        #expect(values.count == count, "\(name) count \(values.count) != \(count)", sourceLocation: sourceLocation)
        guard count > 0, !values.isEmpty else { return }
        let mean = values.reduce(0, +) / Double(values.count)
        func near(_ a: Double, _ b: Double?, relative: Bool = false) -> Bool {
            guard let b else { return false }
            return abs(a - b) <= 0.01 || (relative && abs(a - b) <= 1e-4 * abs(b))
        }
        #expect(near(values.min()!, number(want["min"])), "\(name) min \(values.min()!) vs \(want["min"] ?? "nil")",
                sourceLocation: sourceLocation)
        #expect(near(values.max()!, number(want["max"])), "\(name) max \(values.max()!) vs \(want["max"] ?? "nil")",
                sourceLocation: sourceLocation)
        #expect(near(mean, number(want["mean"]), relative: true), "\(name) mean \(mean) vs \(want["mean"] ?? "nil")",
                sourceLocation: sourceLocation)
    }

    static func expectEnds(_ got: [PhySample], _ want: [[String: Any]], _ name: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(got.count == want.count, "\(name) count", sourceLocation: sourceLocation)
        for (s, w) in zip(got, want) {
            let t = number(w["tMs"]) ?? .nan
            #expect(abs(s.tMs - t) <= 1.0, "\(name) tMs \(s.tMs) vs \(t)", sourceLocation: sourceLocation)
            if let list = w["value"] as? [Any] {
                let mine = s.perIndex ?? []
                #expect(mine.count == list.count, "\(name) per-index length", sourceLocation: sourceLocation)
                for (a, b) in zip(mine, list) {
                    let bb = number(b)
                    #expect((a == nil && bb == nil) || (a != nil && bb != nil && abs(a! - bb!) <= 0.01),
                            "\(name) per-index \(String(describing: a)) vs \(b)", sourceLocation: sourceLocation)
                }
            } else {
                let b = number(w["value"])
                #expect((s.value == nil && b == nil) || (s.value != nil && b != nil && abs(s.value! - b!) <= 0.01),
                        "\(name) value \(String(describing: s.value)) vs \(String(describing: b))",
                        sourceLocation: sourceLocation)
            }
        }
    }

    static func number(_ x: Any?) -> Double? {
        if x is NSNull { return nil }
        if let n = x as? NSNumber { return n.doubleValue }
        return nil
    }
}
