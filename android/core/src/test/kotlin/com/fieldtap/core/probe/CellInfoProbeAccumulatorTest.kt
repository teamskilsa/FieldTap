package com.fieldtap.core.probe

import com.fieldtap.core.input.CellInfoAnswer
import com.fieldtap.core.input.CellSnapshot
import com.fieldtap.core.input.DeviceConditions
import com.fieldtap.format.CellInfoSource
import com.fieldtap.format.Rat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CellInfoProbeAccumulatorTest {

    @Test
    fun anEmptyAccumulatorReportsNothingSeen() {
        val probe = CellInfoProbeAccumulator()

        assertEquals(
            CellInfoProbe(
                requests = 0,
                answers = 0,
                errors = 0,
                maxCellsPerAnswer = 0,
                neighboursSeen = false,
                servingRats = emptyList(),
                bandListsPresent = false,
                connectionStatusReported = false,
                nsaSecondarySeen = false,
                timestampsAdvance = null,
                minFreshIntervalMs = null,
                rsrpMin = null,
                rsrpMax = null,
                sinrMin = null,
                sinrMax = null,
            ),
            probe.result(),
        )
        assertEquals(listOf("No cell information was requested."), probe.notes())
    }

    @Test
    fun requestsWithoutAnswersAreNoted() {
        val probe = CellInfoProbeAccumulator()
        probe.onRequest()
        probe.onRequest()

        assertEquals(2, probe.result().requests)
        assertEquals(listOf("No cell-info answer arrived for 2 requests."), probe.notes())
    }

    @Test
    fun countsRequestsErrorsAnswersAndTheLargestAnswer() {
        val probe = CellInfoProbeAccumulator()
        repeat(3) { probe.onRequest() }
        probe.onError()
        probe.onAnswer(answer(lte(timestampMs = 1_000)))
        probe.onAnswer(answer(lte(timestampMs = 1_000), lteNeighbour(pci = 11), lteNeighbour(pci = 12)))
        probe.onAnswer(answer())

        val result = probe.result()
        assertEquals(3, result.requests)
        assertEquals(1, result.errors)
        assertEquals(3, result.answers)
        assertEquals(3, result.maxCellsPerAnswer)
        assertTrue(probe.notes().contains("1 cell-info request failed."))
        assertTrue(probe.notes().contains("1 answer held no cells."))
    }

    @Test
    fun timestampsAdvanceIsUnknownWithFewerThanTwoServingAnswers() {
        val one = CellInfoProbeAccumulator()
        one.onAnswer(answer(lte(timestampMs = 1_000)))
        assertNull(one.result().timestampsAdvance)

        val noServing = CellInfoProbeAccumulator()
        noServing.onAnswer(answer(lteNeighbour(timestampMs = 1_000)))
        noServing.onAnswer(answer(lteNeighbour(timestampMs = 3_000)))
        assertNull(noServing.result().timestampsAdvance)
        assertNull(noServing.result().minFreshIntervalMs)
    }

    @Test
    fun repeatedTimestampsNeverAdvance() {
        val probe = CellInfoProbeAccumulator()
        repeat(3) { probe.onAnswer(answer(lte(timestampMs = 56_019))) }

        assertEquals(false, probe.result().timestampsAdvance)
        assertNull(probe.result().minFreshIntervalMs)
        assertTrue(probe.notes().any { it.startsWith("The serving cell's modem timestamp never advanced") })
    }

    @Test
    fun advancingTimestampsGiveTheSmallestFreshStep() {
        val probe = CellInfoProbeAccumulator()
        for (timestamp in listOf(1_000L, 1_000L, 3_000L, 3_000L, 5_500L, 2_000L, 7_500L)) {
            probe.onAnswer(answer(lte(timestampMs = timestamp)))
        }

        val result = probe.result()
        assertEquals(true, result.timestampsAdvance)
        // Steps 2000, 2500, 2000; the older 2000 ms report neither advances nor shortens the step.
        assertEquals(2_000L, result.minFreshIntervalMs)
        assertFalse(probe.notes().any { it.contains("never advanced") })
    }

    @Test
    fun servingRatsAreListedInFirstSeenOrder() {
        val probe = CellInfoProbeAccumulator()
        probe.onAnswer(answer(lte(timestampMs = 1_000)))
        probe.onAnswer(answer(nr(status = 1, timestampMs = 2_000)))
        probe.onAnswer(answer(lte(timestampMs = 3_000)))

        assertEquals(listOf("lte", "nr"), probe.result().servingRats)
    }

    @Test
    fun withoutConnectionStatusesTheFirstRegisteredLteOrNrCellServes() {
        val probe = CellInfoProbeAccumulator()
        val wcdma = CellSnapshot(rat = Rat.WCDMA, registered = true, connectionStatus = null, timestampMs = 900)
        probe.onAnswer(
            answer(
                wcdma,
                lte(status = null, timestampMs = 1_000),
                nr(status = null, registered = false, timestampMs = 1_000),
            ),
        )

        val result = probe.result()
        assertEquals(listOf("lte"), result.servingRats)
        assertFalse(result.connectionStatusReported)
        assertTrue(result.neighboursSeen)
        assertTrue(probe.notes().any { it.startsWith("No cell reported a connection status") })
    }

    @Test
    fun aNonLtePrimaryWithStatusOneIsReported() {
        val probe = CellInfoProbeAccumulator()
        probe.onAnswer(answer(CellSnapshot(rat = Rat.WCDMA, registered = true, connectionStatus = 1, timestampMs = 1_000)))

        assertEquals(listOf("wcdma"), probe.result().servingRats)
    }

    @Test
    fun anIdlePhoneCampedOnACellHasAServingCell() {
        // RRC idle: status 0 on the cell the phone is registered to. That is the normal state of an
        // attached phone moving no data, and it is still being served — a probe that called it
        // unserved told a user with a working lab network that FieldTap could not measure it.
        val probe = CellInfoProbeAccumulator()
        probe.onAnswer(answer(lte(status = 0, registered = true, timestampMs = 1_000)))

        assertEquals(listOf(Rat.LTE.wire), probe.result().servingRats)
        assertTrue(probe.result().connectionStatusReported)
    }

    @Test
    fun statusesWithNothingRegisteredMeanNoServingCell() {
        val probe = CellInfoProbeAccumulator()
        probe.onAnswer(answer(lte(status = 0, registered = false, timestampMs = 1_000)))

        assertTrue(probe.result().servingRats.isEmpty())
        assertTrue(probe.notes().contains("No primary serving cell was identified, so no KPI rows would be written."))
    }

    @Test
    fun anNsaSecondaryNeedsAnLtePrimary() {
        val nsa = CellInfoProbeAccumulator()
        nsa.onAnswer(answer(lte(timestampMs = 1_000), nr(status = 2, registered = false, timestampMs = 1_000)))
        assertTrue(nsa.result().nsaSecondarySeen)
        assertFalse(nsa.result().neighboursSeen)

        val sa = CellInfoProbeAccumulator()
        sa.onAnswer(answer(nr(status = 1, timestampMs = 1_000), nr(status = 2, registered = false, pci = 7, timestampMs = 1_000)))
        assertFalse(sa.result().nsaSecondarySeen)
    }

    @Test
    fun neighboursAreUnregisteredCellsThatDoNotServe() {
        val withNeighbour = CellInfoProbeAccumulator()
        withNeighbour.onAnswer(answer(lte(timestampMs = 1_000), lteNeighbour(pci = 11)))
        assertTrue(withNeighbour.result().neighboursSeen)

        val registeredOnly = CellInfoProbeAccumulator()
        registeredOnly.onAnswer(answer(lte(status = 0, timestampMs = 1_000)))
        assertFalse(registeredOnly.result().neighboursSeen)
        assertTrue(registeredOnly.notes().contains("No neighbour cells were reported."))
    }

    @Test
    fun bandListsAreDetectedAndTheirAbsenceNoted() {
        val withoutBands = CellInfoProbeAccumulator()
        withoutBands.onAnswer(answer(lte(timestampMs = 1_000, bands = emptyList())))
        assertFalse(withoutBands.result().bandListsPresent)
        assertTrue(withoutBands.notes().contains("No cell reported a band list."))

        val withBands = CellInfoProbeAccumulator()
        withBands.onAnswer(answer(lte(timestampMs = 1_000, bands = listOf(66))))
        assertTrue(withBands.result().bandListsPresent)
        assertFalse(withBands.notes().contains("No cell reported a band list."))
    }

    @Test
    fun rsrpAndSinrRangesSpanEveryCellAndIgnoreMissingValues() {
        val probe = CellInfoProbeAccumulator()
        probe.onAnswer(
            answer(
                lte(timestampMs = 1_000, rsrp = -80, sinr = 5),
                lteNeighbour(pci = 11, rsrp = -120, sinr = -3),
                lteNeighbour(pci = 12, rsrp = null, sinr = null),
            ),
        )
        probe.onAnswer(answer(lte(timestampMs = 3_000, rsrp = -95, sinr = 12)))

        val result = probe.result()
        assertEquals(-120, result.rsrpMin)
        assertEquals(-80, result.rsrpMax)
        assertEquals(-3, result.sinrMin)
        assertEquals(12, result.sinrMax)
    }

    @Test
    fun valuesOutsideTheSchemaRangesAreNotedButStillCounted() {
        val probe = CellInfoProbeAccumulator()
        probe.onAnswer(answer(nr(status = 1, timestampMs = 1_000, sinr = 150)))
        probe.onAnswer(answer(nr(status = 1, timestampMs = 3_000, sinr = 160), lteNeighbour(pci = 11, rsrp = -30)))
        // Other RATs have no range in the schema, so nothing is noted for them.
        probe.onAnswer(answer(CellSnapshot(rat = Rat.GSM, registered = false, connectionStatus = 0, timestampMs = 3_000, rsrp = -10)))

        val notes = probe.notes()
        assertTrue(notes.contains("NR SINR outside -23..40 dB in 2 samples (first 150), so those values are written blank."))
        assertTrue(notes.contains("LTE RSRP outside -156..-43 dBm in 1 sample (first -30), so those values are written blank."))
        assertEquals(2, notes.count { it.contains(" outside ") })
        assertEquals(160, probe.result().sinrMax)
        assertEquals(-10, probe.result().rsrpMax)
    }

    @Test
    fun theEmulatorsSingleServingCellGivesTheExpectedNotes() {
        // The GitHub Actions emulator: one LTE cell with status 1 and bands, timestamps every 10 s.
        val probe = CellInfoProbeAccumulator()
        for (timestamp in listOf(56_019L, 56_019L, 66_013L, 66_013L, 76_014L)) {
            probe.onRequest()
            probe.onAnswer(answer(lte(timestampMs = timestamp, bands = listOf(42), rsrp = -64, sinr = null)))
        }

        val result = probe.result()
        assertEquals(5, result.requests)
        assertEquals(1, result.maxCellsPerAnswer)
        assertEquals(true, result.timestampsAdvance)
        assertEquals(9_994L, result.minFreshIntervalMs)
        assertNull(result.sinrMin)
        assertEquals(listOf("No neighbour cells were reported."), probe.notes())
    }

    private fun answer(vararg cells: CellSnapshot): CellInfoAnswer = CellInfoAnswer(
        source = CellInfoSource.REQUEST,
        cells = cells.toList(),
        subId = 1,
        conditions = DeviceConditions(screenOn = true, charging = false, wifiConnected = false),
        observedWallMs = 1_789_050_600_000L,
        observedElapsedMs = 80_000L,
    )

    private fun lte(
        status: Int? = 1,
        registered: Boolean = true,
        timestampMs: Long,
        pci: Int = 10,
        bands: List<Int> = listOf(66),
        rsrp: Int? = -95,
        sinr: Int? = 12,
    ): CellSnapshot = CellSnapshot(
        rat = Rat.LTE,
        registered = registered,
        connectionStatus = status,
        timestampMs = timestampMs,
        mcc = "311",
        mnc = "480",
        pci = pci,
        arfcn = 66_486,
        bands = bands,
        rsrp = rsrp,
        rsrq = -10,
        sinr = sinr,
    )

    private fun lteNeighbour(pci: Int = 11, timestampMs: Long = 1_000, rsrp: Int? = -110, sinr: Int? = 2): CellSnapshot =
        lte(status = 0, registered = false, timestampMs = timestampMs, pci = pci, rsrp = rsrp, sinr = sinr)

    private fun nr(
        status: Int?,
        registered: Boolean = true,
        timestampMs: Long,
        pci: Int = 555,
        sinr: Int? = 20,
    ): CellSnapshot = CellSnapshot(
        rat = Rat.NR,
        registered = registered,
        connectionStatus = status,
        timestampMs = timestampMs,
        mcc = "310",
        mnc = "260",
        pci = pci,
        arfcn = 9_000,
        bands = listOf(41),
        rsrp = -90,
        rsrq = -11,
        sinr = sinr,
    )
}
