package com.fieldtap.ui.settings

import android.app.Activity
import android.content.Context
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.fieldtap.R
import com.fieldtap.app.AppGraph
import com.fieldtap.core.input.FixSample
import com.fieldtap.core.nettest.TestSettings
import com.fieldtap.core.privacy.Consent
import com.fieldtap.core.privacy.ConsentRecord
import com.fieldtap.core.privacy.PrivacyZone
import com.fieldtap.core.privacy.PrivacyZones
import com.fieldtap.core.readiness.SettingsTarget
import com.fieldtap.core.settings.AppSettings
import com.fieldtap.diag.CaptureProfile
import com.fieldtap.platform.Permissions
import com.fieldtap.ui.components.EmptyState
import com.fieldtap.ui.components.FieldTapPreviews
import com.fieldtap.ui.components.LoadingState
import com.fieldtap.ui.components.NavigationRow
import com.fieldtap.ui.components.PermissionStatus
import com.fieldtap.ui.components.PreviewSurface
import com.fieldtap.ui.components.RadioRow
import com.fieldtap.ui.components.SectionCard
import com.fieldtap.ui.components.SectionDivider
import com.fieldtap.ui.components.ToggleRow
import com.fieldtap.ui.setup.PermissionAction
import com.fieldtap.ui.setup.PermissionRules
import com.fieldtap.ui.setup.PermissionUi
import com.fieldtap.ui.setup.SettingsIntents
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
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * What the Settings screen shows.
 *
 * @param settings the stored settings, or null until they are read.
 */
data class SettingsUiState(
    val settings: AppSettings?,
    /** Validation problems of the zone being edited (`PrivacyZones.validate`). */
    val zoneProblems: List<String>,
)

/** Something the Settings screen tells the user once, as a snackbar. */
sealed interface SettingsEvent {
    data object TestsSaved : SettingsEvent

    data object ZoneSaved : SettingsEvent

    /** [zone] was deleted; saving it again undoes that. */
    data class ZoneDeleted(val zone: PrivacyZone) : SettingsEvent

    data object ConsentWithdrawn : SettingsEvent

    /** A change could not be written. */
    data object SaveFailed : SettingsEvent
}

/**
 * Settings, persisted through `SettingsRepository.update`, whose atomic edit never loses a concurrent change.
 *
 * - [state] follows the stored settings. [saveZone] validates with `PrivacyZones.validate` first: problems go to
 *   [SettingsUiState.zoneProblems] at once and nothing is saved; a valid zone replaces the zone with its id in place,
 *   or is added at the end. [deleteZone] removes by id and emits the zone for undo.
 * - [updateTests] saves only settings that pass `TestSettingsRules`; otherwise [testProblems] lists why.
 * - [zoneAtCurrentPosition] centres a zone on the newest fix of `AppGraph.live` when it is at most
 *   `ZoneDrafts.MAX_FIX_AGE_MS` old. Collect [recentFix] while "add zone here" is open: collecting the live feed is
 *   what starts the location source.
 * - [withdrawConsent] clears the stored consent (android/ARCHITECTURE.md decision 2), so new sessions cannot start.
 * - A failed write emits [SettingsEvent.SaveFailed] on [events].
 *
 * Owner: workstream `ui-setup`.
 */
class SettingsViewModel(private val graph: AppGraph) : ViewModel() {
    private val mutableState = MutableStateFlow(SettingsUiState(settings = null, zoneProblems = emptyList()))
    private val mutableTestProblems = MutableStateFlow<List<TestSettingsProblem>>(emptyList())
    private val mutableLoadFailed = MutableStateFlow(false)
    private val eventChannel = Channel<SettingsEvent>(Channel.BUFFERED)
    private var loadJob: Job? = null

    val state: StateFlow<SettingsUiState> = mutableState.asStateFlow()

    /** Why the last [updateTests] saved nothing; empty after a save. */
    val testProblems: StateFlow<List<TestSettingsProblem>> = mutableTestProblems.asStateFlow()

    /** The settings could not be read; [retryLoad] tries again. */
    val loadFailed: StateFlow<Boolean> = mutableLoadFailed.asStateFlow()

    /** Snackbar messages, each delivered once. */
    val events: Flow<SettingsEvent> = eventChannel.receiveAsFlow()

