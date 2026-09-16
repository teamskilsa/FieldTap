package com.fieldtap.ui.live

import android.content.Context
import android.view.WindowManager
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.StringRes
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.fieldtap.R
import com.fieldtap.app.AppGraph
import com.fieldtap.app.SessionStatus
import com.fieldtap.app.StartResult
import com.fieldtap.core.input.ListenerOutcome
import com.fieldtap.core.input.RadioListener
import com.fieldtap.core.live.AgeBadge
import com.fieldtap.core.live.ChartPoint
import com.fieldtap.core.live.LiveCell
import com.fieldtap.core.live.LiveState
import com.fieldtap.core.live.ServingVisit
import com.fieldtap.core.live.LiveStateReducer
import com.fieldtap.core.nettest.TestSettings
import com.fieldtap.core.privacy.Consent
import com.fieldtap.core.readiness.SettingsTarget
import com.fieldtap.core.session.RecorderSnapshot
import com.fieldtap.core.session.SessionOutcome
import com.fieldtap.core.session.StartRefusal
import com.fieldtap.core.session.StartRequest
import com.fieldtap.core.settings.AppSettings
import com.fieldtap.format.Rat
import com.fieldtap.format.ServingRat
import com.fieldtap.platform.Permissions
import com.fieldtap.ui.FieldTapTheme
import com.fieldtap.ui.common.DisplayTime
import com.fieldtap.ui.common.SystemSettings
import com.fieldtap.ui.common.contentWidth
import com.fieldtap.ui.common.exitReasonWords
import com.fieldtap.ui.common.findActivity
import com.fieldtap.ui.common.ratName
import com.fieldtap.ui.common.screenGutter
import com.fieldtap.ui.common.signalQualityLabels
import com.fieldtap.ui.components.CellSignalRow
import com.fieldtap.ui.components.ChartMath
import com.fieldtap.ui.components.FieldTapFloatingActionBar
import com.fieldtap.ui.components.FieldTapPreviews
import com.fieldtap.ui.components.FieldTapTopBar
import com.fieldtap.ui.components.KeyValueRow
import com.fieldtap.ui.components.LimitsStatementCard
import com.fieldtap.ui.components.ReadinessProblem
import com.fieldtap.ui.components.ReadinessSheet
import com.fieldtap.ui.components.RecordingDot
import com.fieldtap.ui.components.SecondaryMetricTile
import com.fieldtap.ui.components.SectionCard
import com.fieldtap.ui.components.SectionDivider
import com.fieldtap.ui.components.SessionButton
import com.fieldtap.ui.components.SessionButtonState
import com.fieldtap.ui.components.SignalChartLabels
import com.fieldtap.ui.components.SignalDonutHero
import com.fieldtap.ui.components.SignalHistoryChart
import com.fieldtap.ui.components.SignalQualityLabels
import com.fieldtap.ui.components.StatusBanner
import com.fieldtap.ui.components.ViewSwitcher
import com.fieldtap.ui.components.StatusChip
import com.fieldtap.ui.components.TopBarAction
import com.fieldtap.ui.components.TopBarToggleAction
import com.fieldtap.ui.components.cadenceTone
import com.fieldtap.ui.components.rememberTopBarScroll
import com.fieldtap.ui.components.statusIcon
import com.fieldtap.ui.settings.TestSettingsRules
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.FieldTapIcons
import com.fieldtap.ui.theme.Formats
import com.fieldtap.ui.theme.ShapeRoles
import com.fieldtap.ui.theme.SignalMetric
import com.fieldtap.ui.theme.SignalScale
import com.fieldtap.ui.theme.Sizes
import com.fieldtap.ui.theme.Spacing
import com.fieldtap.ui.theme.StatusTone
import com.fieldtap.ui.theme.tabular
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Everything the Live screen renders. */
data class LiveUiState(
    val live: LiveState,
    val status: SessionStatus,
    val testsDefaultOn: Boolean,
    /** The last refusal, until dismissed. */
    val refusal: StartRefusal?,
    /** Sessions closed by launch recovery, shown as a banner until acknowledged. */
    val recovered: List<SessionOutcome>,
    /** The Start flow: checks running, the pre-start sheet, or the start call in flight. */
    val prestart: PrestartState = PrestartState.None,
    /** A one-off message for the snackbar, until [LiveViewModel.consumeMessage] is called with its id. */
    val message: LiveMessageEvent? = null,
    /** The test targets in Settings, named in the Start dialog; null until settings were read. */
    val tests: TestSettings? = null,
) {
    /** Mark writes an event only while recording outside a privacy zone. */
    val markEnabled: Boolean get() = LivePresentation.markAllowed(status)

    /** The running session is paused because a fix showed the phone inside a privacy zone. */
    val pausedInZone: Boolean get() = LivePresentation.pausedInZone(status)

    /** The running session writes nothing until a location fix shows the phone outside its privacy zones. */
    val waitingForLocation: Boolean get() = LivePresentation.waitingForLocation(status)

    /** Location services are off: nothing new can be measured, and a running session records nothing. */
    val locationOff: Boolean get() = LivePresentation.locationOff(live, status)
}

/** A short confirmation or failure shown in the snackbar. */
enum class LiveMessage {
    MARKED,

    /** Accepted, but written only once a location fix shows it was tapped outside the privacy zones. */
    MARK_HELD,

    /** A marker accepted earlier was dropped: no fix showed it was tapped outside the privacy zones. */
    MARK_DROPPED,
    NOT_RECORDING,
    PAUSED,

    /** Marks are off while logging waits, paused, for a fix that shows the phone outside its privacy zones. */
    PAUSED_NO_FIX,
    START_FAILED,
    STOP_FAILED,

    /**
     * Recording started with advice outstanding: things that could cost samples but do not stop a
     * session. The readiness check under Setup lists them.
     */
    STARTED_WITH_ADVICE,
}

/** A [LiveMessage] with an id, so the same message twice is shown twice. */
data class LiveMessageEvent(val id: Long, val message: LiveMessage)

/**
 * The Live screen's view model. Collecting [state] starts the radio and location sources (through
 * `AppGraph.live`); they stop 5 s after the screen stops collecting, unless a session runs.
 *
 * Start follows android/ARCHITECTURE.md decision 7: [start] runs the readiness checks and reads consent
 * and storage; with no problem it calls `SessionControl.start` at once, otherwise it shows the pre-start
 * sheet ([PrestartState.Review]), from which [startAnyway] starts when nothing blocks. A refusal from
 * `SessionControl.start` is kept in [LiveUiState.refusal] and, when the sheet can name it, shown there.
 *
 * Every call is made on the main thread; slow work happens inside the facades, which move it off.
 *
 * Owner: workstream `ui-session`.
 */
class LiveViewModel(private val graph: AppGraph) : ViewModel() {
    private val refusal = MutableStateFlow<StartRefusal?>(null)
    private val prestart = MutableStateFlow<PrestartState>(PrestartState.None)
    private val message = MutableStateFlow<LiveMessageEvent?>(null)
    private var nextMessageId = 0L
    private var startJob: Job? = null

    private val storedSettings: Flow<AppSettings?> = graph.settings.settings
        .map<AppSettings, AppSettings?> { it }
        .catch { emit(null) }

    private val screenLocal: Flow<ScreenLocal> =
        combine(refusal, prestart, message) { refused, flow, event -> ScreenLocal(refused, flow, event) }

    val state: StateFlow<LiveUiState> =
        combine(graph.live.state, graph.sessionControl.status, storedSettings, screenLocal, graph.recovery.closed) { live, status, settings, local, recovered ->
            LiveUiState(
                live = live,
                status = status,
                testsDefaultOn = settings?.testsDefaultOn ?: false,
                refusal = local.refusal,
                recovered = recovered,
                prestart = local.prestart,
                message = local.message,
                tests = settings?.tests,
            )
        }.stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(STOP_TIMEOUT_MS),
            initialValue = LiveUiState(
                live = graph.live.state.value,
                status = graph.sessionControl.status.value,
                testsDefaultOn = false,
                refusal = null,
                recovered = graph.recovery.closed.value,
            ),
        )

    init {
        // A marker the recorder accepted and a privacy pause then dropped must not go unnoticed: the running session's
        // snapshots and its outcome count them, and each rise is said once.
        val reported = HashMap<String, Int>()
        fun onMarkersDropped(dirName: String, count: Int) {
            val before = reported[dirName]
            reported[dirName] = maxOf(before ?: count, count)
            if (before != null && count > before) post(LiveMessage.MARK_DROPPED)
        }
        viewModelScope.launch {
            graph.sessionControl.status.collect { status ->
                val snapshot = when (status) {
                    is SessionStatus.Recording -> status.snapshot
                    is SessionStatus.Stopping -> status.snapshot
                    else -> null
                }
                if (snapshot != null) onMarkersDropped(snapshot.dirName, snapshot.markersDropped)
            }
        }
        viewModelScope.launch {
            graph.sessionControl.lastOutcome.collect { outcome -> if (outcome != null) onMarkersDropped(outcome.dirName, outcome.markersDropped) }
        }
    }

    /** Called from the Start dialog while the screen is visible. */
    fun start(request: StartRequest) {
        if (startJob?.isActive == true) return
        val normalized = request.copy(
            name = request.name.trim(),
            note = request.note?.trim()?.takeIf { it.isNotEmpty() },
            location = request.location?.trim()?.takeIf { it.isNotEmpty() },
        )
        if (graph.sessionControl.status.value != SessionStatus.Idle) {
            refusal.value = StartRefusal.SESSION_RUNNING
            return
        }
        if (normalized.name.isEmpty()) {
            refusal.value = StartRefusal.BLANK_NAME
            return
        }
        refusal.value = null
        startJob = viewModelScope.launch {
            prestart.value = PrestartState.Checking(normalized)
            val issues = findIssues(refusal = null)
            // Only something that actually stops a session is worth a second screen. Advice -- battery
            // optimisation, a vendor that kills background apps -- used to open the sheet too, so the
            // common path was a form, a wall of caveats, and a button labelled "Start anyway" for a
            // session nothing was wrong with. Advice now starts the session and says so afterwards.
            if (issues.none { it.blocking }) {
                begin(normalized)
                if (issues.isNotEmpty()) post(LiveMessage.STARTED_WITH_ADVICE)
            } else {
                prestart.value = PrestartState.Review(normalized, issues)
            }
        }
    }

    /** Starts the reviewed session when no problem on the sheet blocks. */
    fun startAnyway() {
        val review = prestart.value as? PrestartState.Review ?: return
        if (!review.canStartAnyway || startJob?.isActive == true) return
        startJob = viewModelScope.launch { begin(review.request) }
    }

    /** Runs the checks again while the pre-start sheet shows, for example back from a settings screen. */
    fun recheckReadiness() {
        val review = prestart.value as? PrestartState.Review ?: return
        if (startJob?.isActive == true) return
        startJob = viewModelScope.launch {
            val issues = findIssues(refusal = null)
            if (prestart.value is PrestartState.Review) {
                prestart.value = PrestartState.Review(review.request, issues)
                if (issues.none { it.blocking }) refusal.value = null
            }
        }
    }

    /** Closes the pre-start sheet, or abandons the checks; a start call already made is not cancelled. */
    fun dismissPrestart() {
        when (prestart.value) {
            is PrestartState.Checking, is PrestartState.Review -> {
                startJob?.cancel()
                prestart.value = PrestartState.None
            }
            PrestartState.None, is PrestartState.Starting -> Unit
        }
    }

    fun mark(note: String?) {
        val status = graph.sessionControl.status.value
        if (!LivePresentation.markAllowed(status)) {
            post(refusedMark(status))
            return
        }
        val waits = LivePresentation.markWaitsForLocation(status)
        val accepted = try {
            graph.sessionControl.mark(note?.trim()?.takeIf { it.isNotEmpty() })
        } catch (e: RuntimeException) {
            false
        }
        post(
            when {
                // Said so, because a pause may still drop it; MARK_DROPPED follows if one does.
                accepted -> if (waits) LiveMessage.MARK_HELD else LiveMessage.MARKED
                else -> refusedMark(graph.sessionControl.status.value)
            },
        )
    }

    private fun refusedMark(status: SessionStatus): LiveMessage = when {
        LivePresentation.pausedInZone(status) -> LiveMessage.PAUSED
        LivePresentation.pausedWaitingForLocation(status) -> LiveMessage.PAUSED_NO_FIX
        else -> LiveMessage.NOT_RECORDING
    }

    fun stop() {
        try {
            graph.sessionControl.stop()
        } catch (e: RuntimeException) {
            post(LiveMessage.STOP_FAILED)
        }
    }

    fun dismissRefusal() {
        refusal.value = null
    }

    fun acknowledgeRecovered(dirName: String) {
        graph.recovery.acknowledge(dirName)
    }

    /** Clears the message with [id] once the snackbar has shown it; a newer message stays. */
    fun consumeMessage(id: Long) {
        message.update { current -> if (current?.id == id) null else current }
    }

    /** The app's wall clock, for the Start dialog's suggested name. */
    fun nowWallMs(): Long = graph.clock.wallMillis()

    private suspend fun begin(request: StartRequest) {
        prestart.value = PrestartState.Starting(request)
        val outcomeBefore = graph.sessionControl.lastOutcome.value
        when (val result = attempt { graph.sessionControl.start(request) }) {
            null -> {
                prestart.value = PrestartState.None
                post(LiveMessage.START_FAILED)
            }
            StartResult.Accepted -> {
                prestart.value = PrestartState.None
                refusal.value = null
                watchAcceptedStart(outcomeBefore)
            }
            is StartResult.Refused -> {
                refusal.value = result.refusal
                val issues = if (PrestartPlanner.kindOf(result.refusal) != null) findIssues(result.refusal) else emptyList()
                prestart.value = if (issues.isEmpty()) PrestartState.None else PrestartState.Review(request, issues)
            }
        }
    }

    /**
     * An accepted start can still fail before it records: Android refuses the foreground service, the service
     * does not come up in time, or the session files cannot be created. `SessionControl` then moves from
     * Starting back to Idle without a new outcome, which on its own would look as if nothing happened, so the
     * screen says the start failed.
     */
    private fun watchAcceptedStart(outcomeBefore: SessionOutcome?) {
        viewModelScope.launch {
            val settled = graph.sessionControl.status.first { it !is SessionStatus.Starting }
            if (settled == SessionStatus.Idle && graph.sessionControl.lastOutcome.value == outcomeBefore) {
                post(LiveMessage.START_FAILED)
            }
        }
    }

    private suspend fun findIssues(refusal: StartRefusal?): List<PrestartIssue> {
        val report = attempt { graph.readiness.check() }
        val consentCurrent = attempt { graph.settings.current() }?.let { Consent.isCurrent(it.consent) }
        val storageCanStart = attempt { graph.sessions.storage() }?.canStart
        return PrestartPlanner.issues(report, consentCurrent, storageCanStart, refusal, checkFailed = report == null)
    }

    private fun post(kind: LiveMessage) {
        nextMessageId += 1
        message.value = LiveMessageEvent(nextMessageId, kind)
    }

    private data class ScreenLocal(
        val refusal: StartRefusal?,
        val prestart: PrestartState,
        val message: LiveMessageEvent?,
    )

    private companion object {
        const val STOP_TIMEOUT_MS: Long = 5_000
    }
}

