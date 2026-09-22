// The cursor queries: serving cells and header values with their staleness rules, marker stepping, carrier
// attribution, and the NR band candidates.

import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTJourney

@Suite struct JourneyQueryTests {
    /// Samples around the 15.0-16.0 s handover, identifier-free and made up for the staleness rules.
    static func phy() -> PhyCapture {
        func series(_ m: PhyMetric, _ samples: [PhySample]) -> PhySeries {
            PhySeries(metric: m, unit: "", code: 0xB193, version: "1", confidence: .high, samples: samples)
        }
        var p = PhyCapture.empty
        p.series[.lte_rsrp_filtered] = series(.lte_rsrp_filtered, [
            PhySample(tMs: 14_800, value: -108.0),
            PhySample(tMs: 14_900, value: -107.5),
            PhySample(tMs: 14_950, value: -90.0, carrier: 1),                  // an SCell: not the header's
            PhySample(tMs: 15_995, value: -99.0, earfcn: 5_110, pci: 235),
            PhySample(tMs: 15_998, value: -120.0, earfcn: 67_086, pci: 80),   // the old cell, after the handover
        ])
        p.series[.lte_rsrq_filtered] = series(.lte_rsrq_filtered, [PhySample(tMs: 14_300, value: -12.0)])
        p.series[.lte_cqi_wideband_cw0] = series(.lte_cqi_wideband_cw0, [PhySample(tMs: 14_990, value: 10)])
        p.series[.lte_ri] = series(.lte_ri, [PhySample(tMs: 14_995, value: 2)])
        p.series[.lte_dl_mcs] = series(.lte_dl_mcs, [13_900, 14_100, 14_400, 14_700, 14_900, 14_990].enumerated().map {
            PhySample(tMs: Double($0.element), value: [3, 19, 17, 21, 19, 25][$0.offset])
        })
        p.series[.nr_ss_rsrp] = series(.nr_ss_rsrp, [PhySample(tMs: 13_500, value: -104.2)])
        p.series[.nr_dl_mcs] = series(.nr_dl_mcs, [PhySample(tMs: 14_500, value: 10), PhySample(tMs: 14_800, value: 12),
                                                   PhySample(tMs: 14_950, value: 14)])
        return p
    }

    @Test(.fixture("contract/callflow-golden.json"), .fixture("contract/phy-summary.json"))
    func servingAtCursor() throws {
        guard let (_, _, j) = try JourneyContractTests.iphone() else { return }
        let phy = Self.phy()

        let a = JourneyQuery.serving(at: 15_000, journey: j, phy: phy)
        #expect(a.state == .connected)
        #expect(a.pcell?.cell == Cell(earfcn: 67_086, pci: 80) && a.pcell?.band == "B66")
        #expect(a.pscell?.cell == Cell(earfcn: 174_770, pci: 80, nr: true) && a.pscell?.bandCandidates == [5, 26])
        #expect(a.scells.isEmpty)
        #expect(a.rsrp == -107.5)                      // newest carrier-0 sample within 500 ms
        #expect(a.rsrq == nil && a.stale.contains("rsrq"))   // 700 ms old
        #expect(a.rssi == nil && !a.stale.contains("rssi"))  // never logged
        #expect(a.cqi == 10 && a.ri == 2)
        #expect(a.dlMcs == 19)                         // median of 19, 17, 21, 19, 25 in the last 1 s
        #expect(a.nrRsrp == -104.2)                    // 1.5 s old, inside NR's 2 s
        #expect(a.nrMcs == 12)
        #expect(a.stale == ["rsrq"])

        let b = JourneyQuery.serving(at: 16_000, journey: j, phy: phy)
        #expect(b.pcell?.cell == Cell(earfcn: 5_110, pci: 235) && b.pcell?.band == "B12")
        #expect(b.pscell == nil)
        #expect(b.scells.map(\.index) == [1, 2, 3])
        #expect(b.scells.map(\.cell.earfcn) == [650, 975, 67_086])
        #expect(b.rsrp == -99.0)                       // the B12 sample, not the later B66 one
        #expect(b.nrRsrp == nil && b.stale.contains("nrRsrp"))
        #expect(b.dlMcs == nil && b.stale.contains("dlMcs"))

        let c = JourneyQuery.serving(at: 2_000, journey: j, phy: phy)
        #expect(c.state == .radioOff && c.pcell == nil && c.pscell == nil)
        #expect(c.rsrp == nil && c.stale.isEmpty)

        // At the handover instant the new cell serves (segments are half-open).
        #expect(JourneyQuery.serving(at: 15_083.242, journey: j, phy: .empty).pcell?.band == "B12")
        #expect(JourneyQuery.serving(at: j.durationMs, journey: j, phy: .empty).pcell?.band == "B2")
    }

    @Test(.fixture("contract/callflow-golden.json"), .fixture("contract/phy-summary.json"))
    func markerStepping() throws {
        guard let (_, _, j) = try JourneyContractTests.iphone() else { return }
        #expect(JourneyQuery.marker(after: 0, in: j)?.id == "detachSwitchOff-2")
        #expect(JourneyQuery.marker(after: 15_039.542, in: j)?.kind == .rach)
        #expect(JourneyQuery.marker(before: 15_039.542, in: j)?.id == "scgModify-78")
        #expect(JourneyQuery.marker(after: 22_000, in: j) == nil)
        #expect(JourneyQuery.marker(before: 1_000, in: j) == nil)
        #expect(JourneyQuery.markersPassed(at: 0, in: j) == 0)
        #expect(JourneyQuery.markersPassed(at: 15_039.542, in: j) == 10)
        #expect(JourneyQuery.markersPassed(at: 30_000, in: j) == 13)
    }

