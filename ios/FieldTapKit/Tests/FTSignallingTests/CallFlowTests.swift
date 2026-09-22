// Port of android/diag/src/test/kotlin/com/fieldtap/diag/CallFlowTest.kt at contract v1: the 29 tests of repo
// main plus WP1's three contract-delta tests (D1, D3 twice), with the same inline bytes. The two OnePlus
// captures come from FT_FIXTURES/oneplus instead of the Android test resources.

import Foundation
import Testing
import FTCore
import FTModel
import FTTestSupport
@testable import FTSignalling

/// Constructed records on a running clock, as the Kotlin test's `record()` helpers build them. One per test.
final class Capture {
    private var clockMs: Int64 = 1_000_000_000

    func record(_ code: UInt16, _ body: [UInt8], afterMs: Int64 = 20) -> LogRecord {
        clockMs += afterMs
        return LogRecord(code: code, timestampRaw: UInt64(clockMs * 4 / 5) << 16, body: body)
    }

    static let ulCcch = 10, dlCcch = 8, ulDcch = 11, dlDcch = 9, bcch = 3

    /// A version-27 (SM8450) LTE RRC OTA record body: the layout the real capture uses.
    static func rrc(_ cell: Cell, _ pdu: Int, _ payload: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 21)
        header[0] = 27
        func put16(_ at: Int, _ v: Int) {
            header[at] = UInt8(truncatingIfNeeded: v)
            header[at + 1] = UInt8(truncatingIfNeeded: v >> 8)
        }
        put16(1 + 5, cell.pci)
        put16(1 + 7, Int(cell.earfcn))
        put16(1 + 9, 0)
        header[1 + 13] = UInt8(pdu)
        put16(1 + 18, payload.count)
        return header + payload
    }

    /// A version-26 (iPhone 17) NR RRC OTA record body: 4-byte version, the 31-byte header of layout E, the PDU.
    static func nrRrc(_ cell: Cell, _ pdu: Int, _ payload: [UInt8]) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 4 + 31)
        body[0] = 26
        func put(_ at: Int, _ v: Int64, _ width: Int) {
            for i in 0..<width { body[4 + at + i] = UInt8(truncatingIfNeeded: v >> (8 * Int64(i))) }
        }
        put(2, 1, 1)
        put(3, Int64(cell.pci), 2)
        put(13, cell.earfcn, 4)
        put(20, Int64(pdu), 1)
        put(25, Int64(payload.count), 2)
        return body + payload
    }

    func request(_ cell: Cell) -> LogRecord {
        record(0xB0C0, Self.rrc(cell, Self.ulCcch, bits("0 1 0 0 00000001 11110101 00011010 01100010 10101101 100 0")))
    }
    func setup(_ cell: Cell) -> LogRecord { record(0xB0C0, Self.rrc(cell, Self.dlCcch, bits("0 11 0000"))) }
    func setupComplete(_ cell: Cell) -> LogRecord { record(0xB0C0, Self.rrc(cell, Self.ulDcch, bits("0 0100 000"))) }
    func handoverTo2(_ cell: Cell) -> LogRecord {
        record(0xB0C0, Self.rrc(cell, Self.dlDcch, hex("22082004 0b228246 80000000 0000")))
    }
    func reconfigurationComplete(_ cell: Cell) -> LogRecord { record(0xB0C0, Self.rrc(cell, Self.ulDcch, bits("0 0010 000"))) }
    func release(_ cell: Cell) -> LogRecord { record(0xB0C0, Self.rrc(cell, Self.dlDcch, hex("2801"))) }
    func releaseRedirect(_ cell: Cell) -> LogRecord { record(0xB0C0, Self.rrc(cell, Self.dlDcch, hex("282200a280"))) }
    func reestablishment(_ cell: Cell) -> LogRecord { record(0xB0C0, Self.rrc(cell, Self.ulCcch, hex("0246802abcd4"))) }
    func sib1(_ cell: Cell) -> LogRecord { record(0xB0C0, Self.rrc(cell, Self.bcch, bits("0 1 000000")), afterMs: 800) }

    func connected(_ cell: Cell) -> [LogRecord] { [request(cell), setup(cell), setupComplete(cell)] }

    /// An LTE reconfiguration that is not a handover: it carries radio resources only.
    func reconfiguration(_ cell: Cell) -> LogRecord {
        record(0xB0C0, Self.rrc(cell, Self.dlDcch, bits("0 0100 00 0 000 0 0 0 1 0 0")))
    }
    func nrReconfiguration(_ cell: Cell) -> LogRecord { record(0xB821, Self.nrRrc(cell, 11, hex("0800")), afterMs: 1) }
    func nrReconfigurationComplete(_ cell: Cell) -> LogRecord {
        record(0xB821, Self.nrRrc(cell, 12, hex("0000")), afterMs: 1)
    }

    func nas(_ code: UInt16, _ pdu: String) -> LogRecord { record(code, hex("01000000 " + pdu), afterMs: 1) }

    /// A record stamped `gpsMs` after the GPS epoch, in the modem's 1.25 ms ticks.
    static func stamped(_ gpsMs: Int64, _ record: LogRecord) -> LogRecord {
        var r = record
        r.timestampRaw = UInt64(gpsMs * 4 / 5) << 16
        return r
    }

    /// One log packet, HDLC-framed as a capture holds it.
    static func framed(_ code: UInt16, _ body: [UInt8], timestampRaw: UInt64 = 42) -> [UInt8] {
        Hdlc.encode(DiagProtocol.encodeLogPacket(LogRecord(code: code, timestampRaw: timestampRaw, body: body)))
    }
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

