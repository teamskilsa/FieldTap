package com.fieldtap.ui.signalling

import android.content.ClipData
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fieldtap.R
import com.fieldtap.diag.CallFlow
import com.fieldtap.diag.Field
import com.fieldtap.ui.common.DisplayTime
import com.fieldtap.ui.components.InstrumentTag
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.FieldTapIcons
import com.fieldtap.ui.theme.tabular
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Width of the time column left of the lanes. */
internal val GUTTER_WIDTH: Dp = 70.dp

/** Space right of the lanes, so the core lane is not on the screen edge. */
internal val LADDER_END_PADDING: Dp = 14.dp

/** How far the UE and core lanes sit in from the edges of the lane area: under the middle of their labels. */
private val LANE_INSET: Dp = 18.dp

/** The sticky header over the ladder: filters and lane names. Scroll jumps land below it. */
internal val LADDER_HEADER_HEIGHT: Dp = 96.dp

/** The three lane lines, drawn behind every ladder row so they run unbroken down the screen. */
@Composable
private fun Modifier.lanes(): Modifier {
    val color = MaterialTheme.colorScheme.outlineVariant
    return drawBehind {
        val inset = LANE_INSET.toPx()
        val stroke = 1.dp.toPx()
        listOf(inset, size.width / 2, size.width - inset).forEach { x ->
            drawLine(color, Offset(x, 0f), Offset(x, size.height), strokeWidth = stroke)
        }
    }
}

// MARK: - Rows

/**
 * One message: the name above an arrow between lanes, and the line that matters below it. RRC runs UE ↔ eNB,
 * NAS UE ↔ MME. Colour says the layer (cyan RRC, violet NAS); red says it failed; a dashed arrow says it
 * could not be read.
 */
