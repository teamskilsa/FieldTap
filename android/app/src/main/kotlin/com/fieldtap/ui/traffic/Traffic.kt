package com.fieldtap.ui.traffic

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fieldtap.R
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import com.fieldtap.core.nettest.IperfDirection
import com.fieldtap.core.nettest.IperfProtocol
import com.fieldtap.nettest.IperfVersion
import com.fieldtap.ui.components.FieldTapTopBar
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.tabular
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The Traffic tab: iperf3 and ping against a server the user names — in a lab, the callbox.
 *
 * Everything goes out on the cellular network, never the Wi-Fi the phone is probably also on. The top
 * line says whether there is a cellular data bearer at all and what address the phone has on it,
 * because "attached but no PDN" is the most common reason a lab traffic test fails, and it fails
 * before any server is involved.
 *
 * Owner: workstream `service-and-tests`.
 */
@Composable
fun TrafficScreen(viewModel: TrafficViewModel, modifier: Modifier = Modifier) {
    val s by viewModel.state.collectAsStateWithLifecycle()
    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        topBar = { FieldTapTopBar(title = stringResource(R.string.nav_traffic), actions = { LinkBadge(s) }) },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (!s.link.up) item(key = "nobearer") { NoBearer() }
            item(key = "server") { ServerPanel(s, viewModel) }
            item(key = "mode") {
                Segmented(
                    options = listOf(
                        TrafficMode.IPERF2 to stringResource(R.string.traffic_iperf2),
                        TrafficMode.IPERF3 to stringResource(R.string.traffic_iperf),
                        TrafficMode.PING to stringResource(R.string.traffic_ping),
                    ),
                    selected = s.mode,
                    enabled = !s.running,
                    onSelect = viewModel::setMode,
                )
            }
            item(key = "options") {
                when (s.mode) {
                    TrafficMode.IPERF3, TrafficMode.IPERF2 -> IperfOptions(s, viewModel)
                    TrafficMode.PING -> PingOptions(s, viewModel)
                }
            }
            item(key = "go") { StartStop(s, viewModel) }
            s.sampled?.let { run -> if (s.running || s.samples.isNotEmpty()) item(key = "live") { LivePanel(s, run) } }
            s.error?.let { item(key = "error") { ErrorPanel(it) } }
            s.result?.let { item(key = "result") { ResultPanel(it) } }
            if (s.history.size > 1) {
                item(key = "history-title") { SectionTitle(stringResource(R.string.traffic_history)) }
                items(s.history.drop(1), key = { it.finishedAtMs }) { HistoryRow(it) }
            }
        }
    }
}

// MARK: - Link

