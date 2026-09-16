package com.fieldtap.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fieldtap.R
import com.fieldtap.core.nettest.TestSettings
import com.fieldtap.ui.components.EmptyState
import com.fieldtap.ui.components.FieldTapPreviews
import com.fieldtap.ui.components.LoadingState
import com.fieldtap.ui.components.PreviewSurface
import com.fieldtap.ui.components.SectionCard
import com.fieldtap.ui.components.SectionDivider
import com.fieldtap.ui.components.StatusBanner
import com.fieldtap.ui.setup.SetupParagraph
import com.fieldtap.ui.setup.SetupScreenScaffold
import com.fieldtap.ui.setup.SetupSubheading
import com.fieldtap.ui.setup.setupContentWidth
import com.fieldtap.ui.theme.FieldTapIcons
import com.fieldtap.ui.theme.ShapeRoles
import com.fieldtap.ui.theme.Sizes
import com.fieldtap.ui.theme.Spacing
import com.fieldtap.ui.theme.StatusTone

/**
 * The ping and download test targets, opened from Settings' "Test targets" row: the ping target, its interval and echoes;
 * the download address, its interval, the cap per download and the budget per session. They change rarely, so they have a
 * screen of their own, with Save pinned in a bar at the bottom. Nothing is saved until Save, and only settings
 * `TestSettingsRules` accepts. Leaving with edits that are not saved, by the top bar or Back, asks whether to discard them.
 *
 * Owner: workstream `ui-setup`.
 */
@Composable
fun TestTargetsScreen(
    viewModel: SettingsViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val loadFailed by viewModel.loadFailed.collectAsStateWithLifecycle()
    val testProblems by viewModel.testProblems.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    val testsSavedText = stringResource(R.string.settings_tests_saved)
    val saveFailedText = stringResource(R.string.settings_save_failed)
    // The fields as typed, null until edited. Held here rather than in the form, so leaving can ask first.
    var testsEdit by rememberSaveable(stateSaver = TestSettingsFormSaver) { mutableStateOf<TestSettingsForm?>(null) }
    var confirmDiscard by rememberSaveable { mutableStateOf(false) }
    val storedTests = state.settings?.tests
    val unsaved = storedTests != null && testsEdit?.hasUnsavedChanges(storedTests) == true
    val leave: () -> Unit = { if (unsaved) confirmDiscard = true else onBack() }
    BackHandler(enabled = unsaved) { confirmDiscard = true }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                SettingsEvent.TestsSaved -> snackbarHostState.showSnackbar(testsSavedText)
                SettingsEvent.SaveFailed -> snackbarHostState.showSnackbar(saveFailedText)
                SettingsEvent.ZoneSaved, is SettingsEvent.ZoneDeleted, SettingsEvent.ConsentWithdrawn -> Unit
            }
        }
    }

    TestTargetsContent(
        tests = storedTests,
        loadFailed = loadFailed,
        rejected = testProblems.isNotEmpty(),
        form = testsEdit,
        onFormChange = { form -> testsEdit = form },
        onSave = viewModel::updateTests,
        onBack = leave,
        onRetryLoad = viewModel::retryLoad,
        modifier = modifier,
        snackbarHostState = snackbarHostState,
    )

    if (confirmDiscard) {
        AlertDialog(
            onDismissRequest = { confirmDiscard = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmDiscard = false
                        testsEdit = null
                        onBack()
                    },
                ) {
                    Text(text = stringResource(R.string.settings_discard_confirm))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDiscard = false }) { Text(text = stringResource(R.string.settings_discard_keep)) }
            },
            icon = { Icon(imageVector = FieldTapIcons.Warning, contentDescription = null) },
            title = { Text(text = stringResource(R.string.settings_discard_title)) },
            text = { Text(text = stringResource(R.string.settings_discard_body)) },
        )
    }
}

