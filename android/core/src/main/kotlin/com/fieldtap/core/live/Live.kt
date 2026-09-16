package com.fieldtap.core.live

import com.fieldtap.core.input.CellInfoAnswer
import com.fieldtap.core.input.CellInfoRequestFailed
import com.fieldtap.core.input.CellSnapshot
import com.fieldtap.core.input.DataStateSnapshot
import com.fieldtap.core.input.DeviceConditions
import com.fieldtap.core.input.DisplayInfoSnapshot
import com.fieldtap.core.input.FixSample
import com.fieldtap.core.input.GnssSnapshot
import com.fieldtap.core.input.ListenerOutcome
import com.fieldtap.core.input.ListenerReport
import com.fieldtap.core.input.LocationAvailability
import com.fieldtap.core.input.MeasurementInput
import com.fieldtap.core.input.RadioListener
import com.fieldtap.core.input.ServiceStateSnapshot
import com.fieldtap.core.input.SignalSnapshot
import com.fieldtap.core.radio.CadencePolicy
import com.fieldtap.core.radio.ClassifiedAnswer
import com.fieldtap.core.radio.FreshnessEngine
import com.fieldtap.format.Rat

/** One cell as the Live screen shows it. */
data class LiveCell(
    val rat: Rat,
    val pci: Int?,
    val arfcn: Int?,
    val band: Int?,
    val rsrp: Int?,
    val rsrq: Int?,
    val sinr: Int?,
    val plmn: String?,
    val operator: String?,
    val connectionStatus: Int?,
    /** `timestampMs` of the measurement, to age it on every tick. */
    val timestampMs: Long,
    // What the Signal tab shows beyond the headline three. Defaulted so a cell built for a chart or a
    // test does not have to invent a tracking area.
    val tac: Int? = null,
    val cellId: Long? = null,
    val bandwidthKhz: Int? = null,
    val rssi: Int? = null,
    val cqi: Int? = null,
    val timingAdvance: Int? = null,
) {
    companion object {
        /**
         * The Live view of [cell]: the first of its bands, the PLMN only when both MCC and MNC are known,
         * and the long operator name (else the short one), blank names counting as unknown.
         */
        fun of(cell: CellSnapshot): LiveCell {
            val mcc = cell.mcc
            val mnc = cell.mnc
            return LiveCell(
                rat = cell.rat,
                pci = cell.pci,
                arfcn = cell.arfcn,
                // A modem reports -1 for a band it did not fill in (the OnePlus sends one copy of its
                // serving cell with band 7 and another with -1). Not a band; the EARFCN can say which.
                band = cell.bands.firstOrNull { it > 0 },
                rsrp = cell.rsrp,
                rsrq = cell.rsrq,
                sinr = cell.sinr,
                plmn = if (mcc != null && mnc != null) mcc + mnc else null,
                operator = cell.operatorLong?.takeIf { it.isNotBlank() } ?: cell.operatorShort?.takeIf { it.isNotBlank() },
                connectionStatus = cell.connectionStatus,
                timestampMs = cell.timestampMs,
                tac = cell.tac,
                cellId = cell.cellId,
                bandwidthKhz = cell.bandwidthKhz,
                rssi = cell.rssi,
                cqi = cell.cqi,
                timingAdvance = cell.timingAdvance,
            )
        }
    }
}

/** The age badge on the serving tile. */
enum class AgeBadge {
    /** No serving sample yet. */
    NONE,

    /** At most 2500 ms old. */
    FRESH,

    /** At most 11 000 ms old. */
    AGING,

    /** Older: the tile greys out and says so. */
    STALE,
}

/** A chart point: elapsedRealtime of the measurement and its value. */
data class ChartPoint(val elapsedMs: Long, val value: Int)

/**
 * One stay on one serving cell: the cell as it was last measured, and the measurement times of the
 * first and most recent samples taken while it was serving. `untilMs` equals `sinceMs` for a cell
 * seen once, so a dwell is `untilMs - sinceMs` and is zero rather than unknown.
 */
data class ServingVisit(val cell: LiveCell, val sinceMs: Long, val untilMs: Long)

