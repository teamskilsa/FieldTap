package com.fieldtap.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.fieldtap.core.live.ChartPoint
import com.fieldtap.core.live.LiveStateReducer
import com.fieldtap.ui.theme.FieldTapDesign
import com.fieldtap.ui.theme.ShapeRoles
import com.fieldtap.ui.theme.SignalMetric
import com.fieldtap.ui.theme.SignalScale
import com.fieldtap.ui.theme.SignalZone
import com.fieldtap.ui.theme.Sizes
import com.fieldtap.ui.theme.Spacing

/** The words of a [SignalHistoryChart], all from string resources. */
@Immutable
data class SignalChartLabels(
    /** "RSRP". */
    val rsrpTitle: String,
    /** "dBm". */
    val rsrpUnit: String,
    /** "SINR". */
    val sinrTitle: String,
    /** "dB". */
    val sinrUnit: String,
    /** Under the left end of the time axis: "5 min ago". */
    val windowStart: String,
    /** Under the right end: "Now". */
    val windowEnd: String,
    /** Inside an empty panel: "No fresh samples yet". */
    val noData: String,
    /** In place of a panel whose values the serving cell does not report: "Not reported by this cell". */
    val notReported: String = noData,
    /** Beside the RSRP title, the window the chart covers: "last 5 min". Null shows nothing there. */
    val window: String? = null,
)

/**
 * Five minutes of serving RSRP and SINR, as two panels on one neutral well. Behind each line the signal scale's four
 * zones are a faint tint (≤ 12 % of the level's colour), not saturated bands; 1 dp dashed reference lines sit at the
 * thresholds, and the report's -105 dBm key line (0 dB for SINR) is drawn solid and a hair heavier. The RSRP line (the
 * accent series) carries a faint accent area fill; SINR does not. The thresholds are labelled as far as the labels fit
 * apart, the key line's first ([ChartMath.labelOrder]). Lines break at sampling gaps.
 *
 * [rsrpRange] and [sinrRange] default to the report's axes (RSRP -140..-40 dBm, SINR -25..40 dB); Live passes
 * `ChartMath.fittedRange`, so a steady signal is not squeezed into a fifth of the panel. With [sinrReported] false the SINR
 * panel folds to one line; give the RSRP panel the room with [rsrpPanelHeight].
 *
 * TalkBack reads [summary] as the whole chart, for example "RSRP over the last 5 minutes: latest -92
 * dBm, lowest -104, highest -85. SINR: latest 12 dB, lowest 3, highest 18." Build it from
 * [ChartMath.stats].
 *
 * @param gapThresholdMs pass `ChartMath.gapThresholdMs(live.shortInterval)`.
 */
