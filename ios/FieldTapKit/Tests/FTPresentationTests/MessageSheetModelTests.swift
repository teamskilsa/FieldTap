// The message sheet's masking, on synthetic unmasked events (the golden is masked already and has no bytes, so a
// test on it alone could not fail) and on every event of the iPhone capture's golden.

import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTPresentation

/// Identifier-shaped values built at run time, so no tracked file carries one (privacy-gate.sh).
enum Synthetic {
    static let imsi = (0..<15).map { String(($0 * 7 + 3) % 10) }.joined()
    static let msisdn = "+1 " + (0..<3).map { String($0 + 2) }.joined() + " " + (0..<7).map { String(9 - $0) }.joined()
    static let ipv4 = [10, 20, 30, 40].map(String.init).joined(separator: ".")
    static let ipv6 = ["2001", "db8", "85a3", "0", "0", "8a2e", "370", "7334"].joined(separator: ":")
    static let tmsiHex = "0x" + String(repeating: "c0de", count: 2)
    static let pdu: [UInt8] = Array("imsi".utf8) + [0x21, 0x43, 0x65, 0x87, 0x09]

    static let cell = Cell(earfcn: 67_086, pci: 80)

    /// Events whose decoded fields, summaries and bytes carry every identifier shape the masking must catch.
    static func flow() -> Flow {
        let events = [
            event(0, "Identity response", layer: .NAS, channel: "EMM", cell: cell, uplink: true, summary: "IMSI " + imsi,
                  fields: [Field(label: "Mobile identity", value: "IMSI",
                                 children: [Field(label: "Type", value: "IMSI"), Field(label: "Digits", value: imsi)])],
                  pdu: pdu),
            event(1, "Activate default EPS bearer context request", layer: .NAS, channel: "ESM", cell: cell,
                  summary: "QCI 5 · ims · " + ipv6,
                  fields: [Field(label: "APN", value: "ims"),
                           Field(label: "PDN address", value: ipv4, children: [Field(label: "IPv4", value: ipv4)]),
                           Field(label: "P-CSCF", value: ipv6),
                           Field(label: "Note", value: "server " + ipv4 + " for " + msisdn)],
                  pdu: pdu),
            event(2, "RRC Connection Request", channel: "UL-CCCH", cell: cell, uplink: true, summary: "mo-Signalling",
                  fields: [Field(label: "UE identity", value: tmsiHex), Field(label: "Establishment cause", value: "mo-Signalling")],
                  pdu: pdu),
            {
                var e = event(3, "Attach request", layer: .NAS, channel: "EMM", cell: cell, uplink: true,
                              summary: "combined EPS/IMSI attach", pdu: pdu)
                e.protection = Protection(headerType: 1, mac: 0xDEAD_BEEF, sequence: 206)
                e.carrier = "UL Information Transfer to " + imsi
                return e
            }(),
        ]
        let info = ServingCellInfo(pci: 80, downlinkEarfcn: 67_086, uplinkEarfcn: 132_622, band: 66, plmn: "001-01",
                                   tac: 1_234, cellIdentity: 0x0A_BC12, bandwidthMhz: 10)
        return FTPresentationTests.flow(events, cellDetails: [CellDetail(cell: cell, info: info)])
    }
}

@Suite struct MessageSheetMaskingTests {
    @Test func syntheticIdentifiersAreMaskedEverywhere() {
        let flow = Synthetic.flow()
        #expect(MessageSheetModel.maskingAudit(flow).isEmpty, "\(MessageSheetModel.maskingAudit(flow))")
        for e in flow.events {
            let m = MessageSheetModel(event: e, flow: flow, reveal: false)
            #expect(!m.bytesVisible)
            #expect(m.hexDump == nil)
            #expect(m.bytesNote == MessageSheetModel.bytesHidden)
            for raw in [Synthetic.imsi, Synthetic.ipv4, Synthetic.ipv6, Synthetic.msisdn, Synthetic.tmsiHex,
                        CallFlowPresentation.hex(Synthetic.pdu)] {
                #expect(!m.copyText.contains(raw), "event \(e.index) copy text")
                #expect(!allText(m).contains(raw), "event \(e.index) sections")
            }
        }
        let identity = MessageSheetModel(event: flow.events[0], flow: flow, reveal: false)
        #expect(line(identity, "Decoded", "Digits") == Redaction.masked)
        #expect(identity.summary == "IMSI " + Redaction.masked)
        let bearer = MessageSheetModel(event: flow.events[1], flow: flow, reveal: false)
        #expect(line(bearer, "Decoded", "PDN address") == Redaction.masked)
        #expect(line(bearer, "Decoded", "P-CSCF") == Redaction.masked)
        #expect(line(bearer, "Decoded", "Note") == "server <masked> for <masked>")
        #expect(line(bearer, "Decoded", "APN") == "ims")
        let attach = MessageSheetModel(event: flow.events[3], flow: flow, reveal: false)
        #expect(line(attach, "Security", "MAC") == Redaction.masked)
        #expect(attach.carriedIn == "Carried in UL Information Transfer to <masked>")
    }

