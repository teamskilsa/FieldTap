package com.fieldtap.e2e

import android.os.SystemClock
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import com.fieldtap.MainActivity
import com.fieldtap.R
import com.fieldtap.app.SessionStatus
import com.fieldtap.core.privacy.PrivacyZone
import com.fieldtap.core.session.RecorderSnapshot
import com.fieldtap.debug.DebugAutomation
import java.util.regex.Pattern
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/**
 * Location services switched off while a session records, with a privacy zone 10 km from the walk the host feeds.
 *
 * 1. The session starts through [DebugAutomation] and records fixes from the walk.
 * 2. Location goes off (`cmd location set-location-enabled false`): Live and the notification say so, and the files get
 *    `gps_lost` with the detail "Location services turned off".
 * 3. No fix shows where the phone is, so inputs wait for one: a marker tapped on Live is said to wait.
 * 4. A minute after the last fix outside the zone, logging pauses and drops the marker: Live and the notification say it
 *    was not saved.
 * 5. Location comes back on: the first fix resumes logging (10 km leaves no time to have visited the zone) and writes
 *    `gps_restored`.
 * 6. Stopped, the Session detail screen says a marker was not saved.
 *
 * On the Google APIs images, Google Play services answers location switched off with a "No location access" dialog over
 * the app, which Compose testing cannot see through; every wait after the switch closes it, as a user would.
 *
 * The times of the switches and what each screen said go to `e2e/location-off-result.json`, which android/e2e/check_e2e.py
 * reads with the pulled session. The host grants the permissions beforehand and switches location back on afterwards,
 * whatever happens here; the zone is removed here.
 */
@RunWith(AndroidJUnit4::class)
class LocationOffTest {
    private val compose = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(compose).around(FailureCapture(GROUP))

    private val screens = Screens(compose, GROUP)
    private val result = linkedMapOf<String, Any?>()

    @Test
    fun locationSwitchedOffIsRecordedAndADroppedMarkerIsShown() {
        E2e.upright()
        runBlocking { E2e.graph.settings.update { it.copy(zones = listOf(FAR_ZONE)) } }
        try {
            recordWithLocationSwitchedOff()
        } finally {
            setLocationEnabled(true)
            runBlocking { E2e.graph.settings.update { it.copy(zones = emptyList()) } }
        }
    }

    private fun recordWithLocationSwitchedOff() {
        screens.awaitText(R.string.live_title, Screens.LAUNCH_WAIT_MS)
        val started = runBlocking {
            DebugAutomation.start(
                context = E2e.context,
                name = SESSION_NAME,
                note = null,
                location = null,
                tests = false,
                acceptConsent = true,
                markReady = true,
                timeoutMs = START_TIMEOUT_MS,
            )
        }
        assertTrue("The session did not start: ${started.toJson()}", started.ok)
        result["dir_name"] = started.dirName
        save()
        screens.waitFor("fixes from the walk in the session", FIX_WAIT_MS) {
            snapshot()?.let { it.trackRows >= MIN_TRACK_ROWS && it.hasRecentFix } == true
        }

        result["location_off_utc_ms"] = E2e.graph.clock.wallMillis()
        save()
        setLocationEnabled(false)
        val offBanner = hasText(E2e.string(R.string.live_location_off_recording))
        waitClosingDialog("Live to say location is off", SWITCH_WAIT_MS) { screens.exists(offBanner) }
        result["live_location_off_banner"] = true
        waitClosingDialog("the notification to say location is off", NOTIFICATION_WAIT_MS) {
            E2e.notificationTitle(E2e.sessionNotification()) == E2e.string(R.string.notification_location_off_title)
        }
        result["notification_location_off"] = true
        save()
        closeLateDialog()
        screens.shot("20-live-location-off")

        // No fix shows where the phone is any more, so a marker waits for one.
        waitClosingDialog("inputs to wait for a location fix", HOLD_WAIT_MS) { snapshot()?.holdingInputs == true }
        val inDialog = hasAnyAncestor(isDialog())
        screens.click(hasText(E2e.string(R.string.live_mark)) and hasClickAction() and !inDialog)
        screens.awaitText(R.string.live_mark_dialog_title)
        screens.click(hasText(E2e.string(R.string.live_mark_confirm)) and hasClickAction() and inDialog)
        val heldMessage = hasText(E2e.string(R.string.live_message_mark_held))
        waitClosingDialog("Live to say the marker waits for a fix", SNACKBAR_WAIT_MS) { screens.exists(heldMessage) }
        result["mark_held_message"] = true
        save()

        // A minute after the last fix outside the zone, logging pauses and drops what waited, the marker with it.
        waitClosingDialog("logging to pause for want of a fix", PAUSE_WAIT_MS) {
            snapshot()?.let { it.paused && it.waitingForLocation && it.markersDropped == 1 } == true
        }
        val droppedMessage = hasText(E2e.string(R.string.live_message_mark_dropped))
        waitClosingDialog("Live to say the marker was not saved", SNACKBAR_WAIT_MS) { screens.exists(droppedMessage) }
        result["mark_dropped_message"] = true
        val droppedText = E2e.context.resources.getQuantityString(R.plurals.notification_markers_dropped, 1, 1)
        waitClosingDialog("the notification to say the marker was not saved", NOTIFICATION_WAIT_MS) {
            E2e.notificationText(E2e.sessionNotification()) == droppedText
        }
        result["notification_markers_dropped"] = true
        save()
        screens.shot("21-live-marker-dropped")

        result["location_on_utc_ms"] = E2e.graph.clock.wallMillis()
        save()
        setLocationEnabled(true)
        waitClosingDialog("logging to resume at a fix", RESUME_WAIT_MS) { snapshot()?.let { !it.paused && it.hasRecentFix } == true }
        SystemClock.sleep(AFTER_RESUME_MS)

        val stopped = runBlocking { DebugAutomation.stop(E2e.context, STOP_TIMEOUT_MS) }
        assertTrue("The session did not stop: ${stopped.toJson()}", stopped.ok)
        val outcome = checkNotNull(E2e.graph.sessionControl.lastOutcome.value) { "Stop left no session outcome" }
        assertEquals(started.dirName, outcome.dirName)
        result["outcome_markers_dropped"] = outcome.markersDropped
        save()

        screens.openTab(R.string.nav_logs)
        val row = hasText(SESSION_NAME) and hasClickAction()
        screens.await(row)
        screens.click(row)
        // The dropped-marker banner is the detail's first item and stays at the top; assert it first, then scroll to the
        // Overview section, which this banner and the tall headline push below the fold on the small API 31 screen.
        screens.await(hasText(E2e.context.resources.getQuantityString(R.plurals.detail_markers_dropped, 1, 1)))
        result["detail_markers_dropped_banner"] = true
        save()
        screens.awaitTextInList(R.string.detail_section_overview)
        screens.shotFull("22-session-detail-marker-dropped")
        screens.back()
        screens.await(row)
        // Sessions is a tab root now: leave it by the Live tab, not a Back arrow.
        screens.openTab(R.string.nav_signal)
        screens.awaitText(R.string.live_title)
    }

