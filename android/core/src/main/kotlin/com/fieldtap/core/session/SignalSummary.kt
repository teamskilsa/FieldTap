package com.fieldtap.core.session

import com.fieldtap.format.Csv
import com.fieldtap.format.Ranges
import com.fieldtap.format.ServingRat
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.math.BigDecimal
import java.math.RoundingMode

/**
 * What a session's kpi.csv says about its signal, for the Sessions list and the Session detail screen.
 *
 * kpi.csv holds one row per fresh serving-cell sample per RAT, so an NSA session has LTE anchor rows and NR leg rows.
 * `fieldtap report` keeps the two apart, and so does this summary: it describes one RAT, [rat], never a mix of both.
 *
 * @property samples the rows of [rat] with an RSRP value.
 * @property medianRsrpDbm the median of those values, rounded half to even to a whole dBm. The signal scale's thresholds
 *   are odd numbers, so this rounding never moves the median across one.
 * @property belowFairPct the share of those values below -105 dBm, from 0 to 100, counted as the report's
 *   `pct_below_-105` is.
 * @property trace the RSRP values of [rat] against time, for the Session detail chart. Evenly thinned to at
 *   most [SignalSummaries.TRACE_MAX] points, so a three-hour session costs no more than a three-minute one;
 *   `x` is milliseconds since the session's first sample, so a sampling gap shows as a gap and not as a
 *   straight line through it.
 */
data class SignalSummary(
    val rat: ServingRat,
    val samples: Int,
    val medianRsrpDbm: Int,
    val belowFairPct: Double,
    val trace: List<TracePoint> = emptyList(),
)

/** One point of [SignalSummary.trace]: milliseconds since the first sample, and RSRP in whole dBm. */
data class TracePoint(val atMs: Long, val rsrpDbm: Int)

/**
 * Reads a [SignalSummary] from kpi.csv, one record at a time, so a long session costs no more memory than its RSRP
 * values.
 *
 * - The RAT is the one with more RSRP values, LTE on a tie: the network the session spent most of its samples on.
 * - A blank value, a value outside `Ranges.KPI_RSRP_DBM` for its RAT, and a row whose field count is not the header's
 *   are left out; `fieldtap validate` reports all three.
 * - A last row without its line ending, a torn write, is left out: its value may be cut short.
 *
 * Owner: workstream `session-core`.
 */
object SignalSummaries {
    /** The report's -105 dBm line in tenths of a dBm: a value below it counts in [SignalSummary.belowFairPct]. */
    private const val FAIR_TENTHS: Int = -1050
    /** The most points a trace keeps. More than a phone chart can draw, and a bounded cost. */
    const val TRACE_MAX: Int = 240

    private const val TIME_COLUMN = "time_epoch"
    private const val RAT_COLUMN = "rat"
    private const val RSRP_COLUMN = "rsrp_dbm"
    private const val LINE_FEED: Int = 0x0A
    private const val PERCENT: Double = 100.0

    /** The summary of [kpiCsv], or null when it is missing, cannot be read, lacks its columns or holds no RSRP value. */
    fun read(kpiCsv: File): SignalSummary? {
        if (!kpiCsv.isFile) return null
        return try {
            val complete = endsWithLineFeed(kpiCsv)
            Csv.RecordReader(kpiCsv.reader(Charsets.UTF_8)).use { reader ->
                of(generateSequence { reader.next() }, lastRecordComplete = complete)
            }
        } catch (e: IOException) {
            null
        } catch (e: SecurityException) {
            null
        }
    }

    /**
     * The summary of kpi.csv's [records], header first, as `Csv.RecordReader` returns them. [lastRecordComplete] false
     * leaves the last record out, for a file that does not end in a line feed.
     */
    fun of(records: Sequence<String>, lastRecordComplete: Boolean = true): SignalSummary? {
        val iterator = records.iterator()
        if (!iterator.hasNext()) return null
        val header = Csv.parseRecord(iterator.next())
        val ratIndex = header.indexOf(RAT_COLUMN)
        val rsrpIndex = header.indexOf(RSRP_COLUMN)
        val timeIndex = header.indexOf(TIME_COLUMN)
        if (ratIndex < 0 || rsrpIndex < 0) return null
        val values = ServingRat.entries.associateWith { IntBag() }
        // Kept in arrival order beside the bag, which sorts, because a chart needs the order the
        // samples came in and the median needs them sorted.
        val traces = ServingRat.entries.associateWith { mutableListOf<TracePoint>() }
        var pending: String? = null
        while (iterator.hasNext()) {
            val record = iterator.next()
            pending?.let { add(it, header.size, ratIndex, rsrpIndex, timeIndex, values, traces) }
            pending = record
        }
        if (lastRecordComplete) pending?.let { add(it, header.size, ratIndex, rsrpIndex, timeIndex, values, traces) }
        val lte = values.getValue(ServingRat.LTE)
        val nr = values.getValue(ServingRat.NR)
        val (rat, bag) = if (nr.size > lte.size) ServingRat.NR to nr else ServingRat.LTE to lte
        if (bag.size == 0) return null
        return summary(rat, bag.sorted()).copy(trace = thin(traces.getValue(rat)))
    }

