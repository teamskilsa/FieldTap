package com.fieldtap.ui.traffic

import com.fieldtap.core.nettest.IperfDirection
import java.time.Instant
import java.util.Locale

/** One kind of test in a sequence, in the order a round runs them. */
enum class SequenceStep { PING, DOWNLOAD, UPLOAD }

/**
 * What a sequence runs: the chosen steps, in a fixed order, round after round, with a pause between rounds.
 *
 * The drive-test staple — "ping, download, upload, every minute, for an hour" — is this and nothing more. It uses
 * the server, protocol, duration and streams already set above it, so a sequence is the single test the user just
 * tried, repeated, rather than a second configuration to keep in step.
 *
 * Owner: workstream `service-and-tests`.
 */
data class SequencePlan(
    val steps: Set<SequenceStep>,
    /** How many rounds; [UNTIL_STOPPED] to keep going. */
    val rounds: Int,
    val gapSec: Int,
) {
    val ordered: List<SequenceStep> get() = SequenceStep.entries.filter { it in steps }

    val runnable: Boolean get() = steps.isNotEmpty() && rounds >= UNTIL_STOPPED

    /** The round (from 1) and step of the [index]th test, or null once the plan is done. */
    fun at(index: Int): Pair<Int, SequenceStep>? {
        val steps = ordered
        if (steps.isEmpty() || index < 0) return null
        val round = index / steps.size + 1
        if (rounds != UNTIL_STOPPED && round > rounds) return null
        return round to steps[index % steps.size]
    }

    /** Whether the [index]th test opens a new round after the first: the pause goes before it. */
    fun startsRound(index: Int): Boolean = index > 0 && ordered.isNotEmpty() && index % ordered.size == 0

    companion object {
        const val UNTIL_STOPPED: Int = 0
    }
}

/** Where a running sequence is. [waitingSec] counts down the pause before the next round. */
data class SequenceProgress(
    val round: Int,
    val rounds: Int,
    val step: SequenceStep,
    val waitingSec: Int? = null,
)

/** Medians of what a sequence measured: the numbers a drive report quotes. */
data class SequenceSummary(
    val tests: Int,
    val failures: Int,
    val downloadMbps: Double?,
    val uploadMbps: Double?,
    val rttMs: Double?,
    val pingLossPercent: Double?,
)

object SequenceStats {

    fun summarize(results: List<TrafficResult>): SequenceSummary {
        val iperf = results.filterIsInstance<TrafficResult.Iperf>()
        val pings = results.filterIsInstance<TrafficResult.Ping>()
        val sent = pings.sumOf { it.sent }
        return SequenceSummary(
            tests = results.size,
            failures = results.count { it is TrafficResult.Failed },
            downloadMbps = median(iperf.filter { it.options.direction == IperfDirection.DOWNLOAD }.map { it.mbps }),
            uploadMbps = median(iperf.filter { it.options.direction == IperfDirection.UPLOAD }.map { it.mbps }),
            rttMs = median(pings.mapNotNull { it.avgMs }),
            pingLossPercent = if (sent == 0) null else (sent - pings.sumOf { it.received }) * 100.0 / sent,
        )
    }

    internal fun median(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2
    }
}

/**
 * The results as CSV, oldest first: one row per test, every column a spreadsheet or `pandas.read_csv` wants, with
 * the fields a test did not have left empty rather than zero.
 */
object TrafficCsv {

    val HEADER: List<String> = listOf(
        "time_utc", "test", "host", "protocol", "direction", "streams", "duration_s",
        "mbps", "peak_mbps", "jitter_ms", "loss_percent",
        "ping_sent", "ping_received", "rtt_min_ms", "rtt_avg_ms", "rtt_max_ms", "rtt_mdev_ms", "error",
    )

    fun of(results: List<TrafficResult>): String = buildString {
        append(HEADER.joinToString(",")).append("\r\n")
        for (r in results.sortedBy { it.finishedAtMs }) {
            val row = when (r) {
                is TrafficResult.Iperf -> listOf(
                    time(r.finishedAtMs), if (r.version.name == "V2") "iperf2" else "iperf3", r.options.host,
                    r.options.protocol.name.lowercase(Locale.ROOT), r.options.direction.name.lowercase(Locale.ROOT),
                    "${r.options.parallel}", number(r.seconds, 1), number(r.mbps, 2), number(r.peakMbps, 2),
                    r.jitterMs?.let { number(it, 3) }.orEmpty(), r.lossPercent?.let { number(it, 2) }.orEmpty(),
                    "", "", "", "", "", "", "",
                )
                is TrafficResult.Ping -> listOf(
                    time(r.finishedAtMs), "ping", r.host, "icmp", "", "", "", "", "", "",
                    number(r.lossPercent, 2), "${r.sent}", "${r.received}",
                    r.minMs?.let { number(it, 3) }.orEmpty(), r.avgMs?.let { number(it, 3) }.orEmpty(),
                    r.maxMs?.let { number(it, 3) }.orEmpty(), r.mdevMs?.let { number(it, 3) }.orEmpty(), "",
                )
                is TrafficResult.Failed -> listOf(
                    time(r.finishedAtMs), r.test, r.host, "", "", "", "", "", "", "", "", "", "", "", "", "", "", r.message,
                )
            }
            append(row.joinToString(",") { quote(it) }).append("\r\n")
        }
    }

    private fun time(ms: Long): String = Instant.ofEpochMilli(ms).toString()

    private fun number(v: Double, decimals: Int): String = String.format(Locale.ROOT, "%.${decimals}f", v)

    /** Quoted only when it has to be, the way Python's csv module writes. */
    private fun quote(field: String): String =
        if (field.any { it == ',' || it == '"' || it == '\n' || it == '\r' }) "\"" + field.replace("\"", "\"\"") + "\"" else field
}
