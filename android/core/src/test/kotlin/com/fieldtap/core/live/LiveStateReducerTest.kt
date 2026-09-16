package com.fieldtap.core.live

import com.fieldtap.core.input.CellInfoRequestFailed
import com.fieldtap.core.input.CellSnapshot
import com.fieldtap.core.input.DataConnState
import com.fieldtap.core.input.DataStateSnapshot
import com.fieldtap.core.input.DisplayInfoSnapshot
import com.fieldtap.core.input.FixSample
import com.fieldtap.core.input.GnssSnapshot
import com.fieldtap.core.input.ListenerOutcome
import com.fieldtap.core.input.ListenerReport
import com.fieldtap.core.input.LocationAvailability
import com.fieldtap.core.input.RadioListener
import com.fieldtap.core.input.ServiceRegState
import com.fieldtap.core.input.ServiceStateSnapshot
import com.fieldtap.core.input.SignalSnapshot
import com.fieldtap.core.live.LiveFixtures.BOOT0
import com.fieldtap.core.live.LiveFixtures.POCKET
import com.fieldtap.core.live.LiveFixtures.SHORT
import com.fieldtap.core.live.LiveFixtures.WALL0
import com.fieldtap.core.live.LiveFixtures.answer
import com.fieldtap.core.live.LiveFixtures.gsm
import com.fieldtap.core.live.LiveFixtures.lte
import com.fieldtap.core.live.LiveFixtures.nr
import com.fieldtap.format.FixProvider
import com.fieldtap.format.Rat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveStateReducerTest {

    @Test
    fun badgeThresholdsAre2500And11000MsInclusive() {
        assertEquals(AgeBadge.NONE, LiveStateReducer.badge(null))
        assertEquals(AgeBadge.FRESH, LiveStateReducer.badge(-5))
        assertEquals(AgeBadge.FRESH, LiveStateReducer.badge(0))
        assertEquals(AgeBadge.FRESH, LiveStateReducer.badge(2_500))
        assertEquals(AgeBadge.AGING, LiveStateReducer.badge(2_501))
        assertEquals(AgeBadge.AGING, LiveStateReducer.badge(11_000))
        assertEquals(AgeBadge.STALE, LiveStateReducer.badge(11_001))
        assertEquals(2_500L, LiveStateReducer.FRESH_MAX_AGE_MS)
        assertEquals(11_000L, LiveStateReducer.AGING_MAX_AGE_MS)
        assertEquals(300_000L, LiveStateReducer.WINDOW_MS)
    }

    @Test
    fun aFreshAnswerShowsTheServingCellItsAgeAndAChartPoint() {
        val state = LiveStateReducer().reduce(LiveState(), answer(atMs = 400, cells = listOf(lte(measuredAtMs = 0))))

        assertEquals(
            LiveCell(
                rat = Rat.LTE,
                pci = 212,
                arfcn = 66_786,
                band = 66,
                rsrp = -90,
                rsrq = -9,
                sinr = 12,
                plmn = "311480",
                operator = "Verizon",
                connectionStatus = CellSnapshot.CONNECTION_PRIMARY_SERVING,
                timestampMs = BOOT0,
                // The Signal tab reads the tracking area and cell identity, so they reach the live view.
                tac = 18_704,
                cellId = 21_640_193L,
            ),
            state.serving,
        )
        assertEquals(400L, state.servingAgeMs)
        assertEquals(AgeBadge.FRESH, state.badge)
        assertEquals(listOf(ChartPoint(BOOT0, -90)), state.rsrpSeries)
        assertEquals(listOf(ChartPoint(BOOT0, 12)), state.sinrSeries)
        assertEquals(true, state.shortInterval)
        assertEquals(SHORT, state.conditions)
        assertEquals(BOOT0 + 400, state.nowElapsedMs)
        assertNull("one fresh answer gives no interval yet", state.recentFreshIntervalMs)
    }

    @Test
    fun repeatsAddNoChartPointsWhileTheSampleAges() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(400, listOf(lte(0))))

        state = reducer.reduce(state, answer(1_400, listOf(lte(0))))
        assertEquals(1, state.rsrpSeries.size)
        assertEquals(1_400L, state.servingAgeMs)
        assertEquals(AgeBadge.FRESH, state.badge)

        state = reducer.reduce(state, answer(3_000, listOf(lte(0))))
        assertEquals(1, state.rsrpSeries.size)
        assertEquals(1, state.sinrSeries.size)
        assertEquals(3_000L, state.servingAgeMs)
        assertEquals(AgeBadge.AGING, state.badge)

        state = reducer.reduce(state, answer(3_400, listOf(lte(3_000, rsrp = -88))))
        assertEquals(listOf(ChartPoint(BOOT0, -90), ChartPoint(BOOT0 + 3_000, -88)), state.rsrpSeries)
        assertEquals(AgeBadge.FRESH, state.badge)
    }

    @Test
    fun tickDropsChartPointsOlderThanFiveMinutesAndKeepsTheBoundary() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(400, listOf(lte(0, rsrp = -90, sinr = 10))))
        state = reducer.reduce(state, answer(2_400, listOf(lte(2_000, rsrp = -91, sinr = 11))))

        val atBoundary = reducer.tick(state, BOOT0 + 300_000)
        assertEquals(2, atBoundary.rsrpSeries.size)

        val justAfter = reducer.tick(atBoundary, BOOT0 + 300_001)
        assertEquals(listOf(ChartPoint(BOOT0 + 2_000, -91)), justAfter.rsrpSeries)
        assertEquals(listOf(ChartPoint(BOOT0 + 2_000, 11)), justAfter.sinrSeries)

        val later = reducer.tick(justAfter, BOOT0 + 302_001)
        assertTrue(later.rsrpSeries.isEmpty())
        assertTrue(later.sinrSeries.isEmpty())
        assertEquals(AgeBadge.STALE, later.badge)
        assertEquals(300_001L, later.servingAgeMs)
    }

    @Test
    fun neighboursAreTheOtherCellsStrongestFirstWithUnknownRsrpLast() {
        val state = LiveStateReducer().reduce(
            LiveState(),
            answer(
                400,
                listOf(
                    lte(0, pci = 212),
                    nr(0, pci = 393),
                    lte(0, pci = 100, status = CellSnapshot.CONNECTION_NONE, rsrp = -110, cellId = 1),
                    gsm(0),
                    lte(0, pci = 101, status = CellSnapshot.CONNECTION_NONE, rsrp = -95, cellId = 2),
                    lte(0, pci = 102, status = CellSnapshot.CONNECTION_NONE, rsrp = null, cellId = 3),
                ),
            ),
        )

        assertEquals(
            listOf(Rat.LTE to 101, Rat.LTE to 100, Rat.GSM to null, Rat.LTE to 102),
            state.neighbours.map { it.rat to it.pci },
        )
        assertEquals(212, state.serving?.pci)
        assertEquals(393, state.nsaLeg?.pci)
        assertEquals(Rat.NR, state.nsaLeg?.rat)
    }

    @Test
    fun theNsaLegDisappearsWhenThePrimaryNoLongerHasOne() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(400, listOf(lte(0), nr(0))))
        assertNotNull(state.nsaLeg)
        assertTrue(state.neighbours.isEmpty())

        state = reducer.reduce(state, answer(2_400, listOf(lte(2_000))))
        assertNull(state.nsaLeg)
        assertEquals(BOOT0 + 2_000, state.serving?.timestampMs)
    }

    @Test
    fun anSaPrimaryHasNoNsaLegAndChartsSsRsrp() {
        val state = LiveStateReducer().reduce(
            LiveState(),
            answer(400, listOf(nr(0, pci = 555, status = CellSnapshot.CONNECTION_PRIMARY_SERVING, rsrp = -68, sinr = null))),
        )

        assertEquals(Rat.NR, state.serving?.rat)
        assertNull(state.nsaLeg)
        assertEquals(listOf(ChartPoint(BOOT0, -68)), state.rsrpSeries)
        assertTrue("a missing SINR adds no SINR point", state.sinrSeries.isEmpty())
    }

    @Test
    fun aCachedRepeatOfAnOlderMeasurementNeverReplacesANewerServingCell() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(400, listOf(lte(0, pci = 212))))
        state = reducer.reduce(state, answer(2_400, listOf(lte(2_000, pci = 300, cellId = 9, rsrp = -100))))
        assertEquals(300, state.serving?.pci)

        state = reducer.reduce(state, answer(3_400, listOf(lte(0, pci = 212))))

        assertEquals(300, state.serving?.pci)
        assertEquals(BOOT0 + 2_000, state.serving?.timestampMs)
        assertEquals(2, state.rsrpSeries.size)
        assertEquals("the newest answer holds only its primary cell", emptyList<LiveCell>(), state.neighbours)
    }

    @Test
    fun anAnswerWithoutAServingCellKeepsTheLastOneWhichTurnsStale() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(400, listOf(lte(0), lte(0, pci = 7, status = CellSnapshot.CONNECTION_NONE, cellId = 5))))
        assertEquals(1, state.neighbours.size)

        state = reducer.reduce(state, answer(12_000, emptyList(), conditions = POCKET))

        assertEquals(212, state.serving?.pci)
        assertEquals(12_000L, state.servingAgeMs)
        assertEquals(AgeBadge.STALE, state.badge)
        assertTrue(state.neighbours.isEmpty())
        assertEquals(false, state.shortInterval)
        assertEquals(POCKET, state.conditions)
    }

    @Test
    fun aFreshPointMeasuredBeforeTheNewestOneIsInsertedInTimeOrder() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(1_400, listOf(lte(1_000, pci = 212, rsrp = -80))))

        state = reducer.reduce(state, answer(1_900, listOf(lte(0, pci = 300, cellId = 9, rsrp = -100))))

        assertEquals(listOf(ChartPoint(BOOT0, -100), ChartPoint(BOOT0 + 1_000, -80)), state.rsrpSeries)
        assertEquals("a new measurement from the answer's primary is shown", 300, state.serving?.pci)
    }

    @Test
    fun theRecentFreshIntervalIsTheMedianOfTheLastTenIntervals() {
        val reducer = LiveStateReducer()
        val measured = listOf(0L, 1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 11_000, 16_000, 21_000, 26_000, 31_000)
        var state = LiveState()
        for ((index, measuredAt) in measured.withIndex()) {
            state = reducer.reduce(state, answer(measuredAt + 400, listOf(lte(measuredAt))))
            if (index == 1) assertEquals(1_000L, state.recentFreshIntervalMs)
            // A repeat between fresh answers adds no interval.
            state = reducer.reduce(state, answer(measuredAt + 900, listOf(lte(measuredAt))))
        }

        // Eleven intervals: six of 1000 ms, then five of 5000 ms. The last ten are five of each, and the
        // element at size / 2 of the sorted ten is 5000; over all eleven it would be 1000.
        assertEquals(5_000L, state.recentFreshIntervalMs)
    }

    @Test
    fun snapshotsListenersAndFixesAreKept() {
        val reducer = LiveStateReducer()
        val service = ServiceStateSnapshot(ServiceRegState.IN_SERVICE, false, "311480", "Verizon", false, WALL0 + 10, BOOT0 + 10)
        val data = DataStateSnapshot(DataConnState.CONNECTED, 13, WALL0 + 20, BOOT0 + 20)
        val display = DisplayInfoSnapshot(13, 3, WALL0 + 30, BOOT0 + 30)
        val signal = SignalSnapshot(-91, -10, 8, null, null, null, 3, BOOT0 + 35, WALL0 + 40, BOOT0 + 40)
        val gnss = GnssSnapshot(14, 8, WALL0 + 50, BOOT0 + 50)
        val newerFix = fix(elapsedMs = BOOT0 + 60)
        val olderFix = fix(elapsedMs = BOOT0 + 55)

        var state = LiveState()
        for (input in listOf(service, data, display, signal, gnss, newerFix)) state = reducer.reduce(state, input)
        state = reducer.reduce(state, ListenerReport(RadioListener.CELL_INFO_PUSH, ListenerOutcome.MISSING_PERMISSION, null, WALL0 + 70, BOOT0 + 70))
        state = reducer.reduce(state, ListenerReport(RadioListener.SIGNAL_STRENGTHS, ListenerOutcome.FAILED, "boom", WALL0 + 71, BOOT0 + 71))
        state = reducer.reduce(state, ListenerReport(RadioListener.SIGNAL_STRENGTHS, ListenerOutcome.REGISTERED, null, WALL0 + 72, BOOT0 + 72))
        state = reducer.reduce(state, olderFix.copy(observedElapsedMs = BOOT0 + 80))

        assertSame(service, state.service)
        assertSame(data, state.data)
        assertSame(display, state.display)
        assertSame(signal, state.signal)
        assertSame(gnss, state.gnss)
        assertSame("an older fix never replaces a newer one", newerFix, state.lastFix)
        assertEquals(
            mapOf(RadioListener.CELL_INFO_PUSH to ListenerOutcome.MISSING_PERMISSION, RadioListener.SIGNAL_STRENGTHS to ListenerOutcome.REGISTERED),
            state.listeners,
        )
        assertEquals(BOOT0 + 80, state.nowElapsedMs)

        // Location switched off: the screen must be able to say why no new measurement comes.
        val locationOff = reducer.reduce(state, LocationAvailability(false, true, setOf(FixProvider.GPS), WALL0 + 90, BOOT0 + 90))
        assertEquals(state.copy(nowElapsedMs = BOOT0 + 90, locationEnabled = false), locationOff)
        val failed = reducer.reduce(locationOff, CellInfoRequestFailed(1, "modem busy", WALL0 + 95, BOOT0 + 95))
        assertEquals(locationOff.copy(nowElapsedMs = BOOT0 + 95), failed)
        assertEquals(true, reducer.reduce(failed, LocationAvailability(true, true, setOf(FixProvider.GPS), WALL0 + 99, BOOT0 + 99)).locationEnabled)
    }

    @Test
    fun timeNeverMovesBackwards() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(5_000, listOf(lte(4_000))))
        assertEquals(BOOT0 + 5_000, state.nowElapsedMs)

        state = reducer.tick(state, BOOT0 + 1_000)
        assertEquals(BOOT0 + 5_000, state.nowElapsedMs)
        assertEquals(1_000L, state.servingAgeMs)

        state = reducer.reduce(state, ServiceStateSnapshot(ServiceRegState.IN_SERVICE, false, null, null, null, WALL0 + 2_000, BOOT0 + 2_000))
        assertEquals(BOOT0 + 5_000, state.nowElapsedMs)

        state = reducer.tick(state, BOOT0 + 9_000)
        assertEquals(BOOT0 + 9_000, state.nowElapsedMs)
        assertEquals(5_000L, state.servingAgeMs)
        assertEquals(AgeBadge.AGING, state.badge)
    }

    @Test
    fun tickWithoutAServingCellKeepsTheBadgeAtNone() {
        val state = LiveStateReducer().tick(LiveState(), BOOT0)
        assertNull(state.servingAgeMs)
        assertEquals(AgeBadge.NONE, state.badge)
        assertEquals(BOOT0, state.nowElapsedMs)
    }

    @Test
    fun liveCellNeedsBothMccAndMncForAPlmnAndFallsBackToTheShortOperatorName() {
        val cell = lte(0).copy(mnc = null, operatorLong = " ", operatorShort = "VZW", bands = emptyList())
        val live = LiveCell.of(cell)
        assertNull(live.plmn)
        assertEquals("VZW", live.operator)
        assertNull(live.band)

        assertNull(LiveCell.of(cell.copy(operatorShort = null)).operator)
    }

    private fun fix(elapsedMs: Long): FixSample = FixSample(
        elapsedMs = elapsedMs,
        wallMs = WALL0 + (elapsedMs - BOOT0),
        lat = 40.7128,
        lon = -74.006,
        accuracyM = 4.0,
        altitudeM = null,
        speedMps = 1.2,
        provider = FixProvider.GPS,
        mock = false,
        observedWallMs = WALL0 + (elapsedMs - BOOT0),
        observedElapsedMs = elapsedMs,
    )

    @Test
    fun anLteSecondaryServingCarrierIsAnAggregatedLegNotANeighbour() {
        val state = LiveStateReducer().reduce(
            LiveState(),
            answer(
                400,
                listOf(
                    lte(0, pci = 212),
                    lte(0, pci = 300, status = CellSnapshot.CONNECTION_SECONDARY_SERVING, rsrp = -95, cellId = 2),
                    lte(0, pci = 100, status = CellSnapshot.CONNECTION_NONE, rsrp = -110, cellId = 1),
                ),
            ),
        )
        assertEquals(212, state.serving?.pci)
        assertEquals(
            "a carrier the phone is aggregating is not a neighbour",
            listOf(100),
            state.neighbours.map { it.pci },
        )
        assertEquals(listOf(300), state.aggregatedLegs.map { it.pci })
    }

    @Test
    fun anNrSecondaryCarrierOnStandaloneIsAnAggregatedLegNotANeighbour() {
        val state = LiveStateReducer().reduce(
            LiveState(),
            answer(
                400,
                listOf(
                    nr(0, pci = 393, status = CellSnapshot.CONNECTION_PRIMARY_SERVING),
                    nr(0, pci = 394, status = CellSnapshot.CONNECTION_SECONDARY_SERVING),
                ),
            ),
        )
        assertEquals(393, state.serving?.pci)
        assertNull("standalone NR has no NSA leg", state.nsaLeg)
        assertTrue(state.neighbours.isEmpty())
        assertEquals(listOf(394), state.aggregatedLegs.map { it.pci })
    }

    @Test
    fun theNsaLegIsNotRepeatedAmongTheAggregatedLegs() {
        val state = LiveStateReducer().reduce(
            LiveState(),
            answer(400, listOf(lte(0, pci = 212), nr(0, pci = 393))),
        )
        assertEquals(393, state.nsaLeg?.pci)
        assertTrue("the NSA leg is shown once, as the NSA leg", state.aggregatedLegs.isEmpty())
        assertTrue(state.neighbours.isEmpty())
    }

    @Test
    fun theServingCellHistoryStartsWithTheCellServingNow() {
        val state = LiveStateReducer().reduce(LiveState(), answer(400, listOf(lte(0, pci = 212))))
        assertEquals(listOf(212), state.servingHistory.map { it.cell.pci })
        val visit = state.servingHistory.single()
        assertEquals("one sample is a zero dwell, not an unknown one", visit.sinceMs, visit.untilMs)
    }

    @Test
    fun stayingOnOneCellExtendsItsVisitRatherThanAddingAnother() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(400, listOf(lte(0, pci = 212))))
        state = reducer.reduce(state, answer(2_400, listOf(lte(2_000, pci = 212))))
        state = reducer.reduce(state, answer(4_400, listOf(lte(4_000, pci = 212))))
        val visit = state.servingHistory.single()
        assertEquals(212, visit.cell.pci)
        assertEquals(4_000L, visit.untilMs - visit.sinceMs)
    }

    @Test
    fun movingToAnotherCellOpensAVisitAndKeepsTheOldOne() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(400, listOf(lte(0, pci = 212))))
        state = reducer.reduce(state, answer(2_400, listOf(lte(2_000, pci = 213, cellId = 9))))
        assertEquals("newest first", listOf(213, 212), state.servingHistory.map { it.cell.pci })
    }

    @Test
    fun theHistoryIsCappedAndDropsTheOldest() {
        val reducer = LiveStateReducer()
        var state = LiveState()
        for (i in 0 until LiveStateReducer.HISTORY_MAX + 5) {
            state = reducer.reduce(
                state,
                answer(400 + i * 2_000L, listOf(lte(i * 2_000L, pci = 100 + i, cellId = i.toLong()))),
            )
        }
        assertEquals(LiveStateReducer.HISTORY_MAX, state.servingHistory.size)
        assertEquals("the newest is kept", 100 + LiveStateReducer.HISTORY_MAX + 4, state.servingHistory.first().cell.pci)
    }

    @Test
    fun returningToAnEarlierCellIsANewVisit() {
        val reducer = LiveStateReducer()
        var state = reducer.reduce(LiveState(), answer(400, listOf(lte(0, pci = 212))))
        state = reducer.reduce(state, answer(2_400, listOf(lte(2_000, pci = 213, cellId = 9))))
        state = reducer.reduce(state, answer(4_400, listOf(lte(4_000, pci = 212))))
        assertEquals(
            "a return is a separate stay, not a merge with the first",
            listOf(212, 213, 212),
            state.servingHistory.map { it.cell.pci },
        )
    }
}
