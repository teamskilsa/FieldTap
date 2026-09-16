package com.fieldtap.ui.live

import androidx.compose.ui.unit.dp
import com.fieldtap.app.SessionStatus
import com.fieldtap.core.input.DataConnState
import com.fieldtap.core.input.DataStateSnapshot
import com.fieldtap.core.input.DeviceConditions
import com.fieldtap.core.input.DisplayInfoSnapshot
import com.fieldtap.core.input.FixSample
import com.fieldtap.core.input.ListenerOutcome
import com.fieldtap.core.input.RadioListener
import com.fieldtap.core.input.ServiceRegState
import com.fieldtap.core.input.ServiceStateSnapshot
import com.fieldtap.core.input.SignalSnapshot
import com.fieldtap.core.live.ChartPoint
import com.fieldtap.core.live.LiveCell
import com.fieldtap.core.live.LiveState
import com.fieldtap.core.session.RecorderSnapshot
import com.fieldtap.core.session.StartRequest
import com.fieldtap.format.FixProvider
import com.fieldtap.format.Rat
import com.fieldtap.ui.common.TestData
import com.fieldtap.ui.components.SessionButtonState
import com.fieldtap.ui.theme.StatusTone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LivePresentationTest {

    @Test
    fun cadenceReasonNamesWhatSetsTheInterval() {
        assertNull(LivePresentation.cadenceReason(null))
        for (charging in listOf(false, true)) {
            for (wifi in listOf(false, true)) {
                assertEquals(CadenceReason.SCREEN_OFF, LivePresentation.cadenceReason(DeviceConditions(screenOn = false, charging = charging, wifiConnected = wifi)))
            }
        }
        assertEquals(CadenceReason.SCREEN_ON_WIFI_OFF, LivePresentation.cadenceReason(DeviceConditions(screenOn = true, charging = false, wifiConnected = false)))
        assertEquals(CadenceReason.SCREEN_ON_WIFI_OFF, LivePresentation.cadenceReason(DeviceConditions(screenOn = true, charging = true, wifiConnected = false)))
        assertEquals(CadenceReason.CHARGING_WITH_WIFI, LivePresentation.cadenceReason(DeviceConditions(screenOn = true, charging = true, wifiConnected = true)))
        assertEquals(CadenceReason.WIFI_ON_BATTERY, LivePresentation.cadenceReason(DeviceConditions(screenOn = true, charging = false, wifiConnected = true)))
    }

    @Test
    fun theWifiPromptShowsOnlyWhileRecordingAndOnlyWhenWifiForcesTheLongInterval() {
        val wifiOnBattery = DeviceConditions(screenOn = true, charging = false, wifiConnected = true)
        assertTrue(LivePresentation.showWifiCadencePrompt(recording = true, conditions = wifiOnBattery))
        assertFalse("nothing is being recorded, so the cadence costs nothing",
            LivePresentation.showWifiCadencePrompt(recording = false, conditions = wifiOnBattery))
        assertFalse("charging restores the 2 s interval",
            LivePresentation.showWifiCadencePrompt(recording = true, conditions = wifiOnBattery.copy(charging = true)))
        assertFalse(LivePresentation.showWifiCadencePrompt(recording = true, conditions = wifiOnBattery.copy(wifiConnected = false)))
        assertFalse(LivePresentation.showWifiCadencePrompt(recording = true, conditions = null))
    }

    @Test
    fun serviceChipTakesEmergencyOnlyFromServiceState() {
        assertEquals(ServiceChip.WAITING, LivePresentation.serviceChip(null))
        assertEquals(ServiceChip.IN_SERVICE, LivePresentation.serviceChip(service(ServiceRegState.IN_SERVICE)))
        assertEquals(ServiceChip.ROAMING, LivePresentation.serviceChip(service(ServiceRegState.IN_SERVICE, roaming = true)))
        assertEquals(ServiceChip.EMERGENCY_ONLY, LivePresentation.serviceChip(service(ServiceRegState.OUT_OF_SERVICE, emergencyOnly = true)))
        assertEquals(ServiceChip.EMERGENCY_ONLY, LivePresentation.serviceChip(service(ServiceRegState.EMERGENCY_ONLY)))
        assertEquals(ServiceChip.NO_SERVICE, LivePresentation.serviceChip(service(ServiceRegState.OUT_OF_SERVICE)))
        assertEquals(ServiceChip.RADIO_OFF, LivePresentation.serviceChip(service(ServiceRegState.POWER_OFF)))
        assertEquals(ServiceChip.UNKNOWN, LivePresentation.serviceChip(service(ServiceRegState.UNKNOWN)))
        assertEquals(StatusTone.ERROR, ServiceChip.NO_SERVICE.tone)
        assertEquals(StatusTone.WARNING, ServiceChip.EMERGENCY_ONLY.tone)
    }

    @Test
    fun dataChipAndNetworkName() {
        assertEquals(DataChip.WAITING, LivePresentation.dataChip(null))
        assertEquals(DataChip.CONNECTED, LivePresentation.dataChip(data(DataConnState.CONNECTED)))
        assertEquals(DataChip.CONNECTING, LivePresentation.dataChip(data(DataConnState.HANDOVER_IN_PROGRESS)))
        assertEquals(DataChip.DISCONNECTED, LivePresentation.dataChip(data(DataConnState.DISCONNECTING)))
        assertEquals(DataChip.SUSPENDED, LivePresentation.dataChip(data(DataConnState.SUSPENDED)))
        assertEquals(DataChip.UNKNOWN, LivePresentation.dataChip(data(DataConnState.UNKNOWN)))

        assertEquals("LTE", LivePresentation.dataNetworkName(data(DataConnState.CONNECTED, networkType = 13)))
        assertEquals("NR", LivePresentation.dataNetworkName(data(DataConnState.CONNECTED, networkType = 20)))
        assertEquals("TD SCDMA", LivePresentation.dataNetworkName(data(DataConnState.CONNECTED, networkType = 17)))
        assertNull(LivePresentation.dataNetworkName(data(DataConnState.CONNECTED, networkType = 0)))
        assertNull(LivePresentation.dataNetworkName(data(DataConnState.CONNECTED, networkType = 99)))
        assertNull(LivePresentation.dataNetworkName(null))
    }

    @Test
    fun theFiveGIconIsAnIndicator() {
        assertNull(LivePresentation.fiveGIcon(null))
        assertEquals(true, LivePresentation.fiveGIcon(DisplayInfoSnapshot(13, 3, 0, 0)))
        assertEquals(true, LivePresentation.fiveGIcon(DisplayInfoSnapshot(20, 0, 0, 0)))
        assertEquals(false, LivePresentation.fiveGIcon(DisplayInfoSnapshot(13, 1, 0, 0)))
    }

    @Test
    fun gpsIsLostAfterFiveSecondsWithoutAFix() {
        assertEquals(GpsChip.Waiting, LivePresentation.gpsChip(null, 10_000))
        assertEquals(GpsChip.Fix(4.0), LivePresentation.gpsChip(fix(elapsedMs = 5_000), 10_000))
        assertEquals(GpsChip.Lost(5_001), LivePresentation.gpsChip(fix(elapsedMs = 4_999), 10_000))
        assertEquals("a fix newer than now is fresh", GpsChip.Fix(4.0), LivePresentation.gpsChip(fix(elapsedMs = 12_000), 10_000))
        assertEquals(StatusTone.ERROR, GpsChip.Lost(6_000).tone)
    }

    @Test
    fun listenerNotesSkipRegisteredAndProbeOnlyListeners() {
        val notes = LivePresentation.listenerNotes(
            mapOf(
                RadioListener.SIGNAL_STRENGTHS to ListenerOutcome.FAILED,
                RadioListener.CELL_INFO_PUSH to ListenerOutcome.MISSING_PERMISSION,
                RadioListener.SERVICE_STATE to ListenerOutcome.REGISTERED,
                RadioListener.DISPLAY_INFO to ListenerOutcome.UNREGISTERED,
                RadioListener.BARRING_INFO to ListenerOutcome.REFUSED_BY_PLATFORM,
                RadioListener.CELL_INFO_REQUEST to ListenerOutcome.MISSING_PERMISSION,
                RadioListener.DATA_CONNECTION_STATE to ListenerOutcome.REFUSED_BY_PLATFORM,
            ),
        )

        assertEquals(
            listOf(
                ListenerNote(RadioListener.CELL_INFO_REQUEST, ListenerOutcome.MISSING_PERMISSION, StatusTone.ERROR),
                ListenerNote(RadioListener.CELL_INFO_PUSH, ListenerOutcome.MISSING_PERMISSION, StatusTone.INFO),
                ListenerNote(RadioListener.SIGNAL_STRENGTHS, ListenerOutcome.FAILED, StatusTone.WARNING),
                ListenerNote(RadioListener.DATA_CONNECTION_STATE, ListenerOutcome.REFUSED_BY_PLATFORM, StatusTone.WARNING),
            ),
            notes,
        )
    }

    @Test
    fun servingNetworkDistinguishesTheNsaLeg() {
        assertNull(LivePresentation.servingNetwork(null, null))
        assertEquals(ServingNetwork.LTE, LivePresentation.servingNetwork(cell(Rat.LTE), null))
        assertEquals(ServingNetwork.LTE_WITH_NR_LEG, LivePresentation.servingNetwork(cell(Rat.LTE), cell(Rat.NR)))
        assertEquals(ServingNetwork.NR_STANDALONE, LivePresentation.servingNetwork(cell(Rat.NR), null))
        assertEquals(ServingNetwork.OTHER, LivePresentation.servingNetwork(cell(Rat.WCDMA), null))
    }

    @Test
    fun aSignalReportShowsOnlyWhenNewerThanTheServingMeasurement() {
        val lte = cell(Rat.LTE, timestampMs = 1_000)
        assertEquals(SignalReport(-91, 500), LivePresentation.newerSignalReport(lte, signal(lteRsrp = -91, modemTimestampMs = 1_500), nowElapsedMs = 2_000))
        assertNull(LivePresentation.newerSignalReport(lte, signal(lteRsrp = -91, modemTimestampMs = 1_000), nowElapsedMs = 2_000))
        assertNull(LivePresentation.newerSignalReport(lte, signal(lteRsrp = null, modemTimestampMs = 1_500), nowElapsedMs = 2_000))
        assertEquals(
            "without a modem timestamp the observation time counts",
            SignalReport(-91, 200),
            LivePresentation.newerSignalReport(lte, signal(lteRsrp = -91, modemTimestampMs = null, observedElapsedMs = 1_800), nowElapsedMs = 2_000),
        )
        assertEquals(SignalReport(-70, 0), LivePresentation.newerSignalReport(cell(Rat.NR, timestampMs = 1_000), signal(nrSsRsrp = -70, modemTimestampMs = 2_500), nowElapsedMs = 2_000))
        assertNull(LivePresentation.newerSignalReport(cell(Rat.GSM, timestampMs = 1_000), signal(lteRsrp = -91, modemTimestampMs = 1_500), nowElapsedMs = 2_000))
        assertNull(LivePresentation.newerSignalReport(null, signal(lteRsrp = -91, modemTimestampMs = 1_500), nowElapsedMs = 2_000))
    }

    @Test
    fun sinrIsNotReportedWhenRsrpFillsTheWindowAndSinrDoesNot() {
        val now = 300_000L
        val rsrp = listOf(ChartPoint(290_000, -90), ChartPoint(292_000, -91))

        assertTrue(LivePresentation.sinrNotReported(rsrp, emptyList(), now))
        assertFalse(LivePresentation.sinrNotReported(rsrp, listOf(ChartPoint(292_000, 12)), now))
        assertFalse("before any sample it is not yet known", LivePresentation.sinrNotReported(emptyList(), emptyList(), now))
        // A SINR sample older than the 5-minute window is none in it.
        assertTrue(LivePresentation.sinrNotReported(rsrp, listOf(ChartPoint(-1_000, 12)), now))
    }

    @Test
    fun theSessionButtonsSitBesideTheContentOnlyInAShortWideWindow() {
        assertTrue("a phone in landscape", LivePresentation.actionsBesideContent(915.dp, 412.dp))
        assertFalse("a phone upright", LivePresentation.actionsBesideContent(412.dp, 915.dp))
        assertFalse("a tablet in landscape", LivePresentation.actionsBesideContent(1280.dp, 800.dp))
        assertFalse("a narrow split screen", LivePresentation.actionsBesideContent(560.dp, 360.dp))
    }

    @Test
    fun twoPanesNeedTheirWidthBesideTheSessionButtons() {
        assertTrue("a large phone in landscape", LivePresentation.twoPanes(915.dp, actionsBeside = true))
        assertFalse("a small phone in landscape: one pane beside the buttons", LivePresentation.twoPanes(640.dp, actionsBeside = true))
        assertTrue("a tablet upright, buttons below", LivePresentation.twoPanes(640.dp, actionsBeside = false))
        assertFalse("a phone upright", LivePresentation.twoPanes(412.dp, actionsBeside = false))
    }

    @Test
    fun markNeedsARecordingSessionOutsideAZone() {
        assertFalse(LivePresentation.markAllowed(SessionStatus.Idle))
        assertFalse(LivePresentation.markAllowed(SessionStatus.Starting(StartRequest("Walk"))))
        assertTrue(LivePresentation.markAllowed(SessionStatus.Recording(TestData.snapshot(paused = false))))
        assertFalse(LivePresentation.markAllowed(SessionStatus.Recording(TestData.snapshot(paused = true))))
        assertTrue(LivePresentation.pausedInZone(SessionStatus.Recording(TestData.snapshot(paused = true))))
        assertFalse(LivePresentation.markAllowed(SessionStatus.Stopping(TestData.snapshot())))
    }

    @Test
    fun withoutAServingCellTheTilesSayWhy() {
        val lte = LiveCell(Rat.LTE, 212, 66_786, 66, -92, -11, 14, "311480", "Verizon", 1, 1_000)
        assertNull(LivePresentation.servingAbsence(LiveState(serving = lte, shortInterval = true)))
        assertEquals(ServingAbsence.WaitingForAnswer, LivePresentation.servingAbsence(LiveState()))

        // Answers arrive, but only for another network: the API 31 emulator reports a GSM cell while data is on HSPA.
        val gsm = LiveCell(Rat.GSM, null, 0, null, null, null, null, "310260", null, 0, 1_000)
        val hspa = DataStateSnapshot(DataConnState.CONNECTED, networkType = 10, observedWallMs = 0, observedElapsedMs = 0)
        val hspaName = LivePresentation.dataNetworkName(hspa)
        assertNotNull(hspaName)
        assertEquals(
            ServingAbsence.NoLteOrNrServing(hspaName),
            LivePresentation.servingAbsence(LiveState(neighbours = listOf(gsm), shortInterval = true, data = hspa)),
        )
        assertEquals(ServingAbsence.NoLteOrNrServing(null), LivePresentation.servingAbsence(LiveState(shortInterval = false)))

        // Data on LTE or NR while no cell is marked serving: the tile does not claim the phone is on another network.
        val onLte = hspa.copy(networkType = 13)
        assertEquals(ServingAbsence.NoLteOrNrServing(null), LivePresentation.servingAbsence(LiveState(shortInterval = true, data = onLte)))
        val onNr = hspa.copy(networkType = 20)
        assertEquals(ServingAbsence.NoLteOrNrServing(null), LivePresentation.servingAbsence(LiveState(shortInterval = true, data = onNr)))
    }

    @Test
    fun withNoCellTheTilesNameWhatStopsMeasurementsBeforeBlamingTheNetwork() {
        // With location off Android keeps answering, with no cells: the old wording blamed the network.
        assertEquals(ServingAbsence.LocationOff, LivePresentation.servingAbsence(LiveState(shortInterval = true, locationEnabled = false)))
        assertEquals(ServingAbsence.LocationOff, LivePresentation.servingAbsence(LiveState(locationEnabled = false, service = service(ServiceRegState.POWER_OFF))))
        assertEquals(ServingAbsence.RadioOff, LivePresentation.servingAbsence(LiveState(shortInterval = true, service = service(ServiceRegState.POWER_OFF))))
        assertEquals(
            ServingAbsence.EmergencyOnly,
            LivePresentation.servingAbsence(LiveState(shortInterval = true, service = service(ServiceRegState.OUT_OF_SERVICE, emergencyOnly = true))),
        )
        assertEquals(ServingAbsence.NoService, LivePresentation.servingAbsence(LiveState(shortInterval = true, service = service(ServiceRegState.OUT_OF_SERVICE))))
        assertEquals(ServingAbsence.NoService, LivePresentation.servingAbsence(LiveState(service = service(ServiceRegState.OUT_OF_SERVICE))))
        assertEquals(
            ServingAbsence.NoLteOrNrServing(null),
            LivePresentation.servingAbsence(LiveState(shortInterval = true, locationEnabled = true, service = service(ServiceRegState.IN_SERVICE))),
        )
    }

    @Test
    fun aServingCellStillOnScreenGetsTheReasonItAges() {
        val lte = LiveCell(Rat.LTE, 212, 66_786, 66, -90, -9, 12, "311480", "Verizon", 1, 1_000)
        assertNull(LivePresentation.servingProblem(LiveState(serving = lte, locationEnabled = true, service = service(ServiceRegState.IN_SERVICE))))
        assertEquals(ServingAbsence.LocationOff, LivePresentation.servingProblem(LiveState(serving = lte, locationEnabled = false)))
        assertEquals(ServingAbsence.NoService, LivePresentation.servingProblem(LiveState(serving = lte, service = service(ServiceRegState.OUT_OF_SERVICE))))
        // A SIM-less phone camps on a cell for emergency calls and reports it as registered.
        assertEquals(
            ServingAbsence.EmergencyOnly,
            LivePresentation.servingProblem(LiveState(serving = lte, service = service(ServiceRegState.IN_SERVICE, emergencyOnly = true))),
        )
        assertNull(LivePresentation.servingAbsence(LiveState(serving = lte, locationEnabled = false)))
    }

    @Test
    fun theRecordingStripSaysWhetherTheSessionIsCollecting() {
        val live = LiveState()
        assertNull(LivePresentation.recordingStrip(SessionStatus.Idle, live))

        val recording = snapshot()
        assertEquals(RecordingStrip(RecordingState.RECORDING, 42, StripGps.FIX), LivePresentation.recordingStrip(SessionStatus.Recording(recording), live))
        assertEquals(
            RecordingStrip(RecordingState.LOCATION_OFF, 42, StripGps.LOST),
            LivePresentation.recordingStrip(SessionStatus.Recording(recording.copy(locationEnabled = false, hasRecentFix = false, trackRows = 30)), live),
        )
        assertEquals(
            RecordingState.LOCATION_OFF,
            LivePresentation.recordingStrip(SessionStatus.Recording(recording), live.copy(locationEnabled = false))?.state,
        )
        val waiting = recording.copy(paused = true, waitingForLocation = true, hasRecentFix = false, trackRows = 0)
        assertEquals(RecordingStrip(RecordingState.WAITING_FOR_LOCATION, 42, StripGps.WAITING), LivePresentation.recordingStrip(SessionStatus.Recording(waiting), live))
        assertTrue(LivePresentation.waitingForLocation(SessionStatus.Recording(waiting)))
        assertFalse("waiting for a fix is not a pause inside a zone", LivePresentation.pausedInZone(SessionStatus.Recording(waiting)))
        assertFalse(LivePresentation.markAllowed(SessionStatus.Recording(waiting)))
        assertTrue(LivePresentation.pausedWaitingForLocation(SessionStatus.Recording(waiting)))
        assertFalse(LivePresentation.markWaitsForLocation(SessionStatus.Recording(waiting)))
        // Held for a second or two, before the session counts as waiting: a mark tapped then waits too.
        assertTrue(LivePresentation.markWaitsForLocation(SessionStatus.Recording(recording.copy(holdingInputs = true))))
        assertTrue(LivePresentation.markWaitsForLocation(SessionStatus.Recording(recording.copy(waitingForLocation = true))))
        assertFalse(LivePresentation.markWaitsForLocation(SessionStatus.Recording(recording)))
        assertFalse(LivePresentation.pausedWaitingForLocation(SessionStatus.Recording(recording.copy(paused = true))))

        val inZone = recording.copy(paused = true)
        assertEquals(RecordingState.PAUSED_IN_ZONE, LivePresentation.recordingStrip(SessionStatus.Recording(inZone), live)?.state)
        assertTrue(LivePresentation.pausedInZone(SessionStatus.Recording(inZone)))
        assertEquals(RecordingState.SAVING, LivePresentation.recordingStrip(SessionStatus.Stopping(recording.copy(stopping = true)), live)?.state)

        assertTrue(LivePresentation.locationOff(live.copy(locationEnabled = false), SessionStatus.Idle))
        assertFalse(LivePresentation.locationOff(live, SessionStatus.Idle))
    }

    @Test
    fun theTimerButtonReadsPausedWhileARunningSessionIsNotCollecting() {
        val live = LiveState()
        val recording = snapshot()
        // A plain running session records, so the button says "Recording", not "Paused".
        assertFalse(LivePresentation.recordingPaused(SessionStatus.Recording(recording), live))
        // Location off, waiting for a first fix, or paused in a zone: it collects nothing, so the button says "Paused".
        assertTrue(LivePresentation.recordingPaused(SessionStatus.Recording(recording), live.copy(locationEnabled = false)))
        assertTrue(LivePresentation.recordingPaused(SessionStatus.Recording(recording.copy(paused = true, waitingForLocation = true, hasRecentFix = false, trackRows = 0)), live))
        assertTrue(LivePresentation.recordingPaused(SessionStatus.Recording(recording.copy(paused = true)), live))
        // Idle and saving are never "paused recording".
        assertFalse(LivePresentation.recordingPaused(SessionStatus.Idle, live))
        assertFalse(LivePresentation.recordingPaused(SessionStatus.Stopping(recording.copy(stopping = true)), live))
    }

    private fun snapshot(): RecorderSnapshot = RecorderSnapshot(
        dirName = "20260910-143000_Walk",
        startedUtcMs = 1_789_050_600_000L,
        elapsedMs = 93_000,
        servingRat = null,
        servingRsrpDbm = null,
        newestSampleAgeMs = null,
        paused = false,
        freshSamples = 42,
        repeatsDropped = 40,
        eventsWritten = 3,
        trackRows = 90,
        hasRecentFix = true,
        stopping = false,
    )

    @Test
    fun theButtonIsBusyWhileChecksOrTheStartCallRun() {
        val request = StartRequest("Walk")
        assertEquals(SessionButtonState.IDLE, LivePresentation.buttonState(SessionStatus.Idle, PrestartState.None))
        assertEquals(SessionButtonState.IDLE, LivePresentation.buttonState(SessionStatus.Idle, PrestartState.Review(request, emptyList())))
        assertEquals(SessionButtonState.STARTING, LivePresentation.buttonState(SessionStatus.Idle, PrestartState.Checking(request)))
        assertEquals(SessionButtonState.STARTING, LivePresentation.buttonState(SessionStatus.Idle, PrestartState.Starting(request)))
        assertEquals(SessionButtonState.STARTING, LivePresentation.buttonState(SessionStatus.Starting(request), PrestartState.None))
        assertEquals(SessionButtonState.RECORDING, LivePresentation.buttonState(SessionStatus.Recording(TestData.snapshot()), PrestartState.None))
        assertEquals(SessionButtonState.STOPPING, LivePresentation.buttonState(SessionStatus.Stopping(TestData.snapshot()), PrestartState.None))
    }

    private fun service(state: ServiceRegState, emergencyOnly: Boolean = false, roaming: Boolean? = false) =
        ServiceStateSnapshot(state, emergencyOnly, "311480", "Verizon", roaming, 0, 0)

    private fun data(state: DataConnState, networkType: Int = 13) = DataStateSnapshot(state, networkType, 0, 0)

    private fun fix(elapsedMs: Long) = FixSample(elapsedMs, elapsedMs, 40.0, -74.0, 4.0, null, null, FixProvider.GPS, false, elapsedMs, elapsedMs)

    private fun cell(rat: Rat, timestampMs: Long = 0) = LiveCell(rat, 1, 100, 3, -90, -10, 10, null, null, 1, timestampMs)

    private fun signal(lteRsrp: Int? = null, nrSsRsrp: Int? = null, modemTimestampMs: Long?, observedElapsedMs: Long = 0) =
        SignalSnapshot(lteRsrp, null, null, nrSsRsrp, null, null, 3, modemTimestampMs, 0, observedElapsedMs)

    private fun cell(pci: Int?, arfcn: Int? = 1850, rat: Rat = Rat.LTE, rsrp: Int? = -100) =
        LiveCell(rat, pci, arfcn, 3, rsrp, -11, 9, "311480", "Verizon", 0, 1_000L)

    @Test
    fun aNeighbourReusingThePciModuloThirtyIsFlaggedWithItsMargin() {
        val state = LiveState(
            serving = cell(101, rsrp = -90).copy(connectionStatus = 1),
            neighbours = listOf(cell(131, rsrp = -95)),
        )
        val rows = LivePresentation.neighbourRows(state)
        assertEquals(1, rows.size)
        assertEquals(setOf(3, 6, 30), rows[0].pciReuse)
        assertEquals(5, rows[0].marginDb)
    }

    @Test
    fun aNeighbourOnAnotherCarrierIsNotFlagged() {
        val state = LiveState(
            serving = cell(101, arfcn = 1850),
            neighbours = listOf(cell(131, arfcn = 66_786)),
        )
        assertTrue(LivePresentation.neighbourRows(state).single().pciReuse.isEmpty())
    }

    @Test
    fun withNoServingCellNothingIsFlagged() {
        val state = LiveState(serving = null, neighbours = listOf(cell(131)))
        val row = LivePresentation.neighbourRows(state).single()
        assertTrue(row.pciReuse.isEmpty())
        assertNull(row.marginDb)
    }

    @Test
    fun neighbourRowsKeepTheOrderLiveDraws() {
        val state = LiveState(
            serving = cell(101),
            neighbours = listOf(cell(104), cell(131), cell(200)),
        )
        assertEquals(listOf(104, 131, 200), LivePresentation.neighbourRows(state).map { it.cell.pci })
    }
}
