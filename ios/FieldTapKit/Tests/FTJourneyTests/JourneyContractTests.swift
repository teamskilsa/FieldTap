// J1-J12 against the capture-derived contract fixtures (git-ignored ios/Fixtures/local/contract): the iPhone 17
// capture's journey-expected.json, and the two OnePlus goldens.

import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTJourney

@Suite struct JourneyContractTests {
    static let golden = "contract/callflow-golden.json"
    static let phySummary = "contract/phy-summary.json"
    static let expected = "contract/journey-expected.json"

    /// The capture facts the contract was written for: the D1 trace window and the modem's encrypted census.
    static let iphoneFacts = CaptureFacts(traceWindowMs: 26_959.395, logRecords: 92_133, distinctCodes: 224,
                                          encrypted: EncryptedCensus(records: 23_764, codes: 61), profile: nil,
                                          triggerUtc: nil)

    static func iphone() throws -> (Flow, PhySummary, Journey)? {
        guard let g = Fixtures.require(golden), let p = Fixtures.require(phySummary) else { return nil }
        let flow = try GoldenCodec.decodeFlow(Data(contentsOf: g)).flow
        let phy = try JSONDecoder().decode(PhySummary.self, from: Data(contentsOf: p))
        return (flow, phy, JourneyBuilder.build(flow: flow, phy: phy, facts: iphoneFacts))
    }

    static func onePlus(_ name: String) throws -> (Flow, Journey)? {
        guard let url = Fixtures.require(name) else { return nil }
        let flow = try GoldenCodec.decodeFlow(Data(contentsOf: url)).flow
        let facts = CaptureFacts(traceWindowMs: 0, logRecords: flow.records, distinctCodes: 0, encrypted: .empty,
                                 profile: nil, triggerUtc: nil)
        return (flow, JourneyBuilder.build(flow: flow, phy: .empty, facts: facts))
    }

