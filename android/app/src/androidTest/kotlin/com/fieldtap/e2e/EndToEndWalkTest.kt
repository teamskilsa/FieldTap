package com.fieldtap.e2e

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.os.Build
import android.os.SystemClock
import android.view.WindowManager
import androidx.annotation.StringRes
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasAnyChild
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasParent
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onFirst
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import com.fieldtap.MainActivity
import com.fieldtap.R
import com.fieldtap.app.SessionStatus
import com.fieldtap.platform.Permissions
import java.io.File
import java.util.regex.Pattern
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/**
 * The whole field workflow through the real UI, from a first run to a shared zip. android/e2e/run_e2e.sh clears the
 * app first and, while this runs, feeds a walking GPS track and cycles the emulator's signal profile.
 *
 * 1. The disclosure shows before any permission prompt; consent is accepted.
 * 2. Precise location (and notifications from Android 13) are allowed in Android's own dialog.
 * 3. Live shows a serving cell with its age badge, or, with `-e expect_lte_nr false` (a modem that reports no LTE or NR
 *    cell, as on the API 31 emulator), says Android reports no LTE or NR serving cell.
 * 4. Settings: ping `10.0.2.2` (the emulator drops ICMP beyond its NAT) and a 1 MB download.
 * 5. A session with tests starts, through the pre-start sheet's "Start anyway" when it shows.
 * 6. A marker with a note on Live, and one from the session notification's Mark, whose text must then say which marker
 *    was added and when, for a few seconds; recording for `-e walk_seconds` (default 180).
 * 7. Stop; the session's detail; a zip is built, its SHA-256 on screen checked against the file, and shared.
 *
 * The result (session directory, marker note, test targets, zip name and hashes) is written to
 * `e2e/walk-result.json` after every step, and the zip is copied to `e2e/` for `fieldtap validate`.
 */
@RunWith(AndroidJUnit4::class)
class EndToEndWalkTest {
    private val compose = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(compose).around(FailureCapture(GROUP))

    private val screens = Screens(compose, GROUP)
    private val result = linkedMapOf<String, Any?>()

    @Test
    fun firstRunToSharedSession() {
        E2e.upright()
        val walkMs = (E2e.argument("walk_seconds")?.toLongOrNull() ?: DEFAULT_WALK_SECONDS) * 1_000
        result["api"] = Build.VERSION.SDK_INT
        result["session_name"] = SESSION_NAME
        result["marker_note"] = MARKER_NOTE
        result["ping_target"] = PING_TARGET
        result["download_url"] = DOWNLOAD_URL
        result["walk_ms"] = walkMs
        val expectLteNr = E2e.expectLteNr()
        result["expect_lte_nr"] = expectLteNr
        save()

        acceptDisclosureFirst()
        allowPermissions()
        screens.awaitLiveRadio(expectLteNr)
        screens.shot("04-live-radio")
        checkScreenNotKeptOnBeforeRecording()
        saveTestSettings()
        val dirName = startSession()
        val recordingSinceMs = SystemClock.elapsedRealtime()
        checkScreenKeptOnWhileRecording()
        addMarker(recordingSinceMs)
        markFromNotification()
        keepRecording(recordingSinceMs, walkMs, expectLteNr)
        stopSession(dirName, recordingSinceMs)
        checkScreenReleasedAfterStop()
        exportAndShare(dirName)
    }

    private fun acceptDisclosureFirst() {
        screens.awaitText(R.string.disclosure_heading, Screens.LAUNCH_WAIT_MS)
        assertFalse(
            "Precise location was granted before the disclosure; install the APK without -g",
            E2e.granted(Permissions.FINE_LOCATION),
        )
        assertFalse("A permission dialog showed over the disclosure", PermissionDialogs.showing())
        screens.shot("01-disclosure")
        screens.click(hasText(E2e.string(R.string.disclosure_accept)) and hasClickAction())
        screens.awaitText(R.string.permissions_location_title)
        assertFalse("A permission dialog showed before Allow was tapped", PermissionDialogs.showing())
        assertFalse("Precise location was granted without a prompt", E2e.granted(Permissions.FINE_LOCATION))
        screens.shot("02-permissions")
        result["disclosure_before_prompt"] = true
        save()
    }