    /** The newest fix while it is recent enough to centre a zone on, else null. Collecting it runs the live feed. */
    val recentFix: StateFlow<FixSample?> = graph.live.state
        .map { live -> live.lastFix?.takeIf { fix -> ZoneDrafts.isRecent(fix, graph.clock.elapsedRealtimeMillis()) } }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(FIX_STOP_TIMEOUT_MS), null)

    init {
        load()
    }

    /** Reads the settings again after [loadFailed]. */
    fun retryLoad() {
        if (loadJob?.isActive == true) return
        load()
    }

    fun updateTests(tests: TestSettings) {
        val problems = TestSettingsRules.problems(tests)
        mutableTestProblems.value = problems
        if (problems.isNotEmpty()) return
        save(SettingsEvent.TestsSaved) { settings -> settings.copy(tests = tests) }
    }

    fun setTestsDefaultOn(on: Boolean) {
        save(success = null) { settings -> settings.copy(testsDefaultOn = on) }
    }

    /** What the next RRC / NAS log asks the modem for. Saved at once, like a switch. */
    fun setCaptureProfile(profile: CaptureProfile) {
        save(success = null) { settings -> settings.copy(captureProfile = profile) }
    }

    /** Adds or replaces by id, after validation. */
    fun saveZone(zone: PrivacyZone) {
        val problems = PrivacyZones.validate(zone)
        mutableState.update { it.copy(zoneProblems = problems) }
        if (problems.isNotEmpty()) return
        save(SettingsEvent.ZoneSaved) { settings -> settings.copy(zones = ZoneDrafts.upsert(settings.zones, zone)) }
    }

    fun deleteZone(id: String) {
        val zone = mutableState.value.settings?.zones?.firstOrNull { it.id == id }
        save(zone?.let { SettingsEvent.ZoneDeleted(it) }) { settings ->
            settings.copy(zones = settings.zones.filterNot { it.id == id })
        }
    }

    /** Clears [SettingsUiState.zoneProblems], when the zone editor opens or closes. */
    fun clearZoneProblems() {
        mutableState.update { it.copy(zoneProblems = emptyList()) }
    }

    /** A zone centred on the newest fix (from `AppGraph.live`), for "add zone here". */
    fun zoneAtCurrentPosition(label: String, radiusM: Double): PrivacyZone? {
        val fix = graph.live.state.value.lastFix ?: return null
        if (!ZoneDrafts.isRecent(fix, graph.clock.elapsedRealtimeMillis())) return null
        return PrivacyZone(id = UUID.randomUUID().toString(), label = label, lat = fix.lat, lon = fix.lon, radiusM = radiusM)
    }

    /** Withdraws consent: new sessions cannot start until the disclosure is accepted again. */
    fun withdrawConsent() {
        save(SettingsEvent.ConsentWithdrawn) { settings -> settings.copy(consent = null) }
    }

    private fun load() {
        mutableLoadFailed.value = false
        loadJob = viewModelScope.launch {
            graph.settings.settings
                .catch { error ->
                    if (error is Exception) {
                        mutableLoadFailed.value = true
                    } else {
                        throw error
                    }
                }
                .collect { settings -> mutableState.update { it.copy(settings = settings) } }
        }
    }

    private fun save(success: SettingsEvent?, transform: (AppSettings) -> AppSettings) {
        viewModelScope.launch {
            val saved = try {
                graph.settings.update(transform)
                true
            } catch (e: CancellationException) {
                throw e
            } catch (e: IOException) {
                false
            } catch (e: RuntimeException) {
                false
            }
            val event = if (saved) success else SettingsEvent.SaveFailed
            if (event != null) eventChannel.send(event)
        }
    }

    private companion object {
        /** Keeps the live feed alive across a rotation of the zone editor. */
        const val FIX_STOP_TIMEOUT_MS: Long = 5_000
    }
}

/**
 * Settings, in the order they are changed: Measurement ("Instant cell updates", the only place the Phone permission is
 * asked for, android/ARCHITECTURE.md decision 9); privacy zones (label, radius, "here" from the
 * current fix, or typed coordinates), with a note that zones apply to new sessions and nothing is written inside them,
 * and no map tiles; the ping and download tests, as their default and a row that opens [TestTargetsScreen] with the
 * targets summarised; then withdrawing consent (decision 2). A zone's name never leaves this screen.
 *
 * Switches save at once; the test targets save on their own screen.
 *
 * Owner: workstream `ui-setup`.
 */
