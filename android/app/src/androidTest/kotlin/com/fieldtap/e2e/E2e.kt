package com.fieldtap.e2e

import android.app.Instrumentation
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import androidx.annotation.StringRes
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.printToLog
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.fieldtap.R
import com.fieldtap.app.AppGraph
import com.fieldtap.app.appGraph
import com.fieldtap.format.JsonText
import com.fieldtap.service.SessionService
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale
import java.util.regex.Pattern
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.rules.TestWatcher
import org.junit.runner.Description

/**
 * Shared pieces of the instrumented end-to-end tests. They run in the app's own process on the CI emulator, driven by
 * android/e2e/run_e2e.sh, which sets the theme and font scale before each run, feeds a GPS walk and signal changes,
 * kills the app for the recovery test, and checks every session with fieldtap afterwards.
 *
 * What a test leaves for the host (screenshots, result JSON, the exported zip) goes to
 * `<getExternalFilesDir(null)>/e2e/`, which the host pulls after every run.
 */
object E2e {
    /** Logcat tag of the tests' own diagnostics, such as the semantics tree after a timeout. */
    const val TAG: String = "FieldTapE2e"

    private const val OUTPUT_DIR = "e2e"

    /** Lets a ripple or a snackbar finish appearing before a screenshot; animations are off on the emulator. */
    private const val SETTLE_MS = 700L
    private const val PNG_QUALITY = 100
    private const val BUFFER_BYTES = 64 * 1024

    val instrumentation: Instrumentation get() = InstrumentationRegistry.getInstrumentation()

    /** The app's context: the tests run in the app's process. */
    val context: Context get() = instrumentation.targetContext

    val device: UiDevice get() = UiDevice.getInstance(instrumentation)

    /** The app's own graph, read to confirm what the screens show; every step itself goes through the UI. */
    val graph: AppGraph get() = context.appGraph

    /** An `am instrument -e NAME VALUE` argument, or null when it is absent or blank. */
    fun argument(name: String): String? =
        InstrumentationRegistry.getArguments().getString(name)?.trim()?.takeIf { it.isNotEmpty() }

    /**
     * `-e expect_lte_nr true|false`: whether the emulator's modem reports LTE or NR cells, as android/e2e/run_e2e.sh read
     * from the telephony registry. The API 36 emulator does; the API 31 emulator reports only a GSM cell. Absent means
     * true, so the full LTE and NR checks are the default.
     */
    fun expectLteNr(): Boolean = argument("expect_lte_nr")?.let { value ->
        requireNotNull(value.toBooleanStrictOrNull()) { "expect_lte_nr must be true or false, not $value" }
    } ?: true

    /** An argument the test cannot run without. */
    fun requireArgument(name: String): String = checkNotNull(argument(name)) { "Pass -e $name VALUE to am instrument" }

    /**
     * Whether the screen is phone-sized, as on the API 36 legs' Pixel 7 profile (411 x 914 dp), where the design is judged.
     * The API 31 legs keep the emulator's 320 x 640 dp screen as the robustness check.
     */
    fun phoneSizeScreen(): Boolean {
        val metrics = context.resources.displayMetrics
        val shortSide = minOf(metrics.widthPixels, metrics.heightPixels) / metrics.density
        val longSide = maxOf(metrics.widthPixels, metrics.heightPixels) / metrics.density
        return shortSide >= PHONE_SHORT_SIDE_DP && longSide >= PHONE_LONG_SIDE_DP
    }

    private const val PHONE_SHORT_SIDE_DP = 400f
    private const val PHONE_LONG_SIDE_DP = 850f

    /** Live's Start button: "Start session" upright; in the landscape rail it reads "Start" and is described "Start session". */
    fun startButton(): SemanticsMatcher =
        (hasText(string(R.string.live_start)) or hasContentDescription(string(R.string.live_start))) and hasClickAction()

    /** One of the app's strings, so the tests follow its wording instead of copying it. */
    fun string(@StringRes id: Int, vararg formatArgs: Any): String = context.getString(id, *formatArgs)