    private fun add(
        record: String,
        width: Int,
        ratIndex: Int,
        rsrpIndex: Int,
        timeIndex: Int,
        values: Map<ServingRat, IntBag>,
        traces: Map<ServingRat, MutableList<TracePoint>>,
    ) {
        val fields = Csv.parseRecord(record)
        if (fields.size != width) return
        val rat = ServingRat.entries.firstOrNull { it.wire == fields[ratIndex] } ?: return
        val value = fields[rsrpIndex].toBigDecimalOrNull() ?: return
        val range = Ranges.KPI_RSRP_DBM[rat] ?: return
        if (!range.contains(value.toDouble())) return
        val tenths = value.movePointRight(1).setScale(0, RoundingMode.HALF_EVEN).toInt()
        values.getValue(rat).add(tenths)
        // time_epoch is seconds with a fraction; a row without a usable one is still a sample, just not
        // a point on the chart.
        if (timeIndex >= 0) {
            val seconds = fields[timeIndex].toBigDecimalOrNull()
            if (seconds != null) {
                val atMs = seconds.movePointRight(3).setScale(0, RoundingMode.HALF_EVEN).toLong()
                traces.getValue(rat).add(TracePoint(atMs, Math.round(tenths / 10.0).toInt()))
            }
        }
    }

    /**
     * [points] rezeroed on the first sample and thinned to at most [TRACE_MAX], keeping the first and the
     * last. Thinning takes every nth point rather than averaging: an average would soften exactly the dips
     * the chart exists to show.
     */
    private fun thin(points: List<TracePoint>): List<TracePoint> {
        if (points.isEmpty()) return emptyList()
        val zero = points.first().atMs
        val rebased = points.map { TracePoint(it.atMs - zero, it.rsrpDbm) }
        if (rebased.size <= TRACE_MAX) return rebased
        val step = rebased.size.toDouble() / TRACE_MAX
        val out = ArrayList<TracePoint>(TRACE_MAX)
        var i = 0.0
        while (out.size < TRACE_MAX - 1 && i < rebased.size) {
            out.add(rebased[i.toInt()])
            i += step
        }
        out.add(rebased.last())
        return out
    }

    /** [tenths] sorted ascending, not empty. */
    private fun summary(rat: ServingRat, tenths: IntArray): SignalSummary {
        val n = tenths.size
        val median = if (n % 2 == 1) {
            BigDecimal(tenths[n / 2]).movePointLeft(1)
        } else {
            // Tenths summed, then halved: (a + b) / 2 / 10. Twenty divides out exactly, so no precision is needed.
            BigDecimal(tenths[n / 2 - 1].toLong() + tenths[n / 2]).divide(BigDecimal(20))
        }
        val below = tenths.count { it < FAIR_TENTHS }
        return SignalSummary(
            rat = rat,
            samples = n,
            medianRsrpDbm = median.setScale(0, RoundingMode.HALF_EVEN).toInt(),
            belowFairPct = PERCENT * below / n,
        )
    }

    private fun endsWithLineFeed(file: File): Boolean {
        RandomAccessFile(file, "r").use { access ->
            val length = access.length()
            if (length == 0L) return false
            access.seek(length - 1)
            return access.read() == LINE_FEED
        }
    }

    /** A growable list of ints, so a session's values are never boxed. */
    private class IntBag {
        private var items = IntArray(INITIAL_CAPACITY)
        var size = 0
            private set

        fun add(value: Int) {
            if (size == items.size) items = items.copyOf(items.size * 2)
            items[size++] = value
        }

        fun sorted(): IntArray = items.copyOf(size).also { it.sort() }

        private companion object {
            const val INITIAL_CAPACITY = 256
        }
    }
}