@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel,
    onOpenTestTargets: () -> Unit,
    onOpenReadiness: () -> Unit,
    onOpenAbout: () -> Unit,
    onOpenProbe: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val loadFailed by viewModel.loadFailed.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val activity = LocalActivity.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    val openFailedText = stringResource(R.string.setup_open_settings_failed)
    val testsSavedText = stringResource(R.string.settings_tests_saved)
    val zoneSavedText = stringResource(R.string.settings_zone_saved)
    val zoneDeletedText = stringResource(R.string.settings_zone_deleted)
    val undoText = stringResource(R.string.settings_zone_undo)
    val consentWithdrawnText = stringResource(R.string.settings_consent_withdrawn)
    val saveFailedText = stringResource(R.string.settings_save_failed)

    var phone by remember(context) { mutableStateOf(PhoneSnapshot.read(context, activity)) }
    var phoneRequested by rememberSaveable { mutableStateOf(false) }
    var confirmPhoneOff by rememberSaveable { mutableStateOf(false) }
    var confirmWithdraw by rememberSaveable { mutableStateOf(false) }
    var editor by rememberSaveable(stateSaver = ZoneEditorStateSaver) { mutableStateOf<ZoneEditorState?>(null) }

    LifecycleResumeEffect(context) {
        phone = PhoneSnapshot.read(context, activity)
        onPauseOrDispose { }
    }
    val phoneLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        phoneRequested = true
        phone = PhoneSnapshot.read(context, activity)
    }
    val openSettings: (SettingsTarget) -> Unit = { target ->
        if (!SettingsIntents.open(context, target)) {
            scope.launch { snackbarHostState.showSnackbar(openFailedText) }
        }
    }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                SettingsEvent.TestsSaved -> snackbarHostState.showSnackbar(testsSavedText)
                SettingsEvent.ZoneSaved -> snackbarHostState.showSnackbar(zoneSavedText)
                is SettingsEvent.ZoneDeleted -> {
                    val result = snackbarHostState.showSnackbar(
                        message = zoneDeletedText,
                        actionLabel = undoText,
                        duration = SnackbarDuration.Long,
                    )
                    if (result == SnackbarResult.ActionPerformed) viewModel.saveZone(event.zone)
                }
                SettingsEvent.ConsentWithdrawn -> snackbarHostState.showSnackbar(consentWithdrawnText)
                SettingsEvent.SaveFailed -> snackbarHostState.showSnackbar(saveFailedText)
            }
        }
    }

    val phoneUi = PermissionRules.phone(granted = phone.granted, requestedBefore = phoneRequested, showRationale = phone.rationale)
    SettingsContent(
        state = state,
        loadFailed = loadFailed,
        phone = phoneUi,
        preciseLocation = phone.preciseLocation,
        onRetryLoad = viewModel::retryLoad,
        onOpenTestTargets = onOpenTestTargets,
        onOpenReadiness = onOpenReadiness,
        onOpenAbout = onOpenAbout,
        onOpenProbe = onOpenProbe,
        onTestsDefaultOnChange = viewModel::setTestsDefaultOn,
        onCaptureProfileChange = viewModel::setCaptureProfile,
        onInstantUpdatesChange = { turnOn ->
            if (turnOn) {
                when (phoneUi.action) {
                    PermissionAction.REQUEST -> phoneLauncher.launch(arrayOf(Permissions.READ_PHONE_STATE))
                    PermissionAction.OPEN_APP_SETTINGS -> openSettings(SettingsTarget.APP_DETAILS)
                    PermissionAction.OPEN_NOTIFICATION_SETTINGS, PermissionAction.NONE -> Unit
                }
            } else {
                confirmPhoneOff = true
            }
        },
        onAddZoneHere = {
            viewModel.clearZoneProblems()
            editor = ZoneEditorState(ZoneEditorMode.HERE, ZoneDraft.blank())
        },
        onAddZoneByCoordinates = {
            viewModel.clearZoneProblems()
            editor = ZoneEditorState(ZoneEditorMode.COORDINATES, ZoneDraft.blank())
        },
        onEditZone = { zone ->
            viewModel.clearZoneProblems()
            editor = ZoneEditorState(ZoneEditorMode.EDIT, ZoneDraft.of(zone))
        },
        onDeleteZone = { zone -> viewModel.deleteZone(zone.id) },
        onWithdrawConsent = { confirmWithdraw = true },
        modifier = modifier,
        snackbarHostState = snackbarHostState,
    )

    val openEditor = editor
    if (openEditor != null) {
        // Only "here" needs a position, so only it runs the location source.
        val fix = if (openEditor.mode == ZoneEditorMode.HERE) viewModel.recentFix.collectAsStateWithLifecycle().value else null
        LaunchedEffect(fix, openEditor.mode) {
            val current = editor ?: return@LaunchedEffect
            if (current.mode != ZoneEditorMode.HERE || current.draft.lat.isNotBlank() || current.draft.lon.isNotBlank()) {
                return@LaunchedEffect
            }
            val here = viewModel.zoneAtCurrentPosition(current.draft.label, ZoneDrafts.radiusOrDefault(current.draft.radius))
                ?: return@LaunchedEffect
            editor = current.copy(draft = current.draft.withPosition(here.lat, here.lon))
        }
        ZoneEditorDialog(
            editor = openEditor,
            problems = state.zoneProblems,
            fix = fix,
            onDraftChange = { draft -> editor = openEditor.copy(draft = draft) },
            onUsePosition = {
                val here = viewModel.zoneAtCurrentPosition(openEditor.draft.label, ZoneDrafts.radiusOrDefault(openEditor.draft.radius))
                if (here != null) editor = openEditor.copy(draft = openEditor.draft.withPosition(here.lat, here.lon))
            },
            onSave = {
                viewModel.saveZone(openEditor.draft.toZone { UUID.randomUUID().toString() })
                if (viewModel.state.value.zoneProblems.isEmpty()) editor = null
            },
            onDismiss = {
                editor = null
                viewModel.clearZoneProblems()
            },
        )
    }
    if (confirmPhoneOff) {
        AlertDialog(
            onDismissRequest = { confirmPhoneOff = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmPhoneOff = false
                        openSettings(SettingsTarget.APP_DETAILS)
                    },
                ) {
                    Text(text = stringResource(R.string.setup_open_app_settings))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmPhoneOff = false }) { Text(text = stringResource(R.string.setup_cancel)) }
            },
            icon = { Icon(imageVector = FieldTapIcons.Phone, contentDescription = null) },
            title = { Text(text = stringResource(R.string.settings_instant_updates_off_title)) },
            text = { Text(text = stringResource(R.string.settings_instant_updates_off_body)) },
        )
    }
    if (confirmWithdraw) {
        AlertDialog(
            onDismissRequest = { confirmWithdraw = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmWithdraw = false
                        viewModel.withdrawConsent()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                ) {
                    Text(text = stringResource(R.string.settings_consent_withdraw_confirm))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmWithdraw = false }) { Text(text = stringResource(R.string.setup_cancel)) }
            },
            icon = { Icon(imageVector = FieldTapIcons.Warning, contentDescription = null) },
            title = { Text(text = stringResource(R.string.settings_consent_withdraw_title)) },
            text = { Text(text = stringResource(R.string.settings_consent_withdraw_body)) },
        )
    }
}