    private fun allowPermissions() {
        result["location_permission"] = allow(
            R.string.permissions_location_title,
            Permissions.LOCATION,
            PermissionDialogs.LOCATION_WHILE_IN_USE,
            PermissionDialogs.ALLOW,
        )
        assertTrue("Precise location is not granted after Android's dialog", E2e.granted(Permissions.FINE_LOCATION))
        result["notification_permission"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            allow(R.string.permissions_notifications_title, listOf(Permissions.POST_NOTIFICATIONS), PermissionDialogs.ALLOW)
        } else {
            "not_a_runtime_permission"
        }
        screens.shot("03-permissions-allowed")
        screens.click(hasText(E2e.string(R.string.permissions_continue)) and hasClickAction() and isEnabled())
        save()
    }

    /**
     * Taps Allow on the card titled [cardTitle], answers Android's dialog with the first of [buttons] it offers, and waits
     * for the card to say Allowed. Returns how the permission was granted: `dialog`, or `granted_by_instrumentation`
     * when the dialog appeared without any of those buttons (it is then granted as `adb shell pm grant` would, and the
     * dialog dismissed).
     */
    private fun allow(@StringRes cardTitle: Int, permissions: List<String>, vararg buttons: String): String {
        val inCard = hasParent(hasAnyChild(hasText(E2e.string(cardTitle))))
        val allowButton = hasText(E2e.string(R.string.permissions_action_allow)) and hasClickAction() and inCard
        // A card lower on the screen can sit under the Continue bar, where a tap would land on the bar instead.
        screens.scrollTo(allowButton)
        screens.click(allowButton)
        val how = if (PermissionDialogs.answer(*buttons)) {
            "dialog"
        } else {
            permissions.forEach { E2e.instrumentation.uiAutomation.grantRuntimePermission(E2e.context.packageName, it) }
            if (PermissionDialogs.showing()) E2e.device.pressBack()
            "granted_by_instrumentation"
        }
        assertTrue("Android's permission dialog is still open", PermissionDialogs.awaitGone())
        screens.await(hasText(E2e.string(R.string.permissions_status_allowed)) and inCard, PERMISSION_WAIT_MS)
        return how
    }

    private fun saveTestSettings() {
        screens.openTab(R.string.nav_settings)
        screens.awaitText(R.string.settings_section_measurement)
        // The targets are a screen of their own, opened from the tests card's row.
        val targets = hasText(E2e.string(R.string.settings_test_targets)) and hasClickAction()
        screens.scrollTo(targets)
        screens.click(targets)
        screens.awaitText(R.string.settings_ping_heading)
        screens.replaceText(R.string.settings_ping_target, PING_TARGET)
        screens.replaceText(R.string.settings_ping_interval, PING_INTERVAL_S.toString())
        screens.replaceText(R.string.settings_ping_count, PING_COUNT.toString())
        screens.replaceText(R.string.settings_download_url, DOWNLOAD_URL)
        screens.replaceText(R.string.settings_download_interval, DOWNLOAD_INTERVAL_MIN.toString())
        screens.replaceText(R.string.settings_download_cap, DOWNLOAD_CAP_MB.toString())
        screens.replaceText(R.string.settings_download_budget, SESSION_BUDGET_MB.toString())
        Espresso.closeSoftKeyboard()
        // Leaving with these edits unsaved asks first instead of dropping them: keep editing, then save.
        screens.back()
        screens.awaitText(R.string.settings_discard_title)
        screens.click(hasText(E2e.string(R.string.settings_discard_keep)) and hasClickAction())
        // Save is pinned in the bar under the form, so it needs no scrolling.
        val save = hasText(E2e.string(R.string.settings_tests_save)) and hasClickAction() and isEnabled()
        screens.await(save)
        screens.shot("05-settings-tests")
        screens.click(save)
        screens.awaitText(R.string.settings_tests_saved)

        val tests = runBlocking { E2e.graph.settings.current().tests }
        assertEquals(PING_TARGET, tests.pingTarget)
        assertEquals(PING_INTERVAL_S * 1_000L, tests.pingIntervalMs)
        assertEquals(PING_COUNT, tests.pingCount)
        assertEquals(DOWNLOAD_URL, tests.downloadUrl)
        assertEquals(DOWNLOAD_INTERVAL_MIN * 60_000L, tests.downloadIntervalMs)
        assertEquals(DOWNLOAD_CAP_MB * 1_000_000L, tests.downloadCapBytes)
        assertEquals(SESSION_BUDGET_MB * 1_000_000L, tests.sessionBudgetBytes)
        screens.back()
        screens.awaitText(R.string.settings_title)
        // Settings is a tab root now: leave it by the Live tab, not a Back arrow.
        screens.openTab(R.string.nav_signal)
        screens.awaitText(R.string.live_title)
    }

