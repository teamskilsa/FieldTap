package com.fieldtap.ui.signal

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fieldtap.R
import com.fieldtap.core.input.ListenerOutcome
import com.fieldtap.core.input.RadioListener
import com.fieldtap.core.input.ServiceRegState
import com.fieldtap.core.live.LiveCell
import com.fieldtap.core.live.LiveState
import com.fieldtap.core.radio.ServingCellSelector
import com.fieldtap.core.radio.Spectrum
import com.fieldtap.core.readiness.SettingsTarget
import com.fieldtap.format.Rat
import com.fieldtap.platform.Permissions
import com.fieldtap.ui.common.SystemSettings
import com.fieldtap.ui.components.ChartMath
import com.fieldtap.ui.components.FieldTapTopBar
import com.fieldtap.ui.components.SignalBars
import com.fieldtap.ui.live.LivePresentation
import com.fieldtap.ui.live.LiveViewModel
import com.fieldtap.ui.live.NeighbourRow
import com.fieldtap.ui.live.SignalChart
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.SignalMetric
import com.fieldtap.ui.theme.SignalQuality
import com.fieldtap.ui.theme.SignalScale
import com.fieldtap.ui.theme.tabular
import java.util.Locale

/**
 * The Signal tab: one scroll an RF engineer reads top to bottom, the way LTE Discovery lays it out.
 *
 * The serving cell's RSRP first and large, then its trend, then everything that identifies it — PCI,
 * channel, the frequency that channel is, eNB and cell, tracking area, bandwidth, timing advance —
 * and last the cells around it, strongest first, each against the serving cell.
 *
 * What is not here, on purpose:
 * - Session controls. Recording is a job for the Logs tab; this screen is a meter.
 * - RSRQ and SINR tiles. On the bench they added two cards that said little the RSRP did not, and an
 *   idle modem does not report SINR at all. Both are still written to every log.
 * - A view switcher. Three views of one cell hid two of them; a dashboard shows its data.
 *
 * Owner: workstream `ui-session`.
 */
@Composable
fun SignalScreen(viewModel: LiveViewModel, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val live = state.live
    val context = LocalContext.current
    val locationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        viewModel.recheckReadiness()
    }
    val locationMissing = live.listeners[RadioListener.CELL_INFO_REQUEST] == ListenerOutcome.MISSING_PERMISSION

    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            FieldTapTopBar(
                title = stringResource(R.string.sig_title),
                actions = { live.servingAgeMs?.let { LiveDot(ageMs = it) } },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            when {
                locationMissing -> item(key = "perm") {
                    Notice(
                        title = stringResource(R.string.sig_location_needed_title),
                        message = stringResource(R.string.sig_location_needed),
                        action = stringResource(R.string.sig_location_allow),
                        onAction = { locationPermission.launch(Permissions.LOCATION.toTypedArray()) },
                    )
                }

                state.locationOff -> item(key = "locoff") {
                    Notice(
                        title = stringResource(R.string.sig_location_off_title),
                        message = stringResource(R.string.sig_location_off),
                        action = stringResource(R.string.sig_location_turn_on),
                        onAction = { SystemSettings.open(context, SettingsTarget.LOCATION_SOURCE) },
                    )
                }
            }

            val serving = live.serving
            if (serving == null) {
                item(key = "nocell") { NoCell(live) }
            } else {
                item(key = "hero") { Hero(serving, live) }
                item(key = "chart") {
                    // No panel title: the chart heads itself with "RSRP · last 5 min" and the latest value.
                    Panel {
                        SignalChart(
                            rsrp = live.rsrpSeries,
                            sinr = emptyList(),
                            nowElapsedMs = live.nowElapsedMs,
                            gapThresholdMs = ChartMath.gapThresholdMs(live.shortInterval),
                            compact = true,
                            showSinr = false,
                        )
                    }
                }
                item(key = "cell") { ServingDetails(serving) }
                live.nsaLeg?.let { leg -> item(key = "nr") { NrLeg(leg) } }
                item(key = "neighbours") { Neighbours(LivePresentation.neighbourRows(live)) }
            }
        }
    }
}

// MARK: - The serving cell