/** The Settings screen without its view model, dialogs or permission launcher, for previews. */
@Composable
internal fun SettingsContent(
    state: SettingsUiState,
    loadFailed: Boolean,
    phone: PermissionUi,
    preciseLocation: Boolean,
    onRetryLoad: () -> Unit,
    onOpenTestTargets: () -> Unit,
    onOpenReadiness: () -> Unit,
    onOpenAbout: () -> Unit,
    onOpenProbe: () -> Unit,
    onTestsDefaultOnChange: (Boolean) -> Unit,
    onCaptureProfileChange: (CaptureProfile) -> Unit,
    onInstantUpdatesChange: (Boolean) -> Unit,
    onAddZoneHere: () -> Unit,
    onAddZoneByCoordinates: () -> Unit,
    onEditZone: (PrivacyZone) -> Unit,
    onDeleteZone: (PrivacyZone) -> Unit,
    onWithdrawConsent: () -> Unit,
    modifier: Modifier = Modifier,
    snackbarHostState: SnackbarHostState? = null,
) {
    val titleText = stringResource(R.string.settings_title)
    val loadingText = stringResource(R.string.settings_loading)
    val loadFailedText = stringResource(R.string.settings_load_failed)
    val tryAgainText = stringResource(R.string.setup_try_again)
    val settings = state.settings
    // Settings is a tab root, so SetupScreenScaffold shows no Back arrow (onBack left at its null default).
    SetupScreenScaffold(title = titleText, modifier = modifier, snackbarHostState = snackbarHostState) {
        if (settings == null) {
            item(key = "loading") {
                if (loadFailed) {
                    EmptyState(
                        title = loadFailedText,
                        icon = FieldTapIcons.Error,
                        tone = StatusTone.ERROR,
                        actionLabel = tryAgainText,
                        onAction = onRetryLoad,
                        modifier = Modifier.setupContentWidth(),
                    )
                } else {
                    LoadingState(message = loadingText, modifier = Modifier.setupContentWidth())
                }
            }
        } else {
            // What changes how a session is measured comes first. The ping and download form took the first screen and a half,
            // though it rarely changes: it is one row now, opening a screen of its own.
            item(key = "measurement") {
                MeasurementCard(
                    phone = phone,
                    preciseLocation = preciseLocation,
                    onInstantUpdatesChange = onInstantUpdatesChange,
                    modifier = Modifier.setupContentWidth(),
                )
            }
            item(key = "zones") {
                ZonesCard(
                    zones = settings.zones,
                    onAddZoneHere = onAddZoneHere,
                    onAddZoneByCoordinates = onAddZoneByCoordinates,
                    onEditZone = onEditZone,
                    onDeleteZone = onDeleteZone,
                    modifier = Modifier.setupContentWidth(),
                )
            }
            item(key = "tests") {
                TestsCard(
                    tests = settings.tests,
                    testsDefaultOn = settings.testsDefaultOn,
                    onTestsDefaultOnChange = onTestsDefaultOnChange,
                    onOpenTestTargets = onOpenTestTargets,
                    modifier = Modifier.setupContentWidth(),
                )
            }
            item(key = "capture") {
                CaptureCard(
                    profile = settings.captureProfile,
                    onProfileChange = onCaptureProfileChange,
                    modifier = Modifier.setupContentWidth(),
                )
            }
            item(key = "consent") {
                ConsentCard(consent = settings.consent, onWithdraw = onWithdrawConsent, modifier = Modifier.setupContentWidth())
            }
            item(key = "help") {
                HelpCard(
                    onOpenReadiness = onOpenReadiness,
                    onOpenAbout = onOpenAbout,
                    onOpenProbe = onOpenProbe,
                    modifier = Modifier.setupContentWidth(),
                )
            }
        }
    }
}