/** [block]'s value, or null when it throws anything but cancellation. */
private suspend fun <T> attempt(block: suspend () -> T): T? = try {
    block()
} catch (e: CancellationException) {
    throw e
} catch (e: Exception) {
    null
}

/**
 * The Live screen: serving tile (RAT, PCI, ARFCN, band, RSRP/RSRQ/SINR, PLMN) with its age badge; the
 * NSA NR leg; neighbours; the 5-minute RSRP and SINR chart; the cadence indicator ("2 s cadence" or
 * "10 s cadence", with the reason: screen off, Wi-Fi on while not charging); service, data and 5G icon
 * state; GPS state; Start (with name, note, place and tests opt-in), Mark (with a
 * note) and Stop; a line when a listener was refused ("Phone permission not granted: no push updates").
 * With the screen off on battery, signal-strength fill stops, and pocket mode says so.
 * Language never implies decoding or signalling.
 *
 * @param onOpenDisclosure opens the consent notice, the fix for a start refused for want of consent.
 * @param onOpenSession opens one session's detail, from the banner of a session that recovery closed.
 *
 * Owner: workstream `ui-session`.
 */
@Composable
fun LiveScreen(
    viewModel: LiveViewModel,
    onOpenSessions: () -> Unit,
    onOpenReadiness: () -> Unit,
    onOpenDisclosure: () -> Unit,
    modifier: Modifier = Modifier,
    onOpenSession: (String) -> Unit = {},
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { viewModel.recheckReadiness() }
    KeepScreenOnEffect(enabled = state.status !is SessionStatus.Idle)
    val actions = LiveActions(
        onStart = viewModel::start,
        onStartAnyway = viewModel::startAnyway,
        onDismissPrestart = viewModel::dismissPrestart,
        onRecheck = viewModel::recheckReadiness,
        onMark = viewModel::mark,
        onStop = viewModel::stop,
        onDismissRefusal = viewModel::dismissRefusal,
        onAcknowledgeRecovered = viewModel::acknowledgeRecovered,
        onConsumeMessage = viewModel::consumeMessage,
        onOpenSessions = onOpenSessions,
        onOpenReadiness = onOpenReadiness,
        onOpenDisclosure = onOpenDisclosure,
        onOpenSession = onOpenSession,
        nowWallMs = viewModel::nowWallMs,
    )
    FieldTapTheme {
        LiveContent(state = state, actions = actions, modifier = modifier)
    }
}

/**
 * RSRP (dBm) and SINR (dB) against time over the last 5 minutes, drawn on a Compose Canvas (no chart library). Each panel's
 * range fits the values it draws: at least -120..-60 dBm and -10..30 dB, so every threshold stays in view, at most the
 * report's axes (-140..-40 and -25..40). Points only from fresh samples; gaps are not bridged. A cell that reports no SINR
 * gives the RSRP panel the room.
 *
 * @param gapThresholdMs lines break where two points are further apart; pass
 *   `ChartMath.gapThresholdMs(live.shortInterval)` so a gap on the 2 s interval is not drawn as data.
 * @param compact low panels, for the pane beside the session buttons in a short, wide window.
 *
 * Owner: workstream `ui-session`.
 */
@Composable
fun SignalChart(
    rsrp: List<ChartPoint>,
    sinr: List<ChartPoint>,
    nowElapsedMs: Long,
    modifier: Modifier = Modifier,
    gapThresholdMs: Long = ChartMath.DEFAULT_GAP_THRESHOLD_MS,
    compact: Boolean = false,
    showSinr: Boolean = true,
) {
    val windowMs = LiveStateReducer.WINDOW_MS
    val rsrpStats = ChartMath.stats(rsrp, nowElapsedMs, windowMs)
    val sinrStats = ChartMath.stats(sinr, nowElapsedMs, windowMs)
    val rsrpSummary = if (rsrpStats != null) {
        stringResource(R.string.chart_summary_rsrp, rsrpStats.latest, rsrpStats.min, rsrpStats.max)
    } else {
        stringResource(R.string.chart_summary_rsrp_empty)
    }
    val sinrNotReported = LivePresentation.sinrNotReported(rsrp, sinr, nowElapsedMs, windowMs)
    val sinrSummary = when {
        sinrStats != null -> stringResource(R.string.chart_summary_sinr, sinrStats.latest, sinrStats.min, sinrStats.max)
        sinrNotReported -> stringResource(R.string.chart_summary_sinr_not_reported)
        else -> stringResource(R.string.chart_summary_sinr_empty)
    }
    SignalHistoryChart(
        rsrp = rsrp,
        sinr = sinr,
        nowElapsedMs = nowElapsedMs,
        labels = SignalChartLabels(
            rsrpTitle = stringResource(R.string.chart_rsrp),
            rsrpUnit = stringResource(R.string.unit_dbm),
            sinrTitle = stringResource(R.string.chart_sinr),
            sinrUnit = stringResource(R.string.unit_db),
            windowStart = stringResource(R.string.chart_window_start),
            windowEnd = stringResource(R.string.chart_window_end),
            noData = stringResource(R.string.chart_no_data),
            notReported = stringResource(R.string.chart_not_reported),
            window = stringResource(R.string.chart_window),
        ),
        summary = if (showSinr) "$rsrpSummary $sinrSummary" else rsrpSummary,
        modifier = modifier,
        windowMs = windowMs,
        gapThresholdMs = gapThresholdMs,
        sinrReported = !sinrNotReported,
        rsrpRange = ChartMath.fittedRange(rsrp, nowElapsedMs, windowMs, SignalScale.RSRP_CHART_RANGE, SignalScale.RSRP_DISPLAY_RANGE),
        sinrRange = ChartMath.fittedRange(sinr, nowElapsedMs, windowMs, SignalScale.SINR_CHART_RANGE, SignalScale.SINR_DISPLAY_RANGE),
        rsrpPanelHeight = when {
            compact -> Sizes.ChartPanelCompactHeight
            sinrNotReported -> Sizes.ChartPanelTallHeight
            else -> Sizes.ChartPanelHeight
        },
        sinrPanelHeight = if (compact) Sizes.ChartPanelCompactHeight else Sizes.ChartPanelHeight,
        showSinr = showSinr,
    )
}

/**
 * Keeps the screen on (`FLAG_KEEP_SCREEN_ON`) while a session is recording, and clears the flag on
 * dispose. No wake lock.
 *
 * This is not a preference. Android refreshes cell information every 2 s only while the display is
 * on, and every 10 s once it sleeps, so a session whose screen slept would quietly record a quarter
 * of the samples it reported being able to take. The flag is held for exactly as long as the
 * recording, and never outside one.
 *
 * It never sets the window brightness: a window brightness overrides adaptive brightness and the
 * user's own slider, which would leave the numbers unreadable in daylight, where drive tests happen.
 *
 * Outside an activity (previews) it does nothing.
 *
 * Owner: workstream `ui-session`.
 */