    fun granted(permission: String): Boolean = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** `<externalFilesDir>/e2e/[child]`, created when missing. */
    fun outputDir(child: String = ""): File {
        val root = checkNotNull(context.getExternalFilesDir(null)) { "App-specific external storage is unavailable" }
        val dir = if (child.isEmpty()) File(root, OUTPUT_DIR) else File(File(root, OUTPUT_DIR), child)
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) throw IOException("Could not create $dir")
        return dir
    }

    /** Saves the whole screen, system bars and system dialogs included, as `e2e/screenshots/[group]/[name].png`. */
    fun screenshot(group: String, name: String) {
        screenshotTo(outputDir("screenshots/$group"), name)
    }

    /** Saves the whole screen as `[dir]/[name].png`. */
    fun screenshotTo(dir: File, name: String) {
        instrumentation.waitForIdleSync()
        SystemClock.sleep(SETTLE_MS)
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot()) { "Android returned no screenshot for $name" }
        try {
            File(dir, "$name.png").outputStream().use { out ->
                check(bitmap.compress(Bitmap.CompressFormat.PNG, PNG_QUALITY, out)) { "Could not encode $name.png" }
            }
        } finally {
            bitmap.recycle()
        }
    }

    /** Runs [command] as the shell user and returns what it printed. */
    fun shell(command: String): String {
        val descriptor = instrumentation.uiAutomation.executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes().toString(Charsets.UTF_8) }
    }

    /**
     * Writes [values] as a flat JSON object to `e2e/[fileName]`, replacing the previous file atomically, so the host
     * finds a whole file even when a test fails half way. Booleans, Ints and Longs are JSON literals; anything else is
     * a string.
     */
    fun writeResult(fileName: String, values: Map<String, Any?>) {
        val json = values.entries.joinToString(separator = ",\n", prefix = "{\n", postfix = "\n}\n") { (key, value) ->
            val encoded = when (value) {
                null -> "null"
                is Boolean, is Int, is Long -> value.toString()
                else -> JsonText.quote(value.toString())
            }
            "  ${JsonText.quote(key)}: $encoded"
        }
        val dir = outputDir()
        val temporary = File(dir, "$fileName.tmp")
        temporary.writeText(json, Charsets.UTF_8)
        if (!temporary.renameTo(File(dir, fileName))) throw IOException("Could not replace $fileName")
    }

    /** SHA-256 of [file] as 64 lower-case hex digits. */
    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(BUFFER_BYTES)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte -> String.format(Locale.ROOT, "%02x", byte) }
    }

    /** Taps "Wait" on an "isn't responding" dialog, which a slow CI emulator can show over any app. */
    fun dismissNotRespondingDialog() {
        device.findObject(By.res("android", "aerr_wait"))?.click()
    }

    /** Turns the screen upright with rotation frozen there ([turn]). */
    fun upright() {
        turn(landscape = false)
    }

    /**
     * Turns the screen to landscape, or upright, with rotation frozen there, and fails unless it has turned within
     * [ROTATION_WAIT_MS]. The host's `user_rotation` setting takes effect a step late on the API 36 emulator, so a test that
     * needs an orientation sets it here, through UiAutomator, as [Screens.inLandscape] does.
     */
    fun turn(landscape: Boolean) {
        if (landscape) device.setOrientationLandscape() else device.setOrientationNatural()
        val deadline = SystemClock.elapsedRealtime() + ROTATION_WAIT_MS
        while (turned() != landscape && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(ROTATION_POLL_MS)
        assertEquals("the screen turned to " + if (landscape) "landscape" else "upright", landscape, turned())
        device.waitForIdle()
    }

    private fun turned(): Boolean = device.displayWidth > device.displayHeight

    private const val ROTATION_WAIT_MS = 10_000L
    private const val ROTATION_POLL_MS = 200L

    /** The running session's notification as Android holds it for this app, or null while none is posted. */
    fun sessionNotification(): Notification? =
        context.getSystemService(NotificationManager::class.java)?.activeNotifications
            ?.firstOrNull { it.id == SessionService.NOTIFICATION_ID }
            ?.notification

    fun notificationTitle(notification: Notification?): String? =
        notification?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()

    fun notificationText(notification: Notification?): String? =
        notification?.extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()
}

/**
 * The look a run is checked in. android/e2e/run_e2e.sh applies it with `cmd uimode night`, `font_scale` and
 * `user_rotation`.
 */
enum class Variant(val group: String, private val night: Boolean, val fontScale: Float, val landscape: Boolean = false) {
    LIGHT("light", night = false, fontScale = 1.0f),
    DARK("dark", night = true, fontScale = 1.0f),
    FONT_130("font130", night = false, fontScale = 1.3f),