    /** True while the activity holds FLAG_KEEP_SCREEN_ON. */
    private fun keepsScreenOn(): Boolean {
        compose.waitForIdle()
        var held = false
        compose.runOnUiThread {
            held = compose.activity.window.attributes.flags and
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
        }
        return held
    }

    /** The window brightness, which must stay untouched. */
    private fun windowBrightness(): Float {
        compose.waitForIdle()
        var brightness = 0f
        compose.runOnUiThread { brightness = compose.activity.window.attributes.screenBrightness }
        return brightness
    }

    /** Idle on Live, nothing is being recorded, so the screen is allowed to sleep. */
    private fun checkScreenNotKeptOnBeforeRecording() {
        val held = keepsScreenOn()
        result["keep_screen_on_before_recording"] = held
        save()
        assertFalse("The screen was kept on before a session started", held)
    }

    /**
     * While a session records, the screen is kept on. This is not a preference: Android refreshes cell
     * information every 2 s only while the display is on, and every 10 s once it sleeps, so a session
     * whose screen slept would record a quarter of the samples it reported being able to take.
     *
     * The window brightness is left alone. A window brightness overrides adaptive brightness and the
     * user's own slider, and a fixed dim level is unreadable outdoors, where drive tests happen.
     */
    private fun checkScreenKeptOnWhileRecording() {
        val held = keepsScreenOn()
        val brightness = windowBrightness()
        result["keep_screen_on_while_recording"] = held
        result["keep_screen_on_brightness_override"] =
            brightness != WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        save()
        screens.shot("04b-recording-keeps-screen-on")
        assertTrue("A recording session did not keep the screen on", held)
        assertEquals(
            "Recording set the window brightness",
            WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE, brightness, 0f,
        )
    }

    /** Once the session stops, the flag goes with it. */
    private fun checkScreenReleasedAfterStop() {
        val held = keepsScreenOn()
        result["keep_screen_on_cleared_after_stop"] = !held
        save()
        assertFalse("Stopping the session left the screen kept on", held)
    }

    /** Starts the session from the Start dialog, through the pre-start sheet when it shows; returns its directory. */
    private fun startSession(): String {
        val inDialog = hasAnyAncestor(isDialog())
        screens.click(hasText(E2e.string(R.string.live_start)) and hasClickAction())
        screens.awaitText(R.string.live_start_dialog_title)
        screens.replaceTextIn(hasSetTextAction() and hasText(E2e.string(R.string.live_field_name)) and inDialog, SESSION_NAME)
        val tests = isToggleable() and hasText(E2e.string(R.string.live_tests_title)) and inDialog
        if (!screens.isOn(tests)) screens.click(tests)
        compose.onAllNodes(tests).onFirst().assertIsOn()
        Espresso.closeSoftKeyboard()
        screens.shot("06-start-dialog")
        screens.click(hasText(E2e.string(R.string.live_start_confirm)) and hasClickAction() and inDialog)

        val startAnyway = hasText(E2e.string(R.string.prestart_start_anyway)) and hasClickAction()
        val blocked = hasText(E2e.string(R.string.prestart_title_blocked))
        // The button's description always names the state; on a narrow screen its visible words are left out.
        val recording = hasContentDescription(E2e.string(R.string.live_recording), substring = true) and hasClickAction()
        screens.waitFor("the pre-start sheet or a recording session", PRESTART_WAIT_MS) {
            screens.exists(startAnyway) || screens.exists(blocked) || screens.exists(recording)
        }
        if (screens.exists(blocked)) {
            screens.shot("07-prestart-blocked")
            screens.logTree()
            failure("The pre-start sheet blocks the start; its problems are in logcat under ${E2e.TAG}")
        }
        val sheet = screens.exists(startAnyway)
        if (sheet) {
            screens.shot("07-prestart-sheet")
            screens.click(startAnyway)
        }
        screens.await(recording, RECORDING_WAIT_MS)
        val status = E2e.graph.sessionControl.status.value
        val dirName = (status as? SessionStatus.Recording)?.snapshot?.dirName
            ?: failure("Recording shows on screen, but the session is $status")
        result["prestart_sheet"] = sheet
        result["dir_name"] = dirName
        save()
        return dirName
    }