@Composable
fun KeepScreenOnEffect(enabled: Boolean) {
    val activity = LocalActivity.current
    DisposableEffect(activity, enabled) {
        val window = activity?.window
        if (!enabled || window == null) {
            onDispose { }
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            onDispose { window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
        }
    }
}

/** Longest name, note or place the Start dialog accepts. */
private const val MAX_TEXT_LENGTH: Int = 120

/** Shown for a value Android did not report. Unknown is never 0. */
private const val UNKNOWN_VALUE: String = "—"

/** Everything the Live content can ask for, so the stateless content can be previewed. */
/**
 * Which view of the serving cell the phone layout shows, in switcher order.
 *
 * Live knows nine cards' worth about the cell. All nine in one scroll was the app's own filing order, not
 * anybody's reading order: three named views put the glanceable half first and leave the rest one tap away
 * rather than nine scrolls down.
 *
 * Owner: workstream `ui-session`.
 */
enum class LiveView(@StringRes val label: Int) {
    /** What you look at while walking: the serving tiles, the trend, the state chips. */
    SIGNAL(R.string.live_view_signal),

    /** Which cell this is, which cells it has been, and how often it is being sampled. */
    CELL(R.string.live_view_cell),

    /** Everything else the phone can see from here, and the carriers aggregated with the serving cell. */
    NEIGHBOURS(R.string.live_view_neighbours),
}

private data class LiveActions(
    val onStart: (StartRequest) -> Unit,
    val onStartAnyway: () -> Unit,
    val onDismissPrestart: () -> Unit,
    val onRecheck: () -> Unit,
    val onMark: (String?) -> Unit,
    val onStop: () -> Unit,
    val onDismissRefusal: () -> Unit,
    val onAcknowledgeRecovered: (String) -> Unit,
    val onConsumeMessage: (Long) -> Unit,
    val onOpenSessions: () -> Unit,
    val onOpenReadiness: () -> Unit,
    val onOpenDisclosure: () -> Unit,
    val onOpenSession: (String) -> Unit,
    val nowWallMs: () -> Long,
)

@Composable
private fun LiveContent(state: LiveUiState, actions: LiveActions, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val snackbarHostState = remember { SnackbarHostState() }
    var startDialogOpen by rememberSaveable { mutableStateOf(false) }
    var markDialogOpen by rememberSaveable { mutableStateOf(false) }
    var stopDialogOpen by rememberSaveable { mutableStateOf(false) }
    // Which view of the cell the phone layout is showing. Saved, so it survives rotation and process death:
    // someone watching neighbours who turns the phone should still be watching neighbours.
    var view by rememberSaveable { mutableStateOf(LiveView.SIGNAL) }
    val buttonState = LivePresentation.buttonState(state.status, state.prestart)

    val locationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants[Permissions.FINE_LOCATION] != true) {
            // Android shows no dialog once the user chose "Don't allow" twice; only app settings can help then.
            val canAskAgain = context.findActivity()?.shouldShowRequestPermissionRationale(Permissions.FINE_LOCATION) == true
            if (!canAskAgain) SystemSettings.open(context, SettingsTarget.APP_DETAILS)
        }
        actions.onRecheck()
    }
    val requestPreciseLocation: () -> Unit = { locationPermission.launch(Permissions.LOCATION.toTypedArray()) }

    val event = state.message
    val eventText = event?.let { liveMessageText(it.message) }
    LaunchedEffect(event?.id) {
        if (event != null && eventText != null) {
            try {
                snackbarHostState.showSnackbar(eventText)
            } finally {
                actions.onConsumeMessage(event.id)
            }
        }
    }
    LaunchedEffect(buttonState) {
        if (buttonState != SessionButtonState.RECORDING) {
            markDialogOpen = false
            stopDialogOpen = false
        }
    }

    val liveTitle = stringResource(R.string.live_title)
    BoxWithConstraints(
        modifier = modifier
            .fillMaxSize()
            // Named for TalkBack in landscape too, where the screen has no top bar.
            .semantics { paneTitle = liveTitle },
    ) {
        // A phone in landscape: a bottom bar would leave too little height for the serving cell's value.
        val actionsBeside = LivePresentation.actionsBesideContent(maxWidth, maxHeight)
        val topBarScroll = rememberTopBarScroll()
        Scaffold(
            modifier = Modifier
                .fillMaxSize()
                .nestedScroll(topBarScroll.connection),
            topBar = {
                Column(
                    modifier = if (actionsBeside) {
                        Modifier.windowInsetsPadding(WindowInsets.systemBars.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))
                    } else {
                        Modifier
                    },
                ) {
                    // Beside the content the rail holds the bar's actions: in landscape a 64 dp bar took a fifth of the height.
                    if (!actionsBeside) {
                        FieldTapTopBar(
                            scroll = topBarScroll,
                            title = liveTitle,
                            actions = { LiveBarActions() },
                        )
                    }
                    // Pinned under the bar while a session runs: whether it is collecting stays in view however far the list scrolls.
                    LivePresentation.recordingStrip(state.status, state.live)?.let { RecordingStatusStrip(it) }
                }
            },
            bottomBar = {
                if (!actionsBeside) {
                    LiveActionBar(
                        state = state,
                        buttonState = buttonState,
                        onStart = { startDialogOpen = true },
                        onStop = { stopDialogOpen = true },
                        onMark = { markDialogOpen = true },
                    )
                }
            },
            snackbarHost = { SnackbarHost(snackbarHostState) },
            containerColor = MaterialTheme.colorScheme.background,
        ) { padding ->
            LiveList(
                state = state,
                actions = actions,
                requestPreciseLocation = requestPreciseLocation,
                view = view,
                onSelectView = { view = it },
                modifier = Modifier.padding(padding),
                actionsBeside = if (actionsBeside) {
                    {
                        LiveActionRail(
                            state = state,
                            actions = actions,
                            buttonState = buttonState,
                            onStart = { startDialogOpen = true },
                            onStop = { stopDialogOpen = true },
                            onMark = { markDialogOpen = true },
                        )
                    }
                } else {
                    null
                },
            )
        }
    }

    if (startDialogOpen) {
        val window = LocalWindowInfo.current.containerDpSize
        StartSessionDialog(
            tests = state.tests,
            testsDefaultOn = state.testsDefaultOn,
            nowWallMs = actions.nowWallMs,
            fullScreen = LivePresentation.actionsBesideContent(window.width, window.height),
            onDismiss = { startDialogOpen = false },
            onStart = { request ->
                startDialogOpen = false
                actions.onStart(request)
            },
        )
    }
    if (markDialogOpen) {
        MarkDialog(
            onDismiss = { markDialogOpen = false },
            onMark = { note ->
                markDialogOpen = false
                actions.onMark(note)
            },
        )
    }
    if (stopDialogOpen) {
        StopDialog(
            onDismiss = { stopDialogOpen = false },
            onConfirm = {
                stopDialogOpen = false
                actions.onStop()
            },
        )
    }
    val review = state.prestart as? PrestartState.Review
    if (review != null) {
        PrestartSheet(review = review, actions = actions, requestPreciseLocation = requestPreciseLocation)
    }
}

@Composable
private fun LiveBarActions() {
    // Sessions, Diagnostics, Settings and About are reached from the bottom tab bar; Live has no
    // controls of its own in the bar since walk mode went.
}

@Composable
private fun OverflowItem(@StringRes label: Int, icon: ImageVector, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(text = stringResource(label)) },
        onClick = onClick,
        leadingIcon = { Icon(imageVector = icon, contentDescription = null) },
    )
}

/** What the Live list items need, gathered once, so the phone layout and the wide layout share the same items. */
private class LiveParts(
    val state: LiveUiState,
    val actions: LiveActions,
    val labels: SignalQualityLabels,
    val notes: List<ListenerNote>,
    val locationMissing: Boolean,
    @StringRes val refusalText: Int?,
    val requestPreciseLocation: () -> Unit,
    val openLocationSettings: () -> Unit,
    val openWifiSettings: () -> Unit,
    /** Beside the session buttons in a short, wide window: the age badge in the hero's header, low chart panels. */
    val compact: Boolean,
)

/**
 * Upright on a phone: any banner, then a [ViewSwitcher] over three views of the same cell — Signal (the serving
 * tiles, the 5-minute trend, the cadence/service/data/5G/GPS chips), Cell (its details, the cells it has sat on,
 * the cadence detail) and Neighbours. Nine cards in one scroll was everything the app knows stacked in the order
 * it was written; what an engineer glances at while walking is the first view, on the first screen at font scale
 * 1.0 on a Pixel 7, as ScreenTourTest asserts. From [Sizes.WideLayoutMinWidth] (landscape phones, tablets) there is
 * room for all of it at once, so the wide layout keeps both panes and shows no switcher: two panes, the
 * serving cell and its details on one side, the trend first on the other, then the chips and cadence details.
 * [actionsBeside], in a short wide window, is the rail at the end: the bar's actions at its top, the session buttons at
 * its bottom.
 */
@Composable
private fun LiveList(
    state: LiveUiState,
    actions: LiveActions,
    requestPreciseLocation: () -> Unit,
    view: LiveView,
    onSelectView: (LiveView) -> Unit,
    modifier: Modifier = Modifier,
    actionsBeside: (@Composable () -> Unit)? = null,
) {
    val context = LocalContext.current
    val notes = LivePresentation.listenerNotes(state.live.listeners)
    val requestMissing: (ListenerNote) -> Boolean = { it.listener == RadioListener.CELL_INFO_REQUEST && it.outcome == ListenerOutcome.MISSING_PERMISSION }
    val parts = LiveParts(
        state = state,
        actions = actions,
        labels = signalQualityLabels(),
        notes = notes.filterNot(requestMissing),
        locationMissing = notes.any(requestMissing),
        refusalText = refusalMessageRes(state.refusal),
        requestPreciseLocation = requestPreciseLocation,
        openLocationSettings = { SystemSettings.open(context, SettingsTarget.LOCATION_SOURCE) },
        openWifiSettings = { SystemSettings.open(context, SettingsTarget.WIFI) },
        compact = actionsBeside != null,
    )
    val gutter = screenGutter()
    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        if (LivePresentation.twoPanes(maxWidth, actionsBeside != null)) {
            Row(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = gutter),
                horizontalArrangement = Arrangement.spacedBy(Spacing.SectionGap),
            ) {
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                    contentPadding = PaddingValues(vertical = Spacing.Lg),
                    verticalArrangement = Arrangement.spacedBy(Spacing.SectionGap),
                ) {
                    bannerItems(parts)
                    servingTilesItem(parts)
                    servingCardItem(parts)
                    neighboursItem(parts)
                    servingHistoryItem(parts)
                }
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                    contentPadding = PaddingValues(vertical = Spacing.Lg),
                    verticalArrangement = Arrangement.spacedBy(Spacing.SectionGap),
                ) {
                    chartItem(parts)
                    statusChipsItem(parts)
                    cadenceDetailsItem(parts)
                    limitsItem(parts)
                }
                if (actionsBeside != null) ActionColumn(actionsBeside)
            }
        } else {
            Row(modifier = Modifier.fillMaxSize()) {
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                    contentPadding = PaddingValues(horizontal = gutter, vertical = Spacing.Lg),
                    verticalArrangement = Arrangement.spacedBy(Spacing.SectionGap),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    // Banners sit above the switcher: they are why the screen is not showing what it should,
                    // and hiding one behind an unchosen view would be hiding the answer.
                    bannerItems(parts)
                    item(key = "view-switcher") {
                        ViewSwitcher(
                            options = LiveView.entries,
                            selected = view,
                            label = { stringResource(it.label) },
                            onSelect = onSelectView,
                            modifier = Modifier.contentWidth(),
                        )
                    }
                    when (view) {
                        LiveView.SIGNAL -> {
                            servingTilesItem(parts)
                            chartItem(parts)
                            statusChipsItem(parts)
                            limitsItem(parts)
                        }

                        LiveView.CELL -> {
                            servingCardItem(parts)
                            servingHistoryItem(parts)
                            cadenceDetailsItem(parts)
                            // With no serving cell the Cell view would be sampling figures and nothing
                            // else, which answers a question nobody asked. This says why it is empty.
                            limitsItem(parts)
                        }

                        LiveView.NEIGHBOURS -> neighboursItem(parts)
                    }
                }
                if (actionsBeside != null) ActionColumn(actionsBeside, modifier = Modifier.padding(end = gutter))
            }
        }
    }
}

/** The rail beside the content: the bar's actions at its top, the session buttons at its bottom where a thumb reaches them. */
@Composable
private fun ActionColumn(content: @Composable () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .width(Sizes.ActionRailWidth)
            .fillMaxHeight()
            .padding(vertical = Spacing.Sm),
    ) {
        content()
    }
}