/** The Test targets screen without its view model or dialog, for previews. */
@Composable
internal fun TestTargetsContent(
    tests: TestSettings?,
    loadFailed: Boolean,
    rejected: Boolean,
    form: TestSettingsForm?,
    onFormChange: (TestSettingsForm) -> Unit,
    onSave: (TestSettings) -> Unit,
    onBack: () -> Unit,
    onRetryLoad: () -> Unit,
    modifier: Modifier = Modifier,
    snackbarHostState: SnackbarHostState? = null,
) {
    val shown = tests?.let { form ?: TestSettingsForm.from(it) }
    val parsed = if (tests != null && shown != null) shown.parse(tests) else null
    val unsaved = tests != null && shown != null && shown.hasUnsavedChanges(tests)
    SetupScreenScaffold(
        title = stringResource(R.string.settings_test_targets),
        modifier = modifier,
        onBack = onBack,
        snackbarHostState = snackbarHostState,
        bottomBar = {
            if (tests != null) {
                TestTargetsSaveBar(
                    unsaved = unsaved && !rejected,
                    canSave = unsaved && parsed is TestSettingsParse.Valid,
                    onSave = { (parsed as? TestSettingsParse.Valid)?.let { valid -> onSave(valid.settings) } },
                )
            }
        },
    ) {
        if (tests == null || shown == null) {
            item(key = "loading") {
                if (loadFailed) {
                    EmptyState(
                        title = stringResource(R.string.settings_load_failed),
                        icon = FieldTapIcons.Error,
                        tone = StatusTone.ERROR,
                        actionLabel = stringResource(R.string.setup_try_again),
                        onAction = onRetryLoad,
                        modifier = Modifier.setupContentWidth(),
                    )
                } else {
                    LoadingState(message = stringResource(R.string.settings_loading), modifier = Modifier.setupContentWidth())
                }
            }
        } else {
            item(key = "form") {
                TestsForm(
                    form = shown,
                    problems = (parsed as? TestSettingsParse.Invalid)?.problems.orEmpty(),
                    rejected = rejected,
                    onFormChange = onFormChange,
                    modifier = Modifier.setupContentWidth(),
                )
            }
        }
    }
}