    /** The phone turned on its side, as in a car mount. */
    LANDSCAPE("landscape", night = false, fontScale = 1.0f, landscape = true),
    ;

    /**
     * Turns the screen as this variant asks ([E2e.turn]), then fails unless the app's process started in this variant's
     * night mode and font scale.
     */
    fun apply() {
        E2e.turn(landscape)
        val configuration = E2e.context.resources.configuration
        val nightNow = (configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        assertEquals("night mode of variant $group", night, nightNow)
        assertEquals("font scale of variant $group", fontScale, configuration.fontScale, FONT_SCALE_TOLERANCE)
    }

    companion object {
        private const val FONT_SCALE_TOLERANCE = 0.01f

        /** The variant named by `-e variant light|dark|font130`. */
        fun fromArguments(): Variant {
            val name = E2e.requireArgument("variant")
            return entries.firstOrNull { it.group == name } ?: error("Unknown variant $name")
        }
    }
}

/** Android's runtime permission dialog. It belongs to the permission controller, so UiAutomator drives it. */
object PermissionDialogs {
    private val CONTROLLER: Pattern = Pattern.compile("com\\.(google\\.)?android\\.permissioncontroller")
    private const val APPEAR_MS = 15_000L
    private const val BUTTON_MS = 3_000L
    private const val GONE_MS = 5_000L
    private const val TAP_ATTEMPTS = 3

    /**
     * How long the dialog is left to finish opening before a tap. Android drops touches on an activity whose open
     * transition is still running ("Not sending touch gesture ... NO_INPUT_CHANNEL"), as it did on the API 36 emulator.
     */
    private const val SETTLE_MS = 1_500L

    /** "While using the app", offered for location. */
    const val LOCATION_WHILE_IN_USE: String = "permission_allow_foreground_only_button"

    /** "Allow", offered for notifications, and for location on some versions. */
    const val ALLOW: String = "permission_allow_button"

    fun showing(): Boolean = E2e.device.hasObject(By.pkg(CONTROLLER))

    /**
     * Waits for the dialog, which must appear, lets it finish opening, and taps the first of [buttonIds] it offers until
     * the dialog closes, at most [TAP_ATTEMPTS] times. Returns true once the dialog has closed; false when it offers none
     * of those buttons or stays open after every tap.
     */
    fun answer(vararg buttonIds: String): Boolean {
        val device = E2e.device
        check(device.wait(Until.hasObject(By.pkg(CONTROLLER)), APPEAR_MS) == true) { "Android's permission dialog did not appear" }
        repeat(TAP_ATTEMPTS) { attempt ->
            device.waitForIdle()
            SystemClock.sleep(SETTLE_MS)
            val button = buttonIds.firstNotNullOfOrNull { id ->
                device.wait(Until.findObject(By.pkg(CONTROLLER).res(Pattern.compile(".*:id/" + Pattern.quote(id)))), BUTTON_MS)
            } ?: return false
            button.click()
            if (device.wait(Until.gone(By.pkg(CONTROLLER)), GONE_MS) == true) return true
            Log.w(E2e.TAG, "The permission dialog stayed open after tap ${attempt + 1} of $TAP_ATTEMPTS")
        }
        return false
    }

    /** Waits until no permission dialog shows; false when one is still there after [timeoutMs]. */
    fun awaitGone(timeoutMs: Long = APPEAR_MS): Boolean = E2e.device.wait(Until.gone(By.pkg(CONTROLLER)), timeoutMs) == true
}

/** A node whose text or editable text contains a match of [regex]. */
fun hasTextMatching(regex: Regex): SemanticsMatcher = SemanticsMatcher("has text matching $regex") { node ->
    val texts = node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text } +
        listOfNotNull(node.config.getOrNull(SemanticsProperties.EditableText)?.text)
    texts.any { regex.containsMatchIn(it) }
}

/** A node whose content description contains a match of [regex]. */
fun hasDescriptionMatching(regex: Regex): SemanticsMatcher = SemanticsMatcher("has content description matching $regex") { node ->
    node.config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().any { regex.containsMatchIn(it) }
}

