package com.fieldtap.ui.live

import com.fieldtap.app.SessionStatus
import com.fieldtap.app.StartResult
import com.fieldtap.core.live.LiveState
import com.fieldtap.core.readiness.ReadinessCheck
import com.fieldtap.core.readiness.ReadinessLevel
import com.fieldtap.core.readiness.SettingsTarget
import com.fieldtap.core.session.StartRefusal
import com.fieldtap.core.session.StartRequest
import com.fieldtap.core.session.StoragePolicy
import com.fieldtap.core.session.StorageStatus
import com.fieldtap.ui.common.FakeAppGraph
import com.fieldtap.ui.common.MainDispatcherRule
import com.fieldtap.ui.common.TestData
import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LiveViewModelTest {
    @get:Rule
    val main = MainDispatcherRule()

    private val graph = FakeAppGraph()

    @Test
    fun aStartWithNoProblemStartsAtOnceWithTrimmedFields() = runTest(main.dispatcher) {
        val viewModel = collected()

        viewModel.start(StartRequest(name = "  Mall walk ", note = "  ", location = " North path ", testsEnabled = true, walkMode = true))
        runCurrent()

        assertEquals(listOf(StartRequest("Mall walk", null, "North path", true, true)), graph.sessionControl.startRequests)
        assertEquals(1, graph.readiness.checks)
        assertEquals(PrestartState.None, viewModel.state.value.prestart)
        assertNull(viewModel.state.value.refusal)
        assertTrue(viewModel.state.value.status is SessionStatus.Starting)
    }

    @Test
    fun refusalsAreSurfacedWithTheProblemTheSheetCanName() = runTest(main.dispatcher) {
        graph.sessionControl.startResult = StartResult.Refused(StartRefusal.LOCATION_OFF)
        val viewModel = collected()

        viewModel.start(StartRequest("Walk"))
        runCurrent()

        val state = viewModel.state.value
        assertEquals(StartRefusal.LOCATION_OFF, state.refusal)
        val review = state.prestart as PrestartState.Review
        assertEquals(listOf(PrestartIssue(PrestartIssueKind.LOCATION_OFF, blocking = true)), review.issues)
        assertFalse(review.canStartAnyway)

        viewModel.startAnyway()
        assertEquals("a blocked sheet never starts", 1, graph.sessionControl.startRequests.size)

        viewModel.dismissPrestart()
        viewModel.dismissRefusal()
        runCurrent()
        assertEquals(PrestartState.None, viewModel.state.value.prestart)
        assertNull(viewModel.state.value.refusal)
    }

    @Test
    fun aRefusalTheSheetCannotNameStaysARefusal() = runTest(main.dispatcher) {
        graph.sessionControl.startResult = StartResult.Refused(StartRefusal.SESSION_RUNNING)
        val viewModel = collected()

        viewModel.start(StartRequest("Walk"))
        runCurrent()

        assertEquals(StartRefusal.SESSION_RUNNING, viewModel.state.value.refusal)
        assertEquals(PrestartState.None, viewModel.state.value.prestart)
    }

    @Test
    fun aRunningSessionOrABlankNameIsRefusedWithoutAStartCall() = runTest(main.dispatcher) {
        val viewModel = collected()

        viewModel.start(StartRequest("   "))
        runCurrent()
        assertEquals(StartRefusal.BLANK_NAME, viewModel.state.value.refusal)

        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot())
        viewModel.start(StartRequest("Walk"))
        runCurrent()
        assertEquals(StartRefusal.SESSION_RUNNING, viewModel.state.value.refusal)

        assertTrue(graph.sessionControl.startRequests.isEmpty())
        assertEquals(0, graph.readiness.checks)
    }

    @Test
    fun adviceStartsTheSessionAndSaysSoRatherThanOpeningTheSheet() = runTest(main.dispatcher) {
        graph.readiness.report = TestData.readiness(ReadinessCheck.WIFI_OFF to ReadinessLevel.ADVICE)
        val viewModel = collected()

        viewModel.start(StartRequest("Session"))
        runCurrent()

        assertEquals("advice is not a gate", PrestartState.None, viewModel.state.value.prestart)
        assertEquals(listOf(StartRequest("Session")), graph.sessionControl.startRequests)
        assertEquals(LiveMessage.STARTED_WITH_ADVICE, viewModel.state.value.message?.message)
    }

    @Test
    fun aBlockingReadinessItemHidesStartAnyway() = runTest(main.dispatcher) {
        graph.readiness.report = TestData.readiness(ReadinessCheck.PRECISE_LOCATION to ReadinessLevel.BLOCKER)
        val viewModel = collected()

        viewModel.start(StartRequest("Walk"))
        viewModel.startAnyway()
        runCurrent()

        val review = viewModel.state.value.prestart as PrestartState.Review
        assertFalse(review.canStartAnyway)
        assertTrue(graph.sessionControl.startRequests.isEmpty())
    }

    @Test
    fun consentAndStorageAreCheckedBeforeStarting() = runTest(main.dispatcher) {
        graph.settings.stored.value = TestData.settings(consent = false)
        graph.sessions.storageStatus = StorageStatus(usedBytes = 2_000_000_000, freeBytes = 10_000_000_000, policy = StoragePolicy())
        val viewModel = collected()

        viewModel.start(StartRequest("Walk"))
        runCurrent()

        val review = viewModel.state.value.prestart as PrestartState.Review
        assertEquals(listOf(PrestartIssueKind.NO_CONSENT, PrestartIssueKind.STORAGE_FULL), review.issues.map { it.kind })
        assertTrue(review.issues.all { it.blocking })
        assertTrue(graph.sessionControl.startRequests.isEmpty())
    }

    @Test
    fun aReadinessCheckThatFailsIsAdviceNotABlock() = runTest(main.dispatcher) {
        graph.readiness.failure = IllegalStateException("UsageStatsManager unavailable")
        graph.settings.currentFailure = IOException("DataStore unreadable")
        val viewModel = collected()

        viewModel.start(StartRequest("Session"))
        runCurrent()

        // A check that could not run is advice, so it must not stop the session either.
        assertEquals(PrestartState.None, viewModel.state.value.prestart)
        assertEquals(1, graph.sessionControl.startRequests.size)
        assertEquals(LiveMessage.STARTED_WITH_ADVICE, viewModel.state.value.message?.message)
    }

    @Test
    fun aCleanStartSaysNothingExtra() = runTest(main.dispatcher) {
        val viewModel = collected()

        viewModel.start(StartRequest("Session"))
        runCurrent()

        assertEquals(1, graph.sessionControl.startRequests.size)
        assertEquals("nothing to advise, so no message", null, viewModel.state.value.message?.message)
    }

    @Test
    fun recheckingAfterAFixUpdatesTheSheetAndClearsABlockingRefusal() = runTest(main.dispatcher) {
        graph.sessionControl.startResult = StartResult.Refused(StartRefusal.NO_PRECISE_LOCATION)
        val viewModel = collected()
        viewModel.start(StartRequest("Walk"))
        runCurrent()
        assertEquals(StartRefusal.NO_PRECISE_LOCATION, viewModel.state.value.refusal)

        viewModel.recheckReadiness()
        runCurrent()

        val review = viewModel.state.value.prestart as PrestartState.Review
        assertTrue("the facts no longer show a problem", review.issues.isEmpty())
        assertTrue(review.canStartAnyway)
        assertNull(viewModel.state.value.refusal)
    }

    @Test
    fun recheckDoesNothingWithoutTheSheet() = runTest(main.dispatcher) {
        val viewModel = collected()

        viewModel.recheckReadiness()
        runCurrent()

        assertEquals(0, graph.readiness.checks)
        assertEquals(PrestartState.None, viewModel.state.value.prestart)
    }

    @Test
    fun aStartThatThrowsSaysSo() = runTest(main.dispatcher) {
        graph.sessionControl.startFailure = IllegalStateException("foreground service not allowed")
        val viewModel = collected()

        viewModel.start(StartRequest("Walk"))
        runCurrent()

        assertEquals(LiveMessage.START_FAILED, viewModel.state.value.message?.message)
        assertEquals(PrestartState.None, viewModel.state.value.prestart)
    }

    @Test
    fun anAcceptedStartThatFallsBackToIdleWithoutAnOutcomeSaysItFailed() = runTest(main.dispatcher) {
        val viewModel = collected()

        viewModel.start(StartRequest("Walk"))
        runCurrent()
        assertTrue(viewModel.state.value.status is SessionStatus.Starting)
        assertNull(viewModel.state.value.message)

        // The runtime gave up (foreground refused, service not up in time, files not creatable): no outcome.
        graph.sessionControl.status.value = SessionStatus.Idle
        runCurrent()

        assertEquals(LiveMessage.START_FAILED, viewModel.state.value.message?.message)
    }

    @Test
    fun anAcceptedStartThatRecordsOrEndsWithAnOutcomeSaysNothing() = runTest(main.dispatcher) {
        val viewModel = collected()

        viewModel.start(StartRequest("Walk"))
        runCurrent()
        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot())
        runCurrent()
        graph.sessionControl.status.value = SessionStatus.Idle
        runCurrent()
        assertNull(viewModel.state.value.message)

        viewModel.start(StartRequest("Second walk"))
        runCurrent()
        assertTrue(viewModel.state.value.status is SessionStatus.Starting)
        // A session that ended on its own while starting publishes its outcome: that is not a failed start.
        graph.sessionControl.lastOutcome.value = TestData.outcome(stoppedBy = "storage_full")
        graph.sessionControl.status.value = SessionStatus.Idle
        runCurrent()

        assertNull(viewModel.state.value.message)
    }

    @Test
    fun markIsDisabledWhilePausedInAPrivacyZone() = runTest(main.dispatcher) {
        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot(paused = true))
        val viewModel = collected()
        runCurrent()

        assertFalse(viewModel.state.value.markEnabled)
        assertTrue(viewModel.state.value.pausedInZone)

        viewModel.mark("corner")
        runCurrent()

        assertTrue(graph.sessionControl.marks.isEmpty())
        assertEquals(LiveMessage.PAUSED, viewModel.state.value.message?.message)
    }

    @Test
    fun markWhileRecordingForwardsTheTrimmedNote() = runTest(main.dispatcher) {
        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot(paused = false))
        val viewModel = collected()
        runCurrent()
        assertTrue(viewModel.state.value.markEnabled)

        viewModel.mark("  corner of hall B  ")
        viewModel.mark("   ")
        runCurrent()

        assertEquals(listOf("corner of hall B", null), graph.sessionControl.marks)
        assertEquals(LiveMessage.MARKED, viewModel.state.value.message?.message)
    }

    @Test
    fun aMarkTappedWhileInputsWaitForAFixSaysItIsKeptAndSaysWhenAPauseDropsIt() = runTest(main.dispatcher) {
        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot().copy(holdingInputs = true))
        val viewModel = collected()
        runCurrent()

        viewModel.mark("door 3")
        runCurrent()
        assertEquals(listOf<String?>("door 3"), graph.sessionControl.marks)
        assertEquals(LiveMessage.MARK_HELD, viewModel.state.value.message?.message)

        // No fix came: logging paused and the recorder dropped the marker.
        graph.sessionControl.status.value =
            SessionStatus.Recording(TestData.snapshot(paused = true).copy(waitingForLocation = true, markersDropped = 1))
        runCurrent()
        assertEquals(LiveMessage.MARK_DROPPED, viewModel.state.value.message?.message)

        viewModel.mark("again")
        runCurrent()
        assertEquals(LiveMessage.PAUSED_NO_FIX, viewModel.state.value.message?.message)
        assertEquals(1, graph.sessionControl.marks.size)
    }

    @Test
    fun aMarkerDroppedAtStopIsSaidOnceAndACountFromBeforeTheScreenOpenedIsNot() = runTest(main.dispatcher) {
        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot().copy(markersDropped = 1))
        val viewModel = collected()
        runCurrent()
        assertNull(viewModel.state.value.message)

        graph.sessionControl.lastOutcome.value = TestData.outcome(stoppedBy = "user").copy(markersDropped = 2)
        graph.sessionControl.status.value = SessionStatus.Idle
        runCurrent()
        assertEquals(LiveMessage.MARK_DROPPED, viewModel.state.value.message?.message)
        val said = viewModel.state.value.message?.id

        graph.sessionControl.status.value = SessionStatus.Stopping(TestData.snapshot().copy(markersDropped = 2))
        runCurrent()
        assertEquals("the same count is not said twice", said, viewModel.state.value.message?.id)
    }

    @Test
    fun markWithoutASessionOrRefusedByTheRecorderSaysSo() = runTest(main.dispatcher) {
        val viewModel = collected()

        viewModel.mark("x")
        runCurrent()
        assertEquals(LiveMessage.NOT_RECORDING, viewModel.state.value.message?.message)
        assertTrue(graph.sessionControl.marks.isEmpty())

        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot())
        graph.sessionControl.markResult = false
        viewModel.mark("x")
        runCurrent()
        assertEquals(LiveMessage.NOT_RECORDING, viewModel.state.value.message?.message)
        assertEquals(listOf<String?>("x"), graph.sessionControl.marks)
    }

    @Test
    fun recoveredSessionsShowUntilAcknowledged() = runTest(main.dispatcher) {
        val outcome = TestData.outcome()
        graph.recovery.closed.value = listOf(outcome)
        val viewModel = collected()
        runCurrent()
        assertEquals(listOf(outcome), viewModel.state.value.recovered)

        viewModel.acknowledgeRecovered(outcome.dirName)
        runCurrent()

        assertEquals(listOf(outcome.dirName), graph.recovery.acknowledged)
        assertTrue(viewModel.state.value.recovered.isEmpty())
    }

    @Test
    fun theTestsDefaultFollowsTheSetting() = runTest(main.dispatcher) {
        graph.settings.stored.value = TestData.settings(testsDefaultOn = true)
        val viewModel = collected()
        runCurrent()
        assertTrue(viewModel.state.value.testsDefaultOn)

        graph.settings.stored.value = TestData.settings(testsDefaultOn = false)
        runCurrent()
        assertFalse(viewModel.state.value.testsDefaultOn)
    }

    @Test
    fun unreadableSettingsFallBackToDefaults() = runTest(main.dispatcher) {
        graph.settings.flowFailure = IOException("DataStore corrupt")
        val viewModel = collected()
        graph.live.state.value = LiveState(nowElapsedMs = 42)
        runCurrent()

        assertFalse(viewModel.state.value.testsDefaultOn)
        assertEquals(42L, viewModel.state.value.live.nowElapsedMs)
    }

    @Test
    fun aNewerMessageSurvivesConsumingAnOlderOne() = runTest(main.dispatcher) {
        val viewModel = collected()
        viewModel.mark(null)
        runCurrent()
        val first = viewModel.state.value.message!!

        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot())
        viewModel.mark(null)
        runCurrent()
        val second = viewModel.state.value.message!!

        viewModel.consumeMessage(first.id)
        runCurrent()
        assertEquals(second, viewModel.state.value.message)

        viewModel.consumeMessage(second.id)
        runCurrent()
        assertNull(viewModel.state.value.message)
    }

    @Test
    fun stopAndTheClockGoThroughTheGraph() = runTest(main.dispatcher) {
        val viewModel = collected()

        viewModel.stop()
        viewModel.stop()

        assertEquals(2, graph.sessionControl.stops)
        assertEquals(graph.clock.wallMs, viewModel.nowWallMs())
    }

    /** A view model whose state is collected, as the screen collects it. */
    private fun TestScope.collected(): LiveViewModel {
        val viewModel = LiveViewModel(graph)
        backgroundScope.launch { viewModel.state.collect {} }
        return viewModel
    }
}
