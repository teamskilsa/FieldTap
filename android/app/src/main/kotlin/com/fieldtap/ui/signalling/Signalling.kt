package com.fieldtap.ui.signalling

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fieldtap.R
import com.fieldtap.diag.CallFlow
import com.fieldtap.ui.common.DisplayTime
import com.fieldtap.ui.common.startedWords
import com.fieldtap.ui.components.EmptyState
import com.fieldtap.ui.components.FieldTapTopBar
import com.fieldtap.ui.components.InstrumentPanel
import com.fieldtap.ui.components.TopBarAction
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.FieldTapIcons
import com.fieldtap.ui.theme.Formats
import com.fieldtap.ui.theme.tabular
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * A kept signalling capture, opened: what happened, at three zoom levels.
 *
 * 1. **Timeline** — the whole capture on one bar: when the phone was connected, where it changed cell, where
 *    something failed.
 * 2. **Cells and procedures** — the cells it moved through and how ("B3 PCI 3 → handover → B7 PCI 2"), and each
 *    procedure with its outcome and how long it took. Tapping either jumps to its messages.
 * 3. **The ladder** — every message between UE, eNB and MME, the way a sequence diagram draws it, with the one
 *    line that matters under each (a cause, an APN, a handover target). Tapping a message opens everything that
 *    was decoded from it, its security, and its bytes.
 *
 * Starting and stopping a capture is on the Logs tab; this is where one is read.
 *
 * Owner: workstream `diag-on-handset`.
 */
@Composable
fun CaptureDetailScreen(
    viewModel: CaptureDetailViewModel,
    onBack: () -> Unit,
    onExport: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val nowUtcMs = remember { System.currentTimeMillis() }
    Scaffold(
        modifier = modifier,
        topBar = {
            FieldTapTopBar(
                title = state.capture?.let { startedWords(it.startedUtcMs, nowUtcMs) }
                    ?: stringResource(R.string.recordings_capture_kind),
                onNavigateUp = onBack,
                actions = {
                    TopBarAction(icon = FieldTapIcons.Share, contentDescription = stringResource(R.string.signalling_export), onClick = onExport)
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        val flow = state.flow
        when {
            state.loading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator()
                    Text(stringResource(R.string.signalling_reading), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            state.failed || flow == null -> Box(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
                EmptyState(
                    icon = FieldTapIcons.Error,
                    title = stringResource(R.string.signalling_unreadable),
                    message = stringResource(R.string.signalling_quiet_message),
                )
            }

            flow.events.isEmpty() -> Column(Modifier.fillMaxSize().padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                EmptyState(
                    icon = FieldTapIcons.SignalBars,
                    title = stringResource(R.string.signalling_quiet_title),
                    message = stringResource(R.string.signalling_quiet_message),
                )
                OutlinedButton(onClick = onExport, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.signalling_export)) }
            }

            else -> CallFlowContent(flow, onExport, Modifier.padding(padding))
        }
    }
}

private enum class Section { SUMMARY, TIMELINE, CELLS, PROCEDURES }

@Composable
private fun CallFlowContent(flow: CallFlow.Flow, onExport: () -> Unit, modifier: Modifier = Modifier) {
    var filter by rememberSaveable { mutableStateOf(FlowFilter.ALL) }
    var opened by rememberSaveable { mutableStateOf<Int?>(null) }
    var highlighted by remember { mutableStateOf<Int?>(null) }
    val rows = remember(flow, filter) { CallFlowPresentation.rows(flow, filter) }
    val lanes = remember(flow) { CallFlowPresentation.lanes(flow) }
    val sections = remember(flow) {
        buildList {
            add(Section.SUMMARY)
            add(Section.TIMELINE)
            if (flow.journey.isNotEmpty() || flow.searched.isNotEmpty()) add(Section.CELLS)
            if (flow.procedures.isNotEmpty()) add(Section.PROCEDURES)
        }
    }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val headerOffsetPx = with(LocalDensity.current) { LADDER_HEADER_HEIGHT.roundToPx() }

    // A jump from the timeline, a cell or a procedure: switch to All if the filter hides the target, scroll the
    // ladder to it under the sticky header, and flash it so the eye lands on the right line.
    fun jumpTo(eventIndex: Int) {
        val target = if (CallFlowPresentation.rowOf(rows, eventIndex) < 0) {
            filter = FlowFilter.ALL
            CallFlowPresentation.rows(flow, FlowFilter.ALL)
        } else {
            rows
        }
        val row = CallFlowPresentation.rowOf(target, eventIndex).coerceAtLeast(0)
        highlighted = eventIndex
        scope.launch { listState.animateScrollToItem(sections.size + 1 + row, -headerOffsetPx) }
    }

    LaunchedEffect(highlighted) {
        if (highlighted != null) {
            delay(1_800)
            highlighted = null
        }
    }

    val ground = MaterialTheme.colorScheme.background
    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 32.dp),
    ) {
        items(sections, key = { it.name }) { section ->
            Box(Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp)) {
                when (section) {
                    Section.SUMMARY -> Summary(flow, onExport)
                    Section.TIMELINE -> Timeline(flow)
                    Section.CELLS -> Cells(flow, onJump = ::jumpTo)
                    Section.PROCEDURES -> Procedures(flow, onJump = ::jumpTo)
                }
            }
        }
        stickyHeader(key = "ladder-header") {
            LadderHeader(flow, filter, lanes, onFilter = { filter = it })
        }
        items(rows, key = { it.key }) { row ->
            when (row) {
                is LadderRow.Move -> MoveLine(row.step, ground)
                is LadderRow.ProcedureStart -> ProcedureLine(row.procedure, ground)
                is LadderRow.Message -> MessageLine(
                    row = row,
                    gapMs = CallFlowPresentation.gap(flow.events, row.event.index),
                    highlighted = highlighted == row.event.index || row.repeats.any { it.index == highlighted },
                    ground = ground,
                    onOpen = { opened = row.event.index },
                )
            }
        }
    }

    opened?.let { index ->
        val order = remember(rows) { rows.filterIsInstance<LadderRow.Message>().flatMap { listOf(it.event) + it.repeats }.map { it.index } }
        MessageSheet(
            flow = flow,
            event = flow.events[index],
            lanes = lanes,
            previous = order.getOrNull(order.indexOf(index) - 1),
            next = order.getOrNull(order.indexOf(index) + 1).takeIf { order.indexOf(index) >= 0 },
            onOpen = { opened = it },
            onDismiss = { opened = null },
        )
    }
}

