package com.fieldtap.ui.nav

import com.fieldtap.format.SessionDirName
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutesTest {

    @Test
    fun sessionDetailFillsTheRouteTemplate() {
        val dirName = "20260910-143000_Mall-walk-north-path"

        val route = Routes.sessionDetail(dirName)

        assertEquals("sessions/20260910-143000_Mall-walk-north-path", route)
        assertEquals(Routes.SESSION_DETAIL.replace("{${Routes.ARG_DIR_NAME}}", dirName), route)
        assertTrue("directory names need no escaping in a route", SessionDirName.PATTERN.matches(dirName))
    }

    @Test
    fun routesAreDistinct() {
        val routes = listOf(
            Routes.DISCLOSURE, Routes.PERMISSIONS, Routes.ABOUT_ONBOARDING, Routes.LIVE, Routes.SESSIONS,
            Routes.SESSION_DETAIL, Routes.READINESS, Routes.PROBE, Routes.SETTINGS, Routes.TEST_TARGETS, Routes.ABOUT,
            Routes.TRAFFIC, Routes.CAPTURE_DETAIL,
            Routes.LIVE_GRAPH, Routes.SESSIONS_GRAPH, Routes.TRAFFIC_GRAPH, Routes.SETTINGS_GRAPH,
        )
        assertEquals(routes.size, routes.toSet().size)
    }

    @Test
    fun aCaptureNameFillsTheRouteTemplate() {
        val route = Routes.capture("20260915-084412")

        assertEquals("recordings/capture/20260915-084412", route)
        assertEquals(Routes.CAPTURE_DETAIL.replace("{${Routes.ARG_CAPTURE_NAME}}", "20260915-084412"), route)
    }

    @Test
    fun aCaptureNameIsEscapedIntoItsRoute() {
        // Capture names are stamps, but the route builder must not hand a stray "/" to the nav graph.
        assertEquals("recordings/capture/a%2Fb", Routes.capture("a/b"))
    }

    @Test
    fun everyTabsRootLivesInItsOwnGraph() {
        assertEquals(TopTab.entries.size, TopTab.entries.map { it.graph }.toSet().size)
        assertEquals(TopTab.entries.size, TopTab.entries.map { it.root }.toSet().size)
    }

    @Test
    fun theTabsAreSignalTrafficLogsSettingsInThatOrder() {
        assertEquals(listOf(TopTab.SIGNAL, TopTab.TRAFFIC, TopTab.LOGS, TopTab.SETTINGS), TopTab.entries)
    }

    @Test
    fun theAppOpensOnTheFirstUnfinishedOnboardingStep() {
        assertEquals(Routes.DISCLOSURE, StartDestination.route(consentCurrent = false, preciseLocationGranted = false))
        assertEquals("no location prompt before the disclosure", Routes.DISCLOSURE, StartDestination.route(consentCurrent = false, preciseLocationGranted = true))
        assertEquals(Routes.PERMISSIONS, StartDestination.route(consentCurrent = true, preciseLocationGranted = false))
        assertEquals(Routes.LIVE, StartDestination.route(consentCurrent = true, preciseLocationGranted = true))
    }

    @Test
    fun acceptingTheDisclosureSkipsPermissionsAlreadyGranted() {
        assertEquals(Routes.PERMISSIONS, StartDestination.afterDisclosure(preciseLocationGranted = false))
        assertEquals(Routes.LIVE, StartDestination.afterDisclosure(preciseLocationGranted = true))
    }
}