/** Recovered sessions, a refusal, then what stops measuring (location off, no permission, waiting for a fix, a zone), then the Wi-Fi prompt. */
private fun LazyListScope.bannerItems(parts: LiveParts) {
    val state = parts.state
    val actions = parts.actions
    items(state.recovered, key = { "recovered:" + it.dirName }) { outcome ->
        val name = outcome.name ?: outcome.dirName
        StatusBanner(
            title = stringResource(if (outcome.interrupted) R.string.live_recovered_title else R.string.live_recovered_stopped_title),
            message = if (outcome.interrupted) {
                stringResource(R.string.live_recovered_message, name, exitReasonWords(outcome.stoppedBy))
            } else {
                stringResource(R.string.live_recovered_stopped_message, name)
            },
            tone = StatusTone.WARNING,
            actionLabel = stringResource(R.string.live_action_open_session),
            onAction = {
                actions.onAcknowledgeRecovered(outcome.dirName)
                actions.onOpenSession(outcome.dirName)
            },
            dismissContentDescription = stringResource(R.string.action_dismiss),
            onDismiss = { actions.onAcknowledgeRecovered(outcome.dirName) },
            modifier = Modifier.contentWidth(),
        )
    }
    val refusalText = parts.refusalText
    if (refusalText != null) {
        item(key = "refusal") {
            StatusBanner(
                message = stringResource(refusalText),
                tone = StatusTone.WARNING,
                dismissContentDescription = stringResource(R.string.action_dismiss),
                onDismiss = actions.onDismissRefusal,
                modifier = Modifier.contentWidth(),
            )
        }
    }
    if (state.locationOff) {
        item(key = "location-off") {
            StatusBanner(
                title = stringResource(R.string.issue_location_off_title),
                message = stringResource(
                    if (state.status is SessionStatus.Recording) R.string.live_location_off_recording else R.string.issue_location_off_detail,
                ),
                tone = StatusTone.ERROR,
                icon = FieldTapIcons.Location,
                actionLabel = stringResource(R.string.issue_location_off_fix),
                onAction = parts.openLocationSettings,
                modifier = Modifier.contentWidth(),
            )
        }
    }
    if (parts.locationMissing) {
        item(key = "location-missing") {
            StatusBanner(
                message = stringResource(R.string.live_note_request_missing),
                tone = StatusTone.ERROR,
                icon = FieldTapIcons.Location,
                actionLabel = stringResource(R.string.live_action_allow_location),
                onAction = parts.requestPreciseLocation,
                modifier = Modifier.contentWidth(),
            )
        }
    }
    if (state.waitingForLocation && !state.locationOff) {
        item(key = "waiting-for-location") {
            StatusBanner(
                message = stringResource(R.string.live_waiting_location_banner),
                tone = StatusTone.INFO,
                icon = FieldTapIcons.Shield,
                modifier = Modifier.contentWidth(),
            )
        }
    }
    if (state.pausedInZone) {
        item(key = "paused") {
            StatusBanner(
                message = stringResource(R.string.live_paused_banner),
                tone = StatusTone.INFO,
                icon = FieldTapIcons.Shield,
                modifier = Modifier.contentWidth(),
            )
        }
    }
    if (LivePresentation.showWifiCadencePrompt(state.status !is SessionStatus.Idle, state.live.conditions)) {
        item(key = "wifi-cadence") {
            StatusBanner(
                message = stringResource(R.string.live_wifi_cadence_prompt),
                tone = StatusTone.WARNING,
                icon = FieldTapIcons.Wifi,
                actionLabel = stringResource(R.string.live_action_wifi_settings),
                onAction = parts.openWifiSettings,
                modifier = Modifier.contentWidth(),
            )
        }
    }
}

private fun LazyListScope.servingTilesItem(parts: LiveParts) {
    item(key = "serving-tiles") {
        ServingTiles(live = parts.state.live, labels = parts.labels, modifier = Modifier.contentWidth())
    }
}

private fun LazyListScope.statusChipsItem(parts: LiveParts) {
    item(key = "status-chips") {
        StatusChips(live = parts.state.live, modifier = Modifier.contentWidth())
    }
}

private fun LazyListScope.cadenceDetailsItem(parts: LiveParts) {
    item(key = "cadence-details") {
        CadenceDetailsCard(live = parts.state.live, notes = parts.notes, modifier = Modifier.contentWidth())
    }
}

private fun LazyListScope.servingCardItem(parts: LiveParts) {
    if (parts.state.live.serving != null) {
        item(key = "serving-card") {
            ServingCard(live = parts.state.live, labels = parts.labels, modifier = Modifier.contentWidth())
        }
    }
}

/** The trend in a card without a title: "last 5 min" sits beside the RSRP title, which saves a row. */
private fun LazyListScope.chartItem(parts: LiveParts) {
    item(key = "chart") {
        val live = parts.state.live
        SectionCard(modifier = Modifier.contentWidth()) {
            SignalChart(
                rsrp = live.rsrpSeries,
                sinr = live.sinrSeries,
                nowElapsedMs = live.nowElapsedMs,
                gapThresholdMs = ChartMath.gapThresholdMs(live.shortInterval),
                compact = parts.compact,
            )
        }
    }
}

private fun LazyListScope.servingHistoryItem(parts: LiveParts) {
    if (parts.state.live.servingHistory.size < 2) return
    item(key = "serving-history") {
        ServingHistoryCard(
            history = parts.state.live.servingHistory,
            labels = parts.labels,
            modifier = Modifier.contentWidth(),
        )
    }
}

private fun LazyListScope.neighboursItem(parts: LiveParts) {
    item(key = "neighbours") {
        NeighboursCard(
            neighbours = LivePresentation.neighbourRows(parts.state.live),
            labels = parts.labels,
            modifier = Modifier.contentWidth(),
        )
    }
}

private fun LazyListScope.limitsItem(parts: LiveParts) {
    if (parts.state.live.serving == null) {
        item(key = "limits") {
            LimitsStatementCard(
                title = stringResource(R.string.live_limits_title),
                statement = stringResource(R.string.limits_statement),
                modifier = Modifier.contentWidth(),
            )
        }
    }
}