// MARK: - Summary

@Composable
private fun Summary(flow: CallFlow.Flow, onExport: () -> Unit) {
    InstrumentPanel {
        Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Stat(stringResource(R.string.flow_stat_duration), CallFlowPresentation.duration(flow.durationMs), Modifier.weight(1.3f))
            Stat(stringResource(R.string.flow_stat_messages), Formats.count(flow.events.size.toLong()), Modifier.weight(1f))
            Stat(stringResource(R.string.flow_stat_procedures), Formats.count(flow.procedures.size.toLong()), Modifier.weight(1f))
            Stat(
                stringResource(R.string.flow_stat_failures),
                Formats.count(flow.failures.toLong()),
                Modifier.weight(0.9f),
                color = if (flow.failures > 0) MaterialTheme.colorScheme.error else FieldTapDesign.colors.success.color,
            )
        }
        flow.startUtcMs?.let {
            Text(
                stringResource(R.string.flow_started_at, DisplayTime.timeWithSeconds(it)),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (flow.undecoded > 0) {
            Text(
                pluralStringResource(R.plurals.flow_undecoded, flow.undecoded, Formats.count(flow.undecoded.toLong())),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
            )
        }
        OutlinedButton(onClick = onExport, modifier = Modifier.fillMaxWidth().padding(top = 4.dp)) {
            Icon(FieldTapIcons.Share, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.signalling_export))
        }
    }
}

