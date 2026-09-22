// Parity with the Kotlin presentation: the ladder rows, lanes and procedure groups of the iPhone capture,
// serialised the way ios/Contract/tools/PresDump.kt writes presentation-golden.json, compared exactly.

import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTPresentation

/// PresDump.kt's JSON for a flow, as an object tree (the comparator is structural, so key order is free).
func presDump(_ flow: Flow) -> [String: Any] {
    func str(_ s: String?) -> Any { s ?? NSNull() }
    var out: [String: Any] = [:]
    for filter in FlowFilter.allCases {
        out["rows\(filter.rawValue)"] = CallFlowPresentation.rows(flow, filter).map { row -> [String: Any] in
            switch row {
            case .move(let step):
                return ["type": "move", "key": row.id, "move": step.move.rawValue,
                        "to": CallFlowPresentation.shortCell(step.to), "band": str(CallFlowPresentation.band(step.to)),
                        "downlink": str(CallFlowPresentation.downlinkMhz(step.to))]
            case .procedureStart(let p, _):
                return ["type": "procedure", "key": row.id, "name": p.name, "outcome": p.outcome.rawValue,
                        "duration": CallFlowPresentation.duration(p.durationMs)]
            case .message(let e, let repeats):
                return ["type": "message", "key": row.id, "name": e.name, "count": row.count, "mixed": row.mixed,
                        "cells": CallFlowPresentation.cellsOf(e, repeats: repeats),
                        "cellCount": CallFlowPresentation.cellCount(e, repeats: repeats),
                        "since": CallFlowPresentation.sinceStart(e.sinceStartMs),
                        "gap": str(CallFlowPresentation.gap(flow.events, e.index).map { CallFlowPresentation.duration($0) })]
            }
        }
    }
    let lanes = CallFlowPresentation.lanes(flow)
    out["lanes"] = ["phone": lanes.phone, "ran": lanes.ran, "core": lanes.core]
    out["procedureGroups"] = CallFlowPresentation.procedureGroups(flow).map { g -> [String: Any] in
        ["name": g.name, "layer": g.layer.rawValue, "n": g.items.count, "succeeded": g.succeeded, "failed": g.failed,
         "unanswered": g.unanswered, "median": str(g.medianMs.map { CallFlowPresentation.duration($0) })]
    }
    return out
}

func goldenFlow(_ relative: String = "contract/callflow-golden.json") throws -> Flow {
    try GoldenCodec.decodeFlow(try Fixtures.data(relative)).flow
}

@Suite struct PresentationGoldenTests {
    @Test(.fixture("contract/presentation-golden.json"), .fixture("contract/callflow-golden.json"))
    func presentationGoldenParity() throws {
        guard let expected = Fixtures.require("contract/presentation-golden.json") else { return }
        let flow = try goldenFlow()
        let dump = presDump(flow)
        #expect((dump["rowsALL"] as? [Any])?.count == 157)
        #expect((dump["rowsRRC"] as? [Any])?.count == 127)
        #expect((dump["rowsNAS"] as? [Any])?.count == 29)
        #expect(CallFlowPresentation.lanes(flow) == .init(phone: "UE", ran: "RAN", core: "Core"))
        let data = try JSONSerialization.data(withJSONObject: dump, options: [.sortedKeys])
        // Presentation strings compare exactly: the comparator's tolerance only touches numbers (counts here).
        JSONAssert.equal(data, expected)
    }

    @Test(.fixture("contract/callflow-golden.json"))
    func theStringsTheDesignQuotes() throws {
        let flow = try goldenFlow()
        let groups = CallFlowPresentation.procedureGroups(flow)
        #expect(groups.count == 10)
        let reconf = try #require(groups.first { $0.name == "RRC reconfiguration" })
        #expect(reconf.items.count == 20 && reconf.succeeded == 20)
        #expect(reconf.medianMs.map { CallFlowPresentation.duration($0) } == "10.1 ms")
        // The Overview tiles take their strings from the same function (critique: '34.9 ms', '70.2 ms').
        let handover = try #require(groups.first { $0.name == "Handover" })
        #expect(handover.medianMs.map { CallFlowPresentation.duration($0) } == "34.9 ms")
        let setup = try #require(groups.first { $0.name == "RRC connection setup" })
        #expect(setup.medianMs.map { CallFlowPresentation.duration($0) } == "70.2 ms")
        let attach = try #require(groups.first { $0.name == "Attach" })
        #expect(attach.medianMs.map { CallFlowPresentation.duration($0) } == "335 ms")

        let rows = CallFlowPresentation.rows(flow, .ALL)
        let row73 = try #require(CallFlowPresentation.rowOf(rows, eventIndex: 73))
        guard case .message(let e73, let repeats) = rows[row73] else { Issue.record("event 73 is not a message row"); return }
        #expect(CallFlowPresentation.cellsOf(e73, repeats: repeats) == "NR cell pending")
        #expect(rows.contains { $0.id == "move-83" })
        #expect(flow.events.count { $0.layer == .RRC } == 104)
        #expect(flow.events.count { $0.layer == .NAS } == 24)
    }

    /// The other goldens have no presentation golden; the rows must still cover every event exactly once.
    @Test(arguments: ["contract/callflow-golden.json", "contract/callflow-attach4.json",
                      "contract/oneplus-5g-registration.json", "contract/oneplus-callbox-service-request.json"])
    func everyEventIsOnExactlyOneRow(_ relative: String) throws {
        guard Fixtures.require(relative) != nil else { return }
        let flow = try goldenFlow(relative)
        for filter in FlowFilter.allCases {
            let rows = CallFlowPresentation.rows(flow, filter)
            let covered = rows.flatMap(\.events).map(\.index)
            #expect(covered == flow.events.filter { filter.admits($0) }.map(\.index), "\(relative) \(filter)")
            #expect(Set(rows.map(\.id)).count == rows.count, "row ids are unique in \(relative) \(filter)")
            for e in flow.events where filter.admits(e) {
                #expect(CallFlowPresentation.rowOf(rows, eventIndex: e.index) != nil)
            }
        }
    }
}