@Composable
private fun ServingTiles(live: LiveState, labels: SignalQualityLabels, modifier: Modifier = Modifier) {
    val serving = live.serving
    val rsrpQuality = SignalScale.quality(SignalMetric.RSRP, serving?.rsrp)
    val rsrqQuality = SignalScale.quality(SignalMetric.RSRQ, serving?.rsrq)
    val sinrQuality = SignalScale.quality(SignalMetric.SINR, serving?.sinr)
    val ageMs = live.servingAgeMs
    val absence = LivePresentation.servingAbsence(live)
    val problem = LivePresentation.servingProblem(live)
    val ageText = if (ageMs != null) stringResource(R.string.age_old, Formats.ageSeconds(ageMs)) else absenceBadge(absence)
    val rsrpLabel = stringResource(rsrpLabelRes(serving?.rat))
    val rsrqLabel = stringResource(rsrqLabelRes(serving?.rat))
    val sinrLabel = stringResource(sinrLabelRes(serving?.rat))
    val dbm = stringResource(R.string.unit_dbm)
    // A cell that reports neither gets one line in the hero, not a row of two tiles that only say so.
    val neitherReported = serving != null && serving.rsrq == null && serving.sinr == null
    // With a cell: its identity, its operator, what it does not report, then why it may be ageing. Without: why there is none.
    val supportingText = if (serving != null) {
        listOfNotNull(
            servingSummary(serving),
            if (neitherReported) stringResource(R.string.live_rsrq_sinr_not_reported, rsrqLabel, sinrLabel) else null,
            problem?.let { servingProblemLine(it) },
        ).joinToString("\n")
    } else {
        absenceDetail(absence)
    }
    // TalkBack (and the e2e serving-cell wait) reads the whole hero as one phrase — the value, its level, the freshness and
    // the identity — so the donut, the quality pill, the age pill and the identity line below read once, not four times.
    val heroDescription = listOfNotNull(
        rsrpLabel,
        serving?.rsrp?.let { "$it $dbm" } ?: UNKNOWN_VALUE,
        if (serving != null) labels.of(rsrpQuality) else null,
        ageText,
        supportingText?.takeIf { it.isNotEmpty() },
    ).joinToString(", ")
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(Spacing.Md)) {
        // The Momentum signature: the serving RSRP as the donut/ring gauge hero card (its label, a soft quality pill and the
        // age), with the cell's identity on the line beneath. The whole block is one TalkBack phrase.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clearAndSetSemantics { this.contentDescription = heroDescription },
            verticalArrangement = Arrangement.spacedBy(Spacing.Sm),
        ) {
            SignalDonutHero(
                label = rsrpLabel,
                value = serving?.rsrp,
                quality = rsrpQuality,
                unit = dbm,
                qualityLabel = labels.of(rsrpQuality),
                donutContentDescription = heroDescription,
                metric = SignalMetric.RSRP,
                stale = live.badge == AgeBadge.STALE,
                ageText = ageText,
                ageBadge = live.badge,
                modifier = Modifier.fillMaxWidth(),
            )
            // The identity is several logical lines (the cell, then "operator · PLMN", plus any "not reported"/ageing note),
            // each rendered as its own Text. One Text with maxLines = 2 truncated the two-line identity as soon as the cell
            // line wrapped, pushing the operator and its PLMN behind an ellipsis ("T-Mobile · 310260…"); giving each line its
            // own Text keeps every number readable. The outer Column owns the one TalkBack phrase (heroDescription), so these
            // still read once, not line by line.
            val identityLines = supportingText?.split("\n").orEmpty().filter { it.isNotEmpty() }
            if (identityLines.isNotEmpty()) {
                Column(
                    modifier = Modifier.padding(horizontal = Spacing.Xs),
                    verticalArrangement = Arrangement.spacedBy(Spacing.Xxs),
                ) {
                    identityLines.forEach { line ->
                        Text(
                            text = line,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            // A cell's identity is short and clamps safely. With no cell this is the
                            // sentence explaining why there is none, and cutting it mid-word leaves
                            // the reader with the problem and not the reason.
                            maxLines = if (serving == null) Int.MAX_VALUE else 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
        if (neitherReported) return@Column
        // One row, whatever the width or font scale: two stacked tiles pushed the trend and the cadence off the first screen.
        val notReported = stringResource(R.string.live_not_reported)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min),
            horizontalArrangement = Arrangement.spacedBy(Spacing.Md),
        ) {
            SecondaryMetricTile(
                label = rsrqLabel,
                value = serving?.rsrq?.toString(),
                unit = stringResource(R.string.unit_db),
                quality = rsrqQuality,
                qualityLabel = secondaryQualityLabel(serving, serving?.rsrq, rsrqQuality, labels, notReported),
                stale = live.badge == AgeBadge.STALE,
                placeholder = UNKNOWN_VALUE,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
            )
            SecondaryMetricTile(
                label = sinrLabel,
                value = serving?.sinr?.toString(),
                unit = stringResource(R.string.unit_db),
                quality = sinrQuality,
                qualityLabel = secondaryQualityLabel(serving, serving?.sinr, sinrQuality, labels, notReported),
                stale = live.badge == AgeBadge.STALE,
                placeholder = UNKNOWN_VALUE,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
            )
        }
    }
}

/** No word without a serving cell; "Not reported" when the cell has no such value; else the value's quality. */
private fun secondaryQualityLabel(
    serving: LiveCell?,
    value: Int?,
    quality: com.fieldtap.ui.theme.SignalQuality?,
    labels: SignalQualityLabels,
    notReported: String,
): String? = when {
    serving == null -> null
    value == null -> notReported
    else -> labels.of(quality)
}

@Composable
private fun ServingCard(live: LiveState, labels: SignalQualityLabels, modifier: Modifier = Modifier) {
    val serving = live.serving ?: return
    val dense = Sizes.KeyValueRowDenseMinHeight
    SectionCard(
        title = stringResource(R.string.live_section_serving),
        icon = FieldTapIcons.SignalBars,
        modifier = modifier,
        itemGap = Spacing.Sm,
    ) {
        val network = LivePresentation.servingNetwork(serving, live.nsaLeg)
        if (network != null) {
            KeyValueRow(key = stringResource(R.string.live_row_network), value = stringResource(networkRes(network)), tabular = false, minHeight = dense)
        }
        KeyValueRow(key = stringResource(R.string.live_row_operator), value = operatorText(serving), tabular = false, minHeight = dense)
        KeyValueRow(key = stringResource(R.string.live_row_pci), value = serving.pci?.toString() ?: UNKNOWN_VALUE, minHeight = dense)
        KeyValueRow(
            key = stringResource(R.string.live_row_channel),
            value = serving.arfcn?.let { stringResource(channelRes(serving.rat), it) } ?: UNKNOWN_VALUE,
            minHeight = dense,
        )
        KeyValueRow(
            key = stringResource(R.string.live_row_band),
            value = serving.band?.let { if (serving.rat == Rat.NR) "n$it" else it.toString() } ?: UNKNOWN_VALUE,
            minHeight = dense,
        )
        val report = LivePresentation.newerSignalReport(serving, live.signal, live.nowElapsedMs)
        if (report != null) {
            KeyValueRow(
                key = stringResource(R.string.live_row_signal_report),
                value = stringResource(R.string.live_signal_report_value, report.rsrpDbm, Formats.ageSeconds(report.ageMs)),
                minHeight = dense,
            )
        }
        val leg = live.nsaLeg
        if (leg != null) {
            val quality = SignalScale.quality(SignalMetric.RSRP, leg.rsrp)
            SectionDivider()
            CellSignalRow(
                title = stringResource(R.string.live_nsa_leg),
                valueText = leg.rsrp?.toString(),
                unit = stringResource(R.string.unit_dbm),
                quality = quality,
                qualityLabel = labels.of(quality),
                supportingText = cellIdentity(leg),
                placeholder = UNKNOWN_VALUE,
            )
        }
        // Carriers this phone is aggregating. They belong beside the serving cell because they are
        // being used; the neighbour list is for cells we are not on.
        live.aggregatedLegs.forEach { aggregated ->
            val quality = SignalScale.quality(SignalMetric.RSRP, aggregated.rsrp)
            SectionDivider()
            CellSignalRow(
                title = stringResource(R.string.live_aggregated_leg),
                valueText = aggregated.rsrp?.toString(),
                unit = stringResource(R.string.unit_dbm),
                quality = quality,
                qualityLabel = labels.of(quality),
                supportingText = cellIdentity(aggregated),
                placeholder = UNKNOWN_VALUE,
            )
        }
    }
}

/**
 * Why Android measures at the cadence the chips show, and how it is going: the reason, the measured time between fresh
 * samples, the satellites, and any listener that did not register. Below the trend, in dense rows: none of it changes
 * what an engineer does while walking.
 */
@Composable
private fun CadenceDetailsCard(live: LiveState, notes: List<ListenerNote>, modifier: Modifier = Modifier) {
    val dense = Sizes.KeyValueRowDenseMinHeight
    SectionCard(
        title = stringResource(R.string.live_section_cadence_details),
        icon = FieldTapIcons.Timer,
        modifier = modifier,
        itemGap = Spacing.Sm,
    ) {
        KeyValueRow(
            key = stringResource(R.string.live_row_cadence_reason),
            value = stringResource(cadenceReasonRes(LivePresentation.cadenceReason(live.conditions))),
            tabular = false,
            // The reason can run past one line ("Charging keeps 2 s with Wi-Fi on"); stacked, it reads left-aligned
            // under the key instead of wrapping ragged and right-aligned with an orphaned second line.
            stacked = true,
            minHeight = dense,
        )
        KeyValueRow(
            key = stringResource(R.string.live_row_measured_interval),
            value = live.recentFreshIntervalMs?.let { stringResource(R.string.seconds_value, DisplayTime.seconds(it)) } ?: UNKNOWN_VALUE,
            minHeight = dense,
        )
        val gnss = live.gnss
        if (gnss != null) {
            KeyValueRow(
                key = stringResource(R.string.live_row_satellites),
                value = stringResource(R.string.live_satellites_value, gnss.satellitesUsedInFix, gnss.satellitesVisible),
                minHeight = dense,
            )
        }
        for (note in notes) {
            ListenerNoteLine(note)
        }
    }
}

@Composable
private fun ListenerNoteLine(note: ListenerNote) {
    val family = FieldTapDesign.colors.status(note.tone)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(Spacing.Sm),
    ) {
        Icon(
            imageVector = statusIcon(note.tone),
            contentDescription = null,
            tint = family.color,
            modifier = Modifier
                .padding(top = Spacing.Xxs)
                .size(Sizes.IconSmall),
        )
        Text(
            text = listenerNoteText(note),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * The cadence, service, mobile data, the 5G icon and GPS, as chips in one flowing group under the serving cell, outside
 * any card. The cadence's reason is in the cadence details below the trend; a chip holds only a short state.
 */
@Composable
private fun StatusChips(live: LiveState, modifier: Modifier = Modifier) {
    val service = LivePresentation.serviceChip(live.service)
    val data = LivePresentation.dataChip(live.data)
    val dataNetwork = LivePresentation.dataNetworkName(live.data)
    val fiveG = LivePresentation.fiveGIcon(live.display)
    val gps = LivePresentation.gpsChip(live.lastFix, live.nowElapsedMs)
    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Spacing.Sm),
        verticalArrangement = Arrangement.spacedBy(Spacing.Sm),
    ) {
        StatusChip(
            text = stringResource(
                when (live.shortInterval) {
                    true -> R.string.live_cadence_short
                    false -> R.string.live_cadence_long
                    null -> R.string.live_cadence_unknown
                },
            ),
            tone = calmChipTone(cadenceTone(live.shortInterval)),
            icon = FieldTapIcons.Timer,
        )
        StatusChip(text = stringResource(serviceRes(service)), tone = calmChipTone(service.tone))
        StatusChip(
            text = if (data == DataChip.CONNECTED && dataNetwork != null) {
                stringResource(R.string.live_data_connected_type, dataNetwork)
            } else {
                stringResource(dataRes(data))
            },
            tone = calmChipTone(data.tone),
            icon = FieldTapIcons.Transfer,
        )
        if (fiveG != null) {
            StatusChip(
                text = stringResource(if (fiveG) R.string.live_5g_icon_on else R.string.live_5g_icon_off),
                tone = StatusTone.NEUTRAL,
                icon = FieldTapIcons.SignalBars,
            )
        }
        StatusChip(
            text = gpsText(gps),
            tone = calmChipTone(gps.tone),
            icon = if (gps is GpsChip.Fix) FieldTapIcons.GpsFixed else FieldTapIcons.GpsOff,
        )
    }
}

/**
 * Calms a steady-state chip to neutral, so colour is reserved for the one or two chips that signal a problem
 * (out of service, mobile data off, GPS lost): the row parses as a glanceable status line, not a swatch sampler of
 * green, blue and grey. A WARNING or ERROR keeps its colour; the reassuring "in service" / "GPS fix" states go grey.
 */
private fun calmChipTone(tone: StatusTone): StatusTone =
    if (tone == StatusTone.WARNING || tone == StatusTone.ERROR) tone else StatusTone.NEUTRAL

/**
 * The serving cells this phone has used while Live has been watching, newest first. Drawn only once
 * there are two: a history of one cell is the serving card again, and says nothing about reselection.
 */
@Composable
private fun ServingHistoryCard(history: List<ServingVisit>, labels: SignalQualityLabels, modifier: Modifier = Modifier) {
    if (history.size < 2) return
    SectionCard(
        title = stringResource(R.string.live_section_serving_history),
        subtitle = pluralStringResource(R.plurals.live_serving_history_count, history.size, history.size),
        modifier = modifier,
    ) {
        history.forEachIndexed { index, visit ->
            if (index > 0) SectionDivider()
            val cell = visit.cell
            val quality = SignalScale.quality(SignalMetric.RSRP, cell.rsrp)
            val held = if (index == 0) {
                stringResource(R.string.live_history_serving_now)
            } else {
                stringResource(R.string.live_history_held, Formats.elapsed(visit.untilMs - visit.sinceMs))
            }
            CellSignalRow(
                title = neighbourTitle(cell),
                valueText = cell.rsrp?.toString(),
                unit = stringResource(R.string.unit_dbm),
                quality = quality,
                qualityLabel = labels.of(quality),
                supportingText = listOf(ratName(cell.rat), held).joinToString(stringResource(R.string.value_separator)),
                placeholder = UNKNOWN_VALUE,
            )
        }
    }
}

@Composable
private fun NeighboursCard(neighbours: List<NeighbourRow>, labels: SignalQualityLabels, modifier: Modifier = Modifier) {
    SectionCard(
        title = stringResource(R.string.live_section_neighbours),
        subtitle = if (neighbours.isEmpty()) null else pluralStringResource(R.plurals.live_neighbours_count, neighbours.size, neighbours.size),
        modifier = modifier,
    ) {
        if (neighbours.isEmpty()) {
            Text(
                text = stringResource(R.string.live_neighbours_none),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            neighbours.forEachIndexed { index, row ->
                if (index > 0) SectionDivider()
                val cell = row.cell
                val quality = SignalScale.quality(SignalMetric.RSRP, cell.rsrp)
                CellSignalRow(
                    title = neighbourTitle(cell),
                    valueText = cell.rsrp?.toString(),
                    unit = stringResource(R.string.unit_dbm),
                    quality = quality,
                    qualityLabel = labels.of(quality),
                    supportingText = neighbourSupporting(row),
                    placeholder = UNKNOWN_VALUE,
                )
            }
        }
    }
}

@Composable
private fun LiveActionBar(
    state: LiveUiState,
    buttonState: SessionButtonState,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onMark: () -> Unit,
) {
    // The one dominant primary action per screen lives in the design system's inset floating action bar (clean-design
    // §5, §8.1): a raised surfaceContainerLow card with a hairline, over the navigation bar. Mark joins it, tonal, while
    // recording; Stop is the dominant filled action then (SessionButton, recording tone).
    FieldTapFloatingActionBar {
        LiveSessionButton(state, buttonState, onStart, onStop, modifier = Modifier.weight(1f))
        if (buttonState == SessionButtonState.RECORDING) {
            LiveMarkButton(state, onMark, modifier = Modifier.heightIn(min = Sizes.PrimaryButtonHeight))
        }
    }
}

/**
 * The rail beside the content in a short, wide window: Live's bar actions at its top, where the top bar would
 * have held them, and the session buttons at its bottom, the Start button's label on one line under its icon.
 */
@Composable
private fun LiveActionRail(
    state: LiveUiState,
    actions: LiveActions,
    buttonState: SessionButtonState,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onMark: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxHeight(), verticalArrangement = Arrangement.SpaceBetween) {
        CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurfaceVariant) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                LiveBarActions()
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.Sm)) {
            if (buttonState == SessionButtonState.RECORDING) {
                LiveMarkButton(
                    state,
                    onMark,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = Sizes.PrimaryButtonHeight),
                )
            }
            LiveSessionButton(state, buttonState, onStart, onStop, modifier = Modifier.fillMaxWidth(), stacked = true)
        }
    }
}

@Composable
private fun LiveSessionButton(
    state: LiveUiState,
    buttonState: SessionButtonState,
    onStart: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
    stacked: Boolean = false,
) {
    val elapsedMs = (state.status as? SessionStatus.Recording)?.snapshot?.elapsedMs
    // A running session that is not collecting (location off, waiting for a fix, paused in a zone) reads "Paused", so the
    // button never says "Recording" while the strip above says the session is not recording.
    val paused = buttonState == SessionButtonState.RECORDING && LivePresentation.recordingPaused(state.status, state.live)
    SessionButton(
        state = buttonState,
        startLabel = stringResource(if (stacked) R.string.live_start_short else R.string.live_start),
        stacked = stacked,
        startContentDescription = if (stacked) stringResource(R.string.live_start) else null,
        stopLabel = stringResource(R.string.live_stop),
        onStart = onStart,
        onStop = onStop,
        modifier = modifier,
        busyLabel = stringResource(
            when {
                buttonState == SessionButtonState.STOPPING -> R.string.live_stopping
                state.prestart is PrestartState.Checking -> R.string.live_checking
                else -> R.string.live_starting
            },
        ),
        recordingLabel = stringResource(if (paused) R.string.live_paused else R.string.live_recording),
        elapsedText = elapsedMs?.let { Formats.elapsed(it) },
    )
}

