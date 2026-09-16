package com.fieldtap.ui.sessions

import com.fieldtap.app.SessionStatus
import com.fieldtap.core.export.ExportException
import com.fieldtap.core.session.StartRequest
import com.fieldtap.core.session.StoragePolicy
import com.fieldtap.core.session.StorageStatus
import com.fieldtap.data.CaptureStore
import com.fieldtap.format.GapMeta
import com.fieldtap.format.LocationPrecision
import com.fieldtap.ui.common.FakeAppGraph
import com.fieldtap.ui.common.MainDispatcherRule
import com.fieldtap.ui.common.TestData
import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SessionsViewModelTest {
    @get:Rule
    val main = MainDispatcherRule()

    /** An empty capture store: these tests are about drives, and a phone without root has no captures. */
    @get:Rule
    val captureRoot = TemporaryFolder()

    private val graph = FakeAppGraph()

    @Test
    fun itStartsLoadingAndRefreshReadsSessionsAndStorage() = runTest(main.dispatcher) {
        val sessions = listOf(TestData.summary("20260910-150000_B"), TestData.summary("20260910-143000_A"))
        graph.sessions.summaries = sessions
        val viewModel = SessionsViewModel(graph, CaptureStore(captureRoot.root), main.dispatcher)
        assertTrue(viewModel.state.value.loading)
        assertEquals(0, graph.sessions.listCalls)

        viewModel.refresh()
        runCurrent()

        assertEquals(SessionsUiState(loading = false, sessions = sessions, storage = graph.sessions.storageStatus), viewModel.state.value)
    }

    @Test
    fun aFailedRefreshKeepsTheLastListAndSaysSo() = runTest(main.dispatcher) {
        graph.sessions.summaries = listOf(TestData.summary())
        val viewModel = SessionsViewModel(graph, CaptureStore(captureRoot.root), main.dispatcher)
        viewModel.refresh()
        runCurrent()

        graph.sessions.listFailure = IOException("storage unmounted")
        viewModel.refresh()
        runCurrent()

        val state = viewModel.state.value
        assertEquals(listOf(TestData.summary()), state.sessions)
        assertTrue(state.loadFailed)
        assertFalse(state.loading)
    }

    @Test
    fun anUnmeasurableStorageStillShowsTheSessions() = runTest(main.dispatcher) {
        graph.sessions.summaries = listOf(TestData.summary())
        graph.sessions.storageFailure = IOException("statfs failed")
        val viewModel = SessionsViewModel(graph, CaptureStore(captureRoot.root), main.dispatcher)

        viewModel.refresh()
        runCurrent()

        assertEquals(1, viewModel.state.value.sessions.size)
        assertNull(viewModel.state.value.storage)
        assertFalse(viewModel.state.value.loadFailed)
    }

    @Test
    fun aSessionStartingOrEndingRefreshesTheList() = runTest(main.dispatcher) {
        val viewModel = SessionsViewModel(graph, CaptureStore(captureRoot.root), main.dispatcher)
        runCurrent()
        assertEquals(0, graph.sessions.listCalls)

        graph.sessionControl.status.value = SessionStatus.Starting(StartRequest("Walk"))
        runCurrent()
        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot(elapsedMs = 1_000))
        runCurrent()
        graph.sessionControl.status.value = SessionStatus.Recording(TestData.snapshot(elapsedMs = 2_000))
        runCurrent()

        assertEquals("a new recorder snapshot is not a phase change", 2, graph.sessions.listCalls)
        assertFalse(viewModel.state.value.loading)
    }

    @Test
    fun storageFractionIsClampedAndAZeroCapIsFull() {
        assertEquals(0.5f, SessionsPresentation.storageFraction(StorageStatus(1_000_000_000, 0, StoragePolicy())), 0.0001f)
        assertEquals(1f, SessionsPresentation.storageFraction(StorageStatus(3_000_000_000, 0, StoragePolicy())), 0f)
        assertEquals(1f, SessionsPresentation.storageFraction(StorageStatus(0, 0, StoragePolicy(capBytes = 0))), 0f)
    }

    @Test
    fun gapsAreListedInTimeOrderUpToTheLimit() {
        val gaps = (10 downTo 1).map { GapMeta(it * 1_000L, it * 1_000L + 14_000, "screen_off") }

        val listed = SessionsPresentation.listedGaps(gaps, limit = 3)

        assertEquals(listOf(1_000L, 2_000L, 3_000L), listed.map { it.startUtcMs })
        assertEquals(GapReason.SCREEN_OFF, SessionsPresentation.gapReason("screen_off"))
        assertEquals(GapReason.APP_PAUSED, SessionsPresentation.gapReason("app_paused"))
        assertEquals(GapReason.NO_SERVICE, SessionsPresentation.gapReason("no_service"))
        assertEquals(GapReason.UNKNOWN, SessionsPresentation.gapReason("unknown"))
        assertEquals(GapReason.OTHER, SessionsPresentation.gapReason("tunnel"))
    }

    @Test
    fun theConsentVersionIsShownWithoutTheDraftSuffix() {
        assertEquals("2026-09-10", SessionsPresentation.consentVersionText("2026-09-10-draft"))
        assertEquals("2026-10-01", SessionsPresentation.consentVersionText("2026-10-01"))
        assertEquals("-draft", SessionsPresentation.consentVersionText("-draft"))
    }

    @Test
    fun exportFailureNamesTheReason() {
        assertEquals(ExportFailure.TOO_LARGE, ExportFailure.of(ExportException(ExportException.Reason.TOO_LARGE, "big")))
        assertEquals(ExportFailure.SESSION_OPEN, ExportFailure.of(ExportException(ExportException.Reason.SESSION_OPEN, "open")))
        assertEquals(ExportFailure.UNKNOWN, ExportFailure.of(IllegalStateException("bug")))
        for (reason in ExportException.Reason.entries) {
            assertEquals(reason.name, ExportFailure.of(ExportException(reason, "x")))
        }
        assertEquals(LocationPrecision.entries.size, 3)
    }
}
