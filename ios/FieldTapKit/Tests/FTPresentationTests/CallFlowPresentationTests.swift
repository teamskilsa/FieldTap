// Port of android/app/src/test/kotlin/com/fieldtap/ui/signalling/CallFlowPresentationTest.kt (contract v1), test
// for test, plus the spans the design names.

import Testing
import FTModel
@testable import FTPresentation

let b3 = Cell(earfcn: 1575, pci: 3)
let b7 = Cell(earfcn: 2850, pci: 2)

func event(_ index: Int, _ key: String, layer: Layer = .RRC, channel: String = "DL-DCCH", cell: Cell? = b3,
           atMs: Double? = nil, rat: String = "lte", uplink: Bool = false, summary: String? = nil,
           fields: [Field] = [], pdu: [UInt8] = []) -> Event {
    Event(index: index, record: index + 1, logCode: 0xB0C0, timestampRaw: 0, sinceStartMs: atMs ?? Double(index) * 10,
          layer: layer, rat: rat, uplink: uplink, key: key, name: key, summary: summary, cell: cell, channel: channel,
          fields: fields, cause: nil, causeName: nil, protection: nil, ciphered: false, pdu: pdu)
}

func flow(_ events: [Event], procedures: [Procedure] = [], journey: [Step] = [],
          cellDetails: [CellDetail] = []) -> Flow {
    Flow(events: events, procedures: procedures, journey: journey, searched: [], connections: [],
         cellDetails: cellDetails, records: events.count, undecoded: 0, crcErrors: 0, durationMs: 1_000,
         startUtcMs: nil)
}

@Suite struct CallFlowPresentationTests {
    @Test func broadcastFoldsIntoOneLineAndPagingIntoAnother() {
        let events = [
            event(0, "systemInformationBlockType1", channel: "BCCH-DL-SCH"),
            event(1, "systemInformationBlockType1", channel: "BCCH-DL-SCH"),
            event(2, "systemInformation", channel: "BCCH-DL-SCH"),
            event(3, "paging", channel: "PCCH"),
            event(4, "paging", channel: "PCCH"),
            event(5, "rrcConnectionRequest", channel: "UL-CCCH"),
            event(6, "rrcConnectionRequest", channel: "UL-CCCH"),
        ]
        let rows = CallFlowPresentation.rows(flow(events), .ALL).filter { $0.event != nil }
        #expect(rows.map(\.count) == [3, 2, 1, 1])
        #expect(rows[0].mixed)
        #expect(!rows[1].mixed)
        #expect(CallFlowPresentation.rowOf(rows, eventIndex: 2) == 0)
        #expect(CallFlowPresentation.rowOf(rows, eventIndex: 6) == 3)
    }

    @Test func aSearchAcrossCellsIsOneLineThatNamesTheCells() throws {
        let events = [
            event(0, "systemInformationBlockType1", channel: "BCCH-DL-SCH", cell: b3),
            event(1, "systemInformationBlockType1", channel: "BCCH-DL-SCH", cell: b7),
            event(2, "systemInformationBlockType1", channel: "BCCH-DL-SCH", cell: Cell(earfcn: 1300, pci: 4)),
            event(3, "systemInformationBlockType1", channel: "BCCH-DL-SCH", cell: b3),
        ]
        let rows = CallFlowPresentation.rows(flow(events), .ALL)
        try #require(rows.count == 1)
        guard case .message(let first, let repeats) = rows[0] else { Issue.record("not a message row"); return }
        #expect(rows[0].mixed)
        #expect(CallFlowPresentation.cellCount(first, repeats: repeats) == 3)
        #expect(CallFlowPresentation.cellsOf(first, repeats: repeats) == "B3 PCI 3, B7 PCI 2 +1")
    }

    @Test func proceduresGroupByKindWithTheMedianOfTheSuccessfulOnes() {
        func p(_ name: String, _ outcome: Outcome, _ ms: Double, _ at: Int) -> Procedure {
            Procedure(name: name, layer: .NAS, detail: nil, first: at, last: at, outcome: outcome, durationMs: ms)
        }
        let procedures = [
            p("Attach", .UNANSWERED, 0, 0),
            p("Service request", .SUCCEEDED, 90, 1),
            p("Attach", .FAILED, 110, 2),
            p("Attach", .SUCCEEDED, 300, 3),
            p("Attach", .SUCCEEDED, 260, 4),
        ]
        let groups = CallFlowPresentation.procedureGroups(flow([], procedures: procedures))
        #expect(groups.map(\.name) == ["Attach", "Service request"])
        let attach = groups[0]
        #expect(attach.succeeded == 2 && attach.failed == 1 && attach.unanswered == 1)
        #expect(attach.medianMs == 280)
        #expect(attach.worst == .FAILED)
        #expect(CallFlowPresentation.ProcedureGroup(name: "x", layer: .RRC, items: [p("x", .FAILED, 1, 0)]).medianMs == nil)
    }