@Composable
private fun LiveMarkButton(state: LiveUiState, onMark: () -> Unit, modifier: Modifier = Modifier) {
    val unavailable = stringResource(R.string.live_mark_unavailable)
    FilledTonalButton(
        onClick = onMark,
        // Match the accent Start/Stop button's 12 dp control, not Material's stadium (clean-design §5).
        shape = ShapeRoles.Control,
        enabled = state.markEnabled,
        modifier = modifier.then(if (state.markEnabled) Modifier else Modifier.semantics { contentDescription = unavailable }),
    ) {
        Icon(imageVector = FieldTapIcons.Flag, contentDescription = null, modifier = Modifier.size(Sizes.Icon))
        Spacer(modifier = Modifier.width(Spacing.Sm))
        Text(text = stringResource(R.string.live_mark))
    }
}

/**
 * Name, the tests choice, note and place, then Start. Upright it is an alert dialog. In a window lower than
 * [Sizes.ShortWindowMaxHeight] ([fullScreen], a phone in landscape) the alert's scrolling text slot cut the fields mid-glyph
 * and hid the tests choice, so it fills the screen instead: a bar with Close, the title and Start, over a scrolling form,
 * note and place side by side from [Sizes.WideLayoutMinWidth].
 */
@Composable
private fun StartSessionDialog(
    tests: TestSettings?,
    testsDefaultOn: Boolean,
    nowWallMs: () -> Long,
    fullScreen: Boolean,
    onDismiss: () -> Unit,
    onStart: (StartRequest) -> Unit,
) {
    val openedAtMs = remember { nowWallMs() }
    val suggestedName = stringResource(R.string.live_default_name, DisplayTime.time(openedAtMs))
    var name by rememberSaveable { mutableStateOf(suggestedName) }
    var note by rememberSaveable { mutableStateOf("") }
    var place by rememberSaveable { mutableStateOf("") }
    var testsEnabled by rememberSaveable { mutableStateOf(testsDefaultOn) }
    val nameValid = name.isNotBlank()
    val start: () -> Unit = {
        onStart(
            StartRequest(
                name = name.trim(),
                note = note.trim().ifEmpty { null },
                location = place.trim().ifEmpty { null },
                testsEnabled = testsEnabled,
            ),
        )
    }
    val fields: @Composable (Boolean) -> Unit = { notesSideBySide ->
        StartSessionFields(
            name = name,
            onNameChange = { name = it.take(MAX_TEXT_LENGTH) },
            note = note,
            onNoteChange = { note = it.take(MAX_TEXT_LENGTH) },
            place = place,
            onPlaceChange = { place = it.take(MAX_TEXT_LENGTH) },
            testsEnabled = testsEnabled,
            onTestsChange = { testsEnabled = it },
            tests = tests,
            notesSideBySide = notesSideBySide,
        )
    }
    if (fullScreen) {
        FullScreenStartDialog(nameValid = nameValid, onDismiss = onDismiss, onStart = start, fields = fields)
        return
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = start, enabled = nameValid) {
                Text(text = stringResource(R.string.live_start_confirm))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(text = stringResource(R.string.action_cancel)) }
        },
        title = { Text(text = stringResource(R.string.live_start_dialog_title)) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                fields(false)
            }
        },
    )
}

@Composable
private fun FullScreenStartDialog(
    nameValid: Boolean,
    onDismiss: () -> Unit,
    onStart: () -> Unit,
    fields: @Composable (Boolean) -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val scroll = rememberScrollState()
        Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            Column(modifier = Modifier.fillMaxSize()) {
                FieldTapTopBar(
                    title = stringResource(R.string.live_start_dialog_title),
                    onNavigateUp = onDismiss,
                    navigateUpContentDescription = stringResource(R.string.action_cancel),
                    navigationIcon = FieldTapIcons.Close,
                    actions = {
                        TextButton(onClick = onStart, enabled = nameValid, modifier = Modifier.heightIn(min = Sizes.MinTouchTarget)) {
                            Text(text = stringResource(R.string.live_start_confirm))
                        }
                    },
                )
                // A hairline under the bar once the form moves beneath it. Derived, so scrolling recomposes only when
                // the form leaves or reaches the top, not at every pixel.
                val scrolled by remember(scroll) { derivedStateOf { scroll.value > 0 } }
                if (scrolled) SectionDivider()
                BoxWithConstraints(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                ) {
                    val wide = maxWidth >= Sizes.WideLayoutMinWidth
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(scroll)
                            .imePadding()
                            .padding(horizontal = screenGutter(), vertical = Spacing.Lg),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box(modifier = Modifier.contentWidth()) { fields(wide) }
                    }
                }
            }
        }
    }
}

@Composable
private fun StartSessionFields(
    name: String,
    onNameChange: (String) -> Unit,
    note: String,
    onNoteChange: (String) -> Unit,
    place: String,
    onPlaceChange: (String) -> Unit,
    testsEnabled: Boolean,
    onTestsChange: (Boolean) -> Unit,
    tests: TestSettings?,
    notesSideBySide: Boolean,
) {
    val nameValid = name.isNotBlank()
    val nameError = stringResource(R.string.live_field_name_error)
    val placeSupporting = stringResource(R.string.live_field_place_supporting)
    val noteField: @Composable (Modifier) -> Unit = { fieldModifier ->
        OutlinedTextField(
            value = note,
            onValueChange = onNoteChange,
            modifier = fieldModifier,
            label = { Text(text = stringResource(R.string.live_field_note)) },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
            singleLine = true,
        )
    }
    val placeField: @Composable (Modifier) -> Unit = { fieldModifier ->
        OutlinedTextField(
            value = place,
            onValueChange = onPlaceChange,
            modifier = fieldModifier,
            label = { Text(text = stringResource(R.string.live_field_place)) },
            supportingText = { Text(text = placeSupporting) },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
            singleLine = true,
        )
    }
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.Sm)) {
        OutlinedTextField(
            value = name,
            onValueChange = onNameChange,
            modifier = Modifier.fillMaxWidth(),
            label = { Text(text = stringResource(R.string.live_field_name)) },
            // Null while the name is valid: an always-present slot reserved an empty line and doubled the gap after Name.
            supportingText = if (nameValid) null else { { Text(text = nameError) } },
            isError = !nameValid,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
            singleLine = true,
        )
        // Right after the name: the choice that uses mobile data is never below the dialog's fold.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = Sizes.MinTouchTarget)
                .toggleable(value = testsEnabled, role = Role.Checkbox, onValueChange = onTestsChange),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(Spacing.Md),
        ) {
            Checkbox(checked = testsEnabled, onCheckedChange = null)
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.live_tests_title),
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                // Never cut short: it says what the tests reach over mobile data.
                Text(
                    text = tests?.let { testsTargetsText(it) } ?: stringResource(R.string.live_tests_supporting),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (notesSideBySide) {
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.Md)) {
                noteField(Modifier.weight(1f))
                placeField(Modifier.weight(1f))
            }
        } else {
            noteField(Modifier.fillMaxWidth())
            placeField(Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun MarkDialog(onDismiss: () -> Unit, onMark: (String?) -> Unit) {
    var note by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = { onMark(note.trim().ifEmpty { null }) }) {
                Text(text = stringResource(R.string.live_mark_confirm))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(text = stringResource(R.string.action_cancel)) }
        },
        icon = { Icon(imageVector = FieldTapIcons.Flag, contentDescription = null) },
        title = { Text(text = stringResource(R.string.live_mark_dialog_title)) },
        text = {
            OutlinedTextField(
                value = note,
                onValueChange = { note = it.take(MAX_TEXT_LENGTH) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text(text = stringResource(R.string.live_mark_note)) },
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
                singleLine = true,
            )
        },
    )
}

@Composable
private fun StopDialog(onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(text = stringResource(R.string.live_stop_confirm)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(text = stringResource(R.string.action_cancel)) }
        },
        icon = { Icon(imageVector = FieldTapIcons.Stop, contentDescription = null) },
        title = { Text(text = stringResource(R.string.live_stop_dialog_title)) },
        text = { Text(text = stringResource(R.string.live_stop_dialog_text)) },
    )
}

/**
 * The pre-start sheet for a recording started somewhere other than the old Live screen — the Logs tab.
 * The same checks, the same fixes and the same "Start anyway"; only who asked is different.
 */
@Composable
internal fun PrestartReview(review: PrestartState.Review, viewModel: LiveViewModel, requestPreciseLocation: () -> Unit) {
    PrestartSheet(
        review = review,
        actions = LiveActions(
            onStart = viewModel::start,
            onStartAnyway = viewModel::startAnyway,
            onDismissPrestart = viewModel::dismissPrestart,
            onRecheck = viewModel::recheckReadiness,
            onMark = viewModel::mark,
            onStop = viewModel::stop,
            onDismissRefusal = viewModel::dismissRefusal,
            onAcknowledgeRecovered = viewModel::acknowledgeRecovered,
            onConsumeMessage = viewModel::consumeMessage,
            onOpenSessions = {},
            onOpenReadiness = {},
            onOpenDisclosure = {},
            onOpenSession = {},
            nowWallMs = viewModel::nowWallMs,
        ),
        requestPreciseLocation = requestPreciseLocation,
    )
}

@Composable
private fun PrestartSheet(review: PrestartState.Review, actions: LiveActions, requestPreciseLocation: () -> Unit) {
    val context = LocalContext.current
    val blocked = !review.canStartAnyway
    val empty = review.issues.isEmpty()
    val problems = review.issues.map { issue ->
        issueProblem(issue = issue, onFix = issueFix(issue, context, actions, requestPreciseLocation))
    }
    ReadinessSheet(
        title = stringResource(
            when {
                blocked -> R.string.prestart_title_blocked
                empty -> R.string.prestart_title_ready
                else -> R.string.prestart_title
            },
        ),
        problems = problems,
        startAnywayLabel = stringResource(if (empty) R.string.live_start else R.string.prestart_start_anyway),
        cancelLabel = stringResource(R.string.action_cancel),
        onStartAnyway = actions.onStartAnyway,
        onDismissRequest = {
            actions.onDismissPrestart()
            actions.onDismissRefusal()
        },
        message = when {
            blocked -> null
            empty -> stringResource(R.string.prestart_message_ready)
            else -> stringResource(R.string.prestart_message)
        },
        blockedMessage = stringResource(R.string.prestart_blocked_message),
        blockingTag = stringResource(R.string.prestart_tag_required),
        adviceTag = stringResource(R.string.prestart_tag_recommended),
    )
}

/** The words, icon and fix label of an issue kind. */
private data class IssueCopy(
    @StringRes val title: Int,
    @StringRes val detail: Int,
    @StringRes val fix: Int?,
    val icon: ImageVector,
)

