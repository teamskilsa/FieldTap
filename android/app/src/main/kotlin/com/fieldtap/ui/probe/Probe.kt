package com.fieldtap.ui.probe

import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.fieldtap.R
import com.fieldtap.app.AppGraph
import com.fieldtap.app.FieldTapApplication
import com.fieldtap.core.capability.CapabilityMessages
import com.fieldtap.core.capability.CapabilitySnapshot
import com.fieldtap.core.capability.CaptureAnswer
import com.fieldtap.core.capability.CellularReadout
import com.fieldtap.core.capability.DiagDevice
import com.fieldtap.core.capability.KernelConfigProbe
import com.fieldtap.core.capability.Layer3OnDevice
import com.fieldtap.core.capability.OnDeviceLayer3
import com.fieldtap.core.capability.OnDeviceLayer3Verdict
import com.fieldtap.core.capability.RootConfidence
import com.fieldtap.core.capability.RootDetector
import com.fieldtap.core.capability.RootProbeResult
import com.fieldtap.core.capability.RootSignals
import com.fieldtap.core.capability.SelinuxMode
import com.fieldtap.core.capability.UsbDebugState
import com.fieldtap.core.input.ListenerOutcome
import com.fieldtap.core.input.RadioListener
import com.fieldtap.core.probe.CellInfoProbe
import com.fieldtap.core.probe.ProbeNotes
import com.fieldtap.core.probe.ProbeReport
import com.fieldtap.core.probe.ServiceStateProbe
import com.fieldtap.format.HandsetMeta
import com.fieldtap.platform.Permissions
import com.fieldtap.ui.common.FileSharer
import com.fieldtap.ui.components.ChecklistRow
import com.fieldtap.ui.components.Eyebrow
import com.fieldtap.ui.components.FieldTapPreviews
import com.fieldtap.ui.components.KeyValueRow
import com.fieldtap.ui.components.PreviewSurface
import com.fieldtap.ui.components.SectionCard
import com.fieldtap.ui.components.SectionDivider
import com.fieldtap.ui.components.StatusBanner
import com.fieldtap.ui.components.StatusChip
import com.fieldtap.ui.components.statusIcon
import com.fieldtap.ui.setup.ButtonProgress
import com.fieldtap.ui.setup.SetupFormats
import com.fieldtap.ui.setup.SetupParagraph
import com.fieldtap.ui.setup.SetupScreenScaffold
import com.fieldtap.ui.setup.setupContentWidth
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.FieldTapIcons
import com.fieldtap.ui.theme.ShapeRoles
import com.fieldtap.ui.theme.Sizes
import com.fieldtap.ui.theme.Spacing
import com.fieldtap.ui.theme.StatusTone
import com.fieldtap.ui.theme.tabular
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * What the Capability screen shows.
 *
 * @param running the 30 s telephony probe is listening.
 * @param progress the telephony runner's progress line, for example "Listening: 12 s of 30 s, 12 answers".
 * @param report the finished telephony report, or null before the first run finished (or while a new run listens).
 * @param exported the JSON file of [report] once exported.
 * @param capability the root/diag/USB/verdict panel's state, read passively when the screen opens.
 */
data class ProbeUiState(
    val running: Boolean,
    val progress: String?,
    val report: ProbeReport?,
    val exported: File?,
    val capability: CapabilityUiState = CapabilityUiState(),
)

/**
 * The capability panel's state: the passive snapshot (verdict, root signals, USB, cell access), the result
 * of an explicit "Check with root", and the capability JSON export.
 *
 * @param snapshot the passive reading, or null before it has loaded.
 * @param loadFailed the passive read failed; [snapshot] is the last good one, if any.
 * @param rootProbe the last "Check with root" result, or null before one ran.
 * @param checkingRoot a root check is running.
 * @param exported the exported `fieldtap-capability/2` file, once written.
 * @param exporting the capability export is being written.
 */
data class CapabilityUiState(
    val snapshot: CapabilitySnapshot? = null,
    val loadFailed: Boolean = false,
    val rootProbe: RootProbeResult? = null,
    val checkingRoot: Boolean = false,
    val exported: File? = null,
    val exporting: Boolean = false,
)

/** Why the Capability screen shows a banner. */
enum class ProbeProblem {
    /** The telephony run ended with an error; no report. */
    RUN_FAILED,

    /** The telephony run was cancelled because the screen left the foreground; no report. */
    INTERRUPTED,

    /** The telephony report could not be written for sharing. */
    EXPORT_FAILED,

    /** The capability report could not be written for sharing. */
    CAPABILITY_EXPORT_FAILED,
}

/**
 * The Capability screen's state: the passive capability snapshot (loaded when the screen binds its source),
 * the explicit root check, the 30 s telephony probe, and the two JSON exports.
 *
 * The passive read and the root check reach the phone through a [CapabilitySource] the screen binds once
 * ([bindCapability]); tests bind a fake. The telephony probe stays on `AppGraph.probe`.
 *
 * - [refreshCapability] runs `CapabilitySource.passive` (no su); the screen calls it on open and on resume, so
 *   USB-debugging and permission rows stay fresh after a trip to Android's settings. A failure sets
 *   [CapabilityUiState.loadFailed] and keeps the last snapshot.
 * - [checkWithRoot] runs the read-only root check; a second tap while one is in flight is ignored, and leaving
 *   the screen cancels it (the su process is destroyed in the runner's `finally`).
 * - [exportCapability] writes `fieldtap-capability/2` and asks the screen to share it; [export] does the same
 *   for the telephony `fieldtap-probe/1`.
 * - [run]/[stop]/[interrupt] drive the telephony probe exactly as before; a cancelled run's updates are ignored.
 *
 * Owner: workstream `ui-setup`.
 */
class ProbeViewModel(private val graph: AppGraph) : ViewModel() {
    private val mutableState = MutableStateFlow(
        ProbeUiState(running = false, progress = null, report = null, exported = null, capability = CapabilityUiState()),
    )
    private val mutableProblem = MutableStateFlow<ProbeProblem?>(null)
    private val mutableExporting = MutableStateFlow(false)
    private val shares = Channel<File>(Channel.BUFFERED)
    private val capabilityShares = Channel<File>(Channel.BUFFERED)
    private var runJob: Job? = null
    private var exportJob: Job? = null
    private var loadJob: Job? = null
    private var rootJob: Job? = null
    private var capabilityExportJob: Job? = null
    private var runId = 0L
    private var capabilitySource: CapabilitySource? = null

    val state: StateFlow<ProbeUiState> = mutableState.asStateFlow()

    /** Why a banner shows, or null. */
    val problem: StateFlow<ProbeProblem?> = mutableProblem.asStateFlow()

    /** The telephony probe report is being exported. */
    val exporting: StateFlow<Boolean> = mutableExporting.asStateFlow()

    /** Each exported telephony report file, once, for the screen to share. */
    val shareRequests: Flow<File> = shares.receiveAsFlow()

    /** Each exported capability report file, once, for the screen to share. */
    val capabilityShareRequests: Flow<File> = capabilityShares.receiveAsFlow()