    @Test func aCellChangeBreaksARunAndGetsItsBanner() {
        let events = [
            event(0, "systemInformationBlockType1", channel: "BCCH-DL-SCH"),
            event(1, "systemInformationBlockType1", channel: "BCCH-DL-SCH", cell: b7),
        ]
        let journey = [
            Step(move: .FIRST_SEEN, from: nil, to: b3, event: 0, sinceStartMs: 0),
            Step(move: .RESELECTION, from: b3, to: b7, event: 1, sinceStartMs: 10),
        ]
        let rows = CallFlowPresentation.rows(flow(events, journey: journey), .ALL)
        #expect(rows.map(\.id) == ["event-0", "move-1", "event-1"])
        // With NAS only, no RRC and so no cell banners.
        #expect(CallFlowPresentation.rows(flow(events, journey: journey), .NAS).isEmpty)
    }

    @Test func procedureHeadersFollowTheFilter() {
        let events = [
            event(0, "Service request", layer: .NAS, channel: "EMM"),
            event(1, "rrcConnectionRequest", channel: "UL-CCCH"),
        ]
        let procedures = [
            Procedure(name: "Service request", layer: .NAS, detail: nil, first: 0, last: 1, outcome: .SUCCEEDED,
                      durationMs: 10),
            Procedure(name: "RRC connection setup", layer: .RRC, detail: nil, first: 1, last: 1, outcome: .UNANSWERED,
                      durationMs: 0),
        ]
        let f = flow(events, procedures: procedures)
        #expect(CallFlowPresentation.rows(f, .ALL).map(\.id) == ["procedure-0", "event-0", "procedure-1", "event-1"])
        #expect(CallFlowPresentation.rows(f, .RRC).map(\.id) == ["procedure-1", "event-1"])
        #expect(CallFlowPresentation.rows(f, .NAS).map(\.id) == ["procedure-0", "event-0"])
    }

    @Test func lanesAreNamedForTheRadio() {
        typealias Lanes = CallFlowPresentation.Lanes
        #expect(CallFlowPresentation.lanes(flow([event(0, "x")])) == Lanes(phone: "UE", ran: "eNB", core: "MME"))
        #expect(CallFlowPresentation.lanes(flow([event(0, "x", rat: "nr")])) == Lanes(phone: "UE", ran: "gNB", core: "AMF"))
        #expect(CallFlowPresentation.lanes(flow([event(0, "x"), event(1, "y", rat: "nr")]))
            == Lanes(phone: "UE", ran: "RAN", core: "Core"))
    }

    @Test func cellsReadAsBandAndPci() {
        #expect(CallFlowPresentation.shortCell(b3) == "B3 PCI 3")
        #expect(CallFlowPresentation.shortCell(b7) == "B7 PCI 2")
        #expect(CallFlowPresentation.downlinkMhz(b3) == "1842.5 MHz")
        #expect(CallFlowPresentation.shortCell(Cell(earfcn: 99_999, pci: 1)) == "EARFCN 99999 PCI 1")
    }

    @Test func nrCellsAreNotGivenAnLteBandTheyDoNotHave() {
        // NR-ARFCN 647328 on the global raster is 3709.9 MHz (n77 or n78: the ARFCN cannot say which).
        let nr = Cell(earfcn: 647_328, pci: 417, nr: true)
        #expect(CallFlowPresentation.band(nr) == nil)
        #expect(CallFlowPresentation.shortCell(nr) == "NR PCI 417")
        #expect(CallFlowPresentation.downlinkMhz(nr) == "3709.9 MHz")
        #expect(CallFlowPresentation.channelLabel(nr) == "NR-ARFCN")
        #expect(CallFlowPresentation.channelLabel(b3) == "EARFCN")
    }

    @Test func aPendingNrCellSaysSo() {
        // An NR RRC header logged before the SCG cell is assigned carries PCI 0xFFFF or NR-ARFCN 0xFFFFFFFF (the
        // iPhone's first EN-DC reconfiguration); it is no PCI 65535.
        #expect(CallFlowPresentation.shortCell(Cell(earfcn: 0xFFFF_FFFF, pci: 0xFFFF, nr: true)) == "NR cell pending")
        #expect(CallFlowPresentation.shortCell(Cell(earfcn: 174_770, pci: 0xFFFF, nr: true)) == "NR cell pending")
        #expect(CallFlowPresentation.shortCell(Cell(earfcn: 0xFFFF_FFFF, pci: 80, nr: true)) == "NR cell pending")
        #expect(CallFlowPresentation.shortCell(Cell(earfcn: 174_770, pci: 80, nr: true)) == "NR PCI 80")
        #expect(CallFlowPresentation.downlinkMhz(Cell(earfcn: 0xFFFF_FFFF, pci: 0xFFFF, nr: true)) == nil)
    }

    @Test func timesAndSpans() {
        #expect(CallFlowPresentation.sinceStart(63.771) == "0:00.064")
        #expect(CallFlowPresentation.sinceStart(118_338.425) == "1:58.338")
        #expect(CallFlowPresentation.sinceStart(3_723_004) == "1:02:03.004")
        #expect(CallFlowPresentation.duration(0.4) == "0.4 ms")
        #expect(CallFlowPresentation.duration(67.52) == "67.5 ms")
        #expect(CallFlowPresentation.duration(312) == "312 ms")
        #expect(CallFlowPresentation.duration(1_240) == "1.24 s")
        #expect(CallFlowPresentation.duration(123_400) == "2 min 3 s")
    }

    @Test func theHexDumpFitsAPhoneAndShowsText() {
        let bytes = Array("ims".utf8) + [0, 1, 2, 3, 4, 5, 6]
        #expect(CallFlowPresentation.hexDump(bytes) == "0000  69 6d 73 00 01 02 03 04  ims.....\n0008  05 06                    ..")
        #expect(CallFlowPresentation.hex(Array("ims".utf8)) == "696d73")
    }
}