private fun issueCopy(kind: PrestartIssueKind): IssueCopy = when (kind) {
    PrestartIssueKind.NO_CONSENT ->
        IssueCopy(R.string.issue_no_consent_title, R.string.issue_no_consent_detail, R.string.issue_no_consent_fix, FieldTapIcons.Shield)
    PrestartIssueKind.NO_PRECISE_LOCATION ->
        IssueCopy(R.string.issue_precise_location_title, R.string.issue_precise_location_detail, R.string.live_action_allow_location, FieldTapIcons.Location)
    PrestartIssueKind.LOCATION_OFF ->
        IssueCopy(R.string.issue_location_off_title, R.string.issue_location_off_detail, R.string.issue_location_off_fix, FieldTapIcons.Location)
    PrestartIssueKind.STORAGE_FULL ->
        IssueCopy(R.string.issue_storage_full_title, R.string.issue_storage_full_detail, R.string.issue_storage_full_fix, FieldTapIcons.Storage)
    PrestartIssueKind.NOTIFICATIONS_OFF ->
        IssueCopy(R.string.issue_notifications_title, R.string.issue_notifications_detail, R.string.issue_notifications_fix, FieldTapIcons.Notifications)
    PrestartIssueKind.BATTERY_OPTIMISATION ->
        IssueCopy(R.string.issue_battery_title, R.string.issue_battery_detail, R.string.issue_battery_fix, FieldTapIcons.Battery)
    PrestartIssueKind.BACKGROUND_RESTRICTED ->
        IssueCopy(R.string.issue_background_title, R.string.issue_background_detail, R.string.issue_app_settings_fix, FieldTapIcons.Battery)
    PrestartIssueKind.STANDBY_BUCKET ->
        IssueCopy(R.string.issue_standby_title, R.string.issue_standby_detail, R.string.issue_app_settings_fix, FieldTapIcons.Timer)
    PrestartIssueKind.NO_SIM ->
        IssueCopy(R.string.issue_no_sim_title, R.string.issue_no_sim_detail, null, FieldTapIcons.Sim)
    PrestartIssueKind.WIFI_ON_BATTERY ->
        IssueCopy(R.string.issue_wifi_title, R.string.issue_wifi_detail, R.string.live_action_wifi_settings, FieldTapIcons.Wifi)
    PrestartIssueKind.AGGRESSIVE_OEM ->
        IssueCopy(R.string.issue_oem_title, R.string.issue_oem_detail, R.string.issue_open_readiness_fix, FieldTapIcons.Warning)
    PrestartIssueKind.CHECK_FAILED ->
        IssueCopy(R.string.issue_check_failed_title, R.string.issue_check_failed_detail, R.string.issue_open_readiness_fix, FieldTapIcons.Info)
}

@Composable
private fun issueProblem(issue: PrestartIssue, onFix: (() -> Unit)?): ReadinessProblem {
    val copy = issueCopy(issue.kind)
    val fixLabel = copy.fix?.let { stringResource(it) }
    return ReadinessProblem(
        id = issue.kind.name,
        title = stringResource(copy.title),
        detail = stringResource(copy.detail),
        blocking = issue.blocking,
        icon = copy.icon,
        fixLabel = if (onFix != null) fixLabel else null,
        onFix = if (fixLabel != null) onFix else null,
    )
}

/** What the fix button of [issue] does: a system settings screen, an app screen, or the permission prompt. */
private fun issueFix(
    issue: PrestartIssue,
    context: Context,
    actions: LiveActions,
    requestPreciseLocation: () -> Unit,
): (() -> Unit)? = when (issue.kind) {
    PrestartIssueKind.NO_PRECISE_LOCATION -> requestPreciseLocation
    PrestartIssueKind.NO_CONSENT -> leaveSheetThen(actions, actions.onOpenDisclosure)
    PrestartIssueKind.STORAGE_FULL -> leaveSheetThen(actions, actions.onOpenSessions)
    PrestartIssueKind.AGGRESSIVE_OEM, PrestartIssueKind.CHECK_FAILED -> leaveSheetThen(actions, actions.onOpenReadiness)
    PrestartIssueKind.NO_SIM -> null
    PrestartIssueKind.LOCATION_OFF, PrestartIssueKind.NOTIFICATIONS_OFF, PrestartIssueKind.BATTERY_OPTIMISATION,
    PrestartIssueKind.BACKGROUND_RESTRICTED, PrestartIssueKind.STANDBY_BUCKET, PrestartIssueKind.WIFI_ON_BATTERY ->
        openSettings(context, PrestartPlanner.settingsTarget(issue))
}

/** Closes the sheet before leaving the screen, so it does not linger over the next one. */
private fun leaveSheetThen(actions: LiveActions, navigate: () -> Unit): () -> Unit = {
    actions.onDismissPrestart()
    actions.onDismissRefusal()
    navigate()
}

/** Opens a system settings screen; the sheet stays, and the checks run again when the screen resumes. */
private fun openSettings(context: Context, target: SettingsTarget): () -> Unit = {
    SystemSettings.open(context, target)
}

@StringRes
private fun rsrpLabelRes(rat: Rat?): Int = when (rat) {
    Rat.LTE -> R.string.live_rsrp_lte
    Rat.NR -> R.string.live_rsrp_nr
    else -> R.string.live_rsrp
}

@StringRes
private fun rsrqLabelRes(rat: Rat?): Int = if (rat == Rat.NR) R.string.live_rsrq_nr else R.string.live_rsrq

private fun sinrLabelRes(rat: Rat?): Int = if (rat == Rat.NR) R.string.live_sinr_nr else R.string.live_sinr

private fun channelRes(rat: Rat): Int = when (rat) {
    Rat.LTE -> R.string.live_earfcn
    Rat.NR -> R.string.live_nrarfcn
    else -> R.string.live_arfcn
}

@StringRes
private fun networkRes(network: ServingNetwork): Int = when (network) {
    ServingNetwork.LTE -> R.string.live_network_lte
    ServingNetwork.LTE_WITH_NR_LEG -> R.string.live_network_lte_nsa
    ServingNetwork.NR_STANDALONE -> R.string.live_network_nr_sa
    ServingNetwork.OTHER -> R.string.live_network_other
}

@StringRes
private fun cadenceReasonRes(reason: CadenceReason?): Int = when (reason) {
    null -> R.string.live_cadence_waiting
    CadenceReason.SCREEN_ON_WIFI_OFF -> R.string.live_cadence_screen_on
    CadenceReason.CHARGING_WITH_WIFI -> R.string.live_cadence_charging
    CadenceReason.SCREEN_OFF -> R.string.live_cadence_screen_off
    CadenceReason.WIFI_ON_BATTERY -> R.string.live_cadence_wifi_on_battery
}

@StringRes
private fun serviceRes(chip: ServiceChip): Int = when (chip) {
    ServiceChip.WAITING -> R.string.live_service_waiting
    ServiceChip.IN_SERVICE -> R.string.live_service_in
    ServiceChip.ROAMING -> R.string.live_service_roaming
    ServiceChip.EMERGENCY_ONLY -> R.string.live_service_emergency
    ServiceChip.NO_SERVICE -> R.string.live_service_none
    ServiceChip.RADIO_OFF -> R.string.live_service_radio_off
    ServiceChip.UNKNOWN -> R.string.live_service_unknown
}

@StringRes
private fun dataRes(chip: DataChip): Int = when (chip) {
    DataChip.WAITING -> R.string.live_data_waiting
    DataChip.CONNECTED -> R.string.live_data_connected
    DataChip.CONNECTING -> R.string.live_data_connecting
    DataChip.DISCONNECTED -> R.string.live_data_off
    DataChip.SUSPENDED -> R.string.live_data_suspended
    DataChip.UNKNOWN -> R.string.live_data_unknown
}

@StringRes
private fun refusalMessageRes(refusal: StartRefusal?): Int? = when (refusal) {
    StartRefusal.BLANK_NAME -> R.string.live_refusal_blank_name
    StartRefusal.SESSION_RUNNING -> R.string.live_refusal_running
    else -> null
}

@StringRes
private fun listenerNameRes(listener: RadioListener): Int = when (listener) {
    RadioListener.CELL_INFO_REQUEST -> R.string.live_listener_request
    RadioListener.CELL_INFO_PUSH -> R.string.live_listener_push
    RadioListener.SIGNAL_STRENGTHS -> R.string.live_listener_signal
    RadioListener.SERVICE_STATE -> R.string.live_listener_service
    RadioListener.DISPLAY_INFO -> R.string.live_listener_display
    RadioListener.DATA_CONNECTION_STATE -> R.string.live_listener_data
    RadioListener.PHYSICAL_CHANNEL_CONFIG, RadioListener.BARRING_INFO, RadioListener.REGISTRATION_FAILED -> R.string.live_listener_other
}

@Composable
private fun listenerNoteText(note: ListenerNote): String = when {
    note.listener == RadioListener.CELL_INFO_PUSH && note.outcome == ListenerOutcome.MISSING_PERMISSION ->
        stringResource(R.string.live_note_push_missing)
    note.listener == RadioListener.CELL_INFO_REQUEST && note.outcome == ListenerOutcome.MISSING_PERMISSION ->
        stringResource(R.string.live_note_request_missing)
    note.outcome == ListenerOutcome.REFUSED_BY_PLATFORM ->
        stringResource(R.string.live_note_listener_refused, stringResource(listenerNameRes(note.listener)))
    else ->
        stringResource(R.string.live_note_listener_failed, stringResource(listenerNameRes(note.listener)))
}

@Composable
private fun liveMessageText(message: LiveMessage): String = stringResource(
    when (message) {
        LiveMessage.MARKED -> R.string.live_message_marked
        LiveMessage.MARK_HELD -> R.string.live_message_mark_held
        LiveMessage.MARK_DROPPED -> R.string.live_message_mark_dropped
        LiveMessage.NOT_RECORDING -> R.string.live_message_not_recording
        LiveMessage.PAUSED -> R.string.live_message_paused
        LiveMessage.PAUSED_NO_FIX -> R.string.live_message_paused_no_fix
        LiveMessage.START_FAILED -> R.string.live_message_start_failed
        LiveMessage.STOP_FAILED -> R.string.live_message_stop_failed
        LiveMessage.STARTED_WITH_ADVICE -> R.string.live_message_started_with_advice
    },
)

@Composable
private fun gpsText(chip: GpsChip): String = when (chip) {
    GpsChip.Waiting -> stringResource(R.string.live_gps_waiting)
    is GpsChip.Fix -> {
        val accuracy = chip.accuracyM?.takeIf { it.isFinite() && it >= 0 }
        if (accuracy != null) stringResource(R.string.live_gps_fix_accuracy, accuracy.roundToInt()) else stringResource(R.string.live_gps_fix)
    }
    is GpsChip.Lost -> stringResource(R.string.live_gps_lost, Formats.ageSeconds(chip.ageMs))
}

/** The hero tile's badge when there is no serving cell. */
@Composable
private fun absenceBadge(absence: ServingAbsence?): String = stringResource(
    when (absence) {
        ServingAbsence.LocationOff -> R.string.live_absence_location_off
        ServingAbsence.RadioOff -> R.string.live_absence_radio_off
        ServingAbsence.NoService -> R.string.live_absence_no_service
        ServingAbsence.EmergencyOnly -> R.string.live_absence_emergency
        is ServingAbsence.NoLteOrNrServing -> R.string.live_no_lte_nr_badge
        ServingAbsence.WaitingForAnswer, null -> R.string.live_waiting_first_measurement
    },
)

/** The hero tile's line under the value when there is no serving cell: what stops it, or null while waiting. */
@Composable
private fun absenceDetail(absence: ServingAbsence?): String? = when (absence) {
    ServingAbsence.LocationOff -> stringResource(R.string.issue_location_off_detail)
    ServingAbsence.RadioOff -> stringResource(R.string.live_absence_radio_off_detail)
    ServingAbsence.NoService -> stringResource(R.string.live_absence_no_service_detail)
    ServingAbsence.EmergencyOnly -> stringResource(R.string.live_absence_emergency_detail)
    is ServingAbsence.NoLteOrNrServing ->
        absence.network?.let { stringResource(R.string.live_no_lte_nr_detail_on, it) } ?: stringResource(R.string.live_no_lte_nr_detail)
    ServingAbsence.WaitingForAnswer, null -> null
}