@Composable
private fun TestsForm(
    form: TestSettingsForm,
    problems: List<TestSettingsProblem>,
    rejected: Boolean,
    onFormChange: (TestSettingsForm) -> Unit,
    modifier: Modifier,
) {
    val defaults = TestSettingsForm.from(TestSettings())
    val capMb = TestSettingsForm.parseWholeNumber(form.downloadCapMb) ?: 0L
    val secondsUnit = stringResource(R.string.settings_unit_seconds)
    val minutesUnit = stringResource(R.string.settings_unit_minutes)
    val megabytesUnit = stringResource(R.string.settings_unit_megabytes)
    val host = TestSettingsRules.downloadHost(form.downloadUrl)
    // One helper line under the address, naming the host when there is one.
    val downloadSupporting = when {
        form.downloadUrl.isBlank() -> stringResource(R.string.settings_download_off)
        host != null -> stringResource(R.string.settings_download_host, host)
        else -> stringResource(R.string.settings_download_url_supporting)
    }
    SectionCard(modifier = modifier) {
        SetupParagraph(text = stringResource(R.string.settings_tests_network_note))
        SetupSubheading(text = stringResource(R.string.settings_ping_heading))
        TestField(
            value = form.pingTarget,
            onValueChange = { onFormChange(form.copy(pingTarget = it)) },
            label = stringResource(R.string.settings_ping_target),
            problem = problemText(problems, TestSettingsField.PING_TARGET, capMb),
            supportingText = stringResource(R.string.settings_ping_target_supporting),
            keyboardType = KeyboardType.Uri,
        )
        TestField(
            value = form.pingIntervalS,
            onValueChange = { onFormChange(form.copy(pingIntervalS = it)) },
            label = stringResource(R.string.settings_ping_interval),
            problem = problemText(problems, TestSettingsField.PING_INTERVAL, capMb),
            suffix = secondsUnit,
            keyboardType = KeyboardType.Number,
        )
        TestField(
            value = form.pingCount,
            onValueChange = { onFormChange(form.copy(pingCount = it)) },
            label = stringResource(R.string.settings_ping_count),
            problem = problemText(problems, TestSettingsField.PING_COUNT, capMb),
            keyboardType = KeyboardType.Number,
        )
        SectionDivider()
        SetupSubheading(text = stringResource(R.string.settings_download_heading))
        TestField(
            value = form.downloadUrl,
            onValueChange = { onFormChange(form.copy(downloadUrl = it)) },
            label = stringResource(R.string.settings_download_url),
            problem = problemText(problems, TestSettingsField.DOWNLOAD_URL, capMb),
            supportingText = downloadSupporting,
            keyboardType = KeyboardType.Uri,
        )
        TestField(
            value = form.downloadIntervalMin,
            onValueChange = { onFormChange(form.copy(downloadIntervalMin = it)) },
            label = stringResource(R.string.settings_download_interval),
            problem = problemText(problems, TestSettingsField.DOWNLOAD_INTERVAL, capMb),
            suffix = minutesUnit,
            keyboardType = KeyboardType.Number,
        )
        TestField(
            value = form.downloadCapMb,
            onValueChange = { onFormChange(form.copy(downloadCapMb = it)) },
            label = stringResource(R.string.settings_download_cap),
            problem = problemText(problems, TestSettingsField.DOWNLOAD_CAP, capMb),
            suffix = megabytesUnit,
            keyboardType = KeyboardType.Number,
        )
        SectionDivider()
        SetupSubheading(text = stringResource(R.string.settings_upload_heading))
        TestField(
            value = form.uploadUrl,
            onValueChange = { onFormChange(form.copy(uploadUrl = it)) },
            label = stringResource(R.string.settings_upload_url),
            problem = problemText(problems, TestSettingsField.UPLOAD_URL, capMb),
            supportingText = stringResource(R.string.settings_upload_url_supporting),
            keyboardType = KeyboardType.Uri,
        )
        TestField(
            value = form.uploadIntervalMin,
            onValueChange = { onFormChange(form.copy(uploadIntervalMin = it)) },
            label = stringResource(R.string.settings_upload_interval),
            problem = problemText(problems, TestSettingsField.UPLOAD_INTERVAL, capMb),
            suffix = minutesUnit,
            keyboardType = KeyboardType.Number,
        )
        TestField(
            value = form.uploadCapMb,
            onValueChange = { onFormChange(form.copy(uploadCapMb = it)) },
            label = stringResource(R.string.settings_upload_cap),
            problem = problemText(problems, TestSettingsField.UPLOAD_CAP, capMb),
            suffix = megabytesUnit,
            keyboardType = KeyboardType.Number,
        )
        SectionDivider()
        TestField(
            value = form.sessionBudgetMb,
            onValueChange = { onFormChange(form.copy(sessionBudgetMb = it)) },
            label = stringResource(R.string.settings_download_budget),
            problem = problemText(problems, TestSettingsField.SESSION_BUDGET, capMb),
            suffix = megabytesUnit,
            keyboardType = KeyboardType.Number,
            imeAction = ImeAction.Done,
        )
        if (rejected) StatusBanner(message = stringResource(R.string.settings_tests_rejected), tone = StatusTone.ERROR)
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(
                onClick = { onFormChange(defaults) },
                enabled = form != defaults,
                modifier = Modifier.heightIn(min = Sizes.MinTouchTarget),
            ) {
                Text(text = stringResource(R.string.settings_tests_restore))
            }
        }
    }
}

/** Save, pinned under the form and above the keyboard, with a line saying when there are edits to save. */
@Composable
private fun TestTargetsSaveBar(unsaved: Boolean, canSave: Boolean, onSave: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .imePadding()
                .padding(horizontal = Spacing.ScreenGutter, vertical = Spacing.Sm),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Spacing.Md),
        ) {
            if (unsaved) {
                Text(
                    text = stringResource(R.string.settings_tests_unsaved),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            } else {
                Spacer(modifier = Modifier.weight(1f))
            }
            Button(onClick = onSave, enabled = canSave, shape = ShapeRoles.Control, modifier = Modifier.heightIn(min = Sizes.MinTouchTarget)) {
                Text(text = stringResource(R.string.settings_tests_save))
            }
        }
    }
}

