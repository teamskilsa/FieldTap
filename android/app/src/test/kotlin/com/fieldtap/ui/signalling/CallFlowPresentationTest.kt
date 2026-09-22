package com.fieldtap.ui.signalling

import com.fieldtap.diag.CallFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallFlowPresentationTest {

    private val b3 = CallFlow.Cell(1575, 3)
    private val b7 = CallFlow.Cell(2850, 2)

    private fun event(
        index: Int,
        key: String,
        layer: CallFlow.Layer = CallFlow.Layer.RRC,
        channel: String = "DL-DCCH",
        cell: CallFlow.Cell = b3,
        atMs: Double = index * 10.0,
        rat: String = "lte",
    ) = CallFlow.Event(
        index = index, record = index + 1, logCode = 0xB0C0, timestampRaw = 0, sinceStartMs = atMs, layer = layer, rat = rat,
        uplink = false, key = key, name = key, summary = null, cell = cell, channel = channel, fields = emptyList(),
        cause = null, causeName = null, protection = null, ciphered = false, pdu = ByteArray(0),
    )

    private fun flow(
        events: List<CallFlow.Event>,
        procedures: List<CallFlow.Procedure> = emptyList(),
        journey: List<CallFlow.Step> = emptyList(),
    ) = CallFlow.Flow(
        events = events,
        procedures = procedures,
        journey = journey,
        searched = emptyList(),
        connections = emptyList(),
        records = events.size,
        undecoded = 0,
        crcErrors = 0,
        durationMs = 1_000.0,
        startUtcMs = null,
    )

    @Test
    fun broadcastFoldsIntoOneLineAndPagingIntoAnother() {
        val events = listOf(
            event(0, "systemInformationBlockType1", channel = "BCCH-DL-SCH"),
            event(1, "systemInformationBlockType1", channel = "BCCH-DL-SCH"),
            event(2, "systemInformation", channel = "BCCH-DL-SCH"),
            event(3, "paging", channel = "PCCH"),
            event(4, "paging", channel = "PCCH"),
            event(5, "rrcConnectionRequest", channel = "UL-CCCH"),
            event(6, "rrcConnectionRequest", channel = "UL-CCCH"),
        )
        val rows = CallFlowPresentation.rows(flow(events), FlowFilter.ALL).filterIsInstance<LadderRow.Message>()
        assertEquals(listOf(3, 2, 1, 1), rows.map { it.count })
        assertTrue(rows[0].mixed)
        assertFalse(rows[1].mixed)
        assertEquals(0, CallFlowPresentation.rowOf(rows, 2))
        assertEquals(3, CallFlowPresentation.rowOf(rows, 6))
    }

    @Test
    fun aSearchAcrossCellsIsOneLineThatNamesTheCells() {
        val events = listOf(
            event(0, "systemInformationBlockType1", channel = "BCCH-DL-SCH", cell = b3),
            event(1, "systemInformationBlockType1", channel = "BCCH-DL-SCH", cell = b7),
            event(2, "systemInformationBlockType1", channel = "BCCH-DL-SCH", cell = CallFlow.Cell(1300, 4)),
            event(3, "systemInformationBlockType1", channel = "BCCH-DL-SCH", cell = b3),
        )
        val row = CallFlowPresentation.rows(flow(events), FlowFilter.ALL).single() as LadderRow.Message
        assertTrue(row.mixed)
        assertEquals(3, CallFlowPresentation.cellCount(row))
        assertEquals("B3 PCI 3, B7 PCI 2 +1", CallFlowPresentation.cellsOf(row))
    }

    @Test
    fun proceduresGroupByKindWithTheMedianOfTheSuccessfulOnes() {
        fun p(name: String, outcome: CallFlow.Outcome, ms: Double, at: Int) =
            CallFlow.Procedure(name, CallFlow.Layer.NAS, null, at, at, outcome, ms)
        val procedures = listOf(
            p("Attach", CallFlow.Outcome.UNANSWERED, 0.0, 0),
            p("Service request", CallFlow.Outcome.SUCCEEDED, 90.0, 1),
            p("Attach", CallFlow.Outcome.FAILED, 110.0, 2),
            p("Attach", CallFlow.Outcome.SUCCEEDED, 300.0, 3),
            p("Attach", CallFlow.Outcome.SUCCEEDED, 260.0, 4),
        )
        val groups = CallFlowPresentation.procedureGroups(flow(emptyList(), procedures))
        assertEquals(listOf("Attach", "Service request"), groups.map { it.name })
        val attach = groups.first()
        assertEquals(Triple(2, 1, 1), Triple(attach.succeeded, attach.failed, attach.unanswered))
        assertEquals(280.0, attach.medianMs!!, 0.0)
        assertEquals(null, CallFlowPresentation.ProcedureGroup("x", CallFlow.Layer.RRC, listOf(p("x", CallFlow.Outcome.FAILED, 1.0, 0))).medianMs)
    }

    @Test
    fun aCellChangeBreaksARunAndGetsItsBanner() {
        val events = listOf(
            event(0, "systemInformationBlockType1", channel = "BCCH-DL-SCH"),
            event(1, "systemInformationBlockType1", channel = "BCCH-DL-SCH", cell = b7),
        )
        val journey = listOf(
            CallFlow.Step(CallFlow.Move.FIRST_SEEN, null, b3, 0, 0.0),
            CallFlow.Step(CallFlow.Move.RESELECTION, b3, b7, 1, 10.0),
        )
        val rows = CallFlowPresentation.rows(flow(events, journey = journey), FlowFilter.ALL)
        assertEquals(listOf("event-0", "move-1", "event-1"), rows.map { it.key })
        // With NAS only, no RRC and so no cell banners.
        assertTrue(CallFlowPresentation.rows(flow(events, journey = journey), FlowFilter.NAS).isEmpty())
    }

    @Test
    fun procedureHeadersFollowTheFilter() {
        val events = listOf(
            event(0, "Service request", layer = CallFlow.Layer.NAS, channel = "EMM"),
            event(1, "rrcConnectionRequest", channel = "UL-CCCH"),
        )
        val procedures = listOf(
            CallFlow.Procedure("Service request", CallFlow.Layer.NAS, null, 0, 1, CallFlow.Outcome.SUCCEEDED, 10.0),
            CallFlow.Procedure("RRC connection setup", CallFlow.Layer.RRC, null, 1, 1, CallFlow.Outcome.UNANSWERED, 0.0),
        )
        val f = flow(events, procedures)
        assertEquals(listOf("procedure-0", "event-0", "procedure-1", "event-1"), CallFlowPresentation.rows(f, FlowFilter.ALL).map { it.key })
        assertEquals(listOf("procedure-1", "event-1"), CallFlowPresentation.rows(f, FlowFilter.RRC).map { it.key })
        assertEquals(listOf("procedure-0", "event-0"), CallFlowPresentation.rows(f, FlowFilter.NAS).map { it.key })
    }

    @Test
    fun lanesAreNamedForTheRadio() {
        assertEquals(CallFlowPresentation.Lanes("UE", "eNB", "MME"), CallFlowPresentation.lanes(flow(listOf(event(0, "x")))))
        assertEquals(CallFlowPresentation.Lanes("UE", "gNB", "AMF"), CallFlowPresentation.lanes(flow(listOf(event(0, "x", rat = "nr")))))
        assertEquals(CallFlowPresentation.Lanes("UE", "RAN", "Core"), CallFlowPresentation.lanes(flow(listOf(event(0, "x"), event(1, "y", rat = "nr")))))
    }

    @Test
    fun cellsReadAsBandAndPci() {
        assertEquals("B3 PCI 3", CallFlowPresentation.shortCell(b3))
        assertEquals("B7 PCI 2", CallFlowPresentation.shortCell(b7))
        assertEquals("1842.5 MHz", CallFlowPresentation.downlinkMhz(b3))
        assertEquals("EARFCN 99999 PCI 1", CallFlowPresentation.shortCell(CallFlow.Cell(99_999, 1)))
    }

    @Test
    fun nrCellsAreNotGivenAnLteBandTheyDoNotHave() {
        // NR-ARFCN 647328 on the global raster is 3709.9 MHz (n77 or n78: the ARFCN cannot say which).
        val nr = CallFlow.Cell(647_328, 417, nr = true)
        assertEquals(null, CallFlowPresentation.band(nr))
        assertEquals("NR PCI 417", CallFlowPresentation.shortCell(nr))
        assertEquals("3709.9 MHz", CallFlowPresentation.downlinkMhz(nr))
        assertEquals("NR-ARFCN", CallFlowPresentation.channelLabel(nr))
        assertEquals("EARFCN", CallFlowPresentation.channelLabel(b3))
    }

    @Test
    fun aPendingNrCellSaysSo() {
        // An NR RRC header logged before the SCG cell is assigned carries PCI 0xFFFF or NR-ARFCN 0xFFFFFFFF (the
        // iPhone's first EN-DC reconfiguration); it is no PCI 65535.
        assertEquals("NR cell pending", CallFlowPresentation.shortCell(CallFlow.Cell(0xFFFF_FFFFL, 0xFFFF, nr = true)))
        assertEquals("NR cell pending", CallFlowPresentation.shortCell(CallFlow.Cell(174_770, 0xFFFF, nr = true)))
        assertEquals("NR cell pending", CallFlowPresentation.shortCell(CallFlow.Cell(0xFFFF_FFFFL, 80, nr = true)))
        assertEquals("NR PCI 80", CallFlowPresentation.shortCell(CallFlow.Cell(174_770, 80, nr = true)))
    }

    @Test
    fun timesAndSpans() {
        assertEquals("0:00.064", CallFlowPresentation.sinceStart(63.771))
        assertEquals("1:58.338", CallFlowPresentation.sinceStart(118_338.425))
        assertEquals("1:02:03.004", CallFlowPresentation.sinceStart(3_723_004.0))
        assertEquals("0.4 ms", CallFlowPresentation.duration(0.4))
        assertEquals("67.5 ms", CallFlowPresentation.duration(67.52))
        assertEquals("312 ms", CallFlowPresentation.duration(312.0))
        assertEquals("1.24 s", CallFlowPresentation.duration(1_240.0))
        assertEquals("2 min 3 s", CallFlowPresentation.duration(123_400.0))
    }

    @Test
    fun theHexDumpFitsAPhoneAndShowsText() {
        val bytes = "ims".toByteArray() + byteArrayOf(0, 1, 2, 3, 4, 5, 6)
        assertEquals(
            "0000  69 6d 73 00 01 02 03 04  ims.....\n0008  05 06                    ..",
            CallFlowPresentation.hexDump(bytes),
        )
        assertEquals("696d73", CallFlowPresentation.hex("ims".toByteArray()))
    }
}