    /** Binds the capability source once (the screen binds the platform one, tests a fake), then reads it passively. */
    internal fun bindCapability(source: CapabilitySource) {
        if (capabilitySource != null) return
        capabilitySource = source
        refreshCapability()
    }

    /** Reads the passive capability snapshot (no su call). Ignores a call while a read is in flight. */
    fun refreshCapability() {
        val source = capabilitySource ?: return
        if (loadJob?.isActive == true) return
        loadJob = viewModelScope.launch {
            try {
                val snapshot = source.passive()
                mutableState.update { it.copy(capability = it.capability.copy(snapshot = snapshot, loadFailed = false)) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: RuntimeException) {
                mutableState.update { it.copy(capability = it.capability.copy(loadFailed = true)) }
            }
        }
    }

    /** Runs the read-only root check on an explicit tap; a second tap while one runs is ignored. */
    fun checkWithRoot() {
        val source = capabilitySource ?: return
        if (rootJob?.isActive == true) return
        mutableState.update { it.copy(capability = it.capability.copy(checkingRoot = true)) }
        rootJob = viewModelScope.launch {
            try {
                val result = source.checkWithRoot()
                mutableState.update { it.copy(capability = it.capability.copy(rootProbe = result, checkingRoot = false)) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: RuntimeException) {
                mutableState.update { it.copy(capability = it.capability.copy(checkingRoot = false)) }
            }
        }
    }

    /** Builds and writes the `fieldtap-capability/2` report, then asks the screen to share it. */
    fun exportCapability() {
        val source = capabilitySource ?: return
        val capability = mutableState.value.capability
        val snapshot = capability.snapshot ?: return
        if (capability.exporting || capabilityExportJob?.isActive == true) return
        if (mutableProblem.value == ProbeProblem.CAPABILITY_EXPORT_FAILED) mutableProblem.value = null
        mutableState.update { it.copy(capability = it.capability.copy(exporting = true)) }
        capabilityExportJob = viewModelScope.launch {
            try {
                val file = source.exportCapability(snapshot, capability.rootProbe)
                mutableState.update { it.copy(capability = it.capability.copy(exported = file)) }
                capabilityShares.send(file)
            } catch (e: CancellationException) {
                throw e
            } catch (e: IOException) {
                mutableProblem.value = ProbeProblem.CAPABILITY_EXPORT_FAILED
            } catch (e: RuntimeException) {
                mutableProblem.value = ProbeProblem.CAPABILITY_EXPORT_FAILED
            } finally {
                mutableState.update { it.copy(capability = it.capability.copy(exporting = false)) }
            }
        }
    }

    /** Starts a 30 s telephony run unless one is listening. The screen must stay on and visible while it runs. */
    fun run() {
        if (runJob?.isActive == true) return
        exportJob?.cancel()
        val id = ++runId
        mutableProblem.value = null
        mutableExporting.value = false
        mutableState.update { it.copy(running = true, progress = null, report = null, exported = null) }
        runJob = viewModelScope.launch {
            try {
                val report = graph.probe.run(DURATION_MS) { text ->
                    if (id == runId) mutableState.update { it.copy(progress = text) }
                }
                if (id == runId) mutableState.update { it.copy(running = false, progress = null, report = report) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: IOException) {
                if (id == runId) failRun()
            } catch (e: RuntimeException) {
                if (id == runId) failRun()
            }
        }
    }

    /** Cancels a telephony run at the user's request. */
    fun stop() {
        cancelRun(problem = null)
    }

    /**
     * Cancels a telephony run and a root check because the screen left the foreground. Says the run was
     * interrupted; the silent root-check cancel destroys its su process. Does nothing when neither is running.
     */
    fun interrupt() {
        if (rootJob?.isActive == true) {
            rootJob?.cancel()
            mutableState.update { it.copy(capability = it.capability.copy(checkingRoot = false)) }
        }
        cancelRun(problem = ProbeProblem.INTERRUPTED)
    }

    /** Writes the telephony report as JSON and asks the screen to share it. */
    fun export() {
        val current = mutableState.value
        val report = current.report ?: return
        if (current.running || exportJob?.isActive == true) return
        if (mutableProblem.value == ProbeProblem.EXPORT_FAILED) mutableProblem.value = null
        mutableExporting.value = true
        exportJob = viewModelScope.launch {
            try {
                val file = graph.probe.export(report)
                mutableState.update { state -> if (state.report === report) state.copy(exported = file) else state }
                shares.send(file)
            } catch (e: CancellationException) {
                throw e
            } catch (e: IOException) {
                mutableProblem.value = ProbeProblem.EXPORT_FAILED
            } catch (e: RuntimeException) {
                mutableProblem.value = ProbeProblem.EXPORT_FAILED
            } finally {
                mutableExporting.value = false
            }
        }
    }

    private fun cancelRun(problem: ProbeProblem?) {
        val job = runJob ?: return
        if (!job.isActive) return
        runId++
        job.cancel()
        mutableProblem.value = problem
        mutableState.update { it.copy(running = false, progress = null) }
    }

    private fun failRun() {
        mutableProblem.value = ProbeProblem.RUN_FAILED
        mutableState.update { it.copy(running = false, progress = null) }
    }

    companion object {
        /** How long a telephony run listens. */
        const val DURATION_MS: Long = 30_000
    }
}

/**
 * Capability: the app's signal-analyser self-test panel. The tiered "What 5gto6G FieldTap can capture on this
 * phone" verdict, a Root & diagnostics card with the explicit read-only "Check with root" button, USB-debugging
 * rows, the cell-access readout, then the 30 s telephony probe's findings and detail cards, and JSON export of
 * both `fieldtap-capability/2` and `fieldtap-probe/1` through the system share sheet.
 *
 * The screen never gains root, never decodes signalling, and never claims to. The passive read is safe on open;
 * the root check runs only on an explicit tap. While a telephony run listens or a root check runs the screen is
 * kept on (`View.keepScreenOn`, no wake lock). Leaving the screen cancels both, except across a configuration
 * change such as a rotation.
 *
 * Owner: workstream `ui-setup`.
 */
@Composable
fun ProbeScreen(
    viewModel: ProbeViewModel,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenSignalling: (() -> Unit)? = null,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val problem by viewModel.problem.collectAsStateWithLifecycle()
    val exporting by viewModel.exporting.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val activity = LocalActivity.current
    val view = LocalView.current
    val snackbarHostState = remember { SnackbarHostState() }
    val probeSubject = stringResource(R.string.probe_share_subject)
    val capabilitySubject = stringResource(R.string.probe_capability_share_subject)
    val shareFailedText = stringResource(R.string.setup_share_failed)
    val currentContext by rememberUpdatedState(context)

    LaunchedEffect(viewModel, context) {
        val application = context.applicationContext as? FieldTapApplication
        if (application != null) {
            val graph = application.graph
            viewModel.bindCapability(
                AndroidCapabilitySource(context.applicationContext, graph.appInfo, graph.clock, graph.capability),
            )
        }
    }
    LifecycleResumeEffect(viewModel) {
        viewModel.refreshCapability()
        onPauseOrDispose { }
    }
    if (state.running || state.capability.checkingRoot) {
        DisposableEffect(view) {
            val previous = view.keepScreenOn
            view.keepScreenOn = true
            onDispose { view.keepScreenOn = previous }
        }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) {
        if (activity?.isChangingConfigurations != true) viewModel.interrupt()
    }
    LaunchedEffect(viewModel) {
        viewModel.shareRequests.collect { file -> shareOrToast(currentContext, file, probeSubject, snackbarHostState, shareFailedText) }
    }
    LaunchedEffect(viewModel) {
        viewModel.capabilityShareRequests.collect { file -> shareOrToast(currentContext, file, capabilitySubject, snackbarHostState, shareFailedText) }
    }
    ProbeContent(
        state = state,
        problem = problem,
        exporting = exporting,
        onBack = onBack,
        onRun = viewModel::run,
        onStop = viewModel::stop,
        onExport = viewModel::export,
        onCheckRoot = viewModel::checkWithRoot,
        onExportCapability = viewModel::exportCapability,
        onRetryCapability = viewModel::refreshCapability,
        onOpenSignalling = onOpenSignalling,
        modifier = modifier,
        snackbarHostState = snackbarHostState,
    )
}

private const val JSON_MIME_TYPE = "application/json"

private suspend fun shareOrToast(
    context: android.content.Context,
    file: File,
    subject: String,
    snackbarHostState: SnackbarHostState,
    shareFailedText: String,
) {
    val shared = try {
        FileSharer.share(context, file, JSON_MIME_TYPE, subject, null)
        true
    } catch (e: RuntimeException) {
        // No share target, or a file the FileProvider does not serve: say so rather than crash.
        false
    }
    if (!shared) snackbarHostState.showSnackbar(shareFailedText)
}

/** The Capability screen without its view model, for previews. */
@Composable
internal fun ProbeContent(
    state: ProbeUiState,
    problem: ProbeProblem?,
    exporting: Boolean,
    onOpenSignalling: (() -> Unit)? = null,
    onBack: (() -> Unit)? = null,
    onRun: () -> Unit,
    onStop: () -> Unit,
    onExport: () -> Unit,
    onCheckRoot: () -> Unit,
    onExportCapability: () -> Unit,
    onRetryCapability: () -> Unit,
    modifier: Modifier = Modifier,
    snackbarHostState: SnackbarHostState? = null,
) {
    val titleText = stringResource(R.string.probe_title)
    val report = state.report
    val capability = state.capability
    SetupScreenScaffold(title = titleText, modifier = modifier, onBack = onBack, snackbarHostState = snackbarHostState) {
        if (problem != null) {
            item(key = "problem") {
                ProblemBanner(problem = problem, onRun = onRun, onExport = onExport, onExportCapability = onExportCapability, modifier = Modifier.setupContentWidth())
            }
        }
        item(key = "verdict") {
            VerdictBlock(
                capability = capability,
                running = state.running,
                progress = state.progress,
                hasReport = report != null,
                onRun = onRun,
                onStop = onStop,
                onRetry = onRetryCapability,
                modifier = Modifier.setupContentWidth(),
            )
        }
        if (capability.snapshot != null) {
            val snapshot = capability.snapshot
            item(key = "tiers") { TieredCard(snapshot = snapshot, rootProbe = capability.rootProbe, modifier = Modifier.setupContentWidth()) }
            item(key = "root") {
                RootDiagnosticsCard(
                    root = snapshot.root,
                    usb = snapshot.usb,
                    rootProbe = capability.rootProbe,
                    checkingRoot = capability.checkingRoot,
                    onCheckRoot = onCheckRoot,
                    onOpenSignalling = onOpenSignalling,
                    modifier = Modifier.setupContentWidth(),
                )
            }
            item(key = "cell-access") { CellAccessCard(cellular = snapshot.cellular, modifier = Modifier.setupContentWidth()) }
        }
        if (report != null) {
            item(key = "apis") {
                Eyebrow(text = stringResource(R.string.probe_intro_title), heading = true, modifier = Modifier.setupContentWidth())
            }
            item(key = "summary") { SummaryCard(report = report, modifier = Modifier.setupContentWidth()) }
            item(key = "findings") { FindingsCard(notes = report.notes, modifier = Modifier.setupContentWidth()) }
            item(key = "cell-info") { CellInfoCard(probe = report.cellInfo, modifier = Modifier.setupContentWidth()) }
            item(key = "service") {
                ServiceCard(probe = report.serviceState, overrides = report.displayOverridesSeen, modifier = Modifier.setupContentWidth())
            }
            item(key = "listeners") { ListenersCard(listeners = report.listeners, modifier = Modifier.setupContentWidth()) }
            item(key = "permissions") { PermissionsCard(permissions = report.permissions, modifier = Modifier.setupContentWidth()) }
        }
        item(key = "exports") {
            ExportsCard(
                capability = capability,
                report = report,
                probeExported = state.exported,
                exporting = exporting,
                onExport = onExport,
                onExportCapability = onExportCapability,
                modifier = Modifier.setupContentWidth(),
            )
        }
    }
}

@Composable
private fun ProblemBanner(problem: ProbeProblem, onRun: () -> Unit, onExport: () -> Unit, onExportCapability: () -> Unit, modifier: Modifier) {
    when (problem) {
        ProbeProblem.RUN_FAILED -> StatusBanner(
            message = stringResource(R.string.probe_failed),
            tone = StatusTone.ERROR,
            actionLabel = stringResource(R.string.setup_try_again),
            onAction = onRun,
            modifier = modifier,
        )
        ProbeProblem.INTERRUPTED -> StatusBanner(
            message = stringResource(R.string.probe_interrupted),
            tone = StatusTone.INFO,
            actionLabel = stringResource(R.string.probe_run_again),
            onAction = onRun,
            modifier = modifier,
        )
        ProbeProblem.EXPORT_FAILED -> StatusBanner(
            message = stringResource(R.string.probe_export_failed),
            tone = StatusTone.ERROR,
            actionLabel = stringResource(R.string.setup_try_again),
            onAction = onExport,
            modifier = modifier,
        )
        ProbeProblem.CAPABILITY_EXPORT_FAILED -> StatusBanner(
            message = stringResource(R.string.probe_export_failed),
            tone = StatusTone.ERROR,
            actionLabel = stringResource(R.string.setup_try_again),
            onAction = onExportCapability,
            modifier = modifier,
        )
    }
}

/**
 * The open verdict block (on the ground, no card): the eyebrow, the SUCCESS/WARNING verdict chip, the honest
 * plain sentence (from `:core`), and the primary "Run capability probe" control (or its progress, or "Run again").
 */
@Composable
private fun VerdictBlock(
    capability: CapabilityUiState,
    running: Boolean,
    progress: String?,
    hasReport: Boolean,
    onRun: () -> Unit,
    onStop: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier,
) {
    val snapshot = capability.snapshot
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(Spacing.Md)) {
        Eyebrow(text = stringResource(R.string.probe_capability_verdict_eyebrow), heading = true)
        when {
            snapshot != null -> {
                val verdict = ProbePresentation.verdict(snapshot, capability.rootProbe)
                val canMeasure = ProbePresentation.canMeasureNow(snapshot.cellular)
                StatusChip(
                    text = stringResource(if (canMeasure) R.string.probe_capability_can_measure else R.string.probe_capability_needs_location),
                    tone = if (canMeasure) StatusTone.SUCCESS else StatusTone.WARNING,
                )
                Text(
                    text = ProbePresentation.tier1Detail(verdict),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    // A wide window (landscape, tablet) caps prose at a readable measure rather than one long line.
                    modifier = Modifier.widthIn(max = Sizes.MaxTextWidth),
                )
            }
            capability.loadFailed -> {
                StatusBanner(
                    message = stringResource(R.string.probe_capability_failed),
                    tone = StatusTone.WARNING,
                    actionLabel = stringResource(R.string.setup_try_again),
                    onAction = onRetry,
                )
            }
            else -> SetupParagraph(text = stringResource(R.string.probe_capability_gathering))
        }
        RunControls(running = running, progress = progress, hasReport = hasReport, onRun = onRun, onStop = onStop)
    }
}

@Composable
private fun RunControls(running: Boolean, progress: String?, hasReport: Boolean, onRun: () -> Unit, onStop: () -> Unit) {
    // A wide window (landscape, tablet) caps prose and the primary button at a readable measure so neither
    // stretches the full content width; on a phone the cap is wider than the content, so nothing changes.
    val proseWidth = Modifier.widthIn(max = Sizes.MaxTextWidth)
    when {
        running -> {
            LinearProgressIndicator(modifier = proseWidth.fillMaxWidth())
            Text(
                text = progress ?: stringResource(R.string.probe_starting),
                style = MaterialTheme.typography.bodyLarge.tabular(),
                color = MaterialTheme.colorScheme.onSurface,
            )
            SetupParagraph(text = stringResource(R.string.probe_keep_open), modifier = proseWidth)
            OutlinedButton(
                onClick = onStop,
                shape = ShapeRoles.Control,
                modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
            ) {
                Text(text = stringResource(R.string.probe_stop))
            }
        }
        hasReport -> {
            OutlinedButton(
                onClick = onRun,
                shape = ShapeRoles.Control,
                modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
            ) {
                Text(text = stringResource(R.string.probe_run_again))
            }
        }
        else -> {
            SetupParagraph(text = stringResource(R.string.probe_intro), modifier = proseWidth)
            SetupParagraph(text = stringResource(R.string.probe_keep_open), modifier = proseWidth)
            Button(
                onClick = onRun,
                shape = ShapeRoles.Control,
                modifier = proseWidth
                    .fillMaxWidth()
                    .heightIn(min = Sizes.PrimaryButtonHeight),
            ) {
                Text(text = stringResource(R.string.probe_run))
            }
        }
    }
}

/** The tiered "What this phone can capture" card: three rows, honest sentences from `:core`, grey where neutral. */
@Composable
private fun TieredCard(snapshot: CapabilitySnapshot, rootProbe: RootProbeResult?, modifier: Modifier) {
    val verdict = ProbePresentation.verdict(snapshot, rootProbe)
    SectionCard(title = stringResource(R.string.probe_tiers_title), icon = FieldTapIcons.SignalBars, modifier = modifier) {
        ChecklistRow(
            title = stringResource(R.string.probe_tier_public_api),
            tone = ProbePresentation.captureAnswerTone(verdict.publicApiMeasurements),
            statusText = captureAnswerText(verdict.publicApiMeasurements),
            // A short line, distinct from the hero lede above (which shows tier1Detail), so the two do not repeat verbatim.
            detail = CapabilityMessages.tier1Short(),
            icon = FieldTapIcons.SignalBars,
        )
        SectionDivider()
        ChecklistRow(
            title = stringResource(R.string.probe_tier_push_updates),
            tone = ProbePresentation.captureAnswerTone(verdict.pushCellUpdates),
            statusText = captureAnswerText(verdict.pushCellUpdates),
            detail = ProbePresentation.tier2Detail(verdict),
            icon = FieldTapIcons.Phone,
        )
        SectionDivider()
        ChecklistRow(
            title = stringResource(R.string.probe_tier_layer3),
            tone = ProbePresentation.layer3Tone(verdict.layer3Signalling),
            statusText = layer3Text(verdict.layer3Signalling),
            detail = ProbePresentation.layer3Detail(verdict),
            icon = FieldTapIcons.Storage,
        )
    }
}

/**
 * Root & diagnostics: the passive confidence with the always-present root-hiding caveat, the explicit read-only
 * "Check with root" button (which states its consequence), then the **Deep diagnostics** sub-section it fills in
 * (kernel, SELinux, diag node, kernel diag config, modem interfaces, capture tooling, radio-log readability, USB
 * debugging) with the single honest on-device layer-3 sub-verdict, and finally the wider USB-debugging detail
 * with the line on why it matters for the laptop-over-USB path.
 *
 * Honesty and privacy stay the product: the deep readout shows only capability facts (from the `:core`
 * [com.fieldtap.core.capability.DeepDiagnostics] model, which has no field for a log line or diag byte), the
 * sub-verdict copy comes from `:core`, and layer-3 being not viable stays neutral grey — a normal fact, never red.
 */
@Composable
private fun RootDiagnosticsCard(
    root: RootSignals,
    usb: UsbDebugState,
    rootProbe: RootProbeResult?,
    checkingRoot: Boolean,
    onCheckRoot: () -> Unit,
    onOpenSignalling: (() -> Unit)?,
    modifier: Modifier,
) {
    val labels = deepDiagnosticsLabels()
    SectionCard(title = stringResource(R.string.probe_root_title), icon = FieldTapIcons.Shield, modifier = modifier) {
        ChecklistRow(
            title = rootConfidenceText(root.confidence),
            tone = ProbePresentation.rootConfidenceTone(root.confidence),
            statusText = null,
            detail = root.caveat,
            icon = FieldTapIcons.Shield,
        )
        OutlinedButton(
            onClick = onCheckRoot,
            enabled = !checkingRoot,
            shape = ShapeRoles.Control,
            modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
        ) {
            if (checkingRoot) {
                ButtonProgress()
                Spacer(modifier = Modifier.width(ButtonDefaults.IconSpacing))
            }
            Text(text = stringResource(if (checkingRoot) R.string.probe_checking_root else R.string.probe_check_root))
        }
        SetupParagraph(text = stringResource(R.string.probe_check_root_consequence))
        // Signalling capture lives behind the root card because that is what it needs. It is offered
        // whatever the confidence says: the verdict is a guess from what is readable without asking,
        // and the only certain answer is what the superuser app says when the capture asks for itself.
        if (onOpenSignalling != null) {
            SectionDivider()
            SetupParagraph(text = stringResource(R.string.probe_signalling_blurb))
            OutlinedButton(
                onClick = onOpenSignalling,
                shape = ShapeRoles.Control,
                modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
            ) {
                Text(text = stringResource(R.string.probe_open_signalling))
            }
        }
        SectionDivider()
        DeepDiagnosticsSection(root = root, usb = usb, rootProbe = rootProbe, labels = labels)
        SectionDivider()
        SetupParagraph(text = CapabilityMessages.whyUsbMatters())
        KeyValueRow(key = stringResource(R.string.probe_usb_wireless), value = onOffText(usb.wirelessDebugEnabled), tabular = false)
        KeyValueRow(key = stringResource(R.string.probe_usb_dev_options), value = onOffText(usb.developerOptionsEnabled), tabular = false)
    }
}

/**
 * The Deep diagnostics sub-section (deep-root-spec §5): after "Check with root" folds a deep result, the nine
 * fact rows, the SELinux consequence sentence, and the honest on-device layer-3 sub-verdict. When su was
 * absent/denied/timed-out the deep block is null, so the `/1` facts and the passive rows still inform; before any
 * run, a one-line placeholder and the passive facts that need no su (root manager, USB debugging).
 *
 * The rows are mapped by the pure [ProbePresentation.deepRows]; the screen adds only the structural labels. The
 * value tones are carried in the model (and unit-tested) but not painted on the values here: the accent stays off
 * data rows (Momentum keeps the indigo accent for the primary action, selection and focus only), and the only
 * interpreted mark is the sub-verdict's, which is neutral grey unless viable.
 */
@Composable
private fun DeepDiagnosticsSection(
    root: RootSignals,
    usb: UsbDebugState,
    rootProbe: RootProbeResult?,
    labels: ProbePresentation.DeepDiagnosticsLabels,
) {
    Eyebrow(text = stringResource(R.string.probe_deep_title), heading = true)
    val deep = rootProbe?.deep
    when {
        rootProbe != null && deep != null -> {
            SetupParagraph(text = rootProbe.message)
            DeepRows(rows = ProbePresentation.deepRows(deep, root.rootManagerVersions, usb, labels))
            // The SELinux consequence is one plain :core sentence; it explains the "Enforcing" row's meaning.
            SetupParagraph(text = deep.selinux.consequence)
            Layer3SubVerdict(verdict = OnDeviceLayer3.verdict(rootProbe, usb), usb = usb)
        }
        rootProbe != null -> {
            SetupParagraph(text = rootProbe.message)
            KeyValueRow(key = stringResource(R.string.probe_root_selinux), value = selinuxText(rootProbe.selinux), tabular = false)
            KeyValueRow(key = stringResource(R.string.probe_root_diag_device), value = diagDeviceText(rootProbe.diagDevice), tabular = false)
            KeyValueRow(key = stringResource(R.string.probe_root_kernel_diag), value = kernelDiagText(rootProbe.kernelDiag), tabular = false)
            DeepRows(rows = ProbePresentation.deepPassiveRows(root.rootManagerVersions, usb, labels))
            Layer3SubVerdict(verdict = OnDeviceLayer3.verdict(rootProbe, usb), usb = usb)
        }
        else -> {
            SetupParagraph(text = stringResource(R.string.probe_deep_placeholder))
            DeepRows(rows = ProbePresentation.deepPassiveRows(root.rootManagerVersions, usb, labels))
            Layer3SubVerdict(verdict = OnDeviceLayer3.verdict(root, usb), usb = usb)
        }
    }
}

/** Renders each pure [ProbePresentation.DeepRow] as a labelled value; facts stay calm (no accent on a value). */
@Composable
private fun DeepRows(rows: List<ProbePresentation.DeepRow>) {
    rows.forEach { row ->
        KeyValueRow(key = row.label, value = row.value, tabular = false)
    }
}

/**
 * The single honest on-device layer-3 sub-verdict as its own emphasised [ChecklistRow]: a neutral or success
 * mark (never red — "not viable" is a normal fact), the "Viable / Not viable / Unknown" status word, and the
 * `:core` detail sentence (the reason plus, when not viable, the laptop-over-USB path and the USB-debugging line).
 */
@Composable
private fun Layer3SubVerdict(verdict: OnDeviceLayer3Verdict, usb: UsbDebugState) {
    ChecklistRow(
        title = stringResource(R.string.probe_deep_verdict_title),
        tone = ProbePresentation.layer3SubVerdictTone(verdict.outcome),
        statusText = layer3VerdictStatusText(verdict.outcome),
        detail = ProbePresentation.layer3SubVerdictDetail(verdict, usb),
        icon = FieldTapIcons.Storage,
    )
}

/** The Deep diagnostics structural labels and value words, resolved from resources for the pure mapping. */
@Composable
private fun deepDiagnosticsLabels(): ProbePresentation.DeepDiagnosticsLabels = ProbePresentation.DeepDiagnosticsLabels(
    rootManager = stringResource(R.string.probe_deep_root_manager),
    kernel = stringResource(R.string.probe_deep_kernel),
    selinux = stringResource(R.string.probe_root_selinux),
    diagDevice = stringResource(R.string.probe_root_diag_device),
    kernelDiagConfig = stringResource(R.string.probe_root_kernel_diag),
    modemInterfaces = stringResource(R.string.probe_deep_modem),
    captureTooling = stringResource(R.string.probe_deep_capture),
    radioLog = stringResource(R.string.probe_deep_radio_log),
    usbDebugging = stringResource(R.string.probe_usb_adb),
    rootManagerNone = stringResource(R.string.probe_deep_root_manager_none),
    unknown = stringResource(R.string.probe_deep_unknown),
    smp = stringResource(R.string.probe_deep_kernel_smp),
    preempt = stringResource(R.string.probe_deep_kernel_preempt),
    selinuxEnforcing = stringResource(R.string.probe_selinux_enforcing),
    selinuxPermissive = stringResource(R.string.probe_selinux_permissive),
    selinuxDisabled = stringResource(R.string.probe_selinux_disabled),
    selinuxUnknown = stringResource(R.string.probe_selinux_unknown),
    diagAbsent = stringResource(R.string.probe_diag_absent),
    diagPresentMeta = stringResource(R.string.probe_deep_diag_present_meta),
    diagPresentDenied = stringResource(R.string.probe_deep_diag_present_denied),
    kernelDiagPresent = stringResource(R.string.probe_kernel_present),
    kernelDiagAbsent = stringResource(R.string.probe_kernel_absent),
    kernelDiagUnavailable = stringResource(R.string.probe_kernel_unavailable),
    modemNone = stringResource(R.string.probe_deep_modem_none),
    modemValue = stringResource(R.string.probe_deep_modem_value),
    capturePresent = stringResource(R.string.probe_deep_capture_present),
    captureNone = stringResource(R.string.probe_deep_capture_none),
    radioReadable = stringResource(R.string.probe_deep_radio_readable),
    radioNotReadable = stringResource(R.string.probe_deep_radio_not_readable),
    usbOn = stringResource(R.string.probe_state_on),
    usbOffDevOptions = stringResource(R.string.probe_deep_usb_off_dev),
    usbOff = stringResource(R.string.probe_state_off),
)

@Composable
private fun layer3VerdictStatusText(outcome: Layer3OnDevice): String = stringResource(
    when (outcome) {
        Layer3OnDevice.POSSIBLE -> R.string.probe_deep_verdict_viable
        Layer3OnDevice.NOT_POSSIBLE -> R.string.probe_deep_verdict_not_viable
        Layer3OnDevice.UNKNOWN -> R.string.probe_deep_verdict_unknown
    },
)

/** Cell access: the permission/SIM/location facts that decide whether measurements return anything. */
@Composable
private fun CellAccessCard(cellular: CellularReadout, modifier: Modifier) {
    SectionCard(title = stringResource(R.string.probe_cellular_title), icon = FieldTapIcons.Sim, modifier = modifier) {
        KeyValueRow(key = stringResource(R.string.probe_cellular_phone), value = allowedText(cellular.readPhoneStateGranted), tabular = false)
        KeyValueRow(key = stringResource(R.string.probe_cellular_precise), value = allowedText(cellular.preciseLocationGranted), tabular = false)
        KeyValueRow(key = stringResource(R.string.probe_cellular_location_services), value = onOffText(cellular.locationServicesEnabled), tabular = false)
        KeyValueRow(key = stringResource(R.string.probe_cellular_sim), value = simText(cellular.simReady), tabular = false)
        KeyValueRow(key = stringResource(R.string.probe_cellular_mock), value = mockText(cellular.mockLocationAppSet), tabular = false)
        KeyValueRow(
            key = stringResource(R.string.probe_cellular_mock_build),
            value = stringResource(if (cellular.buildAcceptsMockLocations) R.string.setup_yes else R.string.setup_no),
            tabular = false,
        )
    }
}

/**
 * The two JSON exports, shared through the system share sheet: `fieldtap-capability/2` (available once the
 * passive read has loaded) and `fieldtap-probe/1` (available once the telephony probe has a report). Each
 * confirms its saved file name once written.
 */
@Composable
private fun ExportsCard(
    capability: CapabilityUiState,
    report: ProbeReport?,
    probeExported: File?,
    exporting: Boolean,
    onExport: () -> Unit,
    onExportCapability: () -> Unit,
    modifier: Modifier,
) {
    SectionCard(title = stringResource(R.string.probe_exports_title), icon = FieldTapIcons.Share, modifier = modifier) {
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(Spacing.Sm),
            verticalArrangement = Arrangement.spacedBy(Spacing.Sm),
        ) {
            Button(
                onClick = onExportCapability,
                enabled = capability.snapshot != null && !capability.exporting,
                shape = ShapeRoles.Control,
                modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
            ) {
                if (capability.exporting) {
                    ButtonProgress()
                    Spacer(modifier = Modifier.width(ButtonDefaults.IconSpacing))
                }
                Text(text = stringResource(R.string.probe_export_capability))
            }
            OutlinedButton(
                onClick = onExport,
                enabled = report != null && !exporting,
                shape = ShapeRoles.Control,
                modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
            ) {
                if (exporting) {
                    ButtonProgress()
                    Spacer(modifier = Modifier.width(ButtonDefaults.IconSpacing))
                }
                Text(text = stringResource(R.string.probe_export))
            }
        }
        if (capability.exported != null) {
            SetupParagraph(text = stringResource(R.string.probe_exported, capability.exported.name))
        }
        if (probeExported != null) {
            SetupParagraph(text = stringResource(R.string.probe_exported, probeExported.name))
        }
    }
}

@Composable
private fun SummaryCard(report: ProbeReport, modifier: Modifier) {
    val noValue = stringResource(R.string.setup_no_value)
    val phoneTitle = stringResource(R.string.probe_section_phone)
    val handset = report.handset
    // Titled by the model the report is about; "Phone" when Android named neither maker nor model.
    val model = listOfNotNull(handset.manufacturer, handset.model).joinToString(" ").ifBlank { phoneTitle }
    SectionCard(
        title = model,
        subtitle = SetupFormats.dateTime(report.createdUtcMs),
        icon = FieldTapIcons.Phone,
        modifier = modifier,
    ) {
        KeyValueRow(
            key = stringResource(R.string.probe_key_android),
            value = stringResource(R.string.probe_value_android, handset.androidVersion ?: noValue, report.sdkInt),
        )
        KeyValueRow(key = stringResource(R.string.probe_key_network_type), value = handset.networkType ?: noValue)
        KeyValueRow(key = stringResource(R.string.probe_key_operator), value = operatorText(handset) ?: noValue)
        KeyValueRow(
            key = stringResource(R.string.probe_key_app),
            value = stringResource(R.string.probe_value_app, report.appVersion, report.versionCode),
        )
        KeyValueRow(
            key = stringResource(R.string.probe_key_listened),
            value = stringResource(R.string.probe_value_seconds, ProbePresentation.seconds(report.durationMs)),
        )
    }
}

@Composable
private fun operatorText(handset: HandsetMeta): String? {
    val name = handset.operatorName?.takeIf { it.isNotBlank() }
    val code = handset.operatorMccmnc?.takeIf { it.isNotBlank() }
    return when {
        name != null && code != null -> stringResource(R.string.probe_value_operator, name, code)
        else -> name ?: code
    }
}

@Composable
private fun FindingsCard(notes: List<String>, modifier: Modifier) {
    SectionCard(title = stringResource(R.string.probe_section_findings), icon = FieldTapIcons.Info, modifier = modifier) {
        if (notes.isEmpty()) {
            ChecklistRow(title = stringResource(R.string.probe_no_findings), tone = StatusTone.SUCCESS)
        } else {
            notes.forEachIndexed { index, note ->
                if (index > 0) SectionDivider()
                FindingRow(text = note)
            }
        }
    }
}

@Composable
private fun FindingRow(text: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(Spacing.Md),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = statusIcon(StatusTone.INFO),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(Sizes.IconSmall),
        )
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun CellInfoCard(probe: CellInfoProbe, modifier: Modifier) {
    val noValue = stringResource(R.string.setup_no_value)
    val colors = FieldTapDesign.colors
    SectionCard(title = stringResource(R.string.probe_section_cell_info), icon = FieldTapIcons.SignalBars, modifier = modifier) {
        KeyValueRow(key = stringResource(R.string.probe_key_requests), value = probe.requests.toString())
        KeyValueRow(key = stringResource(R.string.probe_key_answers), value = probe.answers.toString())
        KeyValueRow(
            key = stringResource(R.string.probe_key_errors),
            value = probe.errors.toString(),
            valueColor = if (probe.errors > 0) colors.warning.color else Color.Unspecified,
        )
        KeyValueRow(key = stringResource(R.string.probe_key_max_cells), value = probe.maxCellsPerAnswer.toString())
        KeyValueRow(key = stringResource(R.string.probe_key_neighbours), value = seenText(probe.neighboursSeen), tabular = false)
        KeyValueRow(
            key = stringResource(R.string.probe_key_serving_rats),
            value = ProbePresentation.joined(probe.servingRats) ?: stringResource(R.string.probe_value_none),
            tabular = false,
        )
        KeyValueRow(key = stringResource(R.string.probe_key_band_lists), value = reportedText(probe.bandListsPresent), tabular = false)
        KeyValueRow(
            key = stringResource(R.string.probe_key_connection_status),
            value = reportedText(probe.connectionStatusReported),
            tabular = false,
        )
        KeyValueRow(key = stringResource(R.string.probe_key_nsa), value = seenText(probe.nsaSecondarySeen), tabular = false)
        val timestamps = ProbePresentation.timestamps(probe.timestampsAdvance)
        KeyValueRow(
            key = stringResource(R.string.probe_key_timestamps),
            value = when (timestamps) {
                ProbeAnswer.YES -> stringResource(R.string.setup_yes)
                ProbeAnswer.NO -> stringResource(R.string.setup_no)
                ProbeAnswer.NOT_ENOUGH -> stringResource(R.string.probe_value_not_enough)
            },
            valueColor = if (timestamps == ProbeAnswer.NO) colors.error.color else Color.Unspecified,
            tabular = false,
        )
        KeyValueRow(
            key = stringResource(R.string.probe_key_min_interval),
            value = probe.minFreshIntervalMs?.let { stringResource(R.string.probe_value_seconds, ProbePresentation.seconds(it)) } ?: noValue,
        )
        val rsrp = ProbePresentation.range(probe.rsrpMin, probe.rsrpMax)
        KeyValueRow(
            key = stringResource(R.string.probe_key_rsrp_range),
            value = if (rsrp != null) stringResource(R.string.probe_value_range_dbm, rsrp.first, rsrp.last) else noValue,
        )
        val sinr = ProbePresentation.range(probe.sinrMin, probe.sinrMax)
        KeyValueRow(
            key = stringResource(R.string.probe_key_sinr_range),
            value = if (sinr != null) stringResource(R.string.probe_value_range_db, sinr.first, sinr.last) else noValue,
        )
    }
}

@Composable
private fun ServiceCard(probe: ServiceStateProbe, overrides: List<String>, modifier: Modifier) {
    val none = stringResource(R.string.probe_value_none)
    SectionCard(title = stringResource(R.string.probe_section_service), icon = FieldTapIcons.Sim, modifier = modifier) {
        KeyValueRow(key = stringResource(R.string.probe_key_updates), value = probe.snapshots.toString())
        KeyValueRow(
            key = stringResource(R.string.probe_key_operator_code),
            value = reportedText(probe.operatorNumericPresent),
            tabular = false,
        )
        KeyValueRow(key = stringResource(R.string.probe_key_emergency_only), value = seenText(probe.emergencyOnlySeen), tabular = false)
        KeyValueRow(key = stringResource(R.string.probe_key_states), value = ProbePresentation.joined(probe.states) ?: none, tabular = false)
        KeyValueRow(
            key = stringResource(R.string.probe_key_display_overrides),
            value = ProbePresentation.joined(overrides) ?: none,
            tabular = false,
        )
    }
}

@Composable
private fun ListenersCard(listeners: Map<RadioListener, ListenerOutcome>, modifier: Modifier) {
    val colors = FieldTapDesign.colors
    SectionCard(title = stringResource(R.string.probe_section_listeners), icon = FieldTapIcons.Transfer, modifier = modifier) {
        ProbePresentation.listenerRows(listeners).forEach { (listener, outcome) ->
            val word = ProbePresentation.listenerWord(listener, outcome)
            KeyValueRow(
                key = ProbeNotes.apiName(listener),
                value = listenerText(word),
                valueColor = colors.status(word.tone).color,
                tabular = false,
            )
        }
    }
}

@Composable
private fun PermissionsCard(permissions: Map<String, Boolean>, modifier: Modifier) {
    val colors = FieldTapDesign.colors
    SectionCard(title = stringResource(R.string.probe_section_permissions), icon = FieldTapIcons.Shield, modifier = modifier) {
        permissions.forEach { (name, granted) ->
            KeyValueRow(
                key = permissionText(name),
                value = stringResource(if (granted) R.string.probe_permission_allowed else R.string.probe_permission_not_allowed),
                valueColor = if (granted) colors.success.color else colors.warning.color,
                tabular = false,
            )
        }
    }
}

@Composable
private fun seenText(seen: Boolean): String =
    stringResource(if (seen) R.string.probe_value_seen else R.string.probe_value_not_seen)

@Composable
private fun reportedText(reported: Boolean): String =
    stringResource(if (reported) R.string.probe_value_reported else R.string.probe_value_not_reported)

@Composable
private fun onOffText(on: Boolean): String =
    stringResource(if (on) R.string.probe_state_on else R.string.probe_state_off)

@Composable
private fun allowedText(allowed: Boolean): String =
    stringResource(if (allowed) R.string.probe_permission_allowed else R.string.probe_permission_not_allowed)

@Composable
private fun simText(ready: Boolean): String =
    stringResource(if (ready) R.string.probe_sim_ready else R.string.probe_sim_not_ready)

@Composable
private fun mockText(set: Boolean): String =
    stringResource(if (set) R.string.probe_mock_set else R.string.probe_mock_none)

@Composable
private fun captureAnswerText(answer: CaptureAnswer): String = stringResource(
    when (answer) {
        CaptureAnswer.YES -> R.string.setup_yes
        CaptureAnswer.NO -> R.string.setup_no
        CaptureAnswer.UNKNOWN -> R.string.probe_layer3_unknown
    },
)

@Composable
private fun layer3Text(l3: Layer3OnDevice): String = stringResource(
    when (l3) {
        Layer3OnDevice.POSSIBLE -> R.string.probe_layer3_possible
        Layer3OnDevice.NOT_POSSIBLE -> R.string.probe_layer3_not_possible
        Layer3OnDevice.UNKNOWN -> R.string.probe_layer3_unknown
    },
)

@Composable
private fun rootConfidenceText(confidence: RootConfidence): String = stringResource(
    when (confidence) {
        RootConfidence.NONE -> R.string.probe_root_confidence_none
        RootConfidence.LOW -> R.string.probe_root_confidence_low
        RootConfidence.MEDIUM -> R.string.probe_root_confidence_medium
        RootConfidence.HIGH -> R.string.probe_root_confidence_high
    },
)

@Composable
private fun selinuxText(mode: SelinuxMode): String = stringResource(
    when (mode) {
        SelinuxMode.ENFORCING -> R.string.probe_selinux_enforcing
        SelinuxMode.PERMISSIVE -> R.string.probe_selinux_permissive
        SelinuxMode.DISABLED -> R.string.probe_selinux_disabled
        SelinuxMode.UNKNOWN -> R.string.probe_selinux_unknown
    },
)

@Composable
private fun diagDeviceText(device: DiagDevice): String = stringResource(
    when (device) {
        DiagDevice.PRESENT -> R.string.probe_diag_present
        DiagDevice.ABSENT -> R.string.probe_diag_absent
        DiagDevice.PERMISSION_DENIED -> R.string.probe_diag_denied
        DiagDevice.UNKNOWN -> R.string.probe_diag_unknown
    },
)

@Composable
private fun kernelDiagText(kernel: KernelConfigProbe): String = stringResource(
    when (kernel) {
        KernelConfigProbe.DIAG_PRESENT -> R.string.probe_kernel_present
        KernelConfigProbe.DIAG_ABSENT -> R.string.probe_kernel_absent
        KernelConfigProbe.CONFIG_UNAVAILABLE -> R.string.probe_kernel_unavailable
    },
)

@Composable
private fun listenerText(word: ListenerWord): String = stringResource(
    when (word) {
        ListenerWord.REGISTERED -> R.string.probe_listener_registered
        ListenerWord.MISSING_PERMISSION -> R.string.probe_listener_missing_permission
        ListenerWord.REFUSED -> R.string.probe_listener_refused
        ListenerWord.REFUSED_EXPECTED -> R.string.probe_listener_refused_expected
        ListenerWord.NOT_REGISTERED -> R.string.probe_listener_not_registered
        ListenerWord.FAILED -> R.string.probe_listener_failed
    },
)

@Composable
private fun permissionText(name: String): String = when (ProbePresentation.permissionLabel(name)) {
    ProbePermissionLabel.PRECISE_LOCATION -> stringResource(R.string.probe_permission_precise_location)
    ProbePermissionLabel.APPROXIMATE_LOCATION -> stringResource(R.string.probe_permission_approximate_location)
    ProbePermissionLabel.NOTIFICATIONS -> stringResource(R.string.probe_permission_notifications)
    ProbePermissionLabel.PHONE -> stringResource(R.string.probe_permission_phone)
    ProbePermissionLabel.OTHER -> name
}

private fun previewSnapshot(): CapabilitySnapshot {
    val root = RootDetector.assess(
        com.fieldtap.core.capability.PassiveInputs(
            props = emptyMap(),
            buildTags = "release-keys",
            suBinariesPresent = emptyList(),
            rootManagerPackages = listOf("com.topjohnwu.magisk"),
            writableSystemPaths = emptyList(),
            usb = UsbDebugState(adbEnabled = true, wirelessDebugEnabled = false, developerOptionsEnabled = true),
            cellular = CellularReadout(
                readPhoneStateGranted = false,
                preciseLocationGranted = true,
                locationServicesEnabled = true,
                simReady = true,
                mockLocationAppSet = false,
                buildAcceptsMockLocations = false,
            ),
            rootManagerVersions = listOf(com.fieldtap.core.capability.RootManagerInfo("com.topjohnwu.magisk", "27.0")),
        ),
    )
    val usb = UsbDebugState(adbEnabled = true, wirelessDebugEnabled = false, developerOptionsEnabled = true)
    val cellular = CellularReadout(
        readPhoneStateGranted = false,
        preciseLocationGranted = true,
        locationServicesEnabled = true,
        simReady = true,
        mockLocationAppSet = false,
        buildAcceptsMockLocations = false,
    )
    return CapabilitySnapshot(
        root = root,
        usb = usb,
        cellular = cellular,
        verdict = com.fieldtap.core.capability.CapabilityVerdict.snapshot(root, usb, cellular),
    )
}

/** A folded "Check with root" result with a deep readout: the lead's OnePlus case (rooted, no /dev/diag). */
private fun previewRootProbe(): RootProbeResult {
    val deep = com.fieldtap.core.capability.DeepDiagnostics(
        kernel = com.fieldtap.core.capability.KernelInfo(
            release = "5.10.101-android12-9-g0",
            architecture = "aarch64",
            smp = true,
            preempt = true,
            redactedVersion = "Linux version 5.10.101 SMP PREEMPT",
        ),
        selinux = com.fieldtap.core.capability.SelinuxAssessment(
            mode = SelinuxMode.ENFORCING,
            blocksAppDiagPath = true,
            consequence = CapabilityMessages.selinuxConsequence(SelinuxMode.ENFORCING, blocksAppDiagPath = true),
        ),
        diagNodes = com.fieldtap.core.capability.DiagNodes(
            primary = com.fieldtap.core.capability.DiagNodeStat(
                path = "/dev/diag",
                exists = false,
                charDevice = false,
                octalMode = null,
                ownerUser = null,
                ownerGroup = null,
            ),
            others = emptyList(),
        ),
        kernelDiagConfig = KernelConfigProbe.DIAG_ABSENT,
        modemInterfaces = com.fieldtap.core.capability.ModemInterfaces(count = 3, names = listOf("rmnet_data0", "rmnet_data1", "qmux0")),
        captureTooling = com.fieldtap.core.capability.CaptureTooling(
            tcpdumpPresent = false,
            tcpdumpPaths = emptyList(),
            pcapCapableInterfacePresent = true,
        ),
        radioLog = com.fieldtap.core.capability.RadioLogReadout(readable = true, lineCount = 5),
    )
    return RootProbeResult(
        suStatus = com.fieldtap.core.capability.SuStatus.GRANTED,
        isRoot = true,
        selinux = SelinuxMode.ENFORCING,
        diagDevice = DiagDevice.ABSENT,
        kernelDiag = KernelConfigProbe.DIAG_ABSENT,
        layer3 = Layer3OnDevice.NOT_POSSIBLE,
        elapsedMs = 420,
        message = "The root check confirmed working root on this phone.",
        deep = deep,
    )
}

private fun previewReport(): ProbeReport = com.fieldtap.core.probe.ProbeRecorder().report(
    createdUtcMs = 1_789_050_600_000L,
    durationMs = 30_000,
    appVersion = "0.1.0",
    versionCode = 1,
    sdkInt = 36,
    handset = HandsetMeta(
        manufacturer = "OnePlus",
        model = "10 Pro",
        androidVersion = "16",
        operatorName = "T-Mobile",
        operatorMccmnc = "310260",
        networkType = "NR",
    ),
    permissions = linkedMapOf(
        Permissions.FINE_LOCATION to true,
        Permissions.COARSE_LOCATION to true,
        Permissions.POST_NOTIFICATIONS to true,
        Permissions.READ_PHONE_STATE to false,
    ),
)

@FieldTapPreviews
@Composable
private fun ProbeReportPreview() {
    PreviewSurface {
        ProbeContent(
            state = ProbeUiState(
                running = false,
                progress = null,
                report = previewReport(),
                exported = null,
                capability = CapabilityUiState(snapshot = previewSnapshot(), rootProbe = previewRootProbe()),
            ),
            problem = null,
            exporting = false,
            onBack = {},
            onRun = {},
            onStop = {},
            onExport = {},
            onCheckRoot = {},
            onExportCapability = {},
            onRetryCapability = {},
        )
    }
}

@FieldTapPreviews
@Composable
private fun ProbeRunningPreview() {
    PreviewSurface {
        ProbeContent(
            state = ProbeUiState(
                running = true,
                progress = "Listening: 12 s of 30 s, 12 answers",
                report = null,
                exported = null,
                capability = CapabilityUiState(snapshot = previewSnapshot(), checkingRoot = false),
            ),
            problem = ProbeProblem.INTERRUPTED,
            exporting = false,
            onBack = {},
            onRun = {},
            onStop = {},
            onExport = {},
            onCheckRoot = {},
            onExportCapability = {},
            onRetryCapability = {},
        )
    }
}