@Composable
private fun LinkBadge(s: TrafficUiState) {
    val up = s.link.up
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(end = 12.dp)) {
        Box(
            Modifier.size(8.dp).clip(CircleShape)
                .background(if (up) FieldTapDesign.colors.signal.excellent.fill else MaterialTheme.colorScheme.error),
        )
        Text(
            text = if (up) (s.link.ipv4 ?: stringResource(R.string.traffic_cellular)) else stringResource(R.string.traffic_no_data),
            modifier = Modifier.padding(start = 6.dp),
            style = MaterialTheme.typography.labelMedium.tabular(),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun NoBearer() {
    Panel(accent = MaterialTheme.colorScheme.error) {
        Text(stringResource(R.string.traffic_no_bearer_title), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
        Text(
            stringResource(R.string.traffic_no_bearer),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// MARK: - Inputs

@Composable
private fun ServerPanel(s: TrafficUiState, vm: TrafficViewModel) {
    Panel(title = stringResource(R.string.traffic_server)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
            OutlinedTextField(
                value = s.host,
                onValueChange = vm::setHost,
                label = { Text(stringResource(R.string.traffic_host)) },
                placeholder = { Text(stringResource(R.string.traffic_host_hint)) },
                singleLine = true,
                enabled = !s.running,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next, autoCorrectEnabled = false),
                textStyle = MaterialTheme.typography.bodyLarge.tabular(),
                modifier = Modifier.weight(1f),
            )
            if (s.mode != TrafficMode.PING) {
                OutlinedTextField(
                    value = s.port,
                    onValueChange = vm::setPort,
                    label = { Text(stringResource(R.string.traffic_port)) },
                    singleLine = true,
                    enabled = !s.running,
                    isError = s.port.isNotEmpty() && s.portNumber == null,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                    textStyle = MaterialTheme.typography.bodyLarge.tabular(),
                    modifier = Modifier.width(96.dp),
                )
            }
        }
    }
}

@Composable
private fun IperfOptions(s: TrafficUiState, vm: TrafficViewModel) {
    Panel {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Segmented(
                options = listOf(IperfDirection.DOWNLOAD to stringResource(R.string.traffic_download), IperfDirection.UPLOAD to stringResource(R.string.traffic_upload)),
                selected = s.direction,
                enabled = !s.running,
                onSelect = vm::setDirection,
                modifier = Modifier.weight(1.4f),
            )
            Segmented(
                options = listOf(IperfProtocol.TCP to "TCP", IperfProtocol.UDP to "UDP"),
                selected = s.protocol,
                enabled = !s.running,
                onSelect = vm::setProtocol,
                modifier = Modifier.weight(1f),
            )
        }
        OptionRow(stringResource(R.string.traffic_duration)) {
            val secondsLabel = stringResource(R.string.traffic_seconds)
            Chips(listOf(5, 10, 30, 60), s.durationSec, { secondsLabel.format(it) }, !s.running, vm::setDuration)
        }
        OptionRow(stringResource(R.string.traffic_streams)) {
            Chips(listOf(1, 2, 4, 8), s.parallel, { "$it" }, !s.running, vm::setParallel)
        }
        if (s.protocol == IperfProtocol.UDP) {
            OptionRow(stringResource(R.string.traffic_bitrate)) {
                OutlinedTextField(
                    value = s.udpMbps,
                    onValueChange = vm::setUdpMbps,
                    suffix = { Text(stringResource(R.string.traffic_mbps)) },
                    singleLine = true,
                    enabled = !s.running,
                    isError = s.udpBitrateBps == null,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    textStyle = MaterialTheme.typography.bodyLarge.tabular(),
                    modifier = Modifier.width(150.dp),
                )
            }
        }
    }
}

@Composable
private fun PingOptions(s: TrafficUiState, vm: TrafficViewModel) {
    Panel {
        OptionRow(stringResource(R.string.traffic_echoes)) {
            Chips(listOf(5, 10, 30, 100), s.pingCount, { "$it" }, !s.running, vm::setPingCount)
        }
    }
}

@Composable
private fun StartStop(s: TrafficUiState, vm: TrafficViewModel) {
    if (s.running) {
        Button(
            onClick = vm::stop,
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError),
            shape = RoundedCornerShape(14.dp),
        ) { Text(stringResource(R.string.traffic_stop), style = MaterialTheme.typography.titleMedium) }
    } else {
        Button(
            onClick = vm::start,
            enabled = s.canStart,
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
            shape = RoundedCornerShape(14.dp),
        ) { Text(startLabel(s), style = MaterialTheme.typography.titleMedium) }
    }
}

@Composable
private fun startLabel(s: TrafficUiState): String = when (s.mode) {
    TrafficMode.PING -> if (s.host.isBlank()) stringResource(R.string.traffic_start_ping_blank) else stringResource(R.string.traffic_start_ping, s.host)
    TrafficMode.IPERF3, TrafficMode.IPERF2 -> stringResource(
        if (s.direction == IperfDirection.DOWNLOAD) R.string.traffic_start_download else R.string.traffic_start_upload,
        s.protocol.name,
    )
}

// MARK: - Live and results

@Composable
private fun LivePanel(s: TrafficUiState, run: SampledRun) {
    val iperf = run.mode != TrafficMode.PING
    val latest = s.samples.lastOrNull()
    Panel(title = stringResource(if (iperf) R.string.traffic_throughput else R.string.traffic_round_trip)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = when {
                    latest == null && !iperf && s.samples.isNotEmpty() -> stringResource(R.string.traffic_lost)
                    latest == null -> "—"
                    iperf -> fmt(latest, if (latest < 10) 2 else 1)
                    else -> fmt(latest, 1)
                },
                style = MaterialTheme.typography.displayMedium.tabular().copy(fontWeight = FontWeight.SemiBold, fontSize = 56.sp),
                color = MaterialTheme.colorScheme.primary,
            )
            Text(
                stringResource(if (iperf) R.string.traffic_mbps else R.string.traffic_ms),
                modifier = Modifier.padding(start = 8.dp, bottom = 12.dp),
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.weight(1f))
            Text(
                text = if (iperf) stringResource(R.string.traffic_progress_seconds, s.samples.size, run.slots) else stringResource(R.string.traffic_progress, s.samples.size, run.slots),
                modifier = Modifier.padding(bottom = 14.dp),
                style = MaterialTheme.typography.labelLarge.tabular(),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Bars(
            values = s.samples,
            slots = run.slots,
            color = MaterialTheme.colorScheme.primary,
            lostColor = MaterialTheme.colorScheme.error,
        )
    }
}

/**
 * One bar per second (or per echo), laid out across the whole test from the start, so the chart grows
 * left to right instead of rescaling its x-axis every second. A lost echo is a short red tick.
 */
@Composable
private fun Bars(values: List<Double?>, slots: Int, color: Color, lostColor: Color) {
    val grid = MaterialTheme.colorScheme.outlineVariant
    Canvas(modifier = Modifier.fillMaxWidth().height(110.dp).padding(top = 6.dp)) {
        val count = maxOf(slots, values.size, 1)
        val gap = 2.dp.toPx()
        val barWidth = ((size.width - gap * (count - 1)) / count).coerceAtLeast(1f)
        val peak = (values.filterNotNull().maxOrNull() ?: 1.0).coerceAtLeast(0.001)
        drawLine(grid, Offset(0f, size.height), Offset(size.width, size.height), strokeWidth = 1.dp.toPx())
        drawLine(grid, Offset(0f, size.height / 2), Offset(size.width, size.height / 2), strokeWidth = 1f)
        values.forEachIndexed { index, value ->
            val x = index * (barWidth + gap)
            if (value == null) {
                val tick = 6.dp.toPx()
                drawRoundRect(lostColor, Offset(x, size.height - tick), Size(barWidth, tick), CornerRadius(2f, 2f))
            } else {
                val h = (value / peak * size.height * 0.95).toFloat().coerceAtLeast(2f)
                drawRoundRect(color, Offset(x, size.height - h), Size(barWidth, h), CornerRadius(3f, 3f))
            }
        }
    }
}

@Composable
private fun ResultPanel(result: TrafficResult) {
    when (result) {
        is TrafficResult.Iperf -> {
            val o = result.options
            val title = versionName(result.version) + " · " + pluralStringResource(
                R.plurals.traffic_result_title,
                o.parallel,
                stringResource(if (o.direction == IperfDirection.DOWNLOAD) R.string.traffic_download else R.string.traffic_upload),
                o.protocol.name,
                o.parallel,
            )
            Panel(title = stringResource(R.string.traffic_result)) {
                Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(vertical = 4.dp)) {
                    Text(fmt(result.mbps, 1), style = MaterialTheme.typography.displaySmall.tabular().copy(fontWeight = FontWeight.SemiBold), color = MaterialTheme.colorScheme.onSurface)
                    Text(" " + stringResource(R.string.traffic_mbps_average), modifier = Modifier.padding(bottom = 6.dp), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                val rows = buildList {
                    add(stringResource(R.string.traffic_peak) to "${fmt(result.peakMbps, 1)} " + stringResource(R.string.traffic_mbps))
                    add(stringResource(R.string.traffic_duration) to "${fmt(result.seconds, 1)} s")
                    // A count the far end did not report is shown as unknown, never as a guess.
                    add(stringResource(R.string.traffic_received) to (result.receivedBytes?.let(::bytes) ?: "—"))
                    add(stringResource(R.string.traffic_sent) to (result.sentBytes?.let(::bytes) ?: "—"))
                    if (o.protocol == IperfProtocol.UDP) {
                        add(stringResource(R.string.traffic_jitter) to (result.jitterMs?.let { "${fmt(it, 2)} ms" } ?: "—"))
                        add(stringResource(R.string.traffic_loss) to (result.lossPercent?.let { "${fmt(it, 2)} %  (${result.lostPackets}/${result.packets})" } ?: "—"))
                    }
                }
                Grid(rows)
            }
        }

        is TrafficResult.Ping -> Panel(title = stringResource(R.string.traffic_result)) {
            Text(stringResource(R.string.traffic_ping_to, result.host), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(vertical = 4.dp)) {
                Text(result.avgMs?.let { fmt(it, 1) } ?: "—", style = MaterialTheme.typography.displaySmall.tabular().copy(fontWeight = FontWeight.SemiBold), color = MaterialTheme.colorScheme.onSurface)
                Text(" " + stringResource(R.string.traffic_ms_average), modifier = Modifier.padding(bottom = 6.dp), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Grid(
                listOf(
                    stringResource(R.string.traffic_min) to (result.minMs?.let { "${fmt(it, 1)} ms" } ?: "—"),
                    stringResource(R.string.traffic_max) to (result.maxMs?.let { "${fmt(it, 1)} ms" } ?: "—"),
                    stringResource(R.string.traffic_mdev) to (result.mdevMs?.let { "${fmt(it, 1)} ms" } ?: "—"),
                    stringResource(R.string.traffic_loss) to "${fmt(result.lossPercent, 0)} %  (${result.sent - result.received}/${result.sent})",
                ),
            )
        }
    }
}

@Composable
private fun ErrorPanel(message: String) {
    Panel(accent = MaterialTheme.colorScheme.error) {
        Text(stringResource(R.string.traffic_did_not_run), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.error)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
private fun HistoryRow(result: TrafficResult) {
    val time = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date(result.finishedAtMs))
    val (what, value) = when (result) {
        is TrafficResult.Iperf -> {
            val o = result.options
            "${versionName(result.version)} ${stringResource(if (o.direction == IperfDirection.DOWNLOAD) R.string.traffic_dl else R.string.traffic_ul)} ${o.protocol.name} ×${o.parallel}" to "${fmt(result.mbps, 1)} " + stringResource(R.string.traffic_mbps)
        }

        is TrafficResult.Ping -> stringResource(R.string.traffic_ping_to, result.host) to "${result.avgMs?.let { fmt(it, 1) } ?: "—"} ms · ${fmt(result.lossPercent, 0)}%"
    }
    Panel {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(time, style = MaterialTheme.typography.labelMedium.tabular(), color = MaterialTheme.colorScheme.outline, modifier = Modifier.width(72.dp))
            Text(what, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(value, style = MaterialTheme.typography.titleSmall.tabular(), color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

// MARK: - Pieces

@Composable
private fun Grid(rows: List<Pair<String, String>>) {
    rows.chunked(2).forEachIndexed { index, pair ->
        if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        Row(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
            pair.forEach { (label, value) ->
                Column(Modifier.weight(1f)) {
                    Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(value, style = MaterialTheme.typography.titleMedium.tabular(), color = MaterialTheme.colorScheme.onSurface)
                }
            }
            if (pair.size == 1) Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun OptionRow(label: String, content: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(top = 10.dp)) {
        Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(76.dp))
        content()
    }
}

@Composable
private fun <T> Chips(options: List<T>, selected: T, label: (T) -> String, enabled: Boolean, onSelect: (T) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        options.forEach { option ->
            val on = option == selected
            Surface(
                onClick = { onSelect(option) },
                enabled = enabled,
                shape = RoundedCornerShape(8.dp),
                color = if (on) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
                border = BorderStroke(1.dp, if (on) MaterialTheme.colorScheme.primary.copy(alpha = 0.6f) else MaterialTheme.colorScheme.outlineVariant),
            ) {
                Text(
                    label(option),
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.labelLarge.tabular(),
                    color = if (on) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** A row of equal segments; the chosen one lit in the accent. */
@Composable
private fun <T> Segmented(
    options: List<Pair<T, String>>,
    selected: T,
    enabled: Boolean,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Row(Modifier.padding(4.dp)) {
            options.forEach { (value, text) ->
                val on = value == selected
                Surface(
                    onClick = { onSelect(value) },
                    enabled = enabled,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(9.dp),
                    color = if (on) MaterialTheme.colorScheme.primaryContainer else Color.Transparent,
                ) {
                    Text(
                        text,
                        modifier = Modifier.padding(vertical = 10.dp),
                        style = MaterialTheme.typography.labelLarge.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium),
                        color = if (on) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text.uppercase(Locale.ROOT),
        modifier = Modifier.padding(start = 4.dp, top = 6.dp),
        style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 1.2.sp, fontWeight = FontWeight.SemiBold),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun Panel(title: String? = null, accent: Color? = null, content: @Composable () -> Unit) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        border = BorderStroke(1.dp, accent?.copy(alpha = 0.5f) ?: MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (title != null) {
                Text(
                    title.uppercase(Locale.ROOT),
                    style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 1.2.sp, fontWeight = FontWeight.SemiBold),
                    color = accent ?: MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            content()
        }
    }
}

@Composable
private fun versionName(version: IperfVersion): String =
    stringResource(if (version == IperfVersion.V2) R.string.traffic_iperf2 else R.string.traffic_iperf)

private fun fmt(value: Double, decimals: Int): String = String.format(Locale.ROOT, "%.${decimals}f", value)

private fun bytes(value: Long): String = when {
    value >= 1_000_000_000 -> "${fmt(value / 1e9, 2)} GB"
    value >= 1_000_000 -> "${fmt(value / 1e6, 1)} MB"
    value >= 1_000 -> "${fmt(value / 1e3, 0)} kB"
    else -> "$value B"
}