    private fun addMarker(recordingSinceMs: Long) {
        sleepUntil(recordingSinceMs + MARK_AFTER_MS)
        val inDialog = hasAnyAncestor(isDialog())
        screens.click(hasText(E2e.string(R.string.live_mark)) and hasClickAction() and !inDialog)
        screens.awaitText(R.string.live_mark_dialog_title)
        screens.replaceTextIn(hasSetTextAction() and inDialog, MARKER_NOTE)
        Espresso.closeSoftKeyboard()
        screens.shot("08-mark-dialog")
        screens.click(hasText(E2e.string(R.string.live_mark_confirm)) and hasClickAction() and inDialog)
        screens.awaitText(R.string.live_message_marked, SNACKBAR_WAIT_MS)
        screens.shot("09-marker-added")
        result["marker_added"] = true
        save()
    }

    /**
     * Marks from the session notification, as a phone in a pocket would: the notification's own Mark action is sent, and its
     * text must then say that marker 2 was added and when, then go back to what the session measures within seconds.
     */
    private fun markFromNotification() {
        val markLabel = E2e.string(R.string.notification_action_mark)
        var mark: Notification.Action? = null
        screens.waitFor("the session notification's Mark action", NOTIFICATION_WAIT_MS) {
            mark = E2e.sessionNotification()?.actions?.firstOrNull { it.title?.toString() == markLabel }
            mark != null
        }
        val parts = E2e.string(R.string.notification_marker_added, 2, PLACEHOLDER).split(PLACEHOLDER, limit = 2)
        val confirmation = Regex(Regex.escape(parts[0]) + ".+" + Regex.escape(parts.getOrElse(1) { "" }))
        val sentAtMs = E2e.graph.clock.wallMillis()
        checkNotNull(mark).actionIntent.send()
        var text: String? = null
        screens.waitFor("the notification to confirm marker 2", NOTIFICATION_WAIT_MS) {
            text = E2e.notificationText(E2e.sessionNotification())
            text?.let { confirmation.matches(it) } == true
        }
        result["notification_marker_sent_utc_ms"] = sentAtMs
        result["notification_marker_text"] = text
        save()

        // Where the engineer reads it: the notification shade, pulled down over the app.
        val device = E2e.device
        device.openNotification()
        device.wait(Until.hasObject(By.textStartsWith(parts[0])), SHADE_WAIT_MS)
        E2e.screenshot(GROUP, "09b-notification-marker")
        E2e.instrumentation.uiAutomation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
        if (device.wait(Until.hasObject(By.pkg(E2e.context.packageName)), SHADE_WAIT_MS) != true) E2e.shell("cmd statusbar collapse")
        assertTrue(
            "The app did not come back from the notification shade",
            device.wait(Until.hasObject(By.pkg(E2e.context.packageName)), SHARE_WAIT_MS) == true,
        )

        var after: String? = null
        screens.waitFor("the notification to leave the marker confirmation", NOTICE_CLEARS_MS) {
            after = E2e.notificationText(E2e.sessionNotification())
            after?.let { !confirmation.matches(it) } == true
        }
        result["notification_text_after"] = after
        result["notification_marker_text_cleared"] = true
        save()
    }