/// What the Swift port adds on top of the Kotlin tests: the design's span strings, Java's rounding, row ids.
@Suite struct PresentationExtrasTests {
    @Test func spansRoundLikeJava() {
        // The design's list: '0.4 ms' / '67.5 ms' / '335 ms' / '1.24 s' / '12.3 s' / 'N min M s'.
        #expect(CallFlowPresentation.duration(334.5) == "335 ms")      // Java HALF_UP; C's %.0f gives "334"
        #expect(CallFlowPresentation.duration(12_345) == "12.3 s")
        #expect(CallFlowPresentation.duration(34.85) == "34.9 ms")
        #expect(CallFlowPresentation.duration(99.96) == "100.0 ms")    // the branch is chosen before rounding
        #expect(CallFlowPresentation.duration(-3) == "0.0 ms")
        #expect(CallFlowPresentation.duration(3_723_004) == "1 h 2 min")
        #expect(CallFlowPresentation.duration(.nan) == "—")
        #expect(CallFlowPresentation.sinceStart(-5) == "0:00.000")
        #expect(CallFlowPresentation.sinceStart(0.5) == "0:00.001")     // Math.round: half up
        #expect(CallFlowPresentation.gap([event(0, "a")], 0) == nil)
        #expect(CallFlowPresentation.gap([event(0, "a"), event(1, "b", atMs: 12.5)], 1) == 12.5)
        #expect(CallFlowPresentation.gap([event(0, "a")], 4) == nil)
    }

    @Test func rowIdsFollowTheKotlinKeys() {
        let step = Step(move: .HANDOVER, from: nil, to: Cell(earfcn: 5_110, pci: 235), event: 82, sinceStartMs: 1)
        #expect(LadderRow.move(step).id == "move-82")
        #expect(FlowFilter.allCases == [.ALL, .RRC, .NAS])
        let p = Procedure(name: "Attach", layer: .NAS, detail: nil, first: 0, last: 1, outcome: .SUCCEEDED, durationMs: 1)
        #expect(LadderRow.procedureStart(p, ordinal: 7).id == "procedure-7")
        #expect(LadderRow.procedureStart(p, ordinal: 7).events.isEmpty)
    }

    @Test func directionFollowsTheLayerAndTheLink() {
        let lanes = CallFlowPresentation.Lanes(phone: "UE", ran: "eNB", core: "MME")
        #expect(CallFlowPresentation.direction(event(0, "a", uplink: true), lanes) == "UE → eNB")
        #expect(CallFlowPresentation.direction(event(0, "a", layer: .NAS), lanes) == "MME → UE")
    }

    @Test func aLaterStepOnTheSameEventWins() {
        // Kotlin associateBy keeps the last value for a key.
        let events = [event(0, "a"), event(1, "b", cell: b7)]
        let journey = [
            Step(move: .RESELECTION, from: b3, to: b3, event: 1, sinceStartMs: 10),
            Step(move: .HANDOVER, from: b3, to: b7, event: 1, sinceStartMs: 10),
        ]
        let rows = CallFlowPresentation.rows(flow(events, journey: journey), .RRC)
        guard case .move(let s) = rows[1] else { Issue.record("no move row"); return }
        #expect(s.move == .HANDOVER)
    }
}