/** Everything the Live screen draws. Plain values; the screen never computes. */
data class LiveState(
    val serving: LiveCell? = null,
    val nsaLeg: LiveCell? = null,
    val servingAgeMs: Long? = null,
    val badge: AgeBadge = AgeBadge.NONE,
    /** From the newest answer: cells that are neither primary nor secondary serving, strongest first. */
    val neighbours: List<LiveCell> = emptyList(),
    /**
     * The serving cells this phone has used while Live has been watching, newest first, capped at
     * [LiveStateReducer.HISTORY_MAX]. The first entry is the cell serving now. Reselection and
     * handover thrash is visible here and nowhere else on the screen.
     */
    val servingHistory: List<ServingVisit> = emptyList(),
    /**
     * From the newest answer: carriers this phone is aggregating — cells reporting secondary serving
     * that are not the NSA leg, strongest first. An LTE SCell beside an LTE primary, or an NR SCC on
     * standalone NR. They are being used, so they are not neighbours.
     */
    val aggregatedLegs: List<LiveCell> = emptyList(),
    /** Fresh primary serving RSRP over the last 5 minutes. */
    val rsrpSeries: List<ChartPoint> = emptyList(),
    /** Fresh primary serving SINR over the last 5 minutes. */
    val sinrSeries: List<ChartPoint> = emptyList(),
    /** True for Android's 2 s interval, false for 10 s, null before any answer. */
    val shortInterval: Boolean? = null,
    /** Median of the last 10 fresh intervals. */
    val recentFreshIntervalMs: Long? = null,
    val conditions: DeviceConditions? = null,
    val service: ServiceStateSnapshot? = null,
    val display: DisplayInfoSnapshot? = null,
    val data: DataStateSnapshot? = null,
    val signal: SignalSnapshot? = null,
    val lastFix: FixSample? = null,
    val gnss: GnssSnapshot? = null,
    /** False while location services are switched off, when Android returns no cell information and no fixes; null before Android said. */
    val locationEnabled: Boolean? = null,
    val listeners: Map<RadioListener, ListenerOutcome> = emptyMap(),
    val nowElapsedMs: Long = 0,
)

/**
 * The Live screen's state, reduced from the same [MeasurementInput] stream the recorder gets, while
 * the screen is visible or a session runs. It de-duplicates with its own
 * [com.fieldtap.core.radio.FreshnessEngine] and picks serving cells with
 * [com.fieldtap.core.radio.ServingCellSelector]; it never writes files.
 *
 * - [reduce] folds one input in; [tick] re-ages the badge and drops chart points older than [WINDOW_MS].
 * - [badge]: null -> NONE, <= 2500 FRESH, <= 11 000 AGING, else STALE.
 *
 * Rules [reduce] applies to a cell-info answer:
 * - The serving tile shows the answer's primary serving cell when it is a new measurement, when nothing
 *   is shown yet, or when it is at least as new as the cell shown. A cached repeat of an older measurement
 *   never replaces a newer one. With no primary serving cell in the answer, the last one stays and ages,
 *   so its badge turns STALE rather than the tile going blank.
 * - The NSA leg is taken from the same answer as the serving cell, so it disappears when the primary no
 *   longer has one.
 * - Neighbours are every other cell of the newest answer, strongest RSRP first; cells without RSRP (GSM,
 *   WCDMA) follow in Android's order.
 * - Only a fresh primary serving sample adds a chart point, at its modem timestamp, so repeats never do.
 * - [LiveState.recentFreshIntervalMs] is the median (element `size / 2` of the sorted intervals) of the
 *   last [FRESH_INTERVAL_HISTORY] intervals between fresh answers, measured on modem timestamps.
 *
 * Every input moves [LiveState.nowElapsedMs] to its observation time, and time never moves backwards. The
 * reducer keeps de-duplication memory between calls, so one instance serves one stream; it is not
 * thread-safe.
 *
 * Tests: chart window; repeats do not add chart points; neighbour ordering; badge thresholds.
 *
 * Owner: workstream `ui-session`.
 */
class LiveStateReducer {
    private val freshness = FreshnessEngine()
    private val freshIntervals = ArrayDeque<Long>(FRESH_INTERVAL_HISTORY + 1)
    private var lastFreshReferenceMs: Long? = null