    @Test(.fixture("contract/callflow-golden.json"), .fixture("contract/phy-summary.json"))
    func carrierIndexMapsToTheCellAtThatTime() throws {
        guard let (_, _, j) = try JourneyContractTests.iphone() else { return }
        #expect(JourneyQuery.cell(carrier: 0, at: 16_000, in: j)?.cell == Cell(earfcn: 5_110, pci: 235))
        #expect(JourneyQuery.cell(carrier: 0, at: 10_000, in: j)?.cell == Cell(earfcn: 67_086, pci: 80))
        #expect(JourneyQuery.cell(carrier: 2, at: 16_000, in: j)?.cell == Cell(earfcn: 975, pci: 235))
        #expect(JourneyQuery.cell(carrier: 1, at: 17_000, in: j) == nil)     // SCell1 ended at 16.07 s
        #expect(JourneyQuery.cell(carrier: 0, at: 2_000, in: j) == nil)      // radio off
        #expect(JourneyQuery.segments(at: 14_000, in: j).map(\.lane) == [.pcell, .pscell])
    }

    @Test func nrBandCandidates() {
        // Test PLMNs are not narrowed; overlapping bands are all listed.
        #expect(NrBands.candidates(arfcn: 647_328, mcc: 1) == [77, 78])
        #expect(NrBands.candidates(arfcn: 501_390, mcc: 1) == [41, 90])
        #expect(NrBands.candidates(arfcn: 501_390, mcc: 999) == [41, 90])
        // 873.85 MHz: n5, n18 and n26 on paper; n18 is not a North American band.
        #expect(NrBands.candidates(arfcn: 174_770, mcc: nil) == [5, 18, 26])
        #expect(NrBands.candidates(arfcn: 174_770, mcc: 440) == [5, 18, 26])
        #expect(NrBands.candidates(arfcn: 174_770, mcc: 310) == [5, 26])
        #expect(NrBands.candidates(arfcn: 174_770, mcc: 334) == [5, 26])
        #expect(NrBands.candidates(arfcn: 647_328, mcc: 310) == [77])
        // 28 GHz: n257 and n261 by range; US operators use n261.
        #expect(NrBands.candidates(arfcn: 2_079_167, mcc: nil) == [257, 261])
        #expect(NrBands.candidates(arfcn: 2_079_167, mcc: 311) == [261])
        #expect(NrBands.candidates(arfcn: 501_390, mcc: 302) == [41, 90])
        #expect(NrBands.candidates(arfcn: 520_000, mcc: nil) == [38, 41, 90])
        #expect(NrBands.candidates(arfcn: 50, mcc: nil).isEmpty)
        #expect(NrBands.dlMhz(arfcn: 174_770) == 873.85)
        #expect(NrBands.dlMhz(arfcn: 647_328) == 3709.92)
        #expect(JourneyContext.mcc(plmn: "310-410") == 310 && JourneyContext.mcc(plmn: "001-01") == 1)
    }

    @Test func textFormats() {
        #expect(JourneyText.clock(15_040) == "0:15.040")
        #expect(JourneyText.clock(13_798.721) == "0:13.799")
        #expect(JourneyText.clock(118_315.744) == "1:58.316")
        #expect(JourneyText.shortClock(46_800) == "0:46")
        #expect(JourneyText.duration(43.699) == "44 ms" && JourneyText.duration(12_700) == "12.7 s")
        #expect(JourneyText.seconds(560.909) == "0.56 s")
        #expect(JourneyText.distance(1_406.2) == "1.4 km" && JourneyText.distance(780) == "780 m")
        #expect(JourneyText.count(23_764) == "23,764" && JourneyText.count(999) == "999")
        #expect(JourneyText.mhz(2175) == "2175.0 MHz" && JourneyText.mhz(873.85) == "873.85 MHz")
    }

    @Test func throughputPeaksAddUpTheCarriersOfASecond() {
        var phy = PhyCapture.empty
        phy.series[.lte_dl_phy_throughput] = PhySeries(metric: .lte_dl_phy_throughput, unit: "Mbit/s", code: 0xB173, version: "50",
                                                       confidence: .derived, samples: [
            PhySample(tMs: 15_500, value: 2.5, carrier: 0), PhySample(tMs: 15_500, value: 1.6, carrier: 1),
            PhySample(tMs: 16_500, value: 3.0, carrier: 0),
        ])
        let tiles = KpiTiles.peaks(phy: phy)
        #expect(tiles.map(\.id) == ["lteDlPhyPeak"])
        #expect(tiles.first?.value == "4.1 Mbit/s" && tiles.first?.group == "Integrity")
        #expect(KpiTiles.peaks(phy: .empty).isEmpty)
    }

    @Test func traceWindowAfterThePress() {
        var f = SyntheticFlow(durationMs: 26_959.395)
        f.rrc(100, "systemInformationBlockType1", "SIB1", cell: SyntheticFlow.b66, channel: "BCCH-DL-SCH")
        let facts = CaptureFacts(traceWindowMs: 26_959.395, logRecords: 1, distinctCodes: 1,
                                 encrypted: EncryptedCensus(records: 12, codes: 2, byCode: ["0xB8DD": 10, "0xB9A1": 2]),
                                 profile: nil, triggerUtc: nil,
                                 traceWindowAfterPressMs: TraceWindow(startMs: 19_020, endMs: 46_800), overwrittenFiles: 111)
        let j = JourneyBuilder.build(flow: f.flow, phy: .empty, facts: facts)
        #expect(j.findings.last?.text == "Trace covers 27.0 s (0:19–0:46 after you pressed the buttons).")
        #expect(j.findings.first { $0.kind == .encryptedRecords }?.text
            == "12 NR PHY records in 2 log codes were encrypted by the modem and can't be read.")
    }
}