@Composable
internal fun MessageLine(
    row: LadderRow.Message,
    gapMs: Double?,
    highlighted: Boolean,
    ground: Color,
    onOpen: () -> Unit,
) {
    val event = row.event
    val color = when {
        event.isFailure -> MaterialTheme.colorScheme.error
        event.ciphered -> MaterialTheme.colorScheme.outline
        else -> layerColor(event.layer)
    }
    val rowGround = if (highlighted) MaterialTheme.colorScheme.primary.copy(alpha = 0.16f).compositeOver(ground) else ground
    Row(
        Modifier
            .fillMaxWidth()
            .background(rowGround)
            .clickable(onClick = onOpen)
            .padding(end = LADDER_END_PADDING),
    ) {
        Column(Modifier.width(GUTTER_WIDTH).padding(start = 12.dp, top = 6.dp)) {
            Text(
                CallFlowPresentation.sinceStart(event.sinceStartMs),
                style = MaterialTheme.typography.labelSmall.tabular(),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
            if (gapMs != null && gapMs >= 0.05) {
                Text(
                    "+" + CallFlowPresentation.duration(gapMs),
                    style = MaterialTheme.typography.labelSmall.tabular().copy(fontSize = 10.sp),
                    color = MaterialTheme.colorScheme.outline,
                    maxLines = 1,
                )
            }
        }
        Column(Modifier.weight(1f).lanes().padding(vertical = 5.dp)) {
            Row(Modifier.padding(start = 10.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (row.mixed) stringResource(R.string.flow_broadcast_group) else event.name,
                    modifier = Modifier.weight(1f, fill = false).background(rowGround).padding(horizontal = 4.dp),
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                    color = if (event.isFailure) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (row.count > 1) {
                    Text(
                        stringResource(R.string.flow_repeats, row.count),
                        modifier = Modifier.background(rowGround).padding(horizontal = 2.dp),
                        style = MaterialTheme.typography.labelMedium.tabular(),
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
                if (event.protection != null) {
                    Icon(
                        FieldTapIcons.Shield,
                        contentDescription = stringResource(R.string.flow_protected),
                        tint = MaterialTheme.colorScheme.outline,
                        modifier = Modifier.background(rowGround).padding(horizontal = 2.dp).size(12.dp),
                    )
                }
            }
            Arrow(event, color)
            (if (CallFlowPresentation.cellCount(row) > 1) CallFlowPresentation.cellsOf(row) else event.summary)?.let {
                Text(
                    it,
                    modifier = Modifier.padding(start = 10.dp, end = 4.dp).background(rowGround).padding(horizontal = 4.dp),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (event.isFailure) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun Arrow(event: CallFlow.Event, color: Color) {
    Canvas(Modifier.fillMaxWidth().height(12.dp)) {
        val inset = LANE_INSET.toPx()
        val y = size.height / 2
        val phone = inset
        val ran = size.width / 2
        val core = size.width - inset
        val (from, to) = when {
            event.layer == CallFlow.Layer.RRC && event.uplink -> phone to ran
            event.layer == CallFlow.Layer.RRC -> ran to phone
            event.uplink -> phone to core
            else -> core to phone
        }
        val stroke = 2.dp.toPx()
        val head = 7.dp.toPx()
        val sign = if (to > from) 1f else -1f
        drawCircle(color, radius = 3.dp.toPx(), center = Offset(from, y))
        drawLine(
            color,
            Offset(from, y),
            Offset(to - sign * head * 0.6f, y),
            strokeWidth = stroke,
            pathEffect = if (event.ciphered) PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx())) else null,
        )
        val path = Path().apply {
            moveTo(to, y)
            lineTo(to - sign * head, y - head * 0.55f)
            lineTo(to - sign * head, y + head * 0.55f)
            close()
        }
        drawPath(path, color)
    }
}

/** The phone arrived on another cell: a band across the lanes, before the first message logged there. */
@Composable
internal fun MoveLine(step: CallFlow.Step, ground: Color) {
    val color = FieldTapDesign.colors.warning.color
    Row(Modifier.fillMaxWidth().padding(end = LADDER_END_PADDING)) {
        Spacer(Modifier.width(GUTTER_WIDTH))
        Box(Modifier.weight(1f).lanes().padding(vertical = 6.dp)) {
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = color.copy(alpha = 0.14f).compositeOver(ground),
                border = BorderStroke(1.dp, color.copy(alpha = 0.55f)),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(Modifier.padding(horizontal = 10.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(FieldTapIcons.Transfer, contentDescription = null, tint = color, modifier = Modifier.size(16.dp))
                    Text(
                        // Non-breaking inside each cell, so a wrap falls between cells and never inside "PCI 417".
                        moveName(step.move) + " · " +
                            (step.from?.let { CallFlowPresentation.shortCell(it).replace(' ', '\u00A0') + " → " } ?: "") +
                            CallFlowPresentation.shortCell(step.to).replace(' ', '\u00A0'),
                        modifier = Modifier.padding(start = 8.dp),
                        style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold),
                        color = color,
                    )
                }
            }
        }
    }
}

/** A procedure begins: its name, how long it took, and a dot for how it ended. */
@Composable
internal fun ProcedureLine(procedure: CallFlow.Procedure, ground: Color) {
    val (_, tint, _) = outcomeLook(procedure.outcome)
    val accent = layerColor(procedure.layer)
    val word = stringResource(R.string.flow_outcome_unanswered_short)
    Row(Modifier.fillMaxWidth().padding(end = LADDER_END_PADDING)) {
        Spacer(Modifier.width(GUTTER_WIDTH))
        Box(Modifier.weight(1f).lanes().padding(top = 10.dp, bottom = 1.dp)) {
            Row(
                Modifier.padding(start = 10.dp).background(ground).padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(tint))
                Text(
                    procedure.name.uppercase(Locale.getDefault()),
                    modifier = Modifier.padding(start = 6.dp),
                    style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp),
                    color = accent,
                )
                val result = when {
                    procedure.outcome == CallFlow.Outcome.UNANSWERED -> word
                    procedure.durationMs >= 0.05 -> CallFlowPresentation.duration(procedure.durationMs)
                    else -> null
                }
                if (result != null) {
                    Text(" · $result", style = MaterialTheme.typography.labelSmall.tabular(), color = tint)
                }
            }
        }
    }
}

// MARK: - One message, opened

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MessageSheet(
    flow: CallFlow.Flow,
    event: CallFlow.Event,
    lanes: CallFlowPresentation.Lanes,
    previous: Int?,
    next: Int?,
    onOpen: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            MessageHeading(event, lanes)
            event.carrier?.let {
                Text(
                    stringResource(R.string.flow_detail_carried, it),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            When(flow, event)
            event.cell?.let { CellSection(event, it, flow.cellDetails[it]) }
            Decoded(event)
            event.protection?.let { SecuritySection(it) }
            Bytes(event)
            Text(
                stringResource(R.string.flow_detail_source, String.format(Locale.ROOT, "0x%04X", event.logCode), event.record),
                style = MaterialTheme.typography.labelSmall.tabular(),
                color = MaterialTheme.colorScheme.outline,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = { previous?.let(onOpen) }, enabled = previous != null, modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.flow_detail_previous))
                }
                OutlinedButton(onClick = { next?.let(onOpen) }, enabled = next != null, modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.flow_detail_next))
                }
            }
        }
    }
}