    @Test(.fixture(golden), .fixture(phySummary), .fixture(expected))
    func iphoneJourneyMatchesContract() throws {
        guard let (flow, _, journey) = try Self.iphone(), let url = Fixtures.require(Self.expected) else { return }
        let want = try JSONDecoder().decode(JourneyExpectation.self, from: Data(contentsOf: url))
        let diff = want.differences(journey, flow: flow)
        #expect(diff.isEmpty, "\(diff.count) differences: \(diff.prefix(30).joined(separator: "; "))")

        // The counts the contract names, stated outright so a comparator bug cannot hide them.
        #expect(journey.states.count == 5)
        #expect(journey.registration.count == 3)
        #expect(journey.cells.filter { $0.lane == .pcell }.count == 4)
        let pscells = journey.cells.filter { $0.lane == .pscell }
        #expect(pscells.count == 1 && pscells[0].endInferred)
        #expect(journey.cells.filter { $0.lane == .scell }.count == 3)
        #expect(journey.markers.count == 13)
        #expect(journey.markers.filter { $0.severity == .failure }.isEmpty)
        #expect(journey.findings.count == 10)
        #expect(journey.findings.map(\.kind) == [.switchedOff, .reattach, .pdnConnected, .scgAdded, .handover,
                                                 .carrierAggregation, .handover, .noFailures, .encryptedRecords, .traceWindow])
    }

    @Test(.fixture(golden), .fixture(phySummary))
    func iphoneValuesReadRight() throws {
        guard let (_, _, j) = try Self.iphone() else { return }
        let texts = j.findings.map(\.text)
        #expect(texts[0] == "Switched off (switch-off detach) on B2 PCI 80 at 0:01.813; radio back 0.56 s later.")
        #expect(texts[1] == "Re-attached on B66 PCI 80 (EARFCN 67086) in 335 ms.")
        #expect(texts[2] == "IMS PDN connected in 240 ms.")
        #expect(texts[3] == "5G NR leg added at 0:13.799 (NR-ARFCN 174770, PCI 80, n5/n26).")
        #expect(texts[4] == "Handover B66 PCI 80 → B12 PCI 235 in 43.7 ms.")
        #expect(texts[5] == "Carrier aggregation: 3 SCells on PCI 235 (B2, B2, B66), from 0:15.391.")
        #expect(texts[6] == "Handover B12 PCI 235 → B2 PCI 80 in 26.1 ms.")
        #expect(texts[7] == "No failures: 34 procedures, all answered.")
        #expect(texts[8] == "23,764 records in 61 log codes were encrypted by the modem and can't be read.")
        #expect(texts[9] == "Trace covers 27.0 s.")

        let tiles = Dictionary(uniqueKeysWithValues: j.tiles.map { ($0.id, $0) })
        #expect(tiles["rrcSetup"]?.value == "70.2 ms")
        #expect(tiles["attach"]?.value == "335 ms")
        // One rule for every length on every screen (CallFlowPresentation.duration / Fmt.duration): the tile said
        // "median 35 ms" while the ladder and the procedure list said 34.9 ms for the same two handovers.
        #expect(tiles["handover"]?.value == "median 34.9 ms")
        #expect(tiles["scgAdd"]?.value == "n5/n26")
        #expect(tiles["abnormalReleases"]?.value == "0 of 2 connections")
        #expect(tiles["procedures"]?.value == "all answered")

        #expect(JourneyDigest.text(of: j) == "B2 → B66 → B12 → B2, NR, CA, 0 failures")
        let preview = JourneyDigest.preview(of: j)
        #expect(preview.segments.map(\.band) == ["B2", "B66", "B12", "B2"] && preview.nr && preview.failures == 0)
    }

    @Test(.fixture(golden), .fixture(phySummary))
    func markerIdsAreUniqueAndOrdered() throws {
        guard let (_, _, j) = try Self.iphone() else { return }
        #expect(Set(j.markers.map(\.id)).count == j.markers.count)
        #expect(Set(j.findings.map(\.id)).count == j.findings.count)
        #expect(Set(j.cells.map(\.id)).count == j.cells.count)
        #expect(j.markers.map(\.id).prefix(5) == ["detachSwitchOff-2", "rrcRelease-5", "attach-10", "reattach-10", "rrcSetup-11"])
        #expect(j.markers.contains { $0.id == "handover-82" } && j.markers.contains { $0.id == "rach-2659.6" })
        // Stable by time, then kind rank: 2593.419 has the re-attach before the RRC setup, 15039.542 the
        // handover before the inferred SCG release.
        for (a, b) in zip(j.markers, j.markers.dropFirst()) {
            #expect(a.tMs < b.tMs || (a.tMs == b.tMs && JourneyMarkers.rank(a.kind) <= JourneyMarkers.rank(b.kind)))
        }
    }

    @Test(.fixture(golden), .fixture(phySummary))
    func annotationsForTheLadder() throws {
        guard let (_, _, j) = try Self.iphone() else { return }
        #expect(JourneyQuery.annotation(forStepEvent: 10, in: j) == "Reselection, after switch-off detach")
        #expect(JourneyQuery.annotation(forStepEvent: 83, in: j) == "Handover in 43.7 ms, NR leg released (inferred)")
        #expect(JourneyQuery.annotation(forStepEvent: 117, in: j) == "Handover in 26.1 ms")
        #expect(JourneyQuery.annotation(forStepEvent: 0, in: j) == nil)
    }

    @Test(.fixture("contract/oneplus-5g-registration.json"))
    func onePlus5gRegistration() throws {
        guard let (_, j) = try Self.onePlus("contract/oneplus-5g-registration.json") else { return }
        let pcells = j.cells.filter { $0.lane == .pcell }
        #expect(pcells.count == 2)
        #expect(pcells.first?.cell == Cell(earfcn: 647_328, pci: 417, nr: true))
        // PLMN 001-01 is a test network: not narrowed, and 3709.92 MHz is in both n77 and n78.
        #expect(pcells.first?.bandCandidates == [77, 78])
        #expect(pcells.first?.dlMhz == 3709.92)
        #expect(pcells.last?.cell == Cell(earfcn: 501_390, pci: 152, nr: true))
        #expect(pcells.last?.bandCandidates == [41, 90])
        #expect(pcells.last?.openAtEnd == true)
        // The duration in this golden is negative (repo main); the lanes run to the last event instead.
        #expect(j.durationMs == 188_150.065)

        let failures = j.markers.filter { $0.severity == .failure }
        #expect(failures.map(\.kind) == [.procedureFailed, .registrationReject])
        #expect(failures.last?.event == 7)
        let finding = j.findings.filter { $0.kind == .failure }
        #expect(finding.count == 1)
        #expect(finding.first?.text.contains("#27") == true)
        #expect(finding.first?.text == "Registration rejected on n77/n78 PCI 417 after 110 ms at 0:00.204: #27 N1 mode not allowed.")
        #expect(!j.findings.contains { $0.kind == .noFailures })
        #expect(j.registration.map(\.state) == [.unknown, .deregistered])
        #expect(j.registration.last?.startMs == 203.863)
        let tiles = Dictionary(uniqueKeysWithValues: j.tiles.map { ($0.id, $0) })
        #expect(tiles["registration"].map { ($0.succeeded, $0.attempts) } ?? (-1, -1) == (0, 1))
        #expect(tiles["rrcSetup"].map { ($0.succeeded, $0.attempts) } ?? (-1, -1) == (1, 1))
        #expect(JourneyDigest.text(of: j) == "n77/n78 → n41/n90, 1 failure")
    }

    @Test(.fixture("contract/oneplus-callbox-service-request.json"))
    func onePlusCallbox() throws {
        guard let (_, j) = try Self.onePlus("contract/oneplus-callbox-service-request.json") else { return }
        #expect(j.markers.filter { $0.severity >= .warning }.isEmpty)
        #expect(j.findings.contains { $0.kind == .noFailures })
        let tiles = Dictionary(uniqueKeysWithValues: j.tiles.map { ($0.id, $0) })
        #expect(tiles["serviceRequest"].map { ($0.succeeded, $0.attempts) } ?? (-1, -1) == (1, 1))
        #expect(tiles["serviceRequest"]?.value == "98.6 ms")
        #expect(tiles["pdn"].map { ($0.succeeded, $0.attempts) } ?? (-1, -1) == (1, 1))
        // Switched off at the very end: radio off runs to the end and no restart is claimed (J3).
        #expect(j.states.last?.state == .radioOff && j.states.last?.openAtEnd == true)
        #expect(j.states.last?.startMs == 118_338.426)
        let off = j.findings.first { $0.kind == .switchedOff }
        #expect(off?.text == "Switched off at the end: switch-off detach on B3 PCI 3 at 1:58.316.")
        #expect(off?.text.contains("radio back") == false)
        // The first NAS procedure is a Service request: registered (assumed) until the switch-off detach.
        #expect(j.registration.map(\.state) == [.registered, .deregistered])
        #expect(j.registration.first?.assumed == true)
        #expect(j.findings.first { $0.kind == .pdnConnected }?.text == "IMS PDN connected in 29.5 ms.")
    }
}
