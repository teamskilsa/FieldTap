package com.fieldtap.ui.logs

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.res.stringResource
import com.fieldtap.R
import com.fieldtap.app.SessionStatus
import com.fieldtap.core.session.StartRequest
import com.fieldtap.platform.Permissions
import com.fieldtap.ui.live.LiveViewModel
import com.fieldtap.ui.live.PrestartReview
import com.fieldtap.ui.live.PrestartState
import com.fieldtap.ui.signalling.SignallingViewModel
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.tabular
import java.util.Locale

/**
 * The two things the Logs tab records, above the list of what has been recorded.
 *
 * - **Signal log**: the serving cell, neighbours and position, sampled every time the modem answers,
 *   written as a session. No root, any phone.
 * - **RRC / NAS**: the modem's own call flow through its diagnostic logger. Needs root. When it
 *   finishes it opens itself, since reading it is the reason it was taken.
 *
 * Each is one button that becomes a stop button. No name is asked for — nobody standing at a callbox
 * wants to type one before pressing record, and the log is filed under the time it started.
 *
 * Owner: workstream `ui-session`.
 */
@Composable
fun LogsHeader(
    live: LiveViewModel,
    signalling: SignallingViewModel,
    onOpenCapture: (String) -> Unit,
) {
    val liveState by live.state.collectAsStateWithLifecycle()
    val capture by signalling.state.collectAsStateWithLifecycle()
    val location = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { live.recheckReadiness() }

    LaunchedEffect(capture.justSaved) {
        capture.justSaved?.let { name ->
            signalling.consumeJustSaved()
            onOpenCapture(name)
        }
    }

    val signalName = stringResource(R.string.logs_signal_name)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(bottom = 6.dp)) {
        val status = liveState.status
        val recording = status as? SessionStatus.Recording
        val busy = status is SessionStatus.Starting || status is SessionStatus.Stopping || liveState.prestart is PrestartState.Checking || liveState.prestart is PrestartState.Starting
        RecordCard(
            title = stringResource(R.string.logs_signal_title),
            detail = when {
                recording != null -> stringResource(R.string.logs_signal_running, elapsed(recording.snapshot.elapsedMs), recording.snapshot.freshSamples.toInt())
                else -> stringResource(R.string.logs_signal_detail)
            },
            active = recording != null,
            busy = busy,
            startLabel = stringResource(R.string.logs_signal_start),
            stopLabel = stringResource(R.string.logs_signal_stop),
            onStart = { live.start(StartRequest(name = signalName)) },
            onStop = live::stop,
        )
        RecordCard(
            title = stringResource(R.string.logs_rrc_title),
            badge = stringResource(R.string.logs_root),
            detail = capture.message ?: stringResource(R.string.logs_rrc_detail),
            detailIsError = capture.failed,
            active = capture.capturing,
            busy = capture.busy,
            startLabel = stringResource(R.string.logs_rrc_start),
            stopLabel = stringResource(R.string.logs_rrc_stop),
            onStart = signalling::start,
            onStop = signalling::stop,
        )
    }

    (liveState.prestart as? PrestartState.Review)?.let { review ->
        PrestartReview(review, live) { location.launch(Permissions.LOCATION.toTypedArray()) }
    }
}

@Composable
private fun RecordCard(
    title: String,
    detail: String,
    active: Boolean,
    busy: Boolean,
    startLabel: String,
    stopLabel: String,
    onStart: () -> Unit,
    onStop: () -> Unit,
    badge: String? = null,
    detailIsError: Boolean = false,
) {
    val recordRed = FieldTapDesign.colors.signal.poor.fill
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        border = BorderStroke(1.dp, if (active) recordRed.copy(alpha = 0.7f) else MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (active) {
                    Box(Modifier.size(9.dp).clip(CircleShape).background(recordRed))
                    Spacer(Modifier.size(8.dp))
                }
                Text(
                    title.uppercase(Locale.ROOT),
                    style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 1.2.sp, fontWeight = FontWeight.SemiBold),
                    color = if (active) recordRed else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (badge != null) {
                    Spacer(Modifier.size(8.dp))
                    Surface(shape = RoundedCornerShape(5.dp), color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.16f)) {
                        Text(
                            badge,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp),
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.tertiary,
                        )
                    }
                }
            }
            Text(
                detail,
                style = if (active) MaterialTheme.typography.titleMedium.tabular() else MaterialTheme.typography.bodyMedium,
                color = when {
                    detailIsError -> MaterialTheme.colorScheme.error
                    active -> MaterialTheme.colorScheme.onSurface
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
            Button(
                onClick = if (active) onStop else onStart,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(top = 2.dp),
                shape = RoundedCornerShape(12.dp),
                colors = if (active) {
                    ButtonDefaults.buttonColors(containerColor = recordRed, contentColor = Color.White)
                } else {
                    ButtonDefaults.buttonColors()
                },
            ) { Text(if (active) stopLabel else startLabel) }
        }
    }
}

private fun elapsed(ms: Long): String {
    val total = ms / 1000
    return String.format(Locale.ROOT, "%02d:%02d", total / 60, total % 60)
}