@Composable
private fun Stat(label: String, value: String, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurface) {
    Column(modifier) {
        // "10 h 11 min" and "40,884" share a phone's width with two more figures: shrink rather than clip.
        Text(
            value,
            style = MaterialTheme.typography.titleMedium.tabular().copy(fontWeight = FontWeight.Bold),
            color = color,
            maxLines = 1,
            softWrap = false,
            autoSize = TextAutoSize.StepBased(minFontSize = 11.sp, maxFontSize = MaterialTheme.typography.titleMedium.fontSize),
        )
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

// MARK: - Timeline

/** The capture on one bar: connected spans, cell changes as ticks, failures and unanswered requests as dots. */
@Composable
private fun Timeline(flow: CallFlow.Flow) {
    val connected = MaterialTheme.colorScheme.primary
    val track = MaterialTheme.colorScheme.outlineVariant
    val move = FieldTapDesign.colors.warning.color
    val failure = MaterialTheme.colorScheme.error
    val noAnswer = FieldTapDesign.colors.warning.color
    val unanswered = flow.connections.any { it.outcome == CallFlow.ConnectionOutcome.NO_ANSWER }
    InstrumentPanel(title = stringResource(R.string.flow_timeline)) {
        Canvas(Modifier.fillMaxWidth().height(46.dp).padding(vertical = 4.dp)) {
            val total = flow.durationMs.coerceAtLeast(1.0)
            fun x(ms: Double) = (ms / total * size.width).toFloat().coerceIn(0f, size.width)
            val y = size.height * 0.6f
            drawLine(track, Offset(0f, y), Offset(size.width, y), strokeWidth = 2.dp.toPx(), cap = StrokeCap.Round)
            // Cell changes stand above the bar, so a night of reselections does not hide when it was connected.
            flow.journey.filter { it.move != CallFlow.Move.FIRST_SEEN }.forEach { s ->
                val at = x(s.sinceStartMs)
                drawLine(move, Offset(at, 0f), Offset(at, y - 6.dp.toPx()), strokeWidth = 1.5.dp.toPx())
            }
            flow.connections.forEach { c ->
                when {
                    c.established -> {
                        val start = x(c.startMs)
                        val end = maxOf(x(c.endMs ?: total), start + 3.dp.toPx())
                        drawLine(connected, Offset(start, y), Offset(end, y), strokeWidth = 8.dp.toPx(), cap = StrokeCap.Round)
                    }
                    c.outcome == CallFlow.ConnectionOutcome.NO_ANSWER ->
                        drawCircle(noAnswer, radius = 2.5.dp.toPx(), center = Offset(x(c.startMs), size.height - 3.dp.toPx()))
                    else -> Unit
                }
            }
            flow.events.filter { it.isFailure }.forEach { e ->
                drawCircle(failure, radius = 4.dp.toPx(), center = Offset(x(e.sinceStartMs), y))
            }
        }
        Row(Modifier.fillMaxWidth()) {
            Text(CallFlowPresentation.sinceStart(0.0), style = MaterialTheme.typography.labelSmall.tabular(), color = MaterialTheme.colorScheme.outline)
            Spacer(Modifier.weight(1f))
            Text(CallFlowPresentation.sinceStart(flow.durationMs), style = MaterialTheme.typography.labelSmall.tabular(), color = MaterialTheme.colorScheme.outline)
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 2.dp)) {
            Legend(connected, stringResource(R.string.flow_legend_connected), wide = true)
            Legend(move, stringResource(R.string.flow_legend_cell_change))
            Legend(failure, stringResource(R.string.flow_legend_failure), round = true)
            if (unanswered) Legend(noAnswer, stringResource(R.string.flow_legend_no_answer), round = true)
        }
    }
}

@Composable
private fun Legend(color: Color, label: String, wide: Boolean = false, round: Boolean = false) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(width = if (wide) 14.dp else if (round) 8.dp else 2.dp, height = if (wide) 6.dp else if (round) 8.dp else 12.dp)
                .clip(if (round) CircleShape else RoundedCornerShape(3.dp))
                .background(color),
        )
        Text(label, modifier = Modifier.padding(start = 6.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// MARK: - Cells

/** "B3 PCI 3 → Handover → B7 PCI 2", scrolling sideways when the phone moved a lot. */
@Composable
private fun Cells(flow: CallFlow.Flow, onJump: (Int) -> Unit) {
    InstrumentPanel(title = stringResource(R.string.flow_cells), count = flow.journey.map { it.to }.distinct().size) {
        if (flow.journey.isNotEmpty()) Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            flow.journey.forEachIndexed { i, step ->
                if (i > 0) Connector(step)
                CellChip(step.to, flow.cellDetails[step.to], onClick = { onJump(step.event) })
            }
        }
        if (flow.journey.size == 1) {
            Text(stringResource(R.string.flow_cells_one), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (flow.searched.isNotEmpty()) {
            Text(
                pluralStringResource(R.plurals.flow_cells_searched, flow.searched.size, Formats.count(flow.searched.size.toLong())),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
            )
        }
    }
}

@Composable
private fun CellChip(cell: CallFlow.Cell, detail: com.fieldtap.diag.CellInfo.Serving?, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.5f)),
        modifier = Modifier.clip(RoundedCornerShape(10.dp)).clickable(onClick = onClick),
    ) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Text(
                CallFlowPresentation.band(cell) ?: if (cell.nr) "NR" else "LTE",
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                color = if (cell.nr) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.primary,
            )
            Text("PCI ${cell.pci}", style = MaterialTheme.typography.labelLarge.tabular(), color = MaterialTheme.colorScheme.onSurface)
            Text(
                "${CallFlowPresentation.channelLabel(cell)} ${cell.earfcn}",
                style = MaterialTheme.typography.labelSmall.tabular(),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            detail?.let {
                Text("${it.plmn} · TAC ${it.tac}", style = MaterialTheme.typography.labelSmall.tabular(), color = MaterialTheme.colorScheme.outline)
            }
        }
    }
}