/** The Readiness check and About, each a row opening a screen of its own. About and Readiness were reached from Live's overflow before the tabs. */
@Composable
private fun HelpCard(
    onOpenReadiness: () -> Unit,
    onOpenAbout: () -> Unit,
    onOpenProbe: () -> Unit,
    modifier: Modifier,
) {
    SectionCard(title = stringResource(R.string.settings_section_help), icon = FieldTapIcons.Info, modifier = modifier) {
        // The capability probe was a tab of its own, which put a once-per-phone task beside the two
        // screens used every day. It belongs with the other setup tasks.
        NavigationRow(
            title = stringResource(R.string.settings_probe),
            onClick = onOpenProbe,
            supportingText = stringResource(R.string.settings_probe_supporting),
            icon = FieldTapIcons.Pulse,
        )
        NavigationRow(
            title = stringResource(R.string.settings_readiness),
            onClick = onOpenReadiness,
            supportingText = stringResource(R.string.settings_readiness_supporting),
            icon = FieldTapIcons.CheckCircle,
        )
        NavigationRow(
            title = stringResource(R.string.settings_about),
            onClick = onOpenAbout,
            supportingText = stringResource(R.string.settings_about_supporting),
            icon = FieldTapIcons.Info,
        )
    }
}

/**
 * The tests as Settings shows them: their default for new sessions, and one row naming the targets that opens
 * [TestTargetsScreen]. Every toggle of this screen has a leading icon, so their words line up.
 */
@Composable
private fun TestsCard(
    tests: TestSettings,
    testsDefaultOn: Boolean,
    onTestsDefaultOnChange: (Boolean) -> Unit,
    onOpenTestTargets: () -> Unit,
    modifier: Modifier,
) {
    SectionCard(
        title = stringResource(R.string.settings_section_tests),
        subtitle = stringResource(R.string.settings_tests_network_note),
        icon = FieldTapIcons.Transfer,
        modifier = modifier,
    ) {
        ToggleRow(
            title = stringResource(R.string.settings_tests_default),
            checked = testsDefaultOn,
            onCheckedChange = onTestsDefaultOnChange,
            supportingText = stringResource(R.string.settings_tests_default_supporting),
            icon = FieldTapIcons.Transfer,
        )
        NavigationRow(
            title = stringResource(R.string.settings_test_targets),
            onClick = onOpenTestTargets,
            supportingText = testTargetsSummary(tests),
            icon = FieldTapIcons.Tune,
        )
    }
}

