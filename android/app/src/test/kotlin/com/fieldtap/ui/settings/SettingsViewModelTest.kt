@file:OptIn(ExperimentalCoroutinesApi::class)

package com.fieldtap.ui.settings

import com.fieldtap.core.live.LiveState
import com.fieldtap.core.nettest.TestSettings
import com.fieldtap.core.privacy.Consent
import com.fieldtap.core.privacy.PrivacyZone
import com.fieldtap.core.privacy.PrivacyZones
import com.fieldtap.ui.setup.FakeAppGraph
import com.fieldtap.ui.setup.SetupMainDispatcherRule
import com.fieldtap.ui.setup.SetupSamples
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class SettingsViewModelTest {
    @get:Rule
    val mainRule = SetupMainDispatcherRule()

    private val home = PrivacyZone(id = "home", label = "Home", lat = 52.520008, lon = 13.404954, radiusM = 200.0)
    private val office = PrivacyZone(id = "office", label = "Office", lat = 48.137154, lon = 11.576124, radiusM = 150.0)

    @Test
    fun theStateFollowsTheStoredSettings() = runTest {
        val graph = FakeAppGraph(SetupSamples.settings(zones = listOf(home)))
        val viewModel = SettingsViewModel(graph)
        assertNull(viewModel.state.value.settings)

        advanceUntilIdle()
        assertEquals(listOf(home), viewModel.state.value.settings?.zones)

        graph.fakeSettings.stored.value = graph.fakeSettings.stored.value.copy(testsDefaultOn = true)
        advanceUntilIdle()
        assertEquals(true, viewModel.state.value.settings?.testsDefaultOn)
        assertFalse(viewModel.loadFailed.value)
    }

    @Test
    fun unreadableSettingsAreShownAndCanBeReadAgain() = runTest {
        val graph = FakeAppGraph()
        graph.fakeSettings.readFailure = IOException("unreadable")
        val viewModel = SettingsViewModel(graph)
        advanceUntilIdle()
        assertTrue(viewModel.loadFailed.value)
        assertNull(viewModel.state.value.settings)

        graph.fakeSettings.readFailure = null
        viewModel.retryLoad()
        advanceUntilIdle()
        assertFalse(viewModel.loadFailed.value)
        assertNotNull(viewModel.state.value.settings)
    }

    @Test
    fun anInvalidZoneIsRejectedAtOnceWithItsProblemsAndNotSaved() = runTest {
        val graph = FakeAppGraph()
        val viewModel = SettingsViewModel(graph)
        advanceUntilIdle()
        val invalid = PrivacyZone(id = "zone", label = " ", lat = 91.0, lon = 0.0, radiusM = 10.0)

        viewModel.saveZone(invalid)

        assertEquals(PrivacyZones.validate(invalid), viewModel.state.value.zoneProblems)
        assertEquals(3, viewModel.state.value.zoneProblems.size)
        advanceUntilIdle()
        assertEquals(0, graph.fakeSettings.updates)
        assertTrue(graph.fakeSettings.stored.value.zones.isEmpty())
    }

    @Test
    fun aZoneTheEditorCouldNotReadIsRejectedToo() = runTest {
        val graph = FakeAppGraph()
        val viewModel = SettingsViewModel(graph)
        advanceUntilIdle()
        val zone = ZoneDraft(id = null, label = "Home", radius = "abc", lat = "52,52", lon = "").toZone { "new-zone" }

        viewModel.saveZone(zone)

        assertEquals(
            listOf("Longitude must be between -180 and 180.", "Radius must be between 50 m and 5000 m."),
            viewModel.state.value.zoneProblems,
        )
        advanceUntilIdle()
        assertEquals(0, graph.fakeSettings.updates)
    }

    @Test
    fun aValidZoneIsAddedItsProblemsClearedAndTheSaveAnnounced() = runTest {
        val graph = FakeAppGraph()
        val viewModel = SettingsViewModel(graph)
        val events = collectEvents(viewModel)
        advanceUntilIdle()

        viewModel.saveZone(home.copy(radiusM = 1.0))
        assertFalse(viewModel.state.value.zoneProblems.isEmpty())
        viewModel.saveZone(home)
        assertTrue(viewModel.state.value.zoneProblems.isEmpty())
        advanceUntilIdle()

        assertEquals(listOf(home), graph.fakeSettings.stored.value.zones)
        assertEquals(listOf(home), viewModel.state.value.settings?.zones)
        assertEquals(listOf<SettingsEvent>(SettingsEvent.ZoneSaved), events)
    }

    @Test
    fun savingAZoneWithAKnownIdReplacesItInPlace() = runTest {
        val graph = FakeAppGraph(SetupSamples.settings(zones = listOf(home, office)))
        val viewModel = SettingsViewModel(graph)
        advanceUntilIdle()
        val moved = home.copy(label = "Flat", radiusM = 300.0)

        viewModel.saveZone(moved)
        advanceUntilIdle()

        assertEquals(listOf(moved, office), graph.fakeSettings.stored.value.zones)
    }

    @Test
    fun deleteZoneRemovesByIdAndHandsTheZoneBackForUndo() = runTest {
        val graph = FakeAppGraph(SetupSamples.settings(zones = listOf(home, office)))
        val viewModel = SettingsViewModel(graph)
        val events = collectEvents(viewModel)
        advanceUntilIdle()

        viewModel.deleteZone("home")
        advanceUntilIdle()
        assertEquals(listOf(office), graph.fakeSettings.stored.value.zones)
        assertEquals(listOf<SettingsEvent>(SettingsEvent.ZoneDeleted(home)), events)

        viewModel.saveZone((events.single() as SettingsEvent.ZoneDeleted).zone)
        advanceUntilIdle()
        assertEquals(setOf(home, office), graph.fakeSettings.stored.value.zones.toSet())
    }

    @Test
    fun deletingAnUnknownZoneChangesNothingAndSaysNothing() = runTest {
        val graph = FakeAppGraph(SetupSamples.settings(zones = listOf(home)))
        val viewModel = SettingsViewModel(graph)
        val events = collectEvents(viewModel)
        advanceUntilIdle()

        viewModel.deleteZone("nowhere")
        advanceUntilIdle()

        assertEquals(listOf(home), graph.fakeSettings.stored.value.zones)
        assertTrue(events.isEmpty())
    }

    @Test
    fun updateTestsSavesValidSettings() = runTest {
        val graph = FakeAppGraph()
        val viewModel = SettingsViewModel(graph)
        val events = collectEvents(viewModel)
        advanceUntilIdle()
        val tests = TestSettings(
            pingTarget = "10.0.2.2",
            downloadUrl = "https://speed.cloudflare.com/__down?bytes=1000000",
            downloadCapBytes = 1_000_000,
        )

        viewModel.updateTests(tests)
        advanceUntilIdle()

        assertEquals(tests, graph.fakeSettings.stored.value.tests)
        assertTrue(viewModel.testProblems.value.isEmpty())
        assertEquals(listOf<SettingsEvent>(SettingsEvent.TestsSaved), events)
    }

    @Test
    fun updateTestsRejectsInvalidSettingsAndSavesNothing() = runTest {
        val graph = FakeAppGraph()
        val viewModel = SettingsViewModel(graph)
        advanceUntilIdle()

        viewModel.updateTests(TestSettings(pingTarget = "http://8.8.8.8", downloadUrl = "http://example.com/file"))

        assertEquals(
            listOf(
                TestSettingsProblem(TestSettingsField.PING_TARGET, TestSettingsProblemKind.INVALID_HOST),
                TestSettingsProblem(TestSettingsField.DOWNLOAD_URL, TestSettingsProblemKind.NOT_HTTPS),
            ),
            viewModel.testProblems.value,
        )
        advanceUntilIdle()
        assertEquals(0, graph.fakeSettings.updates)
        assertEquals(TestSettings(), graph.fakeSettings.stored.value.tests)

        viewModel.updateTests(TestSettings())
        assertTrue(viewModel.testProblems.value.isEmpty())
    }

    @Test
    fun theTestsDefaultAndTheWalkModeDefaultAreSaved() = runTest {
        val graph = FakeAppGraph()
        val viewModel = SettingsViewModel(graph)
        advanceUntilIdle()

        viewModel.setTestsDefaultOn(true)
        advanceUntilIdle()
        assertTrue(graph.fakeSettings.stored.value.testsDefaultOn)

        viewModel.setTestsDefaultOn(false)
        advanceUntilIdle()
        assertFalse(graph.fakeSettings.stored.value.testsDefaultOn)
    }

    @Test
    fun zoneAtCurrentPositionCentresANewZoneOnTheNewestFix() = runTest {
        val graph = FakeAppGraph()
        graph.clock.elapsedMs = 100_000
        graph.fakeLive.state.value = LiveState(lastFix = SetupSamples.fix(elapsedMs = 90_000, lat = -33.8688, lon = 151.2093))
        val viewModel = SettingsViewModel(graph)

        val zone = viewModel.zoneAtCurrentPosition(label = "Hotel", radiusM = 250.0)

        assertNotNull(zone)
        assertEquals(-33.8688, zone!!.lat, 0.0)
        assertEquals(151.2093, zone.lon, 0.0)
        assertEquals("Hotel", zone.label)
        assertEquals(250.0, zone.radiusM, 0.0)
        assertEquals(zone.id, UUID.fromString(zone.id).toString())
        assertNotEquals(zone.id, viewModel.zoneAtCurrentPosition(label = "Hotel", radiusM = 250.0)?.id)
    }

    @Test
    fun zoneAtCurrentPositionNeedsAFixAtMostAMinuteOld() = runTest {
        val graph = FakeAppGraph()
        val viewModel = SettingsViewModel(graph)
        graph.clock.elapsedMs = 100_000
        assertNull(viewModel.zoneAtCurrentPosition(label = "Home", radiusM = 200.0))

        graph.fakeLive.state.value = LiveState(lastFix = SetupSamples.fix(elapsedMs = 40_000))
        assertNotNull(viewModel.zoneAtCurrentPosition(label = "Home", radiusM = 200.0))

        graph.clock.elapsedMs = 100_001
        assertNull(viewModel.zoneAtCurrentPosition(label = "Home", radiusM = 200.0))
    }

    @Test
    fun recentFixFollowsTheLiveFeedWhileCollected() = runTest {
        val graph = FakeAppGraph()
        graph.clock.elapsedMs = 100_000
        val viewModel = SettingsViewModel(graph)
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { viewModel.recentFix.collect { } }
        advanceUntilIdle()
        assertNull(viewModel.recentFix.value)

        val fix = SetupSamples.fix(elapsedMs = 95_000)
        graph.fakeLive.state.value = LiveState(lastFix = fix, nowElapsedMs = 100_000)
        advanceUntilIdle()
        assertEquals(fix, viewModel.recentFix.value)

        graph.clock.elapsedMs = 200_000
        graph.fakeLive.state.value = LiveState(lastFix = fix, nowElapsedMs = 200_000)
        advanceUntilIdle()
        assertNull(viewModel.recentFix.value)
    }

    @Test
    fun withdrawConsentClearsTheConsent() = runTest {
        val graph = FakeAppGraph(SetupSamples.settings(consent = Consent.record(grantedUtcMs = SetupSamples.NOW_UTC_MS)))
        val viewModel = SettingsViewModel(graph)
        val events = collectEvents(viewModel)
        advanceUntilIdle()

        viewModel.withdrawConsent()
        advanceUntilIdle()

        assertNull(graph.fakeSettings.stored.value.consent)
        assertFalse(Consent.isCurrent(viewModel.state.value.settings?.consent))
        assertEquals(listOf<SettingsEvent>(SettingsEvent.ConsentWithdrawn), events)
    }

    @Test
    fun aFailedWriteIsAnnouncedAndChangesNothing() = runTest {
        val graph = FakeAppGraph()
        val viewModel = SettingsViewModel(graph)
        val events = collectEvents(viewModel)
        advanceUntilIdle()

        graph.fakeSettings.failure = IOException("disk full")
        viewModel.setTestsDefaultOn(true)
        advanceUntilIdle()
        graph.fakeSettings.failure = IllegalStateException("store closed")
        viewModel.saveZone(home)
        advanceUntilIdle()

        assertEquals(listOf<SettingsEvent>(SettingsEvent.SaveFailed, SettingsEvent.SaveFailed), events)
        assertFalse(graph.fakeSettings.stored.value.testsDefaultOn)
        assertTrue(graph.fakeSettings.stored.value.zones.isEmpty())
    }

    @Test
    fun clearZoneProblemsEmptiesTheList() = runTest {
        val viewModel = SettingsViewModel(FakeAppGraph())
        viewModel.saveZone(home.copy(label = ""))
        assertFalse(viewModel.state.value.zoneProblems.isEmpty())

        viewModel.clearZoneProblems()

        assertTrue(viewModel.state.value.zoneProblems.isEmpty())
    }

    private fun TestScope.collectEvents(viewModel: SettingsViewModel): MutableList<SettingsEvent> {
        val events = mutableListOf<SettingsEvent>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { viewModel.events.collect { events += it } }
        return events
    }
}