    private fun snapshot(): RecorderSnapshot? = (E2e.graph.sessionControl.status.value as? SessionStatus.Recording)?.snapshot

    private fun setLocationEnabled(enabled: Boolean) {
        E2e.shell("cmd location set-location-enabled $enabled")
    }

    /** [Screens.waitFor], closing Google Play services' location dialog whenever it covers the app meanwhile. */
    private fun waitClosingDialog(what: String, timeoutMs: Long, condition: () -> Boolean) {
        screens.waitFor(what, timeoutMs) {
            closeLocationDialog()
            condition()
        }
    }

    /** Gives Google Play services a few seconds to open its location dialog after the switch, and closes it if it does. */
    private fun closeLateDialog() {
        val deadline = SystemClock.elapsedRealtime() + LATE_DIALOG_MS
        while (SystemClock.elapsedRealtime() < deadline && !closeLocationDialog()) SystemClock.sleep(DIALOG_POLL_MS)
    }

    /** Taps Close on Google Play services' "No location access" dialog when it shows; true when it did. */
    private fun closeLocationDialog(): Boolean {
        val close = E2e.device.findObject(LOCATION_DIALOG_CLOSE) ?: return false
        close.click()
        E2e.device.wait(Until.gone(LOCATION_DIALOG_CLOSE), DIALOG_GONE_MS)
        result["play_services_location_dialog_closed"] = true
        return true
    }

    private fun save() {
        E2e.writeResult(RESULT_FILE, result)
    }

    private companion object {
        const val GROUP = "location-off"
        const val RESULT_FILE = "location-off-result.json"
        const val SESSION_NAME = "E2E location off"

        /**
         * 0.09 degrees, 10 km, north of where android/e2e/check_e2e.py starts the walk: after a minute without a fix, the
         * first fix still leaves no time to have been inside, so logging resumes at once.
         */
        val FAR_ZONE = PrivacyZone(id = "e2e-far-zone", label = "E2E zone 10 km north", lat = 13.0616, lon = 77.5946, radiusM = 100.0)

        /** The Close button of the dialog Google Play services opens when location services are switched off. */
        val LOCATION_DIALOG_CLOSE = By.pkg("com.google.android.gms").clazz("android.widget.Button").text(Pattern.compile("(?i)close"))

        const val MIN_TRACK_ROWS = 5L
        const val START_TIMEOUT_MS = 45_000L
        const val STOP_TIMEOUT_MS = 30_000L
        const val FIX_WAIT_MS = 60_000L
        const val SWITCH_WAIT_MS = 30_000L
        const val NOTIFICATION_WAIT_MS = 15_000L
        const val LATE_DIALOG_MS = 5_000L
        const val DIALOG_POLL_MS = 250L
        const val DIALOG_GONE_MS = 5_000L

        /** Inputs wait from 5 s after the last fix outside the zone. */
        const val HOLD_WAIT_MS = 30_000L
        const val SNACKBAR_WAIT_MS = 10_000L

        /** Logging pauses once no fix outside the zone came for 60 s. */
        const val PAUSE_WAIT_MS = 100_000L
        const val RESUME_WAIT_MS = 60_000L

        /** A few more fixes and cell answers written after logging resumed. */
        const val AFTER_RESUME_MS = 6_000L
    }
}