/** Why the serving cell on screen may be ageing, or that it is an emergency-only camp. */
@Composable
private fun servingProblemLine(problem: ServingAbsence): String? = when (problem) {
    ServingAbsence.LocationOff -> stringResource(R.string.live_problem_location_off)
    ServingAbsence.RadioOff -> stringResource(R.string.live_problem_radio_off)
    ServingAbsence.NoService -> stringResource(R.string.live_problem_no_service)
    ServingAbsence.EmergencyOnly -> stringResource(R.string.live_problem_emergency)
    ServingAbsence.WaitingForAnswer, is ServingAbsence.NoLteOrNrServing -> null
}

/**
 * "LTE · PCI 212 · EARFCN 66786 · band 66", then "Verizon · 311480" on a line of its own: the cell, then who runs it. The
 * explicit break keeps a separator from ending a line where the two did not fit on one ("…band n41 ·").
 */
@Composable
private fun servingSummary(cell: LiveCell): String {
    val operator = listOfNotNull(cell.operator, cell.plmn).joinToString(stringResource(R.string.value_separator))
    return listOf(cellIdentity(cell), operator).filter { it.isNotEmpty() }.joinToString("\n")
}

/** What the tests reach, as Settings has them, under the Start dialog's tests choice. */
@Composable
private fun testsTargetsText(tests: TestSettings): String {
    val ping = tests.pingTarget.trim().takeIf { it.isNotEmpty() }
    val host = TestSettingsRules.downloadHost(tests.downloadUrl)
    return when {
        ping != null && host != null -> stringResource(R.string.live_tests_targets_both, ping, host)
        ping != null -> stringResource(R.string.live_tests_targets_ping, ping)
        host != null -> stringResource(R.string.live_tests_targets_download, host)
        else -> stringResource(R.string.live_tests_targets_none)
    }
}

/**
 * The running session's state and GPS in one line under the top bar, whatever the width or font scale: "Recording · 1,234
 * samples" while it records, otherwise only what stops it ("Not recording: location off", "Waiting for a fix"), because a
 * sample count beside a reason wrapped mid-phrase. Internal for RecordingStripTest.
 */
@Composable
internal fun RecordingStatusStrip(strip: RecordingStrip, modifier: Modifier = Modifier) {
    // The running-state fill is the recording crimson family — the one place a tonal running-state fill appears
    // (clean-design §2.4, §8.2). A running session is never `error`, so recording has its own family; a problem state
    // (location off, paused, waiting, saving) keeps its own tone.
    val recording = strip.state == RecordingState.RECORDING
    val problemTone = when (strip.state) {
        RecordingState.LOCATION_OFF -> StatusTone.ERROR
        RecordingState.PAUSED_IN_ZONE, RecordingState.WAITING_FOR_LOCATION, RecordingState.SAVING -> StatusTone.INFO
        RecordingState.RECORDING -> StatusTone.NEUTRAL // unused: recording uses the crimson family and the dot below
    }
    val family = if (recording) FieldTapDesign.colors.recording else FieldTapDesign.colors.status(problemTone)
    val stateText = when (strip.state) {
        RecordingState.RECORDING -> pluralStringResource(
            R.plurals.live_strip_recording,
            strip.freshSamples.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt(),
            Formats.count(strip.freshSamples),
        )
        RecordingState.PAUSED_IN_ZONE -> stringResource(R.string.live_strip_paused)
        RecordingState.WAITING_FOR_LOCATION -> stringResource(R.string.live_strip_waiting)
        RecordingState.LOCATION_OFF -> stringResource(R.string.live_strip_location_off)
        RecordingState.SAVING -> stringResource(R.string.live_strip_saving)
    }
    val gpsText = stringResource(
        when (strip.gps) {
            StripGps.FIX -> R.string.live_strip_gps_fix
            StripGps.LOST -> R.string.live_strip_gps_lost
            StripGps.WAITING -> R.string.live_strip_gps_waiting
        },
    )
    val gutter = screenGutter()
    val stateStyle = MaterialTheme.typography.labelLarge.tabular()
    val gpsStyle = MaterialTheme.typography.labelLarge
    val measurer = rememberTextMeasurer()
    Surface(color = family.container, contentColor = family.onContainer, modifier = modifier.fillMaxWidth()) {
        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            // Where the state and the GPS word do not fit side by side (font scale 1.3 on a 360 dp phone), the word goes
            // first: its icon stays, and TalkBack reads the word as the icon's description. Only then does the state shrink.
            val fixedPx = with(LocalDensity.current) { (gutter * 2 + Sizes.IconSmall * 2 + Spacing.Sm * 3).roundToPx() }
            val stateWidth = measurer.measure(stateText, stateStyle, maxLines = 1).size.width
            val gpsWidth = measurer.measure(gpsText, gpsStyle, maxLines = 1).size.width
            val gpsWord = !constraints.hasBoundedWidth || stateWidth + gpsWidth + fixedPx <= constraints.maxWidth
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = Sizes.StatusStripMinHeight)
                    .semantics(mergeDescendants = true) {}
                    .padding(horizontal = gutter, vertical = Spacing.Xs),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Spacing.Sm),
            ) {
                // While collecting, the steady recording dot; a problem state shows its tone icon. Both are decorative:
                // the state word carries the meaning for TalkBack (the row merges its descendants).
                Box(modifier = Modifier.size(Sizes.IconSmall), contentAlignment = Alignment.Center) {
                    if (recording) {
                        RecordingDot(color = family.onContainer)
                    } else {
                        Icon(imageVector = statusIcon(problemTone), contentDescription = null, modifier = Modifier.size(Sizes.IconSmall))
                    }
                }
                Text(
                    text = stateText,
                    style = stateStyle,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Ellipsis,
                    autoSize = TextAutoSize.StepBased(minFontSize = MIN_STRIP_TEXT_SP.sp, maxFontSize = stateStyle.fontSize, stepSize = 0.5.sp),
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    imageVector = if (strip.gps == StripGps.FIX) FieldTapIcons.GpsFixed else FieldTapIcons.GpsOff,
                    contentDescription = if (gpsWord) null else gpsText,
                    modifier = Modifier.size(Sizes.IconSmall),
                )
                if (gpsWord) {
                    Text(text = gpsText, style = gpsStyle, maxLines = 1)
                }
            }
        }
    }
}

/** The smallest the strip's state shrinks to, once its GPS word has gone, before it would be cut short. */
private const val MIN_STRIP_TEXT_SP: Float = 11f

/** "LTE · PCI 212 · EARFCN 66786 · band 66". */
@Composable
private fun cellIdentity(cell: LiveCell): String {
    val parts = mutableListOf(ratName(cell.rat))
    cell.pci?.let { parts += stringResource(R.string.live_pci, it) }
    cell.arfcn?.let { parts += stringResource(channelRes(cell.rat), it) }
    cell.band?.let { parts += stringResource(if (cell.rat == Rat.NR) R.string.live_band_nr else R.string.live_band_lte, it) }
    return parts.joinToString(stringResource(R.string.value_separator))
}

/** "PCI 212 · EARFCN 1300", or the RAT when neither is known. */
@Composable
private fun neighbourTitle(cell: LiveCell): String {
    val parts = mutableListOf<String>()
    cell.pci?.let { parts += stringResource(R.string.live_pci, it) }
    cell.arfcn?.let { parts += stringResource(channelRes(cell.rat), it) }
    return if (parts.isEmpty()) ratName(cell.rat) else parts.joinToString(stringResource(R.string.value_separator))
}

/** "LTE · band 3 · reuses PCI mod 3, 6 · 5 dB below serving". */
@Composable
private fun neighbourSupporting(row: NeighbourRow): String {
    val cell = row.cell
    val parts = mutableListOf(ratName(cell.rat))
    cell.band?.let { parts += stringResource(if (cell.rat == Rat.NR) R.string.live_band_nr else R.string.live_band_lte, it) }
    if (row.pciReuse.isNotEmpty()) {
        val moduli = row.pciReuse.sorted().joinToString(stringResource(R.string.live_pci_reuse_separator))
        parts += stringResource(R.string.live_pci_reuse, moduli)
        // The margin earns its place only beside a reuse: it is what says whether the reuse matters.
        row.marginDb?.let { margin ->
            parts += when {
                margin > 0 -> stringResource(R.string.live_margin_below, margin)
                margin < 0 -> stringResource(R.string.live_margin_above, -margin)
                else -> stringResource(R.string.live_margin_level)
            }
        }
    }
    return parts.joinToString(stringResource(R.string.value_separator))
}

/** "Verizon · 311480", either part alone, or a dash. */
@Composable
private fun operatorText(cell: LiveCell): String {
    val parts = listOfNotNull(cell.operator, cell.plmn)
    return if (parts.isEmpty()) UNKNOWN_VALUE else parts.joinToString(stringResource(R.string.value_separator))
}

@FieldTapPreviews
@Composable
private fun LiveContentRecordingPreview() {
    val now = 1_000_000L
    val serving = LiveCell(Rat.LTE, 212, 66_786, 66, -92, -11, 14, "311480", "Verizon", 1, now - 1_200)
    val leg = LiveCell(Rat.NR, 393, 650_000, 77, -97, -12, 9, null, null, 2, now - 1_200)
    val rsrp = (0 until 120).map { ChartPoint(now - 240_000 + it * 2_000L, -95 + (it * 7) % 11) }
    FieldTapTheme {
        LiveContent(
            state = LiveUiState(
                live = LiveState(
                    serving = serving,
                    nsaLeg = leg,
                    servingAgeMs = 1_200,
                    badge = AgeBadge.FRESH,
                    neighbours = listOf(
                        LiveCell(Rat.LTE, 101, 66_786, 66, -101, -14, null, null, null, 0, now - 1_200),
                        LiveCell(Rat.GSM, null, 128, null, null, null, null, null, null, 0, now - 1_200),
                    ),
                    rsrpSeries = rsrp,
                    sinrSeries = rsrp.map { ChartPoint(it.elapsedMs, it.value + 108) },
                    shortInterval = true,
                    recentFreshIntervalMs = 2_000,
                    nowElapsedMs = now,
                ),
                status = SessionStatus.Recording(
                    RecorderSnapshot(
                        dirName = "20260910-143000_Session-14-30",
                        startedUtcMs = 1_789_050_600_000L,
                        elapsedMs = 754_000,
                        servingRat = ServingRat.LTE,
                        servingRsrpDbm = -92,
                        newestSampleAgeMs = 1_200,
                        paused = false,
                        freshSamples = 377,
                        repeatsDropped = 377,
                        eventsWritten = 4,
                        trackRows = 754,
                        hasRecentFix = true,
                        stopping = false,
                    ),
                ),
                testsDefaultOn = false,
                refusal = null,
                recovered = emptyList(),
            ),
            actions = PreviewActions,
        )
    }
}

@FieldTapPreviews
@Composable
private fun LiveContentWaitingPreview() {
    FieldTapTheme {
        LiveContent(
            state = LiveUiState(
                live = LiveState(),
                status = SessionStatus.Idle,
                testsDefaultOn = false,
                refusal = null,
                recovered = listOf(SessionOutcome("20260909-180200_Car-park", 1_789_000_000_000L, 1_789_000_370_000L, "low_memory", true, 180)),
            ),
            actions = PreviewActions,
        )
    }
}

private val PreviewActions = LiveActions(
    onStart = {},
    onStartAnyway = {},
    onDismissPrestart = {},
    onRecheck = {},
    onMark = {},
    onStop = {},
    onDismissRefusal = {},
    onAcknowledgeRecovered = {},
    onConsumeMessage = {},
    onOpenSessions = {},
    onOpenReadiness = {},
    onOpenDisclosure = {},
    onOpenSession = {},
    nowWallMs = { 1_789_050_600_000L },
)