@Composable
private fun MessageHeading(event: CallFlow.Event, lanes: CallFlowPresentation.Lanes) {
    val accent = layerColor(event.layer)
    val far = if (event.layer == CallFlow.Layer.RRC) lanes.ran else lanes.core
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            InstrumentTag("${event.rat.uppercase(Locale.ROOT)} ${event.layer.name}", accent)
            InstrumentTag(event.channel, MaterialTheme.colorScheme.onSurfaceVariant)
            InstrumentTag(
                if (event.uplink) stringResource(R.string.flow_direction, lanes.phone, far) else stringResource(R.string.flow_direction, far, lanes.phone),
                MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            event.name,
            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
            color = if (event.isFailure) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        )
        event.summary?.let {
            Text(it, style = MaterialTheme.typography.bodyMedium, color = if (event.isFailure) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun When(flow: CallFlow.Flow, event: CallFlow.Event) {
    SheetSection(stringResource(R.string.flow_detail_when)) {
        CallFlow.utcMs(event.timestampRaw)?.let { utc ->
            KeyValue(stringResource(R.string.flow_detail_modem_time), DisplayTime.timeWithMillis(utc))
        }
        KeyValue(stringResource(R.string.flow_detail_since_start), CallFlowPresentation.sinceStart(event.sinceStartMs))
        CallFlowPresentation.gap(flow.events, event.index)?.let {
            KeyValue(stringResource(R.string.flow_detail_after_previous), "+" + CallFlowPresentation.duration(it))
        }
    }
}

@Composable
private fun CellSection(event: CallFlow.Event, cell: CallFlow.Cell, detail: com.fieldtap.diag.CellInfo.Serving?) {
    SheetSection(stringResource(R.string.flow_detail_cell)) {
        KeyValue("PCI", "${cell.pci}")
        KeyValue(CallFlowPresentation.channelLabel(cell), "${cell.earfcn}")
        CallFlowPresentation.band(cell)?.let { KeyValue(stringResource(R.string.flow_detail_band), it) }
        CallFlowPresentation.downlinkMhz(cell)?.let { KeyValue(stringResource(R.string.flow_detail_downlink), it) }
        detail?.let {
            KeyValue(stringResource(R.string.flow_detail_plmn), it.plmn)
            KeyValue(stringResource(R.string.flow_detail_tac), "${it.tac}")
            KeyValue(stringResource(R.string.flow_detail_enb), "${it.enb} · ${it.sector}")
            it.bandwidthMhz?.let { mhz -> KeyValue(stringResource(R.string.flow_detail_bandwidth), String.format(Locale.ROOT, "%.0f MHz", mhz)) }
        }
        if (event.layer == CallFlow.Layer.NAS && event.carrier == null) {
            Text(stringResource(R.string.flow_detail_cell_nearby), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
        }
    }
}

@Composable
private fun Decoded(event: CallFlow.Event) {
    SheetSection(stringResource(R.string.flow_detail_decoded)) {
        event.cause?.let { cause ->
            KeyValue(stringResource(R.string.flow_detail_cause), listOfNotNull("#$cause", event.causeName).joinToString(" "), valueColor = MaterialTheme.colorScheme.error)
        }
        when {
            event.fields.isNotEmpty() -> FieldLines(event.fields, depth = 0)
            event.ciphered -> Note(stringResource(R.string.flow_detail_ciphered))
            event.cause == null -> Note(stringResource(R.string.flow_detail_nothing_decoded))
        }
    }
}

@Composable
private fun FieldLines(fields: List<Field>, depth: Int) {
    fields.forEach { field ->
        KeyValue(field.label, field.value, indent = (depth * 14).dp)
        if (field.children.isNotEmpty()) FieldLines(field.children, depth + 1)
    }
}

@Composable
private fun SecuritySection(protection: CallFlow.Protection) {
    SheetSection(stringResource(R.string.flow_detail_security)) {
        KeyValue(stringResource(R.string.flow_detail_security_header), protection.headerName)
        KeyValue(stringResource(R.string.flow_detail_mac), String.format(Locale.ROOT, "0x%08x", protection.mac))
        KeyValue(stringResource(R.string.flow_detail_sequence), "${protection.sequence}")
    }
}

@Composable
private fun Bytes(event: CallFlow.Event) {
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    var copied by remember(event.index) { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_500)
            copied = false
        }
    }
    SheetSection(
        stringResource(R.string.flow_detail_bytes, event.pdu.size),
        trailing = {
            TextButton(onClick = {
                scope.launch {
                    clipboard.setClipEntry(ClipEntry(ClipData.newPlainText(event.name, CallFlowPresentation.hex(event.pdu))))
                    copied = true
                }
            }) {
                Text(if (copied) stringResource(R.string.flow_detail_copied) else stringResource(R.string.flow_detail_copy_hex))
            }
        },
    ) {
        Surface(shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceContainerHighest, modifier = Modifier.fillMaxWidth()) {
            Text(
                CallFlowPresentation.hexDump(event.pdu),
                modifier = Modifier.horizontalScroll(rememberScrollState()).padding(10.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 17.sp),
                color = MaterialTheme.colorScheme.onSurface,
                softWrap = false,
            )
        }
    }
}

@Composable
private fun SheetSection(title: String, trailing: (@Composable () -> Unit)? = null, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.heightIn(min = 24.dp)) {
            Text(
                title.uppercase(Locale.getDefault()),
                style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 1.2.sp, fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (trailing != null) {
                Spacer(Modifier.weight(1f))
                trailing()
            }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        content()
    }
}

@Composable
private fun KeyValue(label: String, value: String, indent: Dp = 0.dp, valueColor: Color = MaterialTheme.colorScheme.onSurface) {
    Row(Modifier.fillMaxWidth().padding(top = 5.dp, bottom = 5.dp)) {
        Text(label, modifier = Modifier.weight(0.42f).padding(start = indent), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, modifier = Modifier.weight(0.58f), style = MaterialTheme.typography.bodyMedium.tabular(), color = valueColor)
    }
}

@Composable
private fun Note(text: String) {
    Text(text, modifier = Modifier.padding(vertical = 6.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline)
}