    /** Keeps the session recording until [walkMs] after it started, failing at once if it stops by itself. */
    private fun keepRecording(recordingSinceMs: Long, walkMs: Long, expectLteNr: Boolean) {
        var midwayShot = false
        while (true) {
            val elapsedMs = SystemClock.elapsedRealtime() - recordingSinceMs
            if (elapsedMs >= walkMs) break
            val status = E2e.graph.sessionControl.status.value
            assertTrue("The session stopped by itself after ${elapsedMs / 1_000} s: $status", status is SessionStatus.Recording)
            E2e.dismissNotRespondingDialog()
            if (!midwayShot && elapsedMs >= walkMs / 2) {
                screens.awaitLiveRadio(expectLteNr)
                screens.shot("10-recording")
                assertRecordingControlsAboveNavBar()
                midwayShot = true
            }
            SystemClock.sleep(minOf(POLL_MS, walkMs - elapsedMs))
        }
    }

    /**
     * While recording, Live's floating action bar holds Stop (the dominant action) and Mark, docked over the app's
     * bottom navigation bar. Both must lie wholly above the bar: were they to overlap it, a tap meant for Stop or Mark
     * could land on a tab. Checked on the phone-sized API 36 screen, upright, where the floating bar (not the landscape
     * rail) carries the controls; the "10-recording" shot is the evidence.
     */
    private fun assertRecordingControlsAboveNavBar() {
        val notInDialog = !hasAnyAncestor(isDialog())
        val stop = screens.bounds(hasContentDescription(E2e.string(R.string.live_stop), substring = true) and hasClickAction() and notInDialog)
        val mark = screens.bounds(hasText(E2e.string(R.string.live_mark)) and hasClickAction() and notInDialog)
        val navTop = screens.navBarTopPx()
        val controlsBottom = maxOf(stop.bottom, mark.bottom)
        val gap = navTop - controlsBottom
        val message = "recording controls reach %.0f px; the bottom navigation bar starts at %.0f px (gap %.0f px)"
            .format(controlsBottom, navTop, gap)
        assertTrue(message, controlsBottom <= navTop)
        result["recording_controls_clear"] = true
        result["recording_controls_gap_px"] = gap.toInt()
        save()
    }

    private fun stopSession(dirName: String, recordingSinceMs: Long) {
        val inDialog = hasAnyAncestor(isDialog())
        screens.click(hasContentDescription(E2e.string(R.string.live_stop), substring = true) and hasClickAction() and !inDialog)
        screens.awaitText(R.string.live_stop_dialog_title)
        screens.shot("11-stop-dialog")
        screens.click(hasText(E2e.string(R.string.live_stop_confirm)) and hasClickAction() and inDialog)
        screens.await(hasText(E2e.string(R.string.live_start)) and hasClickAction() and isEnabled(), STOP_WAIT_MS)
        result["recording_ms"] = SystemClock.elapsedRealtime() - recordingSinceMs

        val outcome = E2e.graph.sessionControl.lastOutcome.value ?: failure("Stop left no session outcome")
        assertEquals(dirName, outcome.dirName)
        assertEquals("user", outcome.stoppedBy)
        assertFalse("A stopped session reads as interrupted", outcome.interrupted)
        result["stopped_by"] = outcome.stoppedBy
        result["fresh_samples"] = outcome.freshSamples
        save()
    }

