// One synthetic flow per journey rule the iPhone capture does not exercise: connection outcomes (J2), moves
// (J7), SCG failure and NR PHY past the inferred end (J8), unanswered procedures and merging (J11).

import Testing
import FTModel
@testable import FTJourney

@Suite struct JourneyRuleTests {
    typealias S = SyntheticFlow

    @Test func lostConnectionIsAFailure() {
        var f = S()
        f.rrc(50, "systemInformationBlockType1", "SIB1", cell: S.b66, channel: "BCCH-DL-SCH")
        let request = f.setup(100, on: S.b66)
        let last = f.rrc(500, "measurementReport", "Measurement Report", cell: S.b66, uplink: true)
        f.rrc(2_000, "systemInformationBlockType1", "SIB1", cell: S.b66, channel: "BCCH-DL-SCH")
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: 0)
        f.connection(request, last, .LOST)
        let j = f.journey()

        let lost = j.markers.filter { $0.kind == .connectionLost }
        #expect(lost.count == 1 && lost[0].severity == .failure && lost[0].event == last && lost[0].tMs == 500)
        #expect(j.states.map(\.state) == [.unknown, .idle, .connected, .idle])
        #expect(j.states[2].startMs == 100 && j.states[2].endMs == 500)
        #expect(j.findings.contains { $0.kind == .failure && $0.text.hasPrefix("Connection lost on B66 PCI 80 at 0:00.500") })
        #expect(!j.findings.contains { $0.kind == .noFailures })
        let abnormal = j.tiles.first { $0.id == "abnormalReleases" }
        #expect(abnormal?.succeeded == 1 && abnormal?.attempts == 1)
    }

    @Test func rejectedConnectionMergesIntoOneFailureMarker() {
        var f = S()
        let request = f.rrc(100, "rrcConnectionRequest", "RRC Connection Request", cell: S.b66, uplink: true, channel: "UL-CCCH")
        let reject = f.rrc(150, "rrcConnectionReject", "RRC Connection Reject", cell: S.b66, channel: "DL-CCCH")
        f.procedure("RRC connection setup", .RRC, request, reject, .FAILED, refusal: "rejected")
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: 0)
        f.connection(request, reject, .REJECTED)
        let j = f.journey()

        // The reject event (J11) and the REJECTED connection (J2) are one marker at the reject.
        let atReject = j.markers.filter { $0.event == reject }
        #expect(atReject.count == 1 && atReject[0].kind == .rrcReject && atReject[0].severity == .failure)
        #expect(j.markers.contains { $0.kind == .procedureFailed && $0.event == request })
        #expect(!j.states.contains { $0.state == .connected })
        // Told once: the failed setup's own answer is the reject.
        let failures = j.findings.filter { $0.kind == .failure }
        #expect(failures.count == 1)
        #expect(failures.first?.text == "RRC Connection rejected on B66 PCI 80 after 50.0 ms at 0:00.150.")
        let rrc = j.tiles.first { $0.id == "rrcSetup" }
        #expect(rrc?.succeeded == 0 && rrc?.attempts == 1)
    }

    @Test func unansweredConnectionRequestIsAWarning() {
        var f = S()
        let request = f.rrc(100, "rrcConnectionRequest", "RRC Connection Request", cell: S.b66, uplink: true, channel: "UL-CCCH")
        f.procedure("RRC connection setup", .RRC, request, request, .UNANSWERED)
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: 0)
        f.connection(request, nil, .NO_ANSWER)
        let j = f.journey()

        let atRequest = j.markers.filter { $0.event == request }
        #expect(atRequest.count == 1 && atRequest[0].severity == .warning)
        #expect(j.markers.filter { $0.severity == .failure }.isEmpty)
        #expect(j.findings.contains { $0.kind == .warning })
        #expect(j.findings.first { $0.kind == .noFailures }?.text == "No failures; 1 of 1 procedures got no answer.")
    }

    @Test func unansweredProcedureIsAWarning() {
        var f = S()
        let request = f.setup(100, on: S.b66)
        let enquiry = f.rrc(300, "ueCapabilityEnquiry", "UE Capability Enquiry", cell: S.b66)
        f.procedure("UE capability", .RRC, enquiry, enquiry, .UNANSWERED)
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: request)
        f.connection(request, nil, .OPEN_AT_END)
        let j = f.journey()

        let m = j.markers.first { $0.kind == .procedureUnanswered }
        #expect(m?.event == enquiry && m?.severity == .warning && m?.title == "UE capability: no answer")
        #expect(j.findings.contains { $0.kind == .warning && $0.text == "UE capability: no answer on B66 PCI 80 at 0:00.300." })
        let tile = j.tiles.first { $0.id == "procedures" }
        #expect(tile?.succeeded == 1 && tile?.attempts == 2 && tile?.value == "1 unanswered")
        #expect(j.states.last?.openAtEnd == true)
    }

    @Test func reestablishmentIsAWarningMove() {
        var f = S()
        let request = f.setup(100, on: S.b66)
        let reest = f.rrc(900, "rrcConnectionReestablishmentRequest", "RRC Connection Reestablishment Request", cell: S.b12,
                          uplink: true, channel: "UL-CCCH")
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: request)
        f.step(.REESTABLISHMENT, from: S.b66, to: S.b12, event: reest)
        f.connection(request, nil, .OPEN_AT_END)
        let j = f.journey()

        let m = j.markers.first { $0.kind == .reestablishment }
        #expect(m?.severity == .warning && m?.event == reest && m?.to == S.b12)
        #expect(j.findings.contains { $0.kind == .warning && $0.text.hasPrefix("Re-establishment B66 PCI 80 → B12 PCI 235") })
        #expect(j.tiles.first { $0.id == "abnormalReleases" }?.succeeded == 1)
    }

    @Test func redirectIsAWarningMove() {
        var f = S()
        let request = f.setup(100, on: S.b66)
        let release = f.rrc(400, "rrcConnectionRelease", "RRC Connection Release", cell: S.b66)
        let sib = f.rrc(700, "systemInformationBlockType1", "SIB1", cell: S.b2, channel: "BCCH-DL-SCH")
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: request)
        f.step(.REDIRECT, from: S.b66, to: S.b2, event: sib)
        f.connection(request, release, .RELEASED)
        let j = f.journey()

        let m = j.markers.first { $0.kind == .redirect }
        #expect(m?.severity == .warning && m?.tMs == 700)
        #expect(j.cells.filter { $0.lane == .pcell }.map(\.band) == ["B66", "B2"])
        #expect(j.markers.contains { $0.kind == .rrcRelease && $0.event == release })
    }

    @Test func cellChangeWithoutHandoverIsAWarning() {
        var f = S()
        let request = f.setup(100, on: S.b66)
        let other = f.rrc(800, "measurementReport", "Measurement Report", cell: S.b12, uplink: true)
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: request)
        f.step(.CELL_CHANGE, from: S.b66, to: S.b12, event: other)
        f.connection(request, nil, .OPEN_AT_END)
        let j = f.journey()

        let m = j.markers.first { $0.kind == .cellChange }
        #expect(m?.severity == .warning && m?.detail == "Changed cell while connected without a logged handover.")
        #expect(j.findings.contains { $0.text.contains("changed cell while connected without a logged handover") })
    }

    @Test func scgFailureEndsTheNrLegWithAFailure() {
        var f = S()
        let request = f.setup(100, on: S.b66)
        f.scgAdd(1_000, lte: S.b66)
        let failure = f.rrc(3_000, "scgFailureInformationNR", "SCG Failure Information NR", cell: S.b66, uplink: true)
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: request)
        f.connection(request, nil, .OPEN_AT_END)
        let j = f.journey()

        let leg = j.cells.first { $0.lane == .pscell }
        #expect(leg?.startMs == 1_002 && leg?.addedMs == 1_016 && leg?.endMs == 3_000)
        #expect(leg?.endInferred == false && leg?.endReason == "SCG failure (event \(failure))")
        #expect(leg?.bandCandidates == [5, 26])
        let m = j.markers.filter { $0.event == failure }
        #expect(m.count == 1 && m[0].kind == .scgFailure && m[0].severity == .failure)
        #expect(!j.markers.contains { $0.kind == .scgRelease })
        #expect(j.findings.contains { $0.kind == .failure && $0.text.hasPrefix("The NR leg failed (SCG failure) at 0:03.000") })
        let add = j.tiles.first { $0.id == "scgAdd" }
        #expect(add?.succeeded == 1 && add?.attempts == 1)
    }

    @Test func nrPhyPastTheInferredEndIsAWarning() {
        var f = S()
        let request = f.setup(100, on: S.b66)
        f.scgAdd(1_000, lte: S.b66)
        let command = f.rrc(4_000, "rrcConnectionReconfiguration", "RRC Connection Reconfiguration", cell: S.b66,
                            fields: [Field(label: Event.handoverFieldLabel, value: "to PCI 235, EARFCN 5110")])
        let arrival = f.rrc(4_030, "rrcConnectionReconfigurationComplete", "RRC Connection Reconfiguration Complete",
                            cell: S.b12, uplink: true)
        f.procedure("Handover", .RRC, command, arrival)
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: request)
        f.step(.HANDOVER, from: S.b66, to: S.b12, event: arrival)
        f.connection(request, nil, .OPEN_AT_END)
        var phy = PhySummary.empty
        phy.nrDlActivity = CarrierActivity(index: 0, earfcn: nil, pci: nil, firstMs: 1_100, lastMs: 4_800, records: 50,
                                           source: "0xB887")
        let j = f.journey(phy: phy)

        let leg = j.cells.first { $0.lane == .pscell }
        #expect(leg?.endMs == 4_000 && leg?.endInferred == true && leg?.phyLastMs == 4_800)
        let ho = j.markers.first { $0.kind == .handover }
        #expect(ho?.tMs == 4_000 && ho?.arrivalMs == 4_030 && ho?.durationMs == 30 && ho?.event == command)
        #expect(j.markers.contains { $0.kind == .scgRelease && $0.inferred && $0.tMs == 4_000 })
        let w = j.findings.first { $0.kind == .scgPhyOutlived }
        #expect(w?.severity == .warning)
        #expect(w?.text == "NR data continued 0.80 s after the NR leg's inferred end at 0:04.000.")
    }

    @Test func reselectionWithoutRadioOffStaysAReselection() {
        var f = S()
        f.rrc(100, "systemInformationBlockType1", "SIB1", cell: S.b66, channel: "BCCH-DL-SCH")
        let paging = f.rrc(3_000, "paging", "Paging", cell: S.b2, channel: "PCCH")
        f.step(.FIRST_SEEN, from: nil, to: S.b66, event: 0)
        f.step(.RESELECTION, from: S.b66, to: S.b2, event: paging)
        let j = f.journey()
        #expect(j.markers.map(\.kind) == [.reselection])
        #expect(j.states.map(\.state) == [.unknown, .idle])
        // J5: no NAS procedure at all, so registration is unknown throughout.
        #expect(j.registration.map(\.state) == [.unknown])
        #expect(JourneyQuery.annotation(forStepEvent: paging, in: j) == "Reselection (idle)")
    }

    @Test func mergeKeepsTheHighestSeverity() {
        let warning = Marker(id: "procedureUnanswered-3", kind: .procedureUnanswered, tMs: 1, event: 3, severity: .warning, title: "w")
        let failure = Marker(id: "procedureFailed-3", kind: .procedureFailed, tMs: 1, event: 3, severity: .failure, title: "f")
        let other = Marker(id: "noAnswer-4", kind: .noAnswer, tMs: 2, event: 4, severity: .warning, title: "o")
        let merged = JourneyMarkers.merged([warning, other, failure])
        #expect(merged.map(\.id) == ["procedureFailed-3", "noAnswer-4"])
    }

    @Test func emptyFlowGivesAnEmptyJourneyOfTheFlowsLength() {
        var flow = Flow.empty
        flow.durationMs = 1_000
        let j = JourneyBuilder.build(flow: flow, phy: .empty, facts: CaptureFacts(summary: CaptureSummary(importedAt: .now, sourceName: "x")))
        #expect(j.durationMs == 1_000 && j.markers.isEmpty && j.cells.isEmpty)
        #expect(j.states.map(\.state) == [.unknown])
        #expect(j.findings.map(\.kind) == [.noFailures, .traceWindow])
        #expect(j.findings.last?.text == "Trace covers 1.0 s.")
    }
}
