package com.fieldtap.diag

import com.fieldtap.diag.CallFlow.Move
import com.fieldtap.diag.CallFlow.Outcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CallFlowTest {

    // MARK: - The real capture

    private val fixture: CallFlow.Flow by lazy {
        CallFlow.read(javaClass.getResourceAsStream("/oneplus-callbox-service-request.qmdl")!!.readBytes())
    }

    @Test
    fun eachNasMessageIsOneRowWithItsProtectedCopyFolded() {
        // 26 records: 13 LTE RRC, 9 LTE NAS of which 4 are the protected copies of 4 others, 1 NR RRC, 3 NR NAS.
        assertEquals(26, fixture.records)
        assertEquals(
            listOf(
                "Service request", "rrcConnectionRequest", "rrcConnectionSetup", "rrcConnectionSetupComplete",
                "securityModeCommand", "securityModeComplete", "rrcConnectionReconfiguration",
                "rrcConnectionReconfigurationComplete", "PDN connectivity request", "ulInformationTransfer",
                "rrcConnectionReconfiguration", "rrcConnectionReconfigurationComplete",
                "Activate default EPS bearer context request", "Activate default EPS bearer context accept",
                "ulInformationTransfer", "Detach request", "ulInformationTransfer", "rrcConnectionRelease",
            ),
            fixture.events.map { it.key },
        )
        assertEquals(4, fixture.undecoded)
        assertEquals(0, fixture.failures)
    }

    @Test
    fun theProtectedCopyGivesTheRowWiresharksMacAndSequenceNumber() {
        // Wireshark, frame 11 (the copy of frame 10): integrity protected and ciphered, MAC 0x053bcb66, sequence 46.
        val request = fixture.events.first { it.key == "PDN connectivity request" }
        assertEquals(CallFlow.Protection(2, 0x053bcb66, 46), request.protection)
        assertEquals("integrity protected and ciphered", request.protection!!.headerName)
        // Frame 15 is the copy of frame 16 even though it came first and is logged as EMM.
        val bearer = fixture.events.first { it.key == "Activate default EPS bearer context request" }
        assertEquals(CallFlow.Protection(2, 0xca666570, 32), bearer.protection)
        assertFalse(bearer.uplink)
        assertTrue(fixture.events.none { it.ciphered })
    }

    @Test
    fun rowsCarryTheLineAnEngineerLooksFor() {
        val byKey = fixture.events.associateBy { it.key }
        assertEquals("mo-Data", byKey.getValue("rrcConnectionRequest").summary)
        assertEquals("other", byKey.getValue("rrcConnectionRelease").summary)
        assertEquals("ims", byKey.getValue("PDN connectivity request").summary)
        assertEquals("QCI 5 · ims.mnc001.mcc001.gprs · 192.168.4.2", byKey.getValue("Activate default EPS bearer context request").summary)
        assertEquals("combined EPS/IMSI detach · switch off", byKey.getValue("Detach request").summary)
        assertEquals("Service request", byKey.getValue("Service request").name)
        assertEquals("RRC Connection Request", byKey.getValue("rrcConnectionRequest").name)
    }

    @Test
    fun nasRowsTakeTheCellOfTheRrcAroundThem() {
        assertTrue(fixture.events.all { it.cell == CallFlow.Cell(1575, 3) })
    }

    @Test
    fun timesMatchWiresharksExport() {
        // Wireshark: frame 1 at 23:43:19.718214 UTC, frame 3 (RRCConnectionSetup) 63.771 ms later, release at 23:45:18.056639.
        assertEquals(1_789_602_199_718L, fixture.startUtcMs)
        val setup = fixture.events.first { it.key == "rrcConnectionSetup" }
        assertEquals(63.771, setup.sinceStartMs, 0.01)
        val release = fixture.events.last()
        assertEquals(118_338.425, release.sinceStartMs, 0.01)
    }

    @Test
    fun theProceduresAndHowLongEachTook() {
        assertEquals(
            listOf(
                "Service request" to Outcome.SUCCEEDED,
                "RRC connection setup" to Outcome.SUCCEEDED,
                "AS security" to Outcome.SUCCEEDED,
                "RRC reconfiguration" to Outcome.SUCCEEDED,
                "PDN connectivity" to Outcome.SUCCEEDED,
                "RRC reconfiguration" to Outcome.SUCCEEDED,
                "Detach" to Outcome.SUCCEEDED,
            ),
            fixture.procedures.map { it.name to it.outcome },
        )
        val setup = fixture.procedures.first { it.name == "RRC connection setup" }
        assertEquals("mo-Data", setup.detail)
        // Wireshark: request 19.718709, setup complete 19.786229.
        assertEquals(67.52, setup.durationMs, 0.01)
        // Service request to the RAN starting security: 19.718214 → 19.816842.
        assertEquals(98.63, fixture.procedures.first().durationMs, 0.01)
        // PDN connectivity request 19.850832 → default bearer accept 19.880320.
        assertEquals(29.49, fixture.procedures.first { it.name == "PDN connectivity" }.durationMs, 0.01)
        assertEquals(0.0, fixture.procedures.last().durationMs, 0.0)
    }

    @Test
    fun oneCellAndOneConnection() {
        // The step starts at the service request, the NAS message that brought the connection up on this cell.
        assertEquals(listOf(CallFlow.Step(Move.FIRST_SEEN, null, CallFlow.Cell(1575, 3), 0, fixture.events[1].sinceStartMs)), fixture.journey)
        val connection = fixture.connections.single()
        assertEquals(CallFlow.ConnectionOutcome.RELEASED, connection.outcome)
        assertEquals("mo-Data", connection.establishmentCause)
        assertEquals("other", connection.releaseCause)
        assertEquals(1, connection.first)
        assertEquals(17, connection.last)
    }

    // MARK: - A real 5G registration attempt

    private val fiveG: CallFlow.Flow by lazy {
        CallFlow.read(javaClass.getResourceAsStream("/oneplus-5g-registration.qmdl")!!.readBytes())
    }

    @Test
    fun theFiveGNasComesOutOfTheRrcThatCarriedIt() {
        assertEquals(
            // The modem logs the plain NAS too (0xB80B, 0xB80A); that copy is the row, placed where it was logged:
            // the registration request before the RRC connection it caused.
            listOf(
                "mib", "systemInformationBlockType1", "Registration request", "rrcSetupRequest", "rrcSetup",
                "rrcSetupComplete", "dlInformationTransfer", "Registration reject", "rrcRelease", "paging", "paging",
            ),
            fiveG.events.map { it.key },
        )
        val request = fiveG.events.first { it.key == "Registration request" }
        assertEquals(CallFlow.Layer.NAS, request.layer)
        assertEquals("nr", request.rat)
        assertTrue(request.uplink)
        assertEquals("RRC Setup Complete", request.carrier)
        assertEquals("initial registration", request.summary)
        assertEquals(CallFlow.Cell(647_328, 417, nr = true), request.cell)
        val reject = fiveG.events.first { it.key == "Registration reject" }
        assertFalse(reject.uplink)
        assertEquals("#27 N1 mode not allowed", reject.summary)
        assertEquals("DL Information Transfer", reject.carrier)
    }

    @Test
    fun theFiveGProceduresAreTheRrcSetupAndTheRefusedRegistration() {
        val byName = fiveG.procedures.associateBy { it.name }
        assertEquals(Outcome.SUCCEEDED, byName.getValue("RRC connection setup").outcome)
        assertEquals("mo-Signalling", byName.getValue("RRC connection setup").detail)
        val registration = byName.getValue("Registration")
        assertEquals(Outcome.FAILED, registration.outcome)
        assertEquals("#27 N1 mode not allowed", registration.refusal)
        assertEquals(1, fiveG.failures)
    }

    @Test
    fun theFiveGCellsAreNrCellsAndThePagingCameFromAnother() {
        assertEquals(
            listOf(Move.FIRST_SEEN to CallFlow.Cell(647_328, 417, nr = true), Move.RESELECTION to CallFlow.Cell(501_390, 152, nr = true)),
            fiveG.journey.map { it.move to it.to },
        )
        assertEquals(CallFlow.ConnectionOutcome.RELEASED, fiveG.connections.single().outcome)
    }

    @Test
    fun theServingCellRecordNamesTheCallboxCell() {
        // The LTE serving-cell record in the same file: the callbox cell the phone had been camped on.
        val callbox = fiveG.cellDetails.getValue(CallFlow.Cell(6_300, 8))
        assertEquals("001-01", callbox.plmn)
        assertEquals(107_216L, callbox.enb)
        assertEquals(1, callbox.tac)
    }

    // MARK: - Mobility, from constructed records

    private val a = CallFlow.Cell(1575, 3)
    private val b = CallFlow.Cell(2850, 2)
    private val c = CallFlow.Cell(1300, 4)

    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun bits(s: String): ByteArray {
        val clean = s.replace(" ", "")
        val padded = clean + "0".repeat((8 - clean.length % 8) % 8)
        return padded.chunked(8).map { it.toInt(2).toByte() }.toByteArray()
    }

    /** A version-27 (SM8450) LTE RRC OTA record body: the layout the real capture uses. */
    private fun rrc(cell: CallFlow.Cell, pdu: Int, payload: ByteArray): ByteArray {
        val header = ByteArray(21)
        header[0] = 27
        fun put16(at: Int, v: Int) {
            header[at] = v.toByte(); header[at + 1] = (v shr 8).toByte()
        }
        put16(1 + 5, cell.pci)
        put16(1 + 7, cell.earfcn.toInt())
        put16(1 + 9, 0)
        header[1 + 13] = pdu.toByte()
        put16(1 + 18, payload.size)
        return header + payload
    }

    private var clockMs = 1_000_000_000L

    private fun record(code: Int, body: ByteArray, afterMs: Long = 20): LogRecord {
        clockMs += afterMs
        return LogRecord(code, (clockMs * 4 / 5) shl 16, body)
    }

    private val ulCcch = 10
    private val dlCcch = 8
    private val ulDcch = 11
    private val dlDcch = 9
    private val bcch = 3

    private fun request(cell: CallFlow.Cell) = record(0xB0C0, rrc(cell, ulCcch, bits("0 1 0 0 00000001 11110101000110100110001010101101 100 0")))
    private fun setup(cell: CallFlow.Cell) = record(0xB0C0, rrc(cell, dlCcch, bits("0 11 0000")))
    private fun setupComplete(cell: CallFlow.Cell) = record(0xB0C0, rrc(cell, ulDcch, bits("0 0100 000")))
    private fun handoverTo2(cell: CallFlow.Cell) = record(0xB0C0, rrc(cell, dlDcch, hex("220820040b228246800000000000")))
    private fun reconfigurationComplete(cell: CallFlow.Cell) = record(0xB0C0, rrc(cell, ulDcch, bits("0 0010 000")))
    private fun release(cell: CallFlow.Cell) = record(0xB0C0, rrc(cell, dlDcch, hex("2801")))
    private fun releaseRedirect(cell: CallFlow.Cell) = record(0xB0C0, rrc(cell, dlDcch, hex("282200a280")))
    private fun reestablishment(cell: CallFlow.Cell) = record(0xB0C0, rrc(cell, ulCcch, hex("0246802abcd4")))
    private fun sib1(cell: CallFlow.Cell) = record(0xB0C0, rrc(cell, bcch, bits("0 1 000000")), afterMs = 800)

    private fun connected(cell: CallFlow.Cell) = listOf(request(cell), setup(cell), setupComplete(cell))

    @Test
    fun aHandoverIsTheCellChangeAfterAHandoverCommand() {
        val flow = CallFlow.of(connected(a) + handoverTo2(a) + reconfigurationComplete(b) + release(b))
        assertEquals(listOf(Move.FIRST_SEEN to a, Move.HANDOVER to b), flow.journey.map { it.move to it.to })
        assertEquals(a, flow.journey[1].from)
        assertEquals("handover to PCI 2, EARFCN 2850", flow.events[3].summary)
        val handover = flow.procedures.first { it.name == "Handover" }
        assertEquals(Outcome.SUCCEEDED, handover.outcome)
        assertEquals(20.0, handover.durationMs, 0.01)
    }

    @Test
    fun aReestablishmentOnAnotherCellFailsTheHandover() {
        val flow = CallFlow.of(connected(a) + handoverTo2(a) + reestablishment(c))
        assertEquals(Move.REESTABLISHMENT, flow.journey.last().move)
        assertEquals(c, flow.journey.last().to)
        assertEquals(Outcome.FAILED, flow.procedures.first { it.name == "Handover" }.outcome)
        assertEquals(Outcome.UNANSWERED, flow.procedures.first { it.name == "RRC re-establishment" }.outcome)
        assertEquals("handoverFailure", flow.events.last().summary)
    }

    @Test
    fun aCellChangeWhileIdleIsAReselection() {
        val flow = CallFlow.of(connected(a) + release(a) + sib1(a) + sib1(b) + request(b))
        assertEquals(listOf(Move.FIRST_SEEN, Move.RESELECTION), flow.journey.map { it.move })
        assertEquals(b, flow.journey.last().to)
        assertEquals(
            listOf(CallFlow.ConnectionOutcome.RELEASED, CallFlow.ConnectionOutcome.NO_ANSWER),
            flow.connections.map { it.outcome },
        )
        assertEquals(Outcome.UNANSWERED, flow.procedures.last().outcome)
    }

    @Test
    fun systemInformationReadWhileSearchingIsNotWhereThePhoneWas() {
        // What the phone logged when the callbox went away: SIB1 from every cell it could hear, then unanswered
        // requests on one of them, then a request that was answered.
        val x = CallFlow.Cell(1450, 403)
        val y = CallFlow.Cell(5230, 417)
        val flow = CallFlow.of(
            connected(a) + release(a) + sib1(x) + sib1(y) + sib1(b) + sib1(x) + request(b) + request(b) + connected(b),
        )
        assertEquals(listOf(Move.FIRST_SEEN to a, Move.RESELECTION to b), flow.journey.map { it.move to it.to })
        assertEquals(listOf(x, y), flow.searched)
        assertEquals(
            listOf(
                CallFlow.ConnectionOutcome.RELEASED,
                CallFlow.ConnectionOutcome.NO_ANSWER,
                CallFlow.ConnectionOutcome.NO_ANSWER,
                CallFlow.ConnectionOutcome.OPEN_AT_END,
            ),
            flow.connections.map { it.outcome },
        )
    }

    @Test
    fun aNewRequestWithNoReleaseEndsTheConnectionAsLost() {
        val flow = CallFlow.of(connected(a) + reconfigurationComplete(a) + request(a) + setup(a) + release(a))
        assertEquals(
            listOf(CallFlow.ConnectionOutcome.LOST, CallFlow.ConnectionOutcome.RELEASED),
            flow.connections.map { it.outcome },
        )
        assertEquals(3, flow.connections.first().last)
        assertEquals(listOf(Move.FIRST_SEEN), flow.journey.map { it.move })
    }

    @Test
    fun nasSentAfterAReselectionIsOnTheNewCellAndStartsTheStep() {
        // As logged: release on A, then the TAU request (NAS, uplink) before the RRC request on B, then the
        // reject (NAS, downlink) after the release on B.
        val flow = CallFlow.of(
            connected(a) + release(a) +
                listOf(nas(0xB0ED, "0748010b"), request(b), setup(b), setupComplete(b), release(b), nas(0xB0EC, "074b09")),
        )
        val tau = flow.events.first { it.key == "Tracking area update request" }
        assertEquals(b, tau.cell)
        assertEquals(b, flow.events.last().cell)
        assertEquals(tau.index, flow.journey.last().event)
        assertEquals(Move.RESELECTION, flow.journey.last().move)
    }

    @Test
    fun aRequestOnANewCellAfterALostConnectionIsAReselection() {
        // The callbox went away mid-connection: no release, then a request on another cell.
        val flow = CallFlow.of(connected(a) + reconfigurationComplete(a) + request(c))
        assertEquals(listOf(Move.FIRST_SEEN, Move.RESELECTION), flow.journey.map { it.move })
    }

    @Test
    fun aCellChangeAfterARedirectingReleaseIsARedirect() {
        val flow = CallFlow.of(connected(a) + releaseRedirect(a) + request(c))
        assertEquals(listOf(Move.FIRST_SEEN, Move.REDIRECT), flow.journey.map { it.move })
        assertEquals("other · redirect to EUTRA EARFCN 1300", flow.events[3].summary)
    }

    @Test
    fun aConnectionAlreadyUpWhenTheCaptureStartedStillCounts() {
        val flow = CallFlow.of(listOf(reconfigurationComplete(a), release(a)))
        val connection = flow.connections.single()
        assertEquals(CallFlow.ConnectionOutcome.RELEASED, connection.outcome)
        assertEquals(0, connection.first)
        assertNull(connection.establishmentCause)
    }

    // MARK: - NAS

    private fun nas(code: Int, pdu: String) = record(code, hex("01000000$pdu"), afterMs = 1)

    @Test
    fun aRejectFailsItsProcedureAndCarriesTheCause() {
        // Attach request (IMSI 001010123456789), then Attach reject #15 "No suitable cells in tracking area".
        val flow = CallFlow.of(
            listOf(
                nas(0xB0ED, "074172080910100000000000"),
                nas(0xB0EC, "07440f"),
            ),
        )
        val attach = flow.procedures.single()
        assertEquals("Attach", attach.name)
        assertEquals(Outcome.FAILED, attach.outcome)
        assertTrue(attach.refusal!!.startsWith("#15 "))
        val reject = flow.events.last()
        assertTrue(reject.isFailure)
        assertEquals(15, reject.cause)
        assertTrue(reject.summary!!.startsWith("#15 "))
        assertEquals(1, flow.failures)
    }

    @Test
    fun aProtectedCopyWithNoPlainTwinStaysAsItsOwnRow() {
        // Ciphered, and the inner bytes are not a NAS message.
        val flow = CallFlow.of(listOf(nas(0xB0EB, "27010203040511223344")))
        val row = flow.events.single()
        assertTrue(row.ciphered)
        assertEquals("Ciphered EMM message", row.name)
        assertEquals(CallFlow.Protection(2, 0x01020304, 5), row.protection)
    }

    @Test
    fun aProtectedCopyThatReadsIsNamedFromInside() {
        // Only the protected copy was logged, deciphered: a Detach accept.
        val flow = CallFlow.of(listOf(nas(0xB0EA, "27aabbccdd070746")))
        val row = flow.events.single()
        assertEquals("Detach accept", row.name)
        assertFalse(row.ciphered)
        assertEquals(7, row.protection!!.sequence)
    }

    // MARK: - From framed bytes (carried over from the NAS-only reader this replaces)

    /** One log packet, HDLC-framed as a capture holds it. */
    private fun framed(code: Int, body: ByteArray, timestampRaw: Long = 42): ByteArray {
        val inner = Protocol.LOG_ENTRY_HEADER_LEN + body.size
        val out = ByteArray(Protocol.LOG_HEADER_LEN + body.size)
        out[0] = Protocol.DIAG_LOG_F.toByte()
        fun putU16(at: Int, v: Int) {
            out[at] = (v and 0xFF).toByte(); out[at + 1] = ((v ushr 8) and 0xFF).toByte()
        }
        putU16(2, inner); putU16(4, inner); putU16(6, code)
        for (i in 0 until 8) out[8 + i] = ((timestampRaw ushr (8 * i)) and 0xFF).toByte()
        body.copyInto(out, Protocol.LOG_HEADER_LEN)
        return Hdlc.encode(out)
    }

    @Test
    fun theLteAttachRejectFromTheReferenceHandsetIsAFailureWithItsCause() {
        val flow = CallFlow.read(framed(0xB0EC, hex("01090500074407")))
        val event = flow.events.single()
        assertEquals("Attach reject", event.name)
        assertEquals("EMM", event.channel)
        assertFalse(event.uplink)
        assertEquals(7, event.cause)
        assertEquals("EPS services not allowed", event.causeName)
        assertEquals("#7 EPS services not allowed", event.summary)
    }

    @Test
    fun theFiveGRegistrationRejectIsReadWithItsCause() {
        val event = CallFlow.read(framed(0xB80A, hex("010000000f04007e00441b16012c"))).events.single()
        assertEquals("Registration reject", event.name)
        assertEquals("nr", event.rat)
        assertEquals(27, event.cause)
        assertEquals("N1 mode not allowed", event.causeName)
    }

    @Test
    fun aRecordWithNoNasInItIsCountedRatherThanShownAsAMessage() {
        // What the SM8450 logs under 0xB80C on this callbox: a state struct (PLMN 001-01, then padding), not a PDU.
        // The NAS-only reader showed these as "ciphered 5GMM message" rows; there was no message.
        val flow = CallFlow.read(framed(0xB80C, hex("0100000001020000f110ffffffffffffffffffffffff01000000")))
        assertTrue(flow.events.isEmpty())
        assertEquals(1, flow.undecoded)
    }

    @Test
    fun aCorruptFrameIsCountedAndTheRestStillRead() {
        val good = framed(0xB0EC, hex("01090500074407"))
        val bad = good.copyOf()
        bad[1] = (bad[1] + 1).toByte()
        val flow = CallFlow.read(bad + good)
        assertEquals(1, flow.events.size)
        assertEquals(1, flow.crcErrors)
    }

    @Test
    fun anEmptyCaptureIsAnEmptyFlowRatherThanAFailure() {
        val flow = CallFlow.read(ByteArray(0))
        assertEquals(0, flow.records)
        assertTrue(flow.events.isEmpty())
        assertNull(flow.startUtcMs)
    }

    @Test
    fun aModemWithoutNetworkTimeHasNoWallClock() {
        assertNull(CallFlow.utcMs(1L shl 16))
        assertNull(CallFlow.utcMs(0))
    }
}