@Composable
private fun Connector(step: CallFlow.Step) {
    val color = FieldTapDesign.colors.warning.color
    Column(Modifier.padding(horizontal = 6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(moveName(step.move), style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold), color = color)
        Canvas(Modifier.width(76.dp).height(10.dp)) {
            val y = size.height / 2
            val stroke = 2.dp.toPx()
            drawLine(color, Offset(0f, y), Offset(size.width - 2.dp.toPx(), y), strokeWidth = stroke)
            drawLine(color, Offset(size.width - 7.dp.toPx(), y - 4.dp.toPx()), Offset(size.width, y), strokeWidth = stroke, cap = StrokeCap.Round)
            drawLine(color, Offset(size.width - 7.dp.toPx(), y + 4.dp.toPx()), Offset(size.width, y), strokeWidth = stroke, cap = StrokeCap.Round)
        }
        Text(CallFlowPresentation.sinceStart(step.sinceStartMs), style = MaterialTheme.typography.labelSmall.tabular(), color = MaterialTheme.colorScheme.outline)
    }
}

@Composable
internal fun moveName(move: CallFlow.Move): String = when (move) {
    CallFlow.Move.HANDOVER -> stringResource(R.string.flow_move_handover)
    CallFlow.Move.RESELECTION -> stringResource(R.string.flow_move_reselection)
    CallFlow.Move.REDIRECT -> stringResource(R.string.flow_move_redirect)
    CallFlow.Move.REESTABLISHMENT -> stringResource(R.string.flow_move_reestablishment)
    CallFlow.Move.CELL_CHANGE, CallFlow.Move.FIRST_SEEN -> stringResource(R.string.flow_move_change)
}

// MARK: - Procedures

/** Instances listed under an opened kind before "and N more": a phone retrying all night makes hundreds. */
private const val INSTANCES_LISTED = 25

/**
 * Procedures by kind — "Attach: 3 succeeded, 40 failed, 74 no answer, median 282 ms" — which reads the same
 * for a one-minute test and an overnight run. Opening a kind lists each attempt; tapping one jumps to it.
 */