/** RAT and band, the operator, and the RSRP as big as the screen allows, on its scale. */
@Composable
private fun Hero(cell: LiveCell, live: LiveState) {
    val quality = SignalScale.quality(SignalMetric.RSRP, cell.rsrp)
    val level = FieldTapDesign.colors.signal.of(quality)
    val stale = live.servingAgeMs != null && live.servingAgeMs!! > STALE_AFTER_MS
    Panel {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Tag(text = ratName(cell.rat), color = ratColor(cell.rat))
            bandLabel(cell)?.let { Tag(text = it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End) {
                Text(
                    text = live.service?.operatorAlphaLong?.takeIf { it.isNotBlank() } ?: cell.operator ?: "—",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                cell.plmn?.let {
                    Text(
                        text = formatPlmn(it),
                        style = MaterialTheme.typography.labelMedium.tabular(),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            val rsrpText = cell.rsrp?.toString() ?: "—"
            Text(
                text = rsrpText,
                style = MaterialTheme.typography.displayLarge.tabular().copy(fontSize = 72.sp, fontWeight = FontWeight.SemiBold),
                color = if (stale || quality == null) MaterialTheme.colorScheme.onSurfaceVariant else level.content,
                modifier = Modifier.clearAndSetSemantics {
                    contentDescription = "RSRP $rsrpText dBm"
                },
            )
            Column(modifier = Modifier.padding(start = 8.dp, bottom = 14.dp)) {
                Text(stringResource(R.string.sig_dbm), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    text = stringResource(R.string.sig_rsrp) + (quality?.let { " · " + qualityWord(it) } ?: ""),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.weight(1f))
            Box(modifier = Modifier.padding(bottom = 16.dp)) { SignalBars(quality = quality) }
        }
        RsrpMeter(rsrp = cell.rsrp)
        if (stale) {
            Text(
                text = stringResource(R.string.sig_stale, seconds(live.servingAgeMs!!)),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }
    }
}

/**
 * The RSRP on its scale: four zones from poor to excellent and a marker at the value. A number alone
 * does not say whether -97 is a problem; its place on the bar does.
 */
@Composable
private fun RsrpMeter(rsrp: Int?) {
    val range = SignalScale.RSRP_BAR_RANGE
    val zones = SignalScale.zones(SignalMetric.RSRP, range)
    val colors = FieldTapDesign.colors.signal
    val span = (range.last - range.first).toFloat()
    BoxWithConstraints(modifier = Modifier.fillMaxWidth().height(22.dp)) {
        val width = maxWidth
        Row(
            modifier = Modifier.fillMaxWidth().height(6.dp).align(Alignment.Center).clip(RoundedCornerShape(3.dp)),
        ) {
            zones.forEach { zone ->
                val fraction = (zone.to - zone.from) / span
                Box(
                    modifier = Modifier
                        .weight(fraction.coerceAtLeast(0.001f))
                        .fillMaxHeight()
                        .background(colors.of(zone.quality).fill.copy(alpha = 0.55f)),
                )
            }
        }
        if (rsrp != null) {
            val position = ((rsrp.coerceIn(range) - range.first) / span).coerceIn(0f, 1f)
            Box(
                modifier = Modifier
                    .offset(x = width * position - 2.dp)
                    .width(4.dp)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(2.dp))
                    .background(MaterialTheme.colorScheme.onSurface),
            )
        }
    }
    Row(modifier = Modifier.fillMaxWidth()) {
        Text("${range.first}", style = MaterialTheme.typography.labelSmall.tabular(), color = MaterialTheme.colorScheme.outline)
        Spacer(Modifier.weight(1f))
        Text("${range.last}", style = MaterialTheme.typography.labelSmall.tabular(), color = MaterialTheme.colorScheme.outline)
    }
}

/** Everything that identifies the serving cell, two columns of label and value. */
@Composable
private fun ServingDetails(cell: LiveCell) {
    val rows = buildList {
        add(stringResource(R.string.sig_pci) to (cell.pci?.toString() ?: "—"))
        if (cell.rat == Rat.NR) {
            add(stringResource(R.string.sig_nrarfcn) to (cell.arfcn?.toString() ?: "—"))
            add(stringResource(R.string.sig_frequency) to (Spectrum.nrMhz(cell.arfcn)?.let { mhz(it, 2) } ?: "—"))
        } else {
            val carrier = Spectrum.lte(cell.arfcn)
            add(stringResource(R.string.sig_earfcn) to (cell.arfcn?.toString() ?: "—"))
            add(stringResource(R.string.sig_dl) to (carrier?.let { mhz(it.dlMhz, 1) } ?: "—"))
            add(stringResource(R.string.sig_ul) to (carrier?.ulMhz?.let { mhz(it, 1) + if (carrier.tdd) " · TDD" else "" } ?: "—"))
            val id = Spectrum.lteCellId(cell.cellId)
            add(stringResource(R.string.sig_enb) to (id?.enb?.toString() ?: "—"))
            add(stringResource(R.string.sig_cell) to (id?.cell?.toString() ?: "—"))
            add(stringResource(R.string.sig_eci) to (cell.cellId?.takeIf { id != null }?.toString() ?: "—"))
        }
        add(stringResource(R.string.sig_tac) to (cell.tac?.takeIf { it in 0..0xFFFFFF }?.toString() ?: "—"))
        add(stringResource(R.string.sig_bandwidth) to (cell.bandwidthKhz?.takeIf { it in 1..400_000 }?.let { mhz(it / 1000.0, 1) } ?: "—"))
        add(stringResource(R.string.sig_rssi) to (cell.rssi?.takeIf { it in -140..-10 }?.let { "$it dBm" } ?: "—"))
        if (cell.rat == Rat.LTE) {
            val metres = Spectrum.lteTimingAdvanceMetres(cell.timingAdvance)
            add(stringResource(R.string.sig_ta) to (if (metres != null) stringResource(R.string.sig_ta_value, cell.timingAdvance!!, metres.toInt()) else "—"))
        }
        add(stringResource(R.string.sig_cqi) to (cell.cqi?.takeIf { it in 0..15 }?.toString() ?: "—"))
    }
    Panel(title = stringResource(R.string.sig_serving_cell)) { KeyValueGrid(rows) }
}

@Composable
private fun NrLeg(leg: LiveCell) {
    val rows = listOf(
        stringResource(R.string.sig_pci) to (leg.pci?.toString() ?: "—"),
        stringResource(R.string.sig_nrarfcn) to (leg.arfcn?.toString() ?: "—"),
        stringResource(R.string.sig_frequency) to (Spectrum.nrMhz(leg.arfcn)?.let { mhz(it, 2) } ?: "—"),
        stringResource(R.string.sig_band) to (leg.band?.let { "n$it" } ?: "—"),
        "SS-RSRP" to (leg.rsrp?.let { "$it dBm" } ?: "—"),
    )
    Panel(title = stringResource(R.string.sig_nr_leg), accent = ratColor(Rat.NR)) { KeyValueGrid(rows) }
}

/** Two columns of label over value. The values are the point, so they are the larger, brighter text. */
@Composable
private fun KeyValueGrid(rows: List<Pair<String, String>>) {
    rows.chunked(2).forEachIndexed { index, pair ->
        if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        Row(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
            pair.forEach { (label, value) ->
                Column(modifier = Modifier.weight(1f)) {
                    Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(
                        value,
                        style = MaterialTheme.typography.titleMedium.tabular(),
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (pair.size == 1) Spacer(Modifier.weight(1f))
        }
    }
}

// MARK: - Neighbours

/**
 * The cells around this one, strongest first. Each says how it compares with the serving cell, since
 * that — not its own RSRP — is what makes a neighbour matter: a cell 4 dB stronger than the one the
 * phone is on is a handover waiting to happen.
 */
@Composable
private fun Neighbours(rows: List<NeighbourRow>) {
    val sorted = rows.sortedByDescending { it.cell.rsrp ?: Int.MIN_VALUE }
    Panel(title = stringResource(R.string.sig_neighbours), count = rows.size) {
        if (sorted.isEmpty()) {
            Text(
                stringResource(R.string.sig_neighbours_none),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        sorted.forEachIndexed { index, row ->
            if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            NeighbourLine(row)
        }
    }
}

@Composable
private fun NeighbourLine(row: NeighbourRow) {
    val cell = row.cell
    val quality = SignalScale.quality(SignalMetric.RSRP, cell.rsrp)
    val level = FieldTapDesign.colors.signal.of(quality)
    val frequency = if (cell.rat == Rat.NR) Spectrum.nrMhz(cell.arfcn)?.let { mhz(it, 1) } else Spectrum.lte(cell.arfcn)?.let { mhz(it.dlMhz, 1) }
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SignalBars(quality = quality)
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "PCI ${cell.pci ?: "—"}  ·  ${if (cell.rat == Rat.NR) "ARFCN" else "EARFCN"} ${cell.arfcn ?: "—"}",
                style = MaterialTheme.typography.titleSmall.tabular(),
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = listOfNotNull(ratName(cell.rat), bandLabel(cell), frequency).joinToString("  ·  "),
                style = MaterialTheme.typography.labelMedium.tabular(),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
            if (row.pciReuse.contains(3)) {
                Text(
                    stringResource(R.string.sig_same_pci_mod3),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(
                text = cell.rsrp?.let { "$it" } ?: "—",
                style = MaterialTheme.typography.titleMedium.tabular().copy(fontWeight = FontWeight.SemiBold),
                color = level.content,
            )
            MarginText(row.marginDb)
        }
    }
}

/** "4 dB stronger" in the accent when the neighbour beats the serving cell; quiet otherwise. */
@Composable
private fun MarginText(servingMinusNeighbour: Int?) {
    if (servingMinusNeighbour == null) return
    val (text, color) = when {
        servingMinusNeighbour < 0 -> stringResource(R.string.sig_stronger, -servingMinusNeighbour) to MaterialTheme.colorScheme.primary
        servingMinusNeighbour > 0 -> stringResource(R.string.sig_weaker, servingMinusNeighbour) to MaterialTheme.colorScheme.onSurfaceVariant
        else -> stringResource(R.string.sig_equal) to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Text(text, style = MaterialTheme.typography.labelSmall.tabular(), color = color)
}

// MARK: - Nothing to show

@Composable
private fun NoCell(live: LiveState) {
    val service = live.service
    val message = when {
        service != null && ServingCellSelector.isEmergencyOnly(service) -> stringResource(R.string.sig_emergency_only)
        service != null && (service.state == ServiceRegState.OUT_OF_SERVICE || service.state == ServiceRegState.POWER_OFF) ->
            stringResource(R.string.sig_out_of_service)
        else -> stringResource(R.string.sig_waiting)
    }
    Panel {
        Text(stringResource(R.string.sig_no_cell_title), style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurface)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Notice(title: String, message: String, action: String, onAction: () -> Unit) {
    Panel(accent = MaterialTheme.colorScheme.error) {
        Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        androidx.compose.material3.FilledTonalButton(onClick = onAction, modifier = Modifier.padding(top = 4.dp)) { Text(action) }
    }
}

// MARK: - Pieces

/**
 * The one container on this screen: a flat dark panel with a hairline and a small uppercase title.
 * No shadow — on a near-black ground a shadow is invisible and a hairline is what separates things.
 */
@Composable
private fun Panel(
    title: String? = null,
    count: Int? = null,
    accent: Color? = null,
    content: @Composable () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        border = androidx.compose.foundation.BorderStroke(1.dp, accent?.copy(alpha = 0.45f) ?: MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (title != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        title.uppercase(Locale.ROOT),
                        style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 1.2.sp, fontWeight = FontWeight.SemiBold),
                        color = accent ?: MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (count != null) {
                        Text(
                            "  $count",
                            style = MaterialTheme.typography.labelMedium.tabular(),
                            color = MaterialTheme.colorScheme.outline,
                        )
                    }
                }
            }
            content()
        }
    }
}

@Composable
private fun Tag(text: String, color: Color) {
    Surface(shape = RoundedCornerShape(6.dp), color = color.copy(alpha = 0.14f)) {
        Text(
            text,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
            style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
            color = color,
        )
    }
}

/** A green dot and the age of the newest reading, so a frozen number is never mistaken for a live one. */
@Composable
private fun LiveDot(ageMs: Long) {
    val fresh = ageMs <= STALE_AFTER_MS
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(end = 12.dp)) {
        Box(
            Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(if (fresh) FieldTapDesign.colors.signal.excellent.fill else MaterialTheme.colorScheme.error),
        )
        Text(
            stringResource(R.string.sig_age, seconds(ageMs)),
            modifier = Modifier.padding(start = 6.dp),
            style = MaterialTheme.typography.labelMedium.tabular(),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ratColor(rat: Rat): Color = when (rat) {
    Rat.NR -> MaterialTheme.colorScheme.tertiary
    else -> MaterialTheme.colorScheme.primary
}

private fun ratName(rat: Rat): String = when (rat) {
    Rat.LTE -> "LTE"
    Rat.NR -> "5G NR"
    else -> rat.name
}

/** The reported band, or the one the channel number implies when the modem left it out. */
private fun bandLabel(cell: LiveCell): String? {
    if (cell.rat == Rat.NR) return cell.band?.let { "n$it" }
    val band = cell.band ?: Spectrum.lte(cell.arfcn)?.band
    return band?.let { "B$it" }
}

@Composable
private fun qualityWord(quality: SignalQuality): String = when (quality) {
    SignalQuality.EXCELLENT -> stringResource(R.string.quality_excellent)
    SignalQuality.GOOD -> stringResource(R.string.quality_good)
    SignalQuality.FAIR -> stringResource(R.string.quality_fair)
    SignalQuality.POOR -> stringResource(R.string.quality_poor)
}

/** "00101" as "001-01", the way a callbox and a network plan write it. */
internal fun formatPlmn(plmn: String): String = if (plmn.length >= 5) plmn.substring(0, 3) + "-" + plmn.substring(3) else plmn

private fun mhz(value: Double, decimals: Int): String = String.format(Locale.ROOT, "%.${decimals}f MHz", value)

private fun seconds(ms: Long): String = String.format(Locale.ROOT, "%.1f", ms / 1000.0)

/** A reading older than this is shown as stale rather than as the current signal. */
private const val STALE_AFTER_MS = 11_000L