/**
 * Matches a node by its visible label [text], whether it is exposed as text or as a content description, and
 * regardless of case. Section headers and metric eyebrows now render UPPERCASE for display (the `Eyebrow`
 * component), while keeping the original-case word as a content description for TalkBack, so a screen is
 * awaited by its label rather than by an exact-case string.
 */
fun hasLabel(text: String): SemanticsMatcher =
    hasText(text, ignoreCase = true) or hasContentDescription(text, ignoreCase = true)

/**
 * Steps on the app's screens through Compose semantics. Each waits for what it needs, and a timeout names what was
 * awaited and prints the semantics tree to logcat.
 */
class Screens(private val compose: ComposeTestRule, private val group: String) {
    /**
     * Whether a node matches. False, rather than an error, while no Compose hierarchy of the app can be reached: that is
     * the case while an activity of another app, such as a permission dialog or the share sheet, covers the app, and a
     * wait should then go on waiting.
     */
    fun exists(matcher: SemanticsMatcher, unmerged: Boolean = false): Boolean = try {
        compose.onAllNodes(matcher, useUnmergedTree = unmerged).fetchSemanticsNodes().isNotEmpty()
    } catch (e: IllegalStateException) {
        if (e.message?.startsWith(NO_HIERARCHY) != true) throw e
        false
    }

    /** Waits until [condition] holds; [what] names it in the failure. */
    fun waitFor(what: String, timeoutMs: Long = WAIT_MS, condition: () -> Boolean) {
        try {
            compose.waitUntil(conditionDescription = what, timeoutMillis = timeoutMs, condition = condition)
        } catch (e: ComposeTimeoutException) {
            logTree()
            throw AssertionError("Timed out after $timeoutMs ms waiting for $what", e)
        }
    }

    /** The first node matching [matcher], once one exists. */
    fun await(matcher: SemanticsMatcher, timeoutMs: Long = WAIT_MS, unmerged: Boolean = false): SemanticsNodeInteraction {
        waitFor(matcher.description, timeoutMs) { exists(matcher, unmerged) }
        return compose.onAllNodes(matcher, useUnmergedTree = unmerged).onFirst()
    }

    fun awaitText(@StringRes id: Int, timeoutMs: Long = WAIT_MS): SemanticsNodeInteraction = await(hasLabel(E2e.string(id)), timeoutMs)

    /**
     * Waits for [matcher], scrolling the screen's first lazy list toward it while it is not yet composed, and returns the
     * node once it is. A section can begin below the fold in landscape, where the bottom navigation bar shortens the
     * viewport, and a lazy list composes such an item only once it is scrolled near; this also waits out a screen's
     * initial load, before its list exists. Like [await] it asserts the node is reachable — it only makes an off-screen
     * item compose. Fails, naming [matcher], if it is not reached within [timeoutMs].
     */
    fun awaitInList(matcher: SemanticsMatcher, timeoutMs: Long = WAIT_MS): SemanticsNodeInteraction {
        waitFor("in the list: ${matcher.description}", timeoutMs) {
            if (exists(matcher)) return@waitFor true
            val lists = compose.onAllNodes(hasScrollToIndexAction())
            if (lists.fetchSemanticsNodes().isEmpty()) return@waitFor false
            try {
                lists.onFirst().performScrollToNode(matcher)
                true
            } catch (e: AssertionError) {
                // The item is not in the list yet (the screen is still loading); try again.
                false
            }
        }
        return compose.onAllNodes(matcher).onFirst()
    }

    fun awaitTextInList(@StringRes id: Int, timeoutMs: Long = WAIT_MS): SemanticsNodeInteraction = awaitInList(hasLabel(E2e.string(id)), timeoutMs)

    fun click(matcher: SemanticsMatcher, timeoutMs: Long = WAIT_MS) {
        await(matcher, timeoutMs).performClick()
        compose.waitForIdle()
    }

    /** Scrolls the screen's lazy list until [matcher] is composed, then until it is wholly on screen. */
    fun scrollTo(matcher: SemanticsMatcher) {
        compose.onAllNodes(hasScrollToIndexAction()).onFirst().performScrollToNode(matcher)
        compose.onAllNodes(matcher).onFirst().performScrollTo()
    }

    /** Replaces the text of the field labelled [label] on a scrolling screen. */
    fun replaceText(@StringRes label: Int, value: String) {
        val field = hasSetTextAction() and hasText(E2e.string(label))
        scrollTo(field)
        replaceTextIn(field, value)
    }