@Composable
private fun Procedures(flow: CallFlow.Flow, onJump: (Int) -> Unit) {
    val groups = remember(flow) { CallFlowPresentation.procedureGroups(flow) }
    var opened by rememberSaveable { mutableStateOf<String?>(null) }
    InstrumentPanel(title = stringResource(R.string.flow_procedures), count = flow.procedures.size) {
        groups.forEachIndexed { i, group ->
            if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            val single = group.items.size == 1
            ProcedureGroupRow(
                group = group,
                expanded = opened == group.name,
                onClick = {
                    if (single) onJump(group.items.first().first) else opened = if (opened == group.name) null else group.name
                },
            )
            if (opened == group.name && !single) {
                group.items.take(INSTANCES_LISTED).forEach { p -> ProcedureRow(p, flow.events[p.first].sinceStartMs, onClick = { onJump(p.first) }) }
                if (group.items.size > INSTANCES_LISTED) {
                    Text(
                        stringResource(R.string.flow_more, group.items.size - INSTANCES_LISTED),
                        modifier = Modifier.padding(start = 30.dp, bottom = 6.dp),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
            }
        }
    }
}

@Composable
private fun ProcedureGroupRow(group: CallFlowPresentation.ProcedureGroup, expanded: Boolean, onClick: () -> Unit) {
    val single = group.items.size == 1
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 48.dp).padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val worst = when {
            group.failed > 0 -> CallFlow.Outcome.FAILED
            group.unanswered > 0 -> CallFlow.Outcome.UNANSWERED
            else -> CallFlow.Outcome.SUCCEEDED
        }
        val (icon, tint, word) = outcomeLook(worst)
        Icon(icon, contentDescription = word, tint = tint, modifier = Modifier.size(20.dp))
        Column(Modifier.weight(1f).padding(start = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(6.dp).clip(CircleShape).background(layerColor(group.layer)))
                Text(group.name, modifier = Modifier.padding(start = 6.dp), style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold))
            }
            if (single) {
                val only = group.items.first()
                only.detail?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
                only.refusal?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error, maxLines = 2) }
            } else {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (group.succeeded > 0) Count(stringResource(R.string.flow_count_succeeded, group.succeeded), FieldTapDesign.colors.success.color)
                    if (group.failed > 0) Count(stringResource(R.string.flow_count_failed, group.failed), MaterialTheme.colorScheme.error)
                    if (group.unanswered > 0) Count(stringResource(R.string.flow_count_unanswered, group.unanswered), FieldTapDesign.colors.warning.color)
                }
            }
        }
        Column(horizontalAlignment = Alignment.End) {
            // One attempt shows its own time, answered or refused; several show the median of the successes. A
            // switch-off detach closes the moment it is sent, and "0.0 ms" would be a time nobody measured.
            val only = group.items.singleOrNull()
            val time = when {
                only != null -> only.durationMs.takeIf { only.outcome != CallFlow.Outcome.UNANSWERED }
                else -> group.medianMs
            }?.takeIf { it >= 0.05 }
            Text(
                when {
                    time == null -> "—"
                    single -> CallFlowPresentation.duration(time)
                    else -> stringResource(R.string.flow_median, CallFlowPresentation.duration(time))
                },
                style = MaterialTheme.typography.bodyMedium.tabular(),
                color = when {
                    time == null -> MaterialTheme.colorScheme.outline
                    only?.outcome == CallFlow.Outcome.FAILED -> MaterialTheme.colorScheme.error
                    else -> MaterialTheme.colorScheme.onSurface
                },
            )
            if (!single) {
                Icon(
                    FieldTapIcons.ExpandMore,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.size(18.dp).rotate(if (expanded) 180f else 0f),
                )
            }
        }
    }
}

@Composable
private fun Count(text: String, color: Color) {
    Text(text, style = MaterialTheme.typography.labelSmall.tabular(), color = color)
}