@Suite struct CallFlowTests {
    private let a = Cell(earfcn: 1575, pci: 3)
    private let b = Cell(earfcn: 2850, pci: 2)
    private let c = Cell(earfcn: 1300, pci: 4)

    // MARK: - The real capture

    @Test(.fixture(OnePlus.callboxPath))
    func eachNasMessageIsOneRowWithItsProtectedCopyFolded() throws {
        guard Fixtures.require(OnePlus.callboxPath) != nil, let fixture = OnePlus.callboxFlow else { return }
        // 26 records: 13 LTE RRC, 9 LTE NAS of which 4 are the protected copies of 4 others, 1 NR RRC, 3 NR NAS.
        #expect(fixture.records == 26)
        #expect(fixture.events.map(\.key) == [
            "Service request", "rrcConnectionRequest", "rrcConnectionSetup", "rrcConnectionSetupComplete",
            "securityModeCommand", "securityModeComplete", "rrcConnectionReconfiguration",
            "rrcConnectionReconfigurationComplete", "PDN connectivity request", "ulInformationTransfer",
            "rrcConnectionReconfiguration", "rrcConnectionReconfigurationComplete",
            "Activate default EPS bearer context request", "Activate default EPS bearer context accept",
            "ulInformationTransfer", "Detach request", "ulInformationTransfer", "rrcConnectionRelease",
        ])
        #expect(fixture.undecoded == 4)
        #expect(fixture.failures == 0)
    }

    @Test(.fixture(OnePlus.callboxPath))
    func theProtectedCopyGivesTheRowWiresharksMacAndSequenceNumber() throws {
        guard Fixtures.require(OnePlus.callboxPath) != nil, let fixture = OnePlus.callboxFlow else { return }
        // Wireshark, frame 11 (the copy of frame 10): integrity protected and ciphered, MAC 053b cb66, sequence 46.
        let request = try #require(fixture.events.first { $0.key == "PDN connectivity request" })
        #expect(request.protection == Protection(headerType: 2, mac: 0x053b_cb66, sequence: 46))
        #expect(request.protection?.headerName == "integrity protected and ciphered")
        // Frame 15 is the copy of frame 16 even though it came first and is logged as EMM.
        let bearer = try #require(fixture.events.first { $0.key == "Activate default EPS bearer context request" })
        #expect(bearer.protection == Protection(headerType: 2, mac: 0xca66_6570, sequence: 32))
        #expect(!bearer.uplink)
        #expect(fixture.events.allSatisfy { !$0.ciphered })
    }

    @Test(.fixture(OnePlus.callboxPath))
    func rowsCarryTheLineAnEngineerLooksFor() throws {
        guard Fixtures.require(OnePlus.callboxPath) != nil, let fixture = OnePlus.callboxFlow else { return }
        // Kotlin's associateBy: the last event with a key wins.
        let byKey = Dictionary(fixture.events.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        #expect(byKey["rrcConnectionRequest"]?.summary == "mo-Data")
        #expect(byKey["rrcConnectionRelease"]?.summary == "other")
        #expect(byKey["PDN connectivity request"]?.summary == "ims")
        #expect(byKey["Activate default EPS bearer context request"]?.summary
            == "QCI 5 · ims.mnc001.mcc001.gprs · " + dotted("192 168 4 2"))
        #expect(byKey["Detach request"]?.summary == "combined EPS/IMSI detach · switch off")
        #expect(byKey["Service request"]?.name == "Service request")
        #expect(byKey["rrcConnectionRequest"]?.name == "RRC Connection Request")
    }

    @Test(.fixture(OnePlus.callboxPath))
    func nasRowsTakeTheCellOfTheRrcAroundThem() throws {
        guard Fixtures.require(OnePlus.callboxPath) != nil, let fixture = OnePlus.callboxFlow else { return }
        #expect(fixture.events.allSatisfy { $0.cell == Cell(earfcn: 1575, pci: 3) })
    }

    @Test(.fixture(OnePlus.callboxPath))
    func timesMatchWiresharksExport() throws {
        guard Fixtures.require(OnePlus.callboxPath) != nil, let fixture = OnePlus.callboxFlow else { return }
        // Wireshark: frame 1 at 23:43:19.718214 UTC, frame 3 (RRCConnectionSetup) 63.771 ms later, release at
        // 23:45:18.056639.
        #expect(fixture.startUtcMs == 1_789_602_199_718)
        let setup = try #require(fixture.events.first { $0.key == "rrcConnectionSetup" })
        #expect(near(setup.sinceStartMs, 63.771))
        let release = try #require(fixture.events.last)
        #expect(near(release.sinceStartMs, 118_338.425))
    }

    @Test(.fixture(OnePlus.callboxPath))
    func theProceduresAndHowLongEachTook() throws {
        guard Fixtures.require(OnePlus.callboxPath) != nil, let fixture = OnePlus.callboxFlow else { return }
        #expect(fixture.procedures.map { "\($0.name) \($0.outcome)" } == [
            "Service request SUCCEEDED",
            "RRC connection setup SUCCEEDED",
            "AS security SUCCEEDED",
            "RRC reconfiguration SUCCEEDED",
            "PDN connectivity SUCCEEDED",
            "RRC reconfiguration SUCCEEDED",
            "Detach SUCCEEDED",
        ])
        let setup = try #require(fixture.procedures.first { $0.name == "RRC connection setup" })
        #expect(setup.detail == "mo-Data")
        // Wireshark: request 19.718709, setup complete 19.786229.
        #expect(near(setup.durationMs, 67.52))
        // Service request to the RAN starting security: 19.718214 -> 19.816842.
        let service = try #require(fixture.procedures.first)
        #expect(near(service.durationMs, 98.63))
        // PDN connectivity request 19.850832 -> default bearer accept 19.880320.
        let pdn = try #require(fixture.procedures.first { $0.name == "PDN connectivity" })
        #expect(near(pdn.durationMs, 29.49))
        let detach = try #require(fixture.procedures.last)
        #expect(detach.durationMs == 0)
    }

    @Test(.fixture(OnePlus.callboxPath))
    func oneCellAndOneConnection() throws {
        guard Fixtures.require(OnePlus.callboxPath) != nil, let fixture = OnePlus.callboxFlow else { return }
        // The step starts at the service request, the NAS message that brought the connection up on this cell.
        #expect(fixture.journey == [
            Step(move: .FIRST_SEEN, from: nil, to: Cell(earfcn: 1575, pci: 3), event: 0,
                 sinceStartMs: fixture.events[1].sinceStartMs),
        ])
        #expect(fixture.connections.count == 1)
        let connection = try #require(fixture.connections.first)
        #expect(connection.outcome == .RELEASED)
        #expect(connection.establishmentCause == "mo-Data")
        #expect(connection.releaseCause == "other")
        #expect(connection.first == 1)
        #expect(connection.last == 17)
    }

    // MARK: - A real 5G registration attempt

    @Test(.fixture(OnePlus.fiveGPath))
    func theFiveGNasComesOutOfTheRrcThatCarriedIt() throws {
        guard Fixtures.require(OnePlus.fiveGPath) != nil, let fiveG = OnePlus.fiveGFlow else { return }
        // The modem logs the plain NAS too (0xB80B, 0xB80A); that copy is the row, placed where it was logged:
        // the registration request before the RRC connection it caused.
        #expect(fiveG.events.map(\.key) == [
            "mib", "systemInformationBlockType1", "Registration request", "rrcSetupRequest", "rrcSetup",
            "rrcSetupComplete", "dlInformationTransfer", "Registration reject", "rrcRelease", "paging", "paging",
        ])
        let request = try #require(fiveG.events.first { $0.key == "Registration request" })
        #expect(request.layer == .NAS)
        #expect(request.rat == "nr")
        #expect(request.uplink)
        #expect(request.carrier == "RRC Setup Complete")
        #expect(request.summary == "initial registration")
        #expect(request.cell == Cell(earfcn: 647_328, pci: 417, nr: true))
        let reject = try #require(fiveG.events.first { $0.key == "Registration reject" })
        #expect(!reject.uplink)
        #expect(reject.summary == "#27 N1 mode not allowed")
        #expect(reject.carrier == "DL Information Transfer")
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func theFiveGProceduresAreTheRrcSetupAndTheRefusedRegistration() throws {
        guard Fixtures.require(OnePlus.fiveGPath) != nil, let fiveG = OnePlus.fiveGFlow else { return }
        let byName = Dictionary(fiveG.procedures.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        #expect(byName["RRC connection setup"]?.outcome == .SUCCEEDED)
        #expect(byName["RRC connection setup"]?.detail == "mo-Signalling")
        let registration = try #require(byName["Registration"])
        #expect(registration.outcome == .FAILED)
        #expect(registration.refusal == "#27 N1 mode not allowed")
        #expect(fiveG.failures == 1)
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func theFiveGCellsAreNrCellsAndThePagingCameFromAnother() throws {
        guard Fixtures.require(OnePlus.fiveGPath) != nil, let fiveG = OnePlus.fiveGFlow else { return }
        #expect(fiveG.journey.map(\.move) == [.FIRST_SEEN, .RESELECTION])
        #expect(fiveG.journey.map(\.to) == [Cell(earfcn: 647_328, pci: 417, nr: true), Cell(earfcn: 501_390, pci: 152, nr: true)])
        #expect(fiveG.connections.map(\.outcome) == [.RELEASED])
    }

    @Test(.fixture(OnePlus.fiveGPath))
    func theServingCellRecordNamesTheCallboxCell() throws {
        guard Fixtures.require(OnePlus.fiveGPath) != nil, let fiveG = OnePlus.fiveGFlow else { return }
        // The LTE serving-cell record in the same file: the callbox cell the phone had been camped on.
        let callbox = try #require(fiveG.cellInfo(for: Cell(earfcn: 6_300, pci: 8)))
        #expect(callbox.plmn == "001-01")
        #expect(callbox.enb == 107_216)
        #expect(callbox.tac == 1)
    }

    // MARK: - Mobility, from constructed records

    @Test func aHandoverIsTheCellChangeAfterAHandoverCommand() throws {
        let r = Capture()
        let flow = CallFlowReader.of(r.connected(a) + [r.handoverTo2(a), r.reconfigurationComplete(b), r.release(b)])
        #expect(flow.journey.map(\.move) == [.FIRST_SEEN, .HANDOVER])
        #expect(flow.journey.map(\.to) == [a, b])
        #expect(flow.journey[1].from == a)
        #expect(flow.events[3].summary == "handover to PCI 2, EARFCN 2850")
        let handover = try #require(flow.procedures.first { $0.name == "Handover" })
        #expect(handover.outcome == .SUCCEEDED)
        #expect(near(handover.durationMs, 20.0))
    }

    @Test func aReestablishmentOnAnotherCellFailsTheHandover() throws {
        let r = Capture()
        let flow = CallFlowReader.of(r.connected(a) + [r.handoverTo2(a), r.reestablishment(c)])
        #expect(flow.journey.last?.move == .REESTABLISHMENT)
        #expect(flow.journey.last?.to == c)
        #expect(flow.procedures.first { $0.name == "Handover" }?.outcome == .FAILED)
        #expect(flow.procedures.first { $0.name == "RRC re-establishment" }?.outcome == .UNANSWERED)
        #expect(flow.events.last?.summary == "handoverFailure")
    }

    @Test func aCellChangeWhileIdleIsAReselection() {
        let r = Capture()
        let flow = CallFlowReader.of(r.connected(a) + [r.release(a), r.sib1(a), r.sib1(b), r.request(b)])
        #expect(flow.journey.map(\.move) == [.FIRST_SEEN, .RESELECTION])
        #expect(flow.journey.last?.to == b)
        #expect(flow.connections.map(\.outcome) == [.RELEASED, .NO_ANSWER])
        #expect(flow.procedures.last?.outcome == .UNANSWERED)
    }

    @Test func systemInformationReadWhileSearchingIsNotWhereThePhoneWas() {
        // What the phone logged when the callbox went away: SIB1 from every cell it could hear, then unanswered
        // requests on one of them, then a request that was answered.
        let x = Cell(earfcn: 1450, pci: 403)
        let y = Cell(earfcn: 5230, pci: 417)
        let r = Capture()
        let flow = CallFlowReader.of(
            r.connected(a) + [r.release(a), r.sib1(x), r.sib1(y), r.sib1(b), r.sib1(x), r.request(b), r.request(b)]
                + r.connected(b))
        #expect(flow.journey.map(\.move) == [.FIRST_SEEN, .RESELECTION])
        #expect(flow.journey.map(\.to) == [a, b])
        #expect(flow.searched == [x, y])
        #expect(flow.connections.map(\.outcome) == [.RELEASED, .NO_ANSWER, .NO_ANSWER, .OPEN_AT_END])
    }

    @Test func aNewRequestWithNoReleaseEndsTheConnectionAsLost() {
        let r = Capture()
        let flow = CallFlowReader.of(r.connected(a) + [r.reconfigurationComplete(a), r.request(a), r.setup(a), r.release(a)])
        #expect(flow.connections.map(\.outcome) == [.LOST, .RELEASED])
        #expect(flow.connections.first?.last == 3)
        #expect(flow.journey.map(\.move) == [.FIRST_SEEN])
    }

    @Test func nasSentAfterAReselectionIsOnTheNewCellAndStartsTheStep() throws {
        // As logged: release on A, then the TAU request (NAS, uplink) before the RRC request on B, then the
        // reject (NAS, downlink) after the release on B.
        let r = Capture()
        let flow = CallFlowReader.of(
            r.connected(a) + [r.release(a)]
                + [r.nas(0xB0ED, "0748010b"), r.request(b), r.setup(b), r.setupComplete(b), r.release(b), r.nas(0xB0EC, "074b09")])
        let tau = try #require(flow.events.first { $0.key == "Tracking area update request" })
        #expect(tau.cell == b)
        #expect(flow.events.last?.cell == b)
        #expect(flow.journey.last?.event == tau.index)
        #expect(flow.journey.last?.move == .RESELECTION)
    }

    @Test func aRequestOnANewCellAfterALostConnectionIsAReselection() {
        // The callbox went away mid-connection: no release, then a request on another cell.
        let r = Capture()
        let flow = CallFlowReader.of(r.connected(a) + [r.reconfigurationComplete(a), r.request(c)])
        #expect(flow.journey.map(\.move) == [.FIRST_SEEN, .RESELECTION])
    }

    @Test func aCellChangeAfterARedirectingReleaseIsARedirect() {
        let r = Capture()
        let flow = CallFlowReader.of(r.connected(a) + [r.releaseRedirect(a), r.request(c)])
        #expect(flow.journey.map(\.move) == [.FIRST_SEEN, .REDIRECT])
        #expect(flow.events[3].summary == "other · redirect to EUTRA EARFCN 1300")
    }

    @Test func aConnectionAlreadyUpWhenTheCaptureStartedStillCounts() throws {
        let r = Capture()
        let flow = CallFlowReader.of([r.reconfigurationComplete(a), r.release(a)])
        #expect(flow.connections.count == 1)
        let connection = try #require(flow.connections.first)
        #expect(connection.outcome == .RELEASED)
        #expect(connection.first == 0)
        #expect(connection.establishmentCause == nil)
    }

    // MARK: - Contract v1: what an iPhone trace needs (ios/Contract/CONTRACT.md, D1 and D3)

    /// Kotlin's `Flow.reconfigurations()`: each RRC reconfiguration procedure's RAT and outcome.
    private func reconfigurations(_ flow: Flow) -> [String] {
        flow.procedures.filter { $0.name == "RRC reconfiguration" }.map { "\(flow.events[$0.first].rat) \($0.outcome)" }
    }

    private let scg = Cell(earfcn: 174_770, pci: 80, nr: true)

    @Test func recordsBeforeNetworkTimeDoNotSetTheBaseline() {
        // An iPhone trace opens with records the modem stamped before it had network time, counted from 1980.
        // Measured from those, every event sat 46 years after the start and the trace had no wall-clock time.
        let early = LogRecord(code: 0xB193, timestampRaw: UInt64(1_000 * 4 / 5) << 16, body: [0, 0, 0, 0])
        let t0: Int64 = 1_474_054_925_000 // 2026-09-21 19:42:05 UTC, in GPS milliseconds
        let r = Capture()
        let flow = CallFlowReader.of([early] + r.connected(a).enumerated().map { i, rec in Capture.stamped(t0 + 20 * Int64(i), rec) })
        #expect(flow.records == 4)
        #expect(flow.startUtcMs == 1_790_019_725_000)
        #expect(near(flow.durationMs, 40.0, 0.001))
        #expect(flow.events.map(\.sinceStartMs) == [0.0, 20.0, 40.0])
    }

    @Test func anNrReconfigurationInsideAnLteOneIsAnsweredOnItsOwnRat() throws {
        // EN-DC: the NR RRCReconfiguration rides inside the LTE one and the modem logs both. Each is answered by
        // the complete on its own RAT; the NR start must not close the LTE one as unanswered.
        let r = Capture()
        let flow = CallFlowReader.of(r.connected(a) + [
            r.reconfiguration(a), r.nrReconfiguration(scg), r.nrReconfigurationComplete(scg), r.reconfigurationComplete(a),
        ])
        #expect(reconfigurations(flow) == ["lte SUCCEEDED", "nr SUCCEEDED"])
        let lte = try #require(flow.procedures.first { $0.name == "RRC reconfiguration" })
        #expect(lte.first == 3)
        #expect(lte.last == 6)
    }

    @Test func aSecondStartOnTheSameRatStillMeansTheFirstWentUnanswered() {
        let r = Capture()
        let flow = CallFlowReader.of(r.connected(a) + [
            r.reconfiguration(a), r.nrReconfiguration(scg), r.reconfiguration(a), r.nrReconfigurationComplete(scg),
            r.reconfigurationComplete(a),
        ])
        #expect(reconfigurations(flow) == ["lte UNANSWERED", "nr SUCCEEDED", "lte SUCCEEDED"])
    }

    // MARK: - NAS

    @Test func aRejectFailsItsProcedureAndCarriesTheCause() throws {
        // Attach request (a constructed IMSI), then Attach reject #15 "No suitable cells in tracking area".
        let r = Capture()
        let flow = CallFlowReader.of([
            r.nas(0xB0ED, "07417208 09101000 00000000"),
            r.nas(0xB0EC, "07440f"),
        ])
        #expect(flow.procedures.count == 1)
        let attach = try #require(flow.procedures.first)
        #expect(attach.name == "Attach")
        #expect(attach.outcome == .FAILED)
        #expect(attach.refusal?.hasPrefix("#15 ") == true)
        let reject = try #require(flow.events.last)
        #expect(reject.isFailure)
        #expect(reject.cause == 15)
        #expect(reject.summary?.hasPrefix("#15 ") == true)
        #expect(flow.failures == 1)
    }

    @Test func aProtectedCopyWithNoPlainTwinStaysAsItsOwnRow() throws {
        // Ciphered, and the inner bytes are not a NAS message.
        let r = Capture()
        let flow = CallFlowReader.of([r.nas(0xB0EB, "27010203 04051122 3344")])
        #expect(flow.events.count == 1)
        let row = try #require(flow.events.first)
        #expect(row.ciphered)
        #expect(row.name == "Ciphered EMM message")
        #expect(row.protection == Protection(headerType: 2, mac: 0x0102_0304, sequence: 5))
    }

    @Test func aProtectedCopyThatReadsIsNamedFromInside() throws {
        // Only the protected copy was logged, deciphered: a Detach accept.
        let r = Capture()
        let flow = CallFlowReader.of([r.nas(0xB0EA, "27aabbccdd070746")])
        #expect(flow.events.count == 1)
        let row = try #require(flow.events.first)
        #expect(row.name == "Detach accept")
        #expect(!row.ciphered)
        #expect(row.protection?.sequence == 7)
    }

    // MARK: - From framed bytes (carried over from the NAS-only reader this replaces)

    @Test func theLteAttachRejectFromTheReferenceHandsetIsAFailureWithItsCause() throws {
        let flow = CallFlowReader.read(qmdl: Data(Capture.framed(0xB0EC, hex("01090500 074407"))))
        #expect(flow.events.count == 1)
        let event = try #require(flow.events.first)
        #expect(event.name == "Attach reject")
        #expect(event.channel == "EMM")
        #expect(!event.uplink)
        #expect(event.cause == 7)
        #expect(event.causeName == "EPS services not allowed")
        #expect(event.summary == "#7 EPS services not allowed")
    }

    @Test func theFiveGRegistrationRejectIsReadWithItsCause() throws {
        let flow = CallFlowReader.read(qmdl: Data(Capture.framed(0xB80A, hex("010000000f04007e00441b16012c"))))
        #expect(flow.events.count == 1)
        let event = try #require(flow.events.first)
        #expect(event.name == "Registration reject")
        #expect(event.rat == "nr")
        #expect(event.cause == 27)
        #expect(event.causeName == "N1 mode not allowed")
    }

    @Test func aRecordWithNoNasInItIsCountedRatherThanShownAsAMessage() {
        // What the SM8450 logs under 0xB80C on this callbox: a state struct (PLMN 001-01, then padding), not a PDU.
        // The NAS-only reader showed these as "ciphered 5GMM message" rows; there was no message.
        let flow = CallFlowReader.read(qmdl: Data(Capture.framed(0xB80C, hex("01000000 01020000 f110ffff ffffffff ffffffff ffff0100 0000"))))
        #expect(flow.events.isEmpty)
        #expect(flow.undecoded == 1)
    }

    @Test func aCorruptFrameIsCountedAndTheRestStillRead() {
        let good = Capture.framed(0xB0EC, hex("01090500 074407"))
        var bad = good
        bad[1] = bad[1] &+ 1
        let flow = CallFlowReader.read(qmdl: Data(bad + good))
        #expect(flow.events.count == 1)
        #expect(flow.crcErrors == 1)
    }

    @Test func anEmptyCaptureIsAnEmptyFlowRatherThanAFailure() {
        let flow = CallFlowReader.read(qmdl: Data())
        #expect(flow.records == 0)
        #expect(flow.events.isEmpty)
        #expect(flow.startUtcMs == nil)
    }

    @Test func aModemWithoutNetworkTimeHasNoWallClock() {
        #expect(TimeBase.utcMs(1 << 16) == nil)
        #expect(TimeBase.utcMs(0) == nil)
    }
}