@Composable
private fun TestField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    problem: String?,
    keyboardType: KeyboardType,
    supportingText: String? = null,
    suffix: String? = null,
    imeAction: ImeAction = ImeAction.Next,
) {
    val supporting = problem ?: supportingText
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth(),
        label = { Text(text = label) },
        suffix = if (suffix != null) {
            { Text(text = suffix) }
        } else {
            null
        },
        supportingText = if (supporting != null) {
            { Text(text = supporting) }
        } else {
            null
        },
        isError = problem != null,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction),
        singleLine = true,
    )
}

@Composable
private fun problemText(problems: List<TestSettingsProblem>, field: TestSettingsField, capMb: Long): String? {
    val problem = problems.firstOrNull { it.field == field }
    return when (problem?.kind) {
        null -> null
        TestSettingsProblemKind.NOT_A_WHOLE_NUMBER, TestSettingsProblemKind.OUT_OF_RANGE ->
            stringResource(R.string.settings_problem_whole_number, field.displayRange.first, field.displayRange.last)
        TestSettingsProblemKind.INVALID_HOST -> stringResource(R.string.settings_problem_host)
        TestSettingsProblemKind.NOT_HTTPS -> stringResource(R.string.settings_problem_https)
        TestSettingsProblemKind.INVALID_URL -> stringResource(R.string.settings_problem_url)
        TestSettingsProblemKind.BUDGET_BELOW_CAP -> stringResource(R.string.settings_problem_budget, capMb)
    }
}

/**
 * "Ping 10.0.2.2 every 20 s · 1 MB download every 1 min", for the Settings row that opens this screen, with "Ping off" or
 * "Download off" for a test whose target is empty. The numbers are the form's, in its display units.
 */
@Composable
internal fun testTargetsSummary(tests: TestSettings): String {
    val form = TestSettingsForm.from(tests)
    val target = tests.pingTarget.trim()
    val ping = if (target.isEmpty()) {
        stringResource(R.string.settings_test_targets_ping_off)
    } else {
        stringResource(R.string.settings_test_targets_ping, target, form.pingIntervalS)
    }
    val download = if (tests.downloadUrl.isNullOrBlank()) {
        stringResource(R.string.settings_test_targets_download_off)
    } else {
        stringResource(R.string.settings_test_targets_download, form.downloadCapMb, form.downloadIntervalMin)
    }
    return ping + stringResource(R.string.value_separator) + download
}

private const val FORM_SAVED_FIELDS = 10

/** Keeps typed test settings across a rotation; nothing typed (null) saves as an empty list. */
private val TestSettingsFormSaver: Saver<TestSettingsForm?, Any> = listSaver<TestSettingsForm?, String>(
    save = { form ->
        if (form == null) {
            emptyList()
        } else {
            listOf(
                form.pingTarget,
                form.pingIntervalS,
                form.pingCount,
                form.downloadUrl,
                form.downloadIntervalMin,
                form.downloadCapMb,
                form.uploadUrl,
                form.uploadIntervalMin,
                form.uploadCapMb,
                form.sessionBudgetMb,
            )
        }
    },
    restore = { values ->
        if (values.size != FORM_SAVED_FIELDS) {
            null
        } else {
            TestSettingsForm(
                values[0], values[1], values[2], values[3], values[4],
                values[5], values[6], values[7], values[8], values[9],
            )
        }
    },
)

@FieldTapPreviews
@Composable
private fun TestTargetsPreview() {
    PreviewSurface {
        TestTargetsContent(
            tests = TestSettings(),
            loadFailed = false,
            rejected = false,
            form = null,
            onFormChange = {},
            onSave = {},
            onBack = {},
            onRetryLoad = {},
        )
    }
}
