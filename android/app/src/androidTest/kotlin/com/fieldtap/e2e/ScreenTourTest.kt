package com.fieldtap.e2e

import androidx.annotation.StringRes
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.fieldtap.MainActivity
import com.fieldtap.R
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/**
 * Every screen after the walk, at every scroll position ([Screens.shotFull]), in the variant `-e variant` names: Live with
 * its serving cell, the Start dialog, Sessions, the walk's detail, Readiness, Probe, Settings, its Test targets and About.
 * It also proves the four-tab navigation: each tab tap is checked to move the bottom bar's selection to that tab, and the
 * bar is captured with Live selected (`10-nav-live`) and with another tab selected (`10b-nav-traffic`). An upright
 * variant also turns the phone for Live, the screen a car mount holds; the landscape variant takes every screen turned. On
 * a phone-sized screen upright at font scale 1.0, Live's 5-minute chart must lie wholly on the first screen. The disclosure
 * and Permissions screens are taken on a first run by [FirstRunScreensTest]. `-e dir_name` is the walk's session.
 */
@RunWith(AndroidJUnit4::class)
class ScreenTourTest {
    private val variant = Variant.fromArguments()
    private val compose = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(compose).around(FailureCapture(variant.group))

    @Test
    fun everyScreenAfterARecordedSession() {
        variant.apply()
        val screens = Screens(compose, variant.group)
        val dirName = E2e.requireArgument("dir_name")
        val sessionName = runBlocking { E2e.graph.sessions.detail(dirName) }?.meta?.name
            ?: throw AssertionError("Session $dirName is missing or unreadable")

        val expectLteNr = E2e.expectLteNr()
        screens.awaitLiveRadio(expectLteNr)
        if (expectLteNr && !variant.landscape && variant.fontScale == 1.0f && E2e.phoneSizeScreen()) {
            screens.assertChartOnFirstScreen()
        }
        screens.shotFull("03-live")
        // The bottom navigation bar with Live selected: the tab tap that opened this screen is reflected in the bar.
        screens.assertTabSelected(R.string.nav_signal, selected = true)
        screens.assertTabSelected(R.string.nav_logs, selected = false)
        screens.shot("10-nav-live")
        if (!variant.landscape) {
            // A phone in landscape: two panes, with the session buttons beside them instead of under them.
            screens.inLandscape {
                screens.awaitLive()
                screens.await(E2e.startButton())
                screens.shotFull("03e-live-landscape")
            }
        }
        screens.awaitLive()
        screens.click(E2e.startButton())
        screens.awaitText(R.string.live_start_dialog_title)
        Espresso.closeSoftKeyboard()
        screens.shot("03b-start-dialog")
        // Cancel upright; in landscape the dialog fills the screen and closes with an icon described "Cancel".
        val cancel = E2e.string(R.string.action_cancel)
        screens.click((hasText(cancel) or hasContentDescription(cancel)) and hasClickAction() and hasAnyAncestor(isDialog()))

        // Recordings tab: the recorded drive and its detail. The tap moves the bar's selection off Live.
        screens.openTab(R.string.nav_logs)
        screens.assertTabSelected(R.string.nav_logs, selected = true)
        screens.assertTabSelected(R.string.nav_signal, selected = false)
        val row = hasText(sessionName) and hasClickAction()
        screens.await(row)
        screens.shotFull("04-sessions")
        screens.click(row)
        // Session detail is a lazy list; in landscape the bottom bar shortens it, so the Overview card starts below the
        // tall headline block and is not composed until scrolled to.
        screens.awaitTextInList(R.string.detail_section_overview)
        screens.shotFull("05-session-detail")
        screens.back()
        screens.await(row)

        // Traffic tab: iperf3 and ping against a server the user names. The bar now shows a tab other than
        // Signal selected, the counterpart to the Signal-selected shot above.
        screens.openTab(R.string.nav_traffic)
        screens.assertTabSelected(R.string.nav_traffic, selected = true)
        screens.assertTabSelected(R.string.nav_signal, selected = false)
        screens.awaitText(R.string.traffic_server)
        screens.shotFull("07-traffic")
        screens.shot("10b-nav-traffic")

        // Settings tab, and every screen it reaches: the capability probe, the readiness check, the targets, About.
        screens.openTab(R.string.nav_settings)
        screens.assertTabSelected(R.string.nav_settings, selected = true)
        screens.awaitText(R.string.settings_section_measurement)
        screens.shotFull("08-settings")
        visitFromSettings(screens, R.string.settings_readiness, R.string.readiness_checks_title, "06-readiness")
        visitFromSettings(screens, R.string.settings_test_targets, R.string.settings_ping_heading, "08b-test-targets")
        visitFromSettings(screens, R.string.settings_about, R.string.about_account_title, "09-about")

        // The capability probe moved under Setup: it is run once on a new phone and then left alone.
        val probeRow = hasText(E2e.string(R.string.settings_probe)) and hasClickAction()
        screens.scrollTo(probeRow)
        screens.click(probeRow)
        visitProbe(screens)
    }

    /** From the Settings root, scrolls to [rowLabel] and opens it, waits for [shows], shots [shot] full length, then returns to Settings. */
    private fun visitFromSettings(screens: Screens, @StringRes rowLabel: Int, @StringRes shows: Int, shot: String) {
        val row = hasText(E2e.string(rowLabel)) and hasClickAction()
        screens.scrollTo(row)
        screens.click(row)
        // The opened screen is a lazy list; its awaited section can start below the fold in landscape (the bottom bar
        // shortens the viewport), so scroll to it rather than only awaiting a composed node.
        screens.awaitTextInList(shows)
        screens.shotFull(shot)
        screens.back()
        screens.awaitText(R.string.settings_title)
    }

    /**
     * The Capability screen (opened from Setup) at every scroll position, then its explicit read-only "Check with
     * root" run. The check gains no root and never hangs (a hard timeout in the runner); on the CI emulator it settles
     * quickly, and the SELinux/`/dev/diag`/kernel-config rows it fills in appear whatever `su` allowed. Both looks are
     * captured full length, so the artifact shows the honest per-phone verdict the panel reaches. The probe
     * screen is already open.
     */
    private fun visitProbe(screens: Screens) {
        // The Run button sits in the verdict block; in landscape the bottom bar can push it below the fold.
        screens.awaitTextInList(R.string.probe_run)
        // Wait for the passive capability read at the top of the screen (its verdict chip replaces "Reading this
        // phone…"), so the Root & diagnostics card below the fold is composed by the time we scroll to it.
        screens.await(
            hasLabel(E2e.string(R.string.probe_capability_can_measure)) or
                hasLabel(E2e.string(R.string.probe_capability_needs_location)),
        )
        screens.shotFull("07-probe")
        val checkRoot = hasText(E2e.string(R.string.probe_check_root)) and hasClickAction()
        screens.scrollTo(checkRoot)
        screens.click(checkRoot)
        // The result rows (SELinux, Diag device, Kernel diag support) render once the check has settled; scroll to them
        // since in landscape the expanded card can push them below the fold.
        screens.awaitTextInList(R.string.probe_root_selinux, timeoutMs = ROOT_CHECK_MS)
        screens.shotFull("07c-probe-root-check")
    }

    private companion object {
        /** Room for the root check to settle: the runner's own su timeout is 6 s, plus slack on a busy emulator. */
        const val ROOT_CHECK_MS: Long = 30_000
    }
}