    /** [state] with [input] folded in, re-aged at the input's observation time. */
    fun reduce(state: LiveState, input: MeasurementInput): LiveState {
        val nowElapsedMs = maxOf(state.nowElapsedMs, input.observedElapsedMs)
        val next = when (input) {
            is CellInfoAnswer -> onAnswer(state, input)
            is CellInfoRequestFailed -> state
            is ServiceStateSnapshot -> state.copy(service = input)
            is DataStateSnapshot -> state.copy(data = input)
            is DisplayInfoSnapshot -> state.copy(display = input)
            is SignalSnapshot -> state.copy(signal = input)
            is ListenerReport -> state.copy(listeners = state.listeners + (input.listener to input.outcome))
            is FixSample -> onFix(state, input)
            is GnssSnapshot -> state.copy(gnss = input)
            is LocationAvailability -> state.copy(locationEnabled = input.locationEnabled)
        }
        return aged(next, nowElapsedMs)
    }

    /** [state] re-aged at [nowElapsedMs] (never earlier than the state's own time), with old chart points dropped. */
    fun tick(state: LiveState, nowElapsedMs: Long): LiveState = aged(state, maxOf(state.nowElapsedMs, nowElapsedMs))

    private fun onAnswer(state: LiveState, answer: CellInfoAnswer): LiveState {
        val classified = freshness.classify(answer)
        val primary = classified.primary
        val shown = state.serving
        val servingFromAnswer = primary?.takeIf { !it.stale || shown == null || it.cell.timestampMs >= shown.timestampMs }

        val serving = servingFromAnswer?.let { LiveCell.of(it.cell) } ?: shown
        val nsaLeg = if (servingFromAnswer != null) classified.nsaSecondary?.let { LiveCell.of(it.cell) } else state.nsaLeg
        val others = classified.cells.filter { it !== classified.primary && it !== classified.nsaSecondary }
        val (aggregated, rest) = others.partition {
            it.cell.connectionStatus == CellSnapshot.CONNECTION_SECONDARY_SERVING
        }
        val aggregatedLegs = aggregated.map { LiveCell.of(it.cell) }.sortedWith(STRONGEST_FIRST)
        val neighbours = rest.map { LiveCell.of(it.cell) }.sortedWith(STRONGEST_FIRST)

        var rsrpSeries = state.rsrpSeries
        var sinrSeries = state.sinrSeries
        if (primary != null && !primary.stale) {
            val measuredAt = primary.cell.timestampMs
            primary.cell.rsrp?.let { rsrpSeries = rsrpSeries.withPoint(ChartPoint(measuredAt, it)) }
            primary.cell.sinr?.let { sinrSeries = sinrSeries.withPoint(ChartPoint(measuredAt, it)) }
        }
        recordFreshInterval(classified)

        return state.copy(
            serving = serving,
            nsaLeg = nsaLeg,
            neighbours = neighbours,
            aggregatedLegs = aggregatedLegs,
            servingHistory = visited(state.servingHistory, serving),
            rsrpSeries = rsrpSeries,
            sinrSeries = sinrSeries,
            shortInterval = CadencePolicy.isShortInterval(answer.conditions),
            recentFreshIntervalMs = medianFreshIntervalMs(),
            conditions = answer.conditions,
        )
    }

    private fun onFix(state: LiveState, fix: FixSample): LiveState {
        val current = state.lastFix
        return if (current == null || fix.elapsedMs >= current.elapsedMs) state.copy(lastFix = fix) else state
    }

    /** Remembers the interval since the previous fresh answer, keyed on the modem timestamp that stands for each. */
    private fun recordFreshInterval(classified: ClassifiedAnswer) {
        if (!classified.fresh) return
        val reference = classified.primary?.cell?.timestampMs
            ?: classified.cells.filter { !it.stale }.maxOfOrNull { it.cell.timestampMs }
            ?: return
        val previous = lastFreshReferenceMs
        if (previous != null && reference <= previous) return
        lastFreshReferenceMs = reference
        if (previous == null) return
        freshIntervals.addLast(reference - previous)
        while (freshIntervals.size > FRESH_INTERVAL_HISTORY) freshIntervals.removeFirst()
    }