    /** Replaces the text of the field [field], which is already on screen (for example in a dialog). */
    fun replaceTextIn(field: SemanticsMatcher, value: String) {
        await(field).performTextReplacement(value)
        compose.waitForIdle()
    }

    /** The texts of the first node matching [matcher]; a merged row holds its key and its value. */
    fun texts(matcher: SemanticsMatcher): List<String> =
        await(matcher).fetchSemanticsNode().config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text }

    fun isOn(matcher: SemanticsMatcher): Boolean =
        await(matcher).fetchSemanticsNode().config.getOrNull(SemanticsProperties.ToggleableState) == ToggleableState.On

    /** A screenshot in this test's group, once the screen is idle. */
    fun shot(name: String) {
        compose.waitForIdle()
        E2e.screenshot(group, name)
    }

    /**
     * The screen at every scroll position, as `[name]-p1`, `[name]-p2` and so on. From the top, each page scrolls every
     * vertical list of the screen (not of a dialog) down by its own height less [PAGE_OVERLAP], so a line cut at the bottom
     * of one page is whole on the next, until none can scroll further or [maxPages] were taken. The lists end at the top
     * again. Two panes side by side page together.
     */
    fun shotFull(name: String, maxPages: Int = MAX_PAGES) {
        scrollListsToTop()
        var page = 1
        shot("$name-p$page")
        while (page < maxPages && scrollListsOnePage()) {
            page++
            shot("$name-p$page")
        }
        scrollListsToTop()
    }

    /** Scrolls each list that can go further by one page; false when none could. */
    private fun scrollListsOnePage(): Boolean {
        val lists = compose.onAllNodes(PAGED_LIST)
        val overlapPx = with(compose.density) { PAGE_OVERLAP.toPx() }
        var moved = false
        lists.fetchSemanticsNodes().forEachIndexed { index, node ->
            val range = node.config.getOrNull(SemanticsProperties.VerticalScrollAxisRange) ?: return@forEachIndexed
            val step = node.boundsInRoot.height - overlapPx
            if (range.value() >= range.maxValue() || step <= 0f) return@forEachIndexed
            lists[index].performSemanticsAction(SemanticsActions.ScrollBy) { scrollBy -> scrollBy(0f, step) }
            moved = true
        }
        compose.waitForIdle()
        return moved
    }

    private fun scrollListsToTop() {
        val lists = compose.onAllNodes(PAGED_LIST)
        lists.fetchSemanticsNodes().forEachIndexed { index, node ->
            if (node.config.getOrNull(SemanticsActions.ScrollToIndex) != null) {
                lists[index].performScrollToIndex(0)
            } else {
                val offset = node.config.getOrNull(SemanticsProperties.VerticalScrollAxisRange)?.value?.invoke() ?: 0f
                if (offset > 0f) lists[index].performSemanticsAction(SemanticsActions.ScrollBy) { scrollBy -> scrollBy(0f, -offset) }
            }
        }
        compose.waitForIdle()
    }

    /** Scrolls the first scrolling list of the screen back to its top. */
    fun scrollToTop() {
        compose.onAllNodes(hasScrollToIndexAction()).onFirst().performScrollToIndex(0)
        compose.waitForIdle()
    }

    /**
     * Runs [block] with the device turned to landscape, the way a phone sits in a car mount, then turns it back and lets
     * the sensor decide again. The activity is recreated both ways, as on a phone.
     */
    fun inLandscape(block: () -> Unit) {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        device.setOrientationLandscape()
        try {
            device.waitForIdle()
            compose.waitForIdle()
            block()
        } finally {
            device.setOrientationNatural()
            device.unfreezeRotation()
            device.waitForIdle()
            compose.waitForIdle()
        }
    }

    /** The top bar's navigate-up button. */
    fun back() {
        click(hasContentDescription(E2e.string(R.string.action_back)) and hasClickAction())
    }

    /** Waits for Live by its Start button, which is present on Live in both orientations (as "Start session" or, in the landscape rail, "Start" described "Start session"). */
    fun awaitLive(timeoutMs: Long = WAIT_MS) {
        await(E2e.startButton(), timeoutMs)
    }

    /**
     * Fails unless Live's 5-minute chart lies wholly inside the list's viewport with the list at its top: what an engineer
     * glances at while walking belongs on a phone's first screen. Call it upright, at font scale 1.0, with a serving cell.
     */
    fun assertChartOnFirstScreen() {
        scrollToTop()
        val chart = hasDescriptionMatching(chartSummary())
        waitFor("Live's chart to be composed on the first screen") { exists(chart) }
        val list = compose.onAllNodes(hasScrollToIndexAction()).onFirst().fetchSemanticsNode().boundsInRoot
        val bounds = compose.onAllNodes(chart).onFirst().fetchSemanticsNode().boundsInRoot
        val density = compose.density.density
        val message = "Live's chart spans %.0f..%.0f dp, beyond the list's %.0f..%.0f dp".format(
            Locale.ROOT,
            bounds.top / density,
            bounds.bottom / density,
            list.top / density,
            list.bottom / density,
        )
        Log.i(E2e.TAG, message.replace("beyond", "inside"))
        assertTrue(message, bounds.top >= list.top && bounds.bottom <= list.bottom)
    }

    /** Opens [label] from an overflow menu. */
    fun openMenuItem(@StringRes label: Int) {
        click(hasContentDescription(E2e.string(R.string.live_action_more)) and hasClickAction())
        click(hasText(E2e.string(label)) and hasClickAction())
    }

    /** Taps a bottom-navigation tab by its label (Live, Sessions, Diagnostics, Settings). */
    fun openTab(@StringRes label: Int) {
        click(navTab(label))
    }

    /**
     * A bottom-navigation tab by its [label]. A tab's merged node carries a `Selected` state and a click action; a
     * top bar's title, which can read the same word (Live's top bar says "Live"), carries neither, so this matches the
     * tab and not the title.
     */
    private fun navTab(@StringRes label: Int): SemanticsMatcher =
        hasText(E2e.string(label)) and hasClickAction() and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)

    /** Fails unless the bottom-navigation tab labelled [label] reports [selected]: the proof that a tab tap switched tabs. */
    fun assertTabSelected(@StringRes label: Int, selected: Boolean) {
        val node = await(navTab(label)).fetchSemanticsNode()
        val isSelected = node.config.getOrNull(SemanticsProperties.Selected) == true
        assertEquals("bottom-navigation tab \"${E2e.string(label)}\" selected", selected, isSelected)
    }

    /** The top edge, in root pixels, of the bottom navigation bar: the highest of its four tab items' tops. */
    fun navBarTopPx(): Float {
        val labels = listOf(R.string.nav_signal, R.string.nav_logs, R.string.nav_traffic, R.string.nav_settings)
        val anyLabel = labels.map { hasText(E2e.string(it)) }.reduce { a, b -> a or b }
        val tabs = anyLabel and hasClickAction() and SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected)
        val nodes = compose.onAllNodes(tabs).fetchSemanticsNodes()
        assertTrue("the bottom navigation bar shows no tabs", nodes.isNotEmpty())
        return nodes.minOf { it.boundsInRoot.top }
    }

    /** The bounds, in root pixels, of the first node matching [matcher]. */
    fun bounds(matcher: SemanticsMatcher): Rect = await(matcher).fetchSemanticsNode().boundsInRoot

    /**
     * Waits until Live shows a serving cell: the hero tile, at the top whatever the font scale, names the cell's PCI and
     * says how old the sample is; then the Serving cell card must exist further down, and the list returns to the top.
     * On a timeout the Live feed's state (cells, listeners, conditions) is written to logcat and to
     * `e2e/failures/[group]/live-state.txt`, so the artifact says why no cell was chosen.
     */
    fun awaitServingCell(timeoutMs: Long = SERVING_CELL_WAIT_MS) {
        try {
            await(hasDescriptionMatching(ageBadge()) and hasDescriptionMatching(pciLabel()), timeoutMs)
            scrollTo(hasLabel(E2e.string(R.string.live_section_serving)))
            compose.onAllNodes(hasScrollToIndexAction()).onFirst().performScrollToIndex(0)
            compose.waitForIdle()
        } catch (e: AssertionError) {
            val state = E2e.graph.live.state.value.toString()
            Log.w(E2e.TAG, "No serving cell on Live; the feed's state: $state")
            try {
                File(E2e.outputDir("failures/$group"), "live-state.txt").writeText(state + "\n", Charsets.UTF_8)
            } catch (io: IOException) {
                Log.w(E2e.TAG, "Could not save the Live state", io)
            }
            throw e
        }
    }

    /**
     * Waits until Live shows what the emulator's modem provides: with [expectLteNr], a serving cell and its age
     * ([awaitServingCell]); without, the hero tile saying Android reports no LTE or NR serving cell.
     */
    fun awaitLiveRadio(expectLteNr: Boolean, timeoutMs: Long = SERVING_CELL_WAIT_MS) {
        if (expectLteNr) {
            awaitServingCell(timeoutMs)
        } else {
            await(hasDescriptionMatching(Regex(Regex.escape(E2e.string(R.string.live_no_lte_nr_badge)))), timeoutMs)
        }
    }

    /** Prints every window's semantics tree to logcat under [E2e.TAG]. */
    fun logTree() {
        try {
            compose.onAllNodes(isRoot(), useUnmergedTree = true).printToLog(E2e.TAG)
        } catch (e: RuntimeException) {
            Log.w(E2e.TAG, "Could not print the semantics tree", e)
        } catch (e: AssertionError) {
            Log.w(E2e.TAG, "Could not print the semantics tree", e)
        }
    }

    companion object {
        const val WAIT_MS: Long = 20_000

        /** The first screen after a cold start on a busy emulator. */
        const val LAUNCH_WAIT_MS: Long = 60_000

        /** The emulator's modem reports cell info every 10 s, and its first answer can take longer after boot. */
        const val SERVING_CELL_WAIT_MS: Long = 120_000

        /** The start of Compose testing's message when no hierarchy of the app is reachable. */
        private const val NO_HIERARCHY = "No compose hierarchies found"

        /** More pages than any screen of the app takes at font scale 1.3 on a small phone. */
        const val MAX_PAGES: Int = 8

        /** What one page of [shotFull] repeats of the page before it. */
        private val PAGE_OVERLAP = 48.dp

        /** A vertical list or scrolling column of the screen itself, not of a dialog over it. */
        private val PAGED_LIST: SemanticsMatcher = hasScrollAction() and
            SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange) and
            !hasAnyAncestor(isDialog())

        private const val PLACEHOLDER = "\u0000"

        /** "PCI 555" as `R.string.live_pci` words it, with any cell id. */
        fun pciLabel(): Regex {
            val sample = 987_654_321
            val parts = E2e.string(R.string.live_pci, sample).split(sample.toString(), limit = 2)
            return Regex(Regex.escape(parts[0]) + "\\d+" + Regex.escape(parts.getOrElse(1) { "" }))
        }

        /** The start of the chart's TalkBack summary: "RSRP over the last 5 minutes: latest ", or its words before any sample. */
        fun chartSummary(): Regex {
            val sample = 987_654_321
            val withSamples = E2e.string(R.string.chart_summary_rsrp, sample, sample, sample).substringBefore(sample.toString())
            val empty = E2e.string(R.string.chart_summary_rsrp_empty)
            return Regex("^(" + Regex.escape(withSamples) + "|" + Regex.escape(empty) + ")")
        }

        /** "2.1 s old" as `R.string.age_old` words it, with any number of seconds. */
        fun ageBadge(): Regex {
            val parts = E2e.string(R.string.age_old, PLACEHOLDER).split(PLACEHOLDER, limit = 2)
            val before = parts[0]
            val after = parts.getOrElse(1) { "" }
            return Regex(Regex.escape(before) + "\\d+([.,]\\d)?" + Regex.escape(after))
        }
    }
}

/** On a failed test, saves a screenshot and Android's window hierarchy in `e2e/failures/[group]/`. */
class FailureCapture(private val group: String) : TestWatcher() {
    override fun failed(e: Throwable, description: Description) {
        val name = "${description.testClass.simpleName}-${description.methodName}"
        try {
            val dir = E2e.outputDir("failures/$group")
            E2e.screenshotTo(dir, name)
            E2e.device.dumpWindowHierarchy(File(dir, "$name.xml"))
        } catch (capture: IOException) {
            Log.w(E2e.TAG, "Could not capture the failure of $name", capture)
        } catch (capture: RuntimeException) {
            Log.w(E2e.TAG, "Could not capture the failure of $name", capture)
        }
    }
}