    @Test func theCellSectionMasksTrackingAreaAndCellIdentity() {
        let flow = Synthetic.flow()
        let masked = MessageSheetModel(event: flow.events[2], flow: flow, reveal: false)
        #expect(line(masked, "Cell", "Tracking area") == Redaction.masked)
        #expect(line(masked, "Cell", "Cell identity") == Redaction.masked)
        #expect(line(masked, "Cell", "eNB · cell") == nil)
        #expect(line(masked, "Cell", "PLMN") == "001-01")
        #expect(line(masked, "Cell", "Band") == "B66")
        #expect(line(masked, "Cell", "Bandwidth") == "10 MHz")
        let shown = MessageSheetModel(event: flow.events[2], flow: flow, reveal: true)
        #expect(line(shown, "Cell", "Tracking area") == "1234")
        #expect(line(shown, "Cell", "eNB · cell") == "2748 · 18")
    }

    @Test func revealShowsTheBytesAndTheAuditWouldCatchIt() {
        let flow = Synthetic.flow()
        let m = MessageSheetModel(event: flow.events[0], flow: flow, reveal: true)
        #expect(m.bytesVisible)
        #expect(m.bytesTitle == "Bytes · 9")
        // The second line's hex column is padded to 8 bytes' width (23 characters), then two spaces.
        #expect(m.hexDump == "0000  69 6d 73 69 21 43 65 87  imsi!Ce.\n0008  09" + String(repeating: " ", count: 23) + ".")
        #expect(m.copyText.contains(Synthetic.imsi))
        #expect(m.copyText.contains("0000  69 6d 73 69"))
        // The audit is not vacuous: on revealed sheets it finds every shape.
        let leaks = MessageSheetModel.audit(flow, reveal: true)
        for kind in ["10+ digits", "IPv4", "IPv6", "0x-hex", "bytes: visible"] {
            #expect(leaks.contains { $0.hasSuffix(kind) }, "audit misses \(kind)")
        }
    }

    @Test func theOneLineCopyIsMasked() {
        let flow = Synthetic.flow()
        let lanes = CallFlowPresentation.lanes(flow)
        #expect(MessageSheetModel.oneLine(flow.events[0], lanes: lanes, reveal: false)
            == "0:00.000 · UE → MME · Identity response · IMSI <masked>")
        #expect(MessageSheetModel.oneLine(flow.events[0], lanes: lanes, reveal: true).hasSuffix(Synthetic.imsi))
    }

    @Test func clocksAreNotMistakenForAddresses() {
        #expect(IdentifierShape.kinds(in: "Modem time (UTC): 2026-09-21 19:42:21.024").isEmpty)
        #expect(IdentifierShape.kinds(in: "Since start: 1:02:03.004").isEmpty)
        #expect(IdentifierShape.kinds(in: "PDN address: " + Synthetic.ipv6) == ["IPv6"])
        #expect(IdentifierShape.kinds(in: Synthetic.imsi) == ["10+ digits"])
    }

    @Test func utcTimesAreCivilDates() {
        #expect(MessageSheetModel.utcText(0) == "1970-01-01 00:00:00.000")
        #expect(MessageSheetModel.utcText(951_782_400_000) == "2000-02-29 00:00:00.000")
        #expect(MessageSheetModel.utcText(1_790_019_725_984) == "2026-09-21 19:42:05.984")
        #expect(MessageSheetModel.utcText(4_102_444_799_999) == "2099-12-31 23:59:59.999")
    }
}

/// The acceptance check on the iPhone capture: every one of its 128 events, masked.
@Suite struct GoldenSheetMaskingTests {
    @Test(.fixture("contract/callflow-golden.json"))
    func messageSheetMasking() throws {
        let flow = try goldenFlow()
        #expect(flow.events.count == 128)
        let leaks = MessageSheetModel.maskingAudit(flow)
        #expect(leaks.isEmpty, "\(leaks.prefix(10))")
        for e in flow.events {
            let masked = MessageSheetModel(event: e, flow: flow, reveal: false)
            #expect(!masked.bytesVisible && masked.hexDump == nil, "event \(e.index)")
            #expect(MessageSheetModel(event: e, flow: flow, reveal: true).bytesVisible, "event \(e.index)")
        }
    }