    private fun medianFreshIntervalMs(): Long? {
        if (freshIntervals.isEmpty()) return null
        val sorted = freshIntervals.sorted()
        return sorted[sorted.size / 2]
    }

    /**
     * [history] with [serving] recorded. The same cell extends the newest visit rather than opening a
     * second one; a different cell opens one and drops the oldest past [HISTORY_MAX]. Cells are the
     * same when their RAT, PCI and channel agree, which is all Live knows about a cell for certain.
     */
    private fun visited(history: List<ServingVisit>, serving: LiveCell?): List<ServingVisit> {
        if (serving == null) return history
        val newest = history.firstOrNull()
        if (newest != null && isSameCell(newest.cell, serving)) {
            // Never let a stale repeat drag the dwell backwards.
            val until = maxOf(newest.untilMs, serving.timestampMs)
            return listOf(newest.copy(cell = serving, untilMs = until)) + history.drop(1)
        }
        val visit = ServingVisit(serving, serving.timestampMs, serving.timestampMs)
        return (listOf(visit) + history).take(HISTORY_MAX)
    }

    private fun isSameCell(a: LiveCell, b: LiveCell): Boolean =
        a.rat == b.rat && a.pci == b.pci && a.arfcn == b.arfcn

    private fun aged(state: LiveState, nowElapsedMs: Long): LiveState {
        val ageMs = state.serving?.let { (nowElapsedMs - it.timestampMs).coerceAtLeast(0) }
        val cutoffMs = nowElapsedMs - WINDOW_MS
        return state.copy(
            nowElapsedMs = nowElapsedMs,
            servingAgeMs = ageMs,
            badge = badge(ageMs),
            rsrpSeries = state.rsrpSeries.prunedBefore(cutoffMs),
            sinrSeries = state.sinrSeries.prunedBefore(cutoffMs),
        )
    }

    companion object {
        /** How many serving cells [LiveState.servingHistory] keeps. */
        const val HISTORY_MAX: Int = 20

        /** The chart window: 5 minutes of elapsedRealtime. */
        const val WINDOW_MS: Long = 300_000

        /** The oldest sample the badge calls FRESH: the KPI age limit on Android's 2 s interval. */
        const val FRESH_MAX_AGE_MS: Long = CadencePolicy.SHORT_MAX_AGE_MS

        /** The oldest sample the badge calls AGING: the KPI age limit on Android's 10 s interval. */
        const val AGING_MAX_AGE_MS: Long = CadencePolicy.LONG_MAX_AGE_MS

        /** How many intervals between fresh answers [LiveState.recentFreshIntervalMs] is the median of. */
        const val FRESH_INTERVAL_HISTORY: Int = 10

        fun badge(ageMs: Long?): AgeBadge = when {
            ageMs == null -> AgeBadge.NONE
            ageMs <= FRESH_MAX_AGE_MS -> AgeBadge.FRESH
            ageMs <= AGING_MAX_AGE_MS -> AgeBadge.AGING
            else -> AgeBadge.STALE
        }

        /** Strongest RSRP first; cells without RSRP keep their order after all cells with one. */
        private val STRONGEST_FIRST: Comparator<LiveCell> =
            compareBy(nullsLast(reverseOrder<Int>())) { cell: LiveCell -> cell.rsrp }
    }
}

/** This series with [point] added in time order; appending is the usual case. */
private fun List<ChartPoint>.withPoint(point: ChartPoint): List<ChartPoint> {
    if (isEmpty() || last().elapsedMs <= point.elapsedMs) return this + point
    val index = indexOfFirst { it.elapsedMs > point.elapsedMs }
    return toMutableList().apply { add(index, point) }
}

/** This series without the points measured before [cutoffMs]; the point at the cutoff stays. */
private fun List<ChartPoint>.prunedBefore(cutoffMs: Long): List<ChartPoint> =
    if (isEmpty() || first().elapsedMs >= cutoffMs) this else filter { it.elapsedMs >= cutoffMs }