/**
 * The capture profile, one radio row per [CaptureProfile] with its own one-line cost. The names and
 * descriptions come from the enum, not from resources, because the desktop decoder calls the profiles the
 * same thing and a capture's summary records the name.
 */
@Composable
private fun CaptureCard(
    profile: CaptureProfile,
    onProfileChange: (CaptureProfile) -> Unit,
    modifier: Modifier,
) {
    SectionCard(
        title = stringResource(R.string.settings_section_capture),
        subtitle = stringResource(R.string.settings_capture_note),
        icon = FieldTapIcons.Pulse,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.selectableGroup()) {
            for (option in CaptureProfile.entries) {
                RadioRow(
                    title = option.label,
                    selected = option == profile,
                    onSelect = { onProfileChange(option) },
                    supportingText = option.description,
                )
            }
        }
    }
}

@Composable
private fun MeasurementCard(
    phone: PermissionUi,
    preciseLocation: Boolean,
    onInstantUpdatesChange: (Boolean) -> Unit,
    modifier: Modifier,
) {
    val granted = phone.status == PermissionStatus.GRANTED
    val instantSupporting = listOfNotNull(
        stringResource(R.string.settings_instant_updates_supporting),
        if (phone.status == PermissionStatus.DENIED_PERMANENTLY) stringResource(R.string.settings_instant_updates_blocked) else null,
        if (granted && !preciseLocation) stringResource(R.string.settings_instant_updates_needs_location) else null,
    ).joinToString(separator = " ")
    SectionCard(
        title = stringResource(R.string.settings_section_measurement),
        subtitle = stringResource(R.string.settings_measurement_note),
        icon = FieldTapIcons.SignalBars,
        modifier = modifier,
    ) {
        ToggleRow(
            title = stringResource(R.string.settings_instant_updates),
            checked = granted,
            onCheckedChange = onInstantUpdatesChange,
            supportingText = instantSupporting,
            icon = FieldTapIcons.Phone,
        )
    }
}