@Composable
fun SignalHistoryChart(
    rsrp: List<ChartPoint>,
    sinr: List<ChartPoint>,
    nowElapsedMs: Long,
    labels: SignalChartLabels,
    summary: String,
    modifier: Modifier = Modifier,
    windowMs: Long = LiveStateReducer.WINDOW_MS,
    gapThresholdMs: Long = ChartMath.DEFAULT_GAP_THRESHOLD_MS,
    sinrReported: Boolean = true,
    rsrpRange: IntRange = SignalScale.RSRP_DISPLAY_RANGE,
    sinrRange: IntRange = SignalScale.SINR_DISPLAY_RANGE,
    rsrpPanelHeight: Dp = Sizes.ChartPanelHeight,
    sinrPanelHeight: Dp = Sizes.ChartPanelHeight,
    /**
     * False draws RSRP alone, with no SINR panel and no "not reported" line in its place. The Signal
     * tab does not show SINR at all; a line saying it was not reported would be answering a question
     * that screen no longer asks.
     */
    showSinr: Boolean = true,
) {
    val colors = FieldTapDesign.colors
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clearAndSetSemantics { contentDescription = summary },
        verticalArrangement = Arrangement.spacedBy(Spacing.Sm),
    ) {
        ChartPanelHeader(
            title = labels.rsrpTitle,
            unit = labels.rsrpUnit,
            stats = ChartMath.stats(rsrp, nowElapsedMs, windowMs),
            lineColor = colors.chartRsrp,
            window = labels.window,
        )
        TimeSeriesChart(
            points = rsrp,
            nowElapsedMs = nowElapsedMs,
            range = rsrpRange,
            lineColor = colors.chartRsrp,
            referenceLines = SignalScale.RSRP_THRESHOLDS.boundaries,
            keyReference = SignalScale.keyReference(SignalMetric.RSRP),
            windowMs = windowMs,
            gapThresholdMs = gapThresholdMs,
            height = rsrpPanelHeight,
            noDataText = labels.noData,
            zones = SignalScale.zones(SignalMetric.RSRP, rsrpRange),
            areaFill = true,
        )
        Spacer(modifier = Modifier.height(Spacing.Xs))
        if (!showSinr) {
            // RSRP alone.
        } else if (sinrReported) {
            ChartPanelHeader(labels.sinrTitle, labels.sinrUnit, ChartMath.stats(sinr, nowElapsedMs, windowMs), colors.chartSinr)
            TimeSeriesChart(
                points = sinr,
                nowElapsedMs = nowElapsedMs,
                range = sinrRange,
                lineColor = colors.chartSinr,
                referenceLines = SignalScale.SINR_THRESHOLDS.boundaries,
                keyReference = SignalScale.keyReference(SignalMetric.SINR),
                windowMs = windowMs,
                gapThresholdMs = gapThresholdMs,
                height = sinrPanelHeight,
                noDataText = labels.noData,
                zones = SignalScale.zones(SignalMetric.SINR, sinrRange),
            )
        } else {
            // An empty panel would say "not yet" for a value this cell never reports: one line says so instead.
            ChartPanelHeader(labels.sinrTitle, labels.sinrUnit, stats = null, lineColor = colors.chartSinr, trailing = labels.notReported)
        }
        CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
            Row(modifier = Modifier.fillMaxWidth()) {
                Text(labels.windowStart, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(modifier = Modifier.weight(1f))
                Text(labels.windowEnd, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun ChartPanelHeader(
    title: String,
    unit: String,
    stats: SeriesStats?,
    lineColor: Color,
    window: String? = null,
    trailing: String? = null,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.Sm)) {
        Box(
            modifier = Modifier
                .size(width = 14.dp, height = 3.dp)
                .background(lineColor, ShapeRoles.Bar),
        )
        Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        if (window != null) {
            Text(
                text = window,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
        }
        Spacer(modifier = Modifier.weight(1f))
        if (stats != null) {
            Text(
                text = "${stats.latest} $unit",
                style = FieldTapDesign.numeric.bodySmall,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
        } else if (trailing != null) {
            Text(text = trailing, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/**
 * One chart panel: a line of [points] against time over [windowMs] ending at [nowElapsedMs], on a
 * vertical [range], over a neutral well ([Sizes] `surfaceContainerHigh` + an `outlineVariant` hairline
 * frame), with [zones] as a faint tint (≤ 12 % of the level's colour), 1 dp dashed [referenceLines] in
 * `chartReference` and the [keyReference] drawn **solid** in `chartKeyReference`, a hair heavier. The lines
 * are labelled by their values in [ChartMath.labelOrder]; a label that would come within 2 dp of one
 * already drawn is left out, so labels never overlap at any panel height or font scale. [areaFill] draws a
 * faint fill of [lineColor] under the line (the accent RSRP series uses it; SINR does not). Single points
 * between gaps are dots; the newest point has a marker. Draws in LTR in every locale, like the report.
 * Decorative for TalkBack: the caller describes it (see [SignalHistoryChart]).
 */
@Composable
fun TimeSeriesChart(
    points: List<ChartPoint>,
    nowElapsedMs: Long,
    range: IntRange,
    lineColor: Color,
    modifier: Modifier = Modifier,
    referenceLines: List<Int> = emptyList(),
    keyReference: Int? = null,
    windowMs: Long = LiveStateReducer.WINDOW_MS,
    gapThresholdMs: Long = ChartMath.DEFAULT_GAP_THRESHOLD_MS,
    height: Dp = Sizes.ChartPanelHeight,
    noDataText: String? = null,
    zones: List<SignalZone> = emptyList(),
    areaFill: Boolean = false,
) {
    val colors = FieldTapDesign.colors
    val signal = FieldTapDesign.signal
    val panel = MaterialTheme.colorScheme.surfaceContainerHigh
    val frame = MaterialTheme.colorScheme.outlineVariant
    val labelColor = MaterialTheme.colorScheme.onSurfaceVariant
    val axisStyle = FieldTapDesign.numeric.axis
    val noDataStyle = MaterialTheme.typography.bodySmall
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val lines = referenceLines.filter { it in range }
    val labelLayouts = remember(lines, axisStyle, density) { lines.associateWith { measurer.measure(it.toString(), axisStyle) } }
    val labelOrder = remember(lines, keyReference) { ChartMath.labelOrder(lines, keyReference) }
    val noDataLayout = remember(noDataText, noDataStyle, density) { noDataText?.let { measurer.measure(it, noDataStyle) } }
    val segments = remember(points, nowElapsedMs, windowMs, gapThresholdMs) {
        ChartMath.segments(points, nowElapsedMs, windowMs, gapThresholdMs)
    }
    val visibleCount = remember(segments) { segments.sumOf { it.size } }
    // Before a trend exists (0–1 fresh samples) the zone bands are damped from a full-height red-to-green wash to a
    // faint tint, so a lone reading does not read as an empty, unfinished panel; they reach full strength at two points.
    val zoneAlpha = if (visibleCount >= 2) ZONE_ALPHA else ZONE_ALPHA_IDLE
    val zoneColors = zones.map { signal.of(it.quality).fill.copy(alpha = zoneAlpha) }

    Canvas(
        modifier = modifier
            .fillMaxWidth()
            .height(height),
    ) {
        val corner = CornerRadius(PanelCornerRadius.toPx())
        drawRoundRect(color = panel, cornerRadius = corner)
        // The neutral well carries a 1 px hairline frame, inset by half its width so it reads fully.
        val frameStroke = 1.dp.toPx()
        drawRoundRect(
            color = frame,
            topLeft = Offset(frameStroke / 2f, frameStroke / 2f),
            size = Size(size.width - frameStroke, size.height - frameStroke),
            cornerRadius = corner,
            style = Stroke(frameStroke),
        )
        val labelWidth = labelLayouts.values.maxOfOrNull { it.size.width }?.toFloat() ?: 0f
        val left = Spacing.Sm.toPx() + labelWidth + if (labelWidth > 0f) Spacing.Xs.toPx() else 0f
        val right = size.width - Spacing.Sm.toPx()
        val top = Spacing.Sm.toPx()
        val bottom = size.height - Spacing.Sm.toPx()
        val plotWidth = (right - left).coerceAtLeast(1f)
        val plotHeight = (bottom - top).coerceAtLeast(1f)
        fun x(elapsedMs: Long) = left + ChartMath.xFraction(elapsedMs, nowElapsedMs, windowMs) * plotWidth
        fun y(value: Int) = bottom - ChartMath.yFraction(value, range) * plotHeight

        if (zones.isNotEmpty()) {
            // Clipped to the panel's rounded corners, which the plot's own corners would otherwise poke through.
            val outline = Path().apply { addRoundRect(RoundRect(0f, 0f, size.width, size.height, corner)) }
            clipPath(outline) {
                zones.forEachIndexed { i, zone ->
                    val zoneTop = y(zone.to)
                    drawRect(color = zoneColors[i], topLeft = Offset(left, zoneTop), size = Size(plotWidth, y(zone.from) - zoneTop))
                }
            }
        }

        val dash = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))
        for (value in lines) {
            val key = value == keyReference
            val yy = y(value)
            drawLine(
                // Thresholds are 1 dp dashed chartReference; the key line (−105 dBm / 0 dB) is solid and heavier.
                color = if (key) colors.chartKeyReference else colors.chartReference,
                start = Offset(left, yy),
                end = Offset(right, yy),
                strokeWidth = if (key) 1.5.dp.toPx() else 1.dp.toPx(),
                pathEffect = if (key) null else dash,
            )
        }
        val grow = LabelGap.toPx()
        val drawnTops = ArrayList<Float>(labelOrder.size)
        val drawnBottoms = ArrayList<Float>(labelOrder.size)
        for (value in labelOrder) {
            val layout = labelLayouts.getValue(value)
            val labelHeight = layout.size.height.toFloat()
            val labelTop = (y(value) - labelHeight / 2f).coerceIn(0f, (size.height - labelHeight).coerceAtLeast(0f))
            val labelBottom = labelTop + labelHeight
            val collides = drawnTops.indices.any { i -> ChartMath.labelCollides(labelTop, labelBottom, drawnTops[i], drawnBottoms[i], grow) }
            if (collides) continue
            drawText(
                textLayoutResult = layout,
                color = labelColor,
                topLeft = Offset(Spacing.Sm.toPx() + labelWidth - layout.size.width, labelTop),
            )
            drawnTops += labelTop
            drawnBottoms += labelBottom
        }

        if (segments.isEmpty()) {
            if (noDataLayout != null) {
                drawText(
                    textLayoutResult = noDataLayout,
                    color = labelColor,
                    topLeft = Offset(
                        left + (plotWidth - noDataLayout.size.width) / 2f,
                        top + (plotHeight - noDataLayout.size.height) / 2f,
                    ),
                )
            }
            return@Canvas
        }

        if (visibleCount == 1) {
            // A lone reading gets a faint current-value guide line across the plot, so a single dot has context
            // instead of floating over the damped bands.
            val only = segments.first().first()
            drawLine(
                color = lineColor.copy(alpha = IDLE_GUIDE_ALPHA),
                start = Offset(left, y(only.value)),
                end = Offset(right, y(only.value)),
                strokeWidth = 1.5.dp.toPx(),
            )
        }

        if (areaFill) {
            // A faint fill of the (accent) line colour under the RSRP line, clipped to the well's corners.
            val fillClip = Path().apply { addRoundRect(RoundRect(0f, 0f, size.width, size.height, corner)) }
            clipPath(fillClip) {
                for (segment in segments) {
                    if (segment.size < 2) continue
                    val area = Path()
                    area.moveTo(x(segment.first().elapsedMs), bottom)
                    segment.forEach { area.lineTo(x(it.elapsedMs), y(it.value)) }
                    area.lineTo(x(segment.last().elapsedMs), bottom)
                    area.close()
                    drawPath(path = area, color = lineColor.copy(alpha = AREA_FILL_ALPHA))
                }
            }
        }

        val stroke = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
        for (segment in segments) {
            if (segment.size == 1) {
                drawCircle(color = lineColor, radius = 2.5.dp.toPx(), center = Offset(x(segment[0].elapsedMs), y(segment[0].value)))
                continue
            }
            val path = Path()
            segment.forEachIndexed { index, point ->
                if (index == 0) path.moveTo(x(point.elapsedMs), y(point.value)) else path.lineTo(x(point.elapsedMs), y(point.value))
            }
            drawPath(path = path, color = lineColor, style = stroke)
        }
        val newest = segments.last().last()
        val haloRadius = 5.5.dp.toPx()
        // Clamp the marker's centre into the plot inset by its halo, and clip it to the panel's rounded rect, so a
        // strong reading's marker is never sliced by the 14 dp panel corner into a detached crescent over the card behind.
        val center = Offset(
            x = x(newest.elapsedMs).coerceIn(left + haloRadius, (right - haloRadius).coerceAtLeast(left + haloRadius)),
            y = y(newest.value).coerceIn(top + haloRadius, (bottom - haloRadius).coerceAtLeast(top + haloRadius)),
        )
        val markerClip = Path().apply { addRoundRect(RoundRect(0f, 0f, size.width, size.height, corner)) }
        clipPath(markerClip) {
            drawCircle(color = panel, radius = haloRadius, center = center)
            drawCircle(color = lineColor, radius = 3.5.dp.toPx(), center = center)
        }
    }
}

/** The chart panel's corner, matching [ShapeRoles.Tile]. */
private val PanelCornerRadius: Dp = 14.dp

/** How far apart two threshold labels must stay; a label closer to one already drawn is left out. */
private val LabelGap: Dp = Spacing.Xxs

/** The zones sit behind the line as a hint of the scale, never as strong as the line or a level's swatch. */
private const val ZONE_ALPHA: Float = 0.12f

/** The accent RSRP line's area fill: a soft indigo wash under the line (the Momentum trend fill). */
private const val AREA_FILL_ALPHA: Float = 0.14f

/** Before a trend exists (0–1 samples) the bands are barely tinted, so the panel does not read as a full pastel wash. */
private const val ZONE_ALPHA_IDLE: Float = 0.05f

/** The lone-reading guide line: a faint hint of the line's colour, so a single dot has a baseline for context. */
private const val IDLE_GUIDE_ALPHA: Float = 0.25f

@FieldTapPreviews
@Composable
private fun SignalHistoryChartPreview() {
    val now = 300_000L
    val rsrp = buildList {
        for (i in 0..60) add(ChartPoint(elapsedMs = i * 2_000L, value = -95 + ((i * 7) % 17) - 8))
        for (i in 90..150) add(ChartPoint(elapsedMs = i * 2_000L, value = -88 + ((i * 5) % 13) - 6))
    }
    val sinr = rsrp.map { ChartPoint(it.elapsedMs, (it.value + 110) / 2) }
    PreviewSurface {
        SectionCard {
            SignalHistoryChart(
                rsrp = rsrp,
                sinr = sinr,
                nowElapsedMs = now,
                labels = SignalChartLabels("RSRP", "dBm", "SINR", "dB", "5 min ago", "Now", "No fresh samples yet", window = "last 5 min"),
                summary = "RSRP over the last 5 minutes: latest -88 dBm.",
                gapThresholdMs = ChartMath.gapThresholdMs(shortInterval = true),
                rsrpRange = ChartMath.fittedRange(rsrp, now, LiveStateReducer.WINDOW_MS, SignalScale.RSRP_CHART_RANGE, SignalScale.RSRP_DISPLAY_RANGE),
            )
        }
        SectionCard(title = "Empty") {
            TimeSeriesChart(
                points = emptyList(),
                nowElapsedMs = now,
                range = SignalScale.RSRP_CHART_RANGE,
                lineColor = FieldTapDesign.colors.chartRsrp,
                referenceLines = SignalScale.RSRP_THRESHOLDS.boundaries,
                keyReference = -105,
                noDataText = "No fresh samples yet",
                zones = SignalScale.zones(SignalMetric.RSRP, SignalScale.RSRP_CHART_RANGE),
            )
        }
    }
}