@Composable
private fun ProcedureRow(p: CallFlow.Procedure, atMs: Double, onClick: () -> Unit) {
    val (icon, tint, word) = outcomeLook(p.outcome)
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 44.dp).padding(start = 30.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = word, tint = tint, modifier = Modifier.size(16.dp))
        Text(
            CallFlowPresentation.sinceStart(atMs),
            modifier = Modifier.padding(start = 8.dp),
            style = MaterialTheme.typography.labelMedium.tabular(),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            p.refusal ?: p.detail.orEmpty(),
            modifier = Modifier.weight(1f).padding(start = 10.dp),
            style = MaterialTheme.typography.labelSmall,
            color = if (p.refusal != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.outline,
            maxLines = 1,
        )
        Text(
            if (p.outcome == CallFlow.Outcome.UNANSWERED) "—" else CallFlowPresentation.duration(p.durationMs),
            style = MaterialTheme.typography.labelMedium.tabular(),
            color = tint,
        )
    }
}

@Composable
internal fun outcomeLook(outcome: CallFlow.Outcome): Triple<androidx.compose.ui.graphics.vector.ImageVector, Color, String> = when (outcome) {
    CallFlow.Outcome.SUCCEEDED -> Triple(FieldTapIcons.CheckCircle, FieldTapDesign.colors.success.color, stringResource(R.string.flow_outcome_succeeded))
    CallFlow.Outcome.FAILED -> Triple(FieldTapIcons.Error, MaterialTheme.colorScheme.error, stringResource(R.string.flow_outcome_failed))
    CallFlow.Outcome.UNANSWERED -> Triple(FieldTapIcons.Timer, FieldTapDesign.colors.warning.color, stringResource(R.string.flow_outcome_unanswered))
}

@Composable
internal fun layerColor(layer: CallFlow.Layer): Color =
    if (layer == CallFlow.Layer.RRC) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.tertiary

// MARK: - Ladder header

@Composable
private fun LadderHeader(flow: CallFlow.Flow, filter: FlowFilter, lanes: CallFlowPresentation.Lanes, onFilter: (FlowFilter) -> Unit) {
    val rrc = flow.events.count { it.layer == CallFlow.Layer.RRC }
    Column(
        Modifier
            .fillMaxWidth()
            .height(LADDER_HEADER_HEIGHT)
            .background(MaterialTheme.colorScheme.background)
            .padding(top = 12.dp),
    ) {
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterSegment(stringResource(R.string.flow_filter_all), flow.events.size, filter == FlowFilter.ALL, MaterialTheme.colorScheme.onSurface) { onFilter(FlowFilter.ALL) }
            FilterSegment(stringResource(R.string.flow_filter_rrc), rrc, filter == FlowFilter.RRC, layerColor(CallFlow.Layer.RRC)) { onFilter(FlowFilter.RRC) }
            FilterSegment(stringResource(R.string.flow_filter_nas), flow.events.size - rrc, filter == FlowFilter.NAS, layerColor(CallFlow.Layer.NAS)) { onFilter(FlowFilter.NAS) }
        }
        Spacer(Modifier.weight(1f))
        Row(Modifier.fillMaxWidth().padding(end = LADDER_END_PADDING)) {
            Spacer(Modifier.width(GUTTER_WIDTH))
            Box(Modifier.weight(1f).height(24.dp)) {
                LaneLabel(lanes.phone, Modifier.align(Alignment.CenterStart))
                LaneLabel(lanes.ran, Modifier.align(Alignment.Center))
                LaneLabel(lanes.core, Modifier.align(Alignment.CenterEnd))
            }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant, modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun FilterSegment(label: String, count: Int, selected: Boolean, accent: Color, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(50),
        color = if (selected) accent.copy(alpha = 0.16f) else Color.Transparent,
        border = androidx.compose.foundation.BorderStroke(1.dp, if (selected) accent.copy(alpha = 0.7f) else MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onClick).heightIn(min = 36.dp),
    ) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold), color = if (selected) accent else MaterialTheme.colorScheme.onSurfaceVariant)
            Text("  " + Formats.count(count.toLong()), style = MaterialTheme.typography.labelMedium.tabular(), color = MaterialTheme.colorScheme.outline)
        }
    }
}

@Composable
private fun LaneLabel(text: String, modifier: Modifier) {
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = modifier,
    ) {
        Text(
            text,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
        )
    }
}