@Composable
private fun ZonesCard(
    zones: List<PrivacyZone>,
    onAddZoneHere: () -> Unit,
    onAddZoneByCoordinates: () -> Unit,
    onEditZone: (PrivacyZone) -> Unit,
    onDeleteZone: (PrivacyZone) -> Unit,
    modifier: Modifier,
) {
    SectionCard(title = stringResource(R.string.settings_section_zones), icon = FieldTapIcons.Shield, modifier = modifier) {
        SetupParagraph(text = stringResource(R.string.settings_zones_intro))
        if (zones.isEmpty()) {
            // No louder than the explanation above it.
            Text(
                text = stringResource(R.string.settings_zones_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            zones.forEachIndexed { index, zone ->
                if (index > 0) SectionDivider()
                ZoneRow(zone = zone, onEdit = { onEditZone(zone) }, onDelete = { onDeleteZone(zone) })
            }
        }
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(Spacing.Sm),
            verticalArrangement = Arrangement.spacedBy(Spacing.Sm),
        ) {
            FilledTonalButton(
                onClick = onAddZoneHere,
                shape = ShapeRoles.Control,
                contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
                modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
            ) {
                Icon(imageVector = FieldTapIcons.Location, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
                Spacer(modifier = Modifier.width(ButtonDefaults.IconSpacing))
                Text(text = stringResource(R.string.settings_zone_add_here))
            }
            OutlinedButton(onClick = onAddZoneByCoordinates, shape = ShapeRoles.Control, modifier = Modifier.heightIn(min = Sizes.MinTouchTarget)) {
                Text(text = stringResource(R.string.settings_zone_add_coordinates))
            }
        }
    }
}

@Composable
private fun ZoneRow(zone: PrivacyZone, onEdit: () -> Unit, onDelete: () -> Unit) {
    val summary = stringResource(
        R.string.settings_zone_summary,
        SetupFormats.metres(zone.radiusM),
        SetupFormats.coordinate(zone.lat),
        SetupFormats.coordinate(zone.lon),
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = Sizes.SettingsRowMinHeight)
            .clip(ShapeRoles.Field)
            .clickable(role = Role.Button, onClick = onEdit)
            .padding(vertical = Spacing.Xs),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.Md),
    ) {
        Icon(
            imageVector = FieldTapIcons.Shield,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(Sizes.Icon),
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Spacing.Xxs)) {
            Text(text = zone.label, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurface)
            Text(
                text = summary,
                style = MaterialTheme.typography.bodyMedium.tabular(),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        IconButton(onClick = onDelete) {
            Icon(imageVector = FieldTapIcons.Delete, contentDescription = stringResource(R.string.settings_zone_delete, zone.label))
        }
    }
}

@Composable
private fun ConsentCard(consent: ConsentRecord?, onWithdraw: () -> Unit, modifier: Modifier) {
    SectionCard(
        title = stringResource(R.string.settings_section_consent),
        subtitle = stringResource(R.string.settings_consent_note),
        icon = FieldTapIcons.CheckCircle,
        modifier = modifier,
    ) {
        if (consent != null && Consent.isCurrent(consent)) {
            SetupParagraph(text = stringResource(R.string.settings_consent_given, SetupFormats.date(consent.grantedUtcMs)))
            OutlinedButton(
                onClick = onWithdraw,
                shape = ShapeRoles.Control,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
                modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
            ) {
                Text(text = stringResource(R.string.settings_consent_withdraw))
            }
        } else if (consent != null) {
            SetupParagraph(text = stringResource(R.string.settings_consent_outdated))
        } else {
            SetupParagraph(text = stringResource(R.string.settings_consent_missing))
        }
    }
}

@Composable
private fun ZoneEditorDialog(
    editor: ZoneEditorState,
    problems: List<String>,
    fix: FixSample?,
    onDraftChange: (ZoneDraft) -> Unit,
    onUsePosition: () -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
) {
    val draft = editor.draft
    val metresUnit = stringResource(R.string.settings_unit_metres)
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onSave) { Text(text = stringResource(R.string.settings_zone_save)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(text = stringResource(R.string.setup_cancel)) }
        },
        icon = { Icon(imageVector = FieldTapIcons.Shield, contentDescription = null) },
        title = {
            Text(
                text = stringResource(
                    if (editor.mode == ZoneEditorMode.EDIT) R.string.settings_zone_editor_edit else R.string.settings_zone_editor_new,
                ),
            )
        },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Spacing.Sm),
            ) {
                OutlinedTextField(
                    value = draft.label,
                    onValueChange = { onDraftChange(draft.copy(label = it)) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(text = stringResource(R.string.settings_zone_name)) },
                    supportingText = { Text(text = stringResource(R.string.settings_zone_name_supporting)) },
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
                    singleLine = true,
                )
                OutlinedTextField(
                    value = draft.radius,
                    onValueChange = { onDraftChange(draft.copy(radius = it)) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(text = stringResource(R.string.settings_zone_radius)) },
                    suffix = { Text(text = metresUnit) },
                    supportingText = {
                        Text(
                            text = stringResource(
                                R.string.settings_zone_radius_supporting,
                                SetupFormats.metres(PrivacyZones.MIN_RADIUS_M),
                                SetupFormats.metres(PrivacyZones.MAX_RADIUS_M),
                            ),
                        )
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Next),
                    singleLine = true,
                )
                OutlinedTextField(
                    value = draft.lat,
                    onValueChange = { onDraftChange(draft.copy(lat = it)) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(text = stringResource(R.string.settings_zone_latitude)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.DecimalSigned, imeAction = ImeAction.Next),
                    singleLine = true,
                )
                OutlinedTextField(
                    value = draft.lon,
                    onValueChange = { onDraftChange(draft.copy(lon = it)) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(text = stringResource(R.string.settings_zone_longitude)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.DecimalSigned, imeAction = ImeAction.Done),
                    singleLine = true,
                )
                if (editor.mode == ZoneEditorMode.HERE) PositionStatus(fix = fix, onUsePosition = onUsePosition)
                if (problems.isNotEmpty()) ZoneProblems(problems = problems)
            }
        },
    )
}