    @Test(.fixture("contract/callflow-golden.json"))
    func theIdentityCarryingEventsShowMasked() throws {
        let flow = try goldenFlow()
        func sheet(_ i: Int) -> MessageSheetModel { MessageSheetModel(event: flow.events[i], flow: flow, reveal: false) }
        // GUTI (events 2 and 10), UE identity (11), PDN address and P-CSCF (34 and 51).
        #expect(sheet(2).sections.first { $0.title == "Decoded" }?.lines.contains { $0.label == "M-TMSI" && $0.value == Redaction.masked } == true)
        #expect(line(sheet(10), "Decoded", "M-TMSI") == Redaction.masked)
        #expect(line(sheet(10), "Decoded", "Identity") == "GUTI")
        #expect(line(sheet(11), "Decoded", "UE identity") == Redaction.masked)
        #expect(line(sheet(34), "Decoded", "PDN address") == Redaction.masked)
        #expect(line(sheet(34), "Decoded", "DNS server") == Redaction.masked)
        #expect(line(sheet(51), "Decoded", "P-CSCF") == Redaction.masked)
        #expect(line(sheet(10), "Cell", "Tracking area") == Redaction.masked)
        #expect(line(sheet(10), "Cell", "Cell identity") == Redaction.masked)
        #expect(line(sheet(10), "Security", "Sequence number") == "206")
    }

    @Test(.fixture("contract/callflow-golden.json"))
    func theIdentityResponseHidesItsBytes() throws {
        // Event 18 decodes to no fields at all; the IMEISV it carries is only in the bytes, which stay hidden.
        let flow = try goldenFlow()
        let m = MessageSheetModel(event: flow.events[18], flow: flow, reveal: false)
        #expect(m.title == "Identity response")
        #expect(!m.bytesVisible && m.hexDump == nil)
        #expect(m.bytesNote == MessageSheetModel.bytesHidden)
        #expect(m.copyText.contains("Bytes hidden while identifiers are masked"))
        #expect(m.sections.first { $0.title == "Decoded" }?.note
            == MessageSheetModel.nothingDecoded + " " + MessageSheetModel.bytesElsewhere)
        let shown = MessageSheetModel(event: flow.events[18], flow: flow, reveal: true)
        #expect(shown.sections.first { $0.title == "Decoded" }?.note == MessageSheetModel.nothingDecoded)
        #expect(m.tags == ["LTE NAS", "EMM", "UE → Core"])
        #expect(IdentifierShape.kinds(in: m.copyText).isEmpty)
    }

    @Test(.fixture("contract/callflow-golden.json"))
    func theHandoverAndThePendingNrCell() throws {
        let flow = try goldenFlow()
        let ho = MessageSheetModel(event: flow.events[82], flow: flow, reveal: false)
        #expect(ho.title == "RRC Connection Reconfiguration")
        #expect(line(ho, "Decoded", "Handover") == "to PCI 235, EARFCN 5110")
        #expect(line(ho, "Cell", "Band") == "B66")
        #expect(line(ho, "Cell", "Downlink") == "2175.0 MHz")
        #expect(line(ho, "When", "Since start") == CallFlowPresentation.sinceStart(flow.events[82].sinceStartMs))
        #expect(line(ho, "When", "Modem time (UTC)")?.hasPrefix("2026-09-21 19:42:") == true)
        let nr = MessageSheetModel(event: flow.events[73], flow: flow, reveal: false)
        #expect(line(nr, "Cell", "PCI") == "pending")
        #expect(line(nr, "Cell", "NR-ARFCN") == "pending")
        #expect(nr.sections.first { $0.title == "Cell" }?.note == MessageSheetModel.pendingNr)
        #expect(nr.tags[0] == "NR RRC")
    }
}

func line(_ m: MessageSheetModel, _ section: String, _ label: String) -> String? {
    m.sections.first { $0.title == section }?.lines.first { $0.label == label }?.value
}

func allText(_ m: MessageSheetModel) -> String {
    ([m.title, m.summary ?? "", m.carriedIn ?? "", m.bytesTitle, m.bytesNote ?? "", m.hexDump ?? "", m.source] + m.tags
        + m.sections.flatMap { s in [s.title, s.note ?? ""] + s.lines.flatMap { [$0.label, $0.value] } })
        .joined(separator: "\n")
}