    private fun exportAndShare(dirName: String) {
        screens.openTab(R.string.nav_logs)
        val row = hasText(SESSION_NAME) and hasClickAction()
        screens.await(row)
        screens.shot("12-sessions")
        screens.click(row)
        // Scroll to the Overview section: on a small screen the tall headline can push it below the fold, where a lazy
        // list has not composed it (a no-op scroll when it is already on screen).
        screens.awaitTextInList(R.string.detail_section_overview)
        screens.shot("13-session-detail")

        val build = hasText(E2e.string(R.string.detail_build_zip)) and hasClickAction()
        screens.scrollTo(build)
        screens.click(build)
        val share = hasText(E2e.string(R.string.detail_share_zip)) and hasClickAction()
        screens.await(share, EXPORT_WAIT_MS)
        screens.scrollTo(share)
        val zipName = screens.texts(hasText(E2e.string(R.string.detail_row_zip))).firstOrNull { it.endsWith(".zip") }
            ?: failure("The Share card names no zip")
        assertEquals("$dirName.zip", zipName)
        val shownSha = shownSha256()
        screens.shot("14-zip-ready")

        val zip = File(E2e.context.cacheDir, "exports/$zipName")
        assertTrue("The exported zip is not at ${zip.path}", zip.isFile)
        val fileSha = E2e.sha256(zip)
        assertEquals("The SHA-256 on screen is not the zip's", fileSha, shownSha)
        zip.copyTo(File(E2e.outputDir(), zip.name), overwrite = true)
        result["zip_name"] = zip.name
        result["zip_bytes"] = zip.length()
        result["zip_sha256_ui"] = shownSha
        result["zip_sha256_file"] = fileSha
        save()

        screens.click(share)
        val device = E2e.device
        assertTrue("Android's share sheet did not open", device.wait(Until.hasObject(By.pkg(SHARE_SHEET)), SHARE_WAIT_MS) == true)
        E2e.screenshot(GROUP, "15-share-sheet")
        device.pressBack()
        assertTrue(
            "The app did not come back from the share sheet",
            device.wait(Until.hasObject(By.pkg(E2e.context.packageName)), SHARE_WAIT_MS) == true,
        )
        screens.await(share)
        result["share_sheet"] = true
        save()
    }

    /**
     * The SHA-256 the Share card shows. The row merges its key and value, so both are its texts; if selection support
     * keeps the value in a node of its own, that node is read from the unmerged tree instead.
     */
    private fun shownSha256(): String {
        screens.texts(hasText(E2e.string(R.string.detail_row_sha256))).firstOrNull { SHA256.matches(it) }?.let { return it }
        val node = screens.await(hasTextMatching(SHA256_LINE), unmerged = true).fetchSemanticsNode()
        return node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text }.firstOrNull { SHA256.matches(it) }
            ?: failure("The Share card shows no SHA-256")
    }

    private fun save() {
        E2e.writeResult(RESULT_FILE, result)
    }

    private fun sleepUntil(elapsedRealtimeMs: Long) {
        val waitMs = elapsedRealtimeMs - SystemClock.elapsedRealtime()
        if (waitMs > 0) SystemClock.sleep(waitMs)
    }

    private fun failure(message: String): Nothing = throw AssertionError(message)

    private companion object {
        const val GROUP = "walk"
        const val RESULT_FILE = "walk-result.json"
        const val SESSION_NAME = "E2E walk"
        const val MARKER_NOTE = "Checkpoint at the north corner"

        /** The emulator answers ICMP only from its NAT gateway. */
        const val PING_TARGET = "10.0.2.2"
        const val DOWNLOAD_URL = "https://speed.cloudflare.com/__down?bytes=1000000"
        const val PING_INTERVAL_S = 20
        const val PING_COUNT = 3
        const val DOWNLOAD_INTERVAL_MIN = 1
        const val DOWNLOAD_CAP_MB = 1
        const val SESSION_BUDGET_MB = 5

        const val DEFAULT_WALK_SECONDS = 180L
        const val MARK_AFTER_MS = 20_000L
        const val POLL_MS = 5_000L
        const val PERMISSION_WAIT_MS = 15_000L
        const val PRESTART_WAIT_MS = 30_000L
        const val RECORDING_WAIT_MS = 45_000L
        const val SNACKBAR_WAIT_MS = 10_000L
        const val STOP_WAIT_MS = 60_000L
        const val EXPORT_WAIT_MS = 60_000L
        const val SHARE_WAIT_MS = 15_000L

        /** The notification is rebuilt at most every 2 s. */
        const val NOTIFICATION_WAIT_MS = 15_000L

        /** The marker confirmation shows for 6 s, and the notification is rebuilt at most every 2 s. */
        const val NOTICE_CLEARS_MS = 20_000L
        const val SHADE_WAIT_MS = 5_000L
        const val PLACEHOLDER = "\u0000"

        /** The chooser: package `android` up to Android 13, the intent resolver from Android 14. */
        val SHARE_SHEET: Pattern = Pattern.compile("android|com\\.android\\.intentresolver")
        val SHA256 = Regex("[0-9a-f]{64}")
        val SHA256_LINE = Regex("^[0-9a-f]{64}$")
    }
}