@Composable
private fun PositionStatus(fix: FixSample?, onUsePosition: () -> Unit) {
    if (fix == null) {
        Row(
            modifier = Modifier.semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Spacing.Sm),
        ) {
            CircularProgressIndicator(modifier = Modifier.size(Sizes.InlineProgress), strokeWidth = Spacing.Xxs)
            SetupParagraph(text = stringResource(R.string.settings_zone_waiting_fix), modifier = Modifier.weight(1f))
        }
    } else {
        val accuracy = fix.accuracyM?.takeIf { it.isFinite() && it >= 0.0 }
        SetupParagraph(
            text = if (accuracy != null) {
                stringResource(R.string.settings_zone_fix_accuracy, SetupFormats.metres(accuracy))
            } else {
                stringResource(R.string.settings_zone_fix)
            },
        )
        TextButton(
            onClick = onUsePosition,
            contentPadding = ButtonDefaults.TextButtonWithIconContentPadding,
            modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
        ) {
            Icon(imageVector = FieldTapIcons.GpsFixed, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
            Spacer(modifier = Modifier.width(ButtonDefaults.IconSpacing))
            Text(text = stringResource(R.string.settings_zone_use_position))
        }
    }
}

@Composable
private fun ZoneProblems(problems: List<String>) {
    val errorColor = FieldTapDesign.colors.error.color
    Column(
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(Spacing.Xs),
    ) {
        problems.forEach { problem ->
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.Sm)) {
                Icon(
                    imageVector = FieldTapIcons.Error,
                    contentDescription = null,
                    tint = errorColor,
                    modifier = Modifier.size(Sizes.IconSmall),
                )
                Text(text = problem, style = MaterialTheme.typography.bodyMedium, color = errorColor)
            }
        }
    }
}

/** How the zone editor was opened. */
internal enum class ZoneEditorMode {
    /** A new zone centred on the current fix. */
    HERE,

    /** A new zone from typed coordinates. */
    COORDINATES,

    /** An existing zone. */
    EDIT,
}

/** The open zone editor. */
internal data class ZoneEditorState(val mode: ZoneEditorMode, val draft: ZoneDraft)

private const val EDITOR_SAVED_FIELDS = 6

/** Keeps the open editor and what was typed across a rotation. */
private val ZoneEditorStateSaver: Saver<ZoneEditorState?, Any> = listSaver<ZoneEditorState?, String>(
    save = { state ->
        if (state == null) {
            emptyList()
        } else {
            listOf(state.mode.name, state.draft.id.orEmpty(), state.draft.label, state.draft.radius, state.draft.lat, state.draft.lon)
        }
    },
    restore = { values ->
        if (values.size != EDITOR_SAVED_FIELDS) {
            null
        } else {
            ZoneEditorState(
                mode = ZoneEditorMode.valueOf(values[0]),
                draft = ZoneDraft(id = values[1].ifEmpty { null }, label = values[2], radius = values[3], lat = values[4], lon = values[5]),
            )
        }
    },
)

/** The Phone permission facts behind "Instant cell updates", read on each resume and after each request. */
private data class PhoneSnapshot(val granted: Boolean, val rationale: Boolean, val preciseLocation: Boolean) {
    companion object {
        fun read(context: Context, activity: Activity?): PhoneSnapshot = PhoneSnapshot(
            granted = Permissions.phoneGranted(context),
            rationale = activity?.shouldShowRequestPermissionRationale(Permissions.READ_PHONE_STATE) == true,
            preciseLocation = Permissions.preciseLocationGranted(context),
        )
    }
}

@FieldTapPreviews
@Composable
private fun SettingsPreview() {
    PreviewSurface {
        SettingsContent(
            state = SettingsUiState(
                settings = AppSettings(
                    installId = "preview",
                    consent = Consent.record(1_789_050_600_000L),
                    zones = listOf(PrivacyZone(id = "home", label = "Home", lat = 52.520008, lon = 13.404954, radiusM = 200.0)),
                ),
                zoneProblems = emptyList(),
            ),
            loadFailed = false,
            phone = PermissionUi(PermissionStatus.NOT_REQUESTED, PermissionAction.REQUEST),
            preciseLocation = true,
            onRetryLoad = {},
            onOpenTestTargets = {},
            onOpenReadiness = {},
            onOpenAbout = {},
            onOpenProbe = {},
            onTestsDefaultOnChange = {},
            onCaptureProfileChange = {},
            onInstantUpdatesChange = {},
            onAddZoneHere = {},
            onAddZoneByCoordinates = {},
            onEditZone = {},
            onDeleteZone = {},
            onWithdrawConsent = {},
        )
    }
}
