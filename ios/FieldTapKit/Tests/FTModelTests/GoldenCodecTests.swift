import Foundation
import Testing
import FTTestSupport
@testable import FTModel

@Suite struct GoldenCodecTests {
    /// The four callflow goldens (GoldenDump.kt output): iPhone full, iPhone attach window, and two OnePlus.
    static let goldens = ["contract/callflow-golden.json", "contract/callflow-attach4.json",
                          "contract/oneplus-5g-registration.json", "contract/oneplus-callbox-service-request.json"]

    @Test(.fixture("contract/callflow-golden.json"), arguments: goldens)
    func goldenRoundTrip(_ path: String) throws {
        guard let url = Fixtures.require(path) else { return }
        let data = try Data(contentsOf: url)
        let g = try GoldenCodec.decodeFlow(data)
        let encoded = GoldenCodec.encodeFlow(g.flow, source: g.source, recordsPerCode: g.recordsPerCode,
                                             pduLengths: g.pduLengths)
        #expect(GoldenCodec.jsonDiff(encoded, data, ignoring: []) == [], "\(path)")
        #expect(!g.flow.events.isEmpty)
    }

    @Test(.fixture("contract/callflow-golden.json"))
    func iphoneGoldenReadsAsAFlow() throws {
        let g = try GoldenCodec.decodeFlow(Fixtures.data("contract/callflow-golden.json"))
        #expect(g.source.hdlcFrames == 92_133 && g.source.crcErrors == 0)
        #expect(g.flow.records == 92_133)
        #expect(abs(g.flow.durationMs - 26_959.395) < 0.001)
        #expect(g.flow.failures == 0)
        #expect(g.flow.procedures.count == 34)
        #expect(g.flow.journey.map(\.move) == [.FIRST_SEEN, .RESELECTION, .HANDOVER, .HANDOVER])
        #expect(g.flow.connections.map(\.outcome) == [.RELEASED, .OPEN_AT_END])
        #expect(g.recordsPerCode.count == 224)
        #expect(g.flow.events.allSatisfy { $0.pdu.isEmpty })
        #expect(g.flow.cellDetails.allSatisfy { $0.info.cellIdentity == nil }, "masked in the golden")
        // The golden has no start time, only startUtcKnown; it is recovered from event 0 as reduce_phy.py does.
        let start = try #require(g.flow.startUtcMs)
        #expect(abs(start - 1_790_019_725_984) <= 1)
        // D4: the NR header of event 73 was logged before the SCG cell was assigned.
        #expect(g.flow.events.contains { $0.cell?.isPendingNr == true })
    }

    @Test func encodeWritesGoldenDumpFieldOrderAndMasking() throws {
        let event = Event(index: 0, record: 7, logCode: 0xB0ED, timestampRaw: 77_282_930_998_480_488, sinceStartMs: 1812.9725,
                          layer: .NAS, rat: "lte", uplink: true, key: "Attach request", name: "Attach request",
                          summary: "from \(Synthetic.ipv4)", cell: Cell(earfcn: 650, pci: 80), channel: "EMM",
                          fields: [Field(label: "IMSI", value: Synthetic.imsiLike)], cause: nil, causeName: nil,
                          protection: Protection(headerType: 2, mac: 0xDEAD, sequence: 5), ciphered: false,
                          pdu: [1, 2, 3])
        let flow = Flow(events: [event], procedures: [], journey: [], searched: [], connections: [], records: 1,
                        undecoded: 0, crcErrors: 0, durationMs: 0, startUtcMs: nil)
        let source = GoldenSource(file: "x.qmdl", bytes: 1, hdlcFrames: 1, crcErrors: 0, logRecords: 1, badPackets: 0)
        let text = String(decoding: GoldenCodec.encodeFlow(flow, source: source, recordsPerCode: [0xB0ED: 1]), as: UTF8.self)
        #expect(text.contains("\"logCode\":\"0xB0ED\",\"timestampRaw\":\(event.timestampRaw),\"sinceStartMs\":1812.973,"))
        #expect(text.contains("\"summary\":\"from <masked>\""))
        #expect(text.contains("{\"label\":\"IMSI\",\"value\":\"<masked>\"}"))
        #expect(text.contains("\"protection\":{\"headerType\":2,\"headerName\":\"integrity protected and ciphered\",\"sequence\":5}"))
        #expect(text.contains("\"pduLength\":3"))
        #expect(!text.contains(Synthetic.imsiLike) && !text.contains(Synthetic.ipv4))
        // It parses back.
        let back = try GoldenCodec.decodeFlow(Data(text.utf8))
        #expect(back.flow.events[0].fields[0].value == "<masked>")
        #expect(back.recordsPerCode == [0xB0ED: 1])
    }

    @Test func jsonDiffSemantics() {
        func d(_ a: String, _ b: String, ignoring: Set<String> = []) -> [String] {
            GoldenCodec.jsonDiff(Data(a.utf8), Data(b.utf8), ignoring: ignoring)
        }
        #expect(d(#"{"a":1.0001,"b":[1,2]}"#, #"{"a":1.0,"b":[1,2]}"#) == [])
        #expect(d(#"{"a":1.01}"#, #"{"a":1.0}"#) == ["a"])
        #expect(d(#"{"a":[1,2,3]}"#, #"{"a":[1,2]}"#) == ["a.length"])
        #expect(d(#"{"a":true}"#, #"{"a":1}"#) == ["a"], "a boolean is not a number")
        #expect(d(#"{"a":"x"}"#, #"{"a":null}"#) == ["a"])
        #expect(d(#"{"a":1}"#, #"{"b":1}"#) == ["a", "b"])
        #expect(d(#"{"source":{"file":"a"}}"#, #"{"source":{"file":"b"}}"#, ignoring: ["source.file"]) == [])
        #expect(d(#"{"e":[{"c":1},{"c":2}]}"#, #"{"e":[{"c":9},{"c":8}]}"#, ignoring: ["e.c"]) == [])
        #expect(d("not json", "{}") == ["<root>"])
    }
}
