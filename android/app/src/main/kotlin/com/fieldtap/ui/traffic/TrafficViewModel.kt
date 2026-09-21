package com.fieldtap.ui.traffic

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.fieldtap.R
import com.fieldtap.core.nettest.IperfDirection
import com.fieldtap.core.nettest.Iperf2Failure
import com.fieldtap.core.nettest.Iperf2Wire
import com.fieldtap.core.nettest.Iperf3Failure
import com.fieldtap.core.nettest.IperfOptions
import com.fieldtap.core.nettest.IperfProtocol
import com.fieldtap.core.nettest.NetFailure
import com.fieldtap.core.nettest.PingOutcome
import com.fieldtap.core.nettest.PingStats
import com.fieldtap.nettest.CellularIperf3
import com.fieldtap.nettest.CellularLink
import com.fieldtap.nettest.IperfVersion
import com.fieldtap.nettest.CellularNetworks
import com.fieldtap.nettest.CellularTestTransport
import com.fieldtap.nettest.cellularLinks
import com.fieldtap.platform.clock.AndroidClock
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What the Traffic tab can run. iperf2 and iperf3 are separate because their servers are. */
enum class TrafficMode { IPERF3, IPERF2, PING;

    val iperfVersion: IperfVersion? get() = when (this) {
        IPERF3 -> IperfVersion.V3
        IPERF2 -> IperfVersion.V2
        PING -> null
    }

    /** The port a stock server of this kind listens on. */
    val defaultPort: Int? get() = when (this) {
        IPERF3 -> IperfOptions.DEFAULT_PORT
        IPERF2 -> Iperf2Wire.DEFAULT_PORT
        PING -> null
    }
}

/** The shape of the run whose samples are on screen: its kind, and how many samples a full run has. */
data class SampledRun(val mode: TrafficMode, val slots: Int)

/** One finished run, for the result card and the history under it. */
sealed interface TrafficResult {
    val finishedAtMs: Long

    data class Iperf(
        override val finishedAtMs: Long,
        val version: IperfVersion,
        val options: IperfOptions,
        val mbps: Double,
        val peakMbps: Double,
        val seconds: Double,
        val sentBytes: Long?,
        val receivedBytes: Long?,
        val jitterMs: Double?,
        val lossPercent: Double?,
        val lostPackets: Long?,
        val packets: Long?,
    ) : TrafficResult

    data class Ping(
        override val finishedAtMs: Long,
        val host: String,
        val sent: Int,
        val received: Int,
        val minMs: Double?,
        val avgMs: Double?,
        val maxMs: Double?,
        val mdevMs: Double?,
    ) : TrafficResult {
        val lossPercent: Double get() = if (sent == 0) 0.0 else (sent - received) * 100.0 / sent
    }

    /** A test in a sequence that did not produce a result: kept in the log, so a sequence's gaps show. */
    data class Failed(
        override val finishedAtMs: Long,
        /** "ping", "iperf2", "iperf3". */
        val test: String,
        val host: String,
        val message: String,
    ) : TrafficResult
}

data class TrafficUiState(
    val host: String = "",
    val port: String = Iperf2Wire.DEFAULT_PORT.toString(),
    val mode: TrafficMode = TrafficMode.IPERF2,
    val protocol: IperfProtocol = IperfProtocol.TCP,
    val direction: IperfDirection = IperfDirection.DOWNLOAD,
    val durationSec: Int = 10,
    val parallel: Int = 1,
    val udpMbps: String = "10",
    val pingCount: Int = 10,
    val link: CellularLink = CellularLink(up = false),
    val running: Boolean = false,
    /** iPerf3: Mbps per second so far. Ping: round trip per echo so far, null where it was lost. */
    val samples: List<Double?> = emptyList(),
    /**
     * What produced [samples], fixed when the run starts. The live panel is labelled from this, never from
     * the current selection: ten ping round trips, left on screen after switching to iPerf3, were drawn as
     * "Throughput 19.5 Mbps · 10 / 60 s" — an iperf run that never happened, apparently dying at 10 s.
     */
    val sampled: SampledRun? = null,
    val result: TrafficResult? = null,
    val error: String? = null,
    val history: List<TrafficResult> = emptyList(),
    val sequenceSteps: Set<SequenceStep> = SequenceStep.entries.toSet(),
    val sequenceRounds: Int = 5,
    val sequenceGapSec: Int = 10,
    /** The iperf a sequence's download and upload steps use: the last one chosen above. */
    val sequenceIperf: TrafficMode = TrafficMode.IPERF2,
    /** Non-null while a sequence runs. */
    val sequence: SequenceProgress? = null,
    /** When the last sequence started, to summarise only what it measured. */
    val sequenceStartedAtMs: Long? = null,
) {
    val plan: SequencePlan get() = SequencePlan(sequenceSteps, sequenceRounds, sequenceGapSec)

    /** A sequence needs the server, and an iperf port when it moves data. */
    val canStartSequence: Boolean
        get() = !running && host.isNotBlank() && plan.runnable &&
            (sequenceSteps == setOf(SequenceStep.PING) || (portNumber != null && (protocol == IperfProtocol.TCP || udpBitrateBps != null)))

    /** What the last sequence measured, once it has measured something. */
    val sequenceResults: List<TrafficResult>
        get() = sequenceStartedAtMs?.let { start -> history.filter { it.finishedAtMs >= start } }.orEmpty()

    val portNumber: Int? get() = port.toIntOrNull()?.takeIf { it in 1..65_535 }
    val udpBitrateBps: Long? get() = udpMbps.toDoubleOrNull()?.takeIf { it > 0 && it <= 10_000 }?.let { (it * 1_000_000).toLong() }

    /** Start is offered only for something that can run: a server, a port, and for UDP a rate. */
    val canStart: Boolean
        get() = !running && host.isNotBlank() &&
            (mode == TrafficMode.PING || (portNumber != null && (protocol == IperfProtocol.TCP || udpBitrateBps != null)))
}

/**
 * Drives the Traffic tab: iperf3 and ping against a server the user names, always on cellular.
 *
 * The server is typed in, not configured once in Settings: in a lab it is the callbox, and the callbox's
 * address changes with the test plan. The last one used is remembered so it is there the next morning.
 *
 * Owner: workstream `service-and-tests`.
 */
class TrafficViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = application.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val networks = CellularNetworks(application)
    private val iperf = CellularIperf3(networks)
    private val transport = CellularTestTransport(networks, AndroidClock)
    private var job: Job? = null

    private val mutableState = MutableStateFlow(restore())
    val state: StateFlow<TrafficUiState> = mutableState.asStateFlow()

    init {
        viewModelScope.launch {
            cellularLinks(application).collect { link -> mutableState.update { it.copy(link = link) } }
        }
    }

    fun setHost(value: String) = edit { it.copy(host = value.trim()) }
    fun setPort(value: String) = edit { it.copy(port = value.filter(Char::isDigit).take(5)) }
    /**
     * Switching between iperf2 and iperf3 moves the port with it when it was still the other one's default:
     * 5001 and 5201 are easy to mix up, and an iperf3 client on an iperf2 port fails in a way that looks
     * like the server is down.
     */
    fun setMode(value: TrafficMode) = edit { current ->
        val otherDefault = current.mode.defaultPort?.toString()
        val port = if (value.defaultPort != null && (current.port == otherDefault || current.port.isBlank())) value.defaultPort.toString() else current.port
        current.copy(mode = value, port = port, sequenceIperf = if (value == TrafficMode.PING) current.sequenceIperf else value)
    }

    fun toggleSequenceStep(step: SequenceStep) = edit {
        it.copy(sequenceSteps = if (step in it.sequenceSteps) it.sequenceSteps - step else it.sequenceSteps + step)
    }
    fun setSequenceRounds(value: Int) = edit { it.copy(sequenceRounds = value) }
    fun setSequenceGap(value: Int) = edit { it.copy(sequenceGapSec = value) }

    /**
     * Runs the plan: each step with the settings above, round after round, a failed step logged and passed
     * over rather than ending the sequence — one refused connection in an hour-long drive is a data point.
     */
    fun startSequence() {
        val first = mutableState.value
        if (!first.canStartSequence) return
        val plan = first.plan
        val startedAt = System.currentTimeMillis()
        mutableState.update { it.copy(running = true, result = null, error = null, sequenceStartedAtMs = startedAt) }
        job = viewModelScope.launch {
            try {
                var index = 0
                while (true) {
                    val (round, step) = plan.at(index) ?: break
                    if (plan.startsRound(index) && plan.gapSec > 0) {
                        for (left in plan.gapSec downTo 1) {
                            mutableState.update { it.copy(sequence = SequenceProgress(round, plan.rounds, step, waitingSec = left)) }
                            delay(1_000)
                        }
                    }
                    val settings = mutableState.value
                    val s = when (step) {
                        SequenceStep.PING -> settings.copy(mode = TrafficMode.PING)
                        SequenceStep.DOWNLOAD -> settings.copy(mode = settings.sequenceIperf, direction = IperfDirection.DOWNLOAD)
                        SequenceStep.UPLOAD -> settings.copy(mode = settings.sequenceIperf, direction = IperfDirection.UPLOAD)
                    }
                    val slots = if (s.mode == TrafficMode.PING) s.pingCount else s.durationSec
                    mutableState.update {
                        it.copy(
                            sequence = SequenceProgress(round, plan.rounds, step),
                            samples = emptyList(),
                            sampled = SampledRun(s.mode, slots),
                            error = null,
                        )
                    }
                    val outcome = try {
                        when (s.mode) {
                            TrafficMode.PING -> runPing(s)
                            TrafficMode.IPERF3, TrafficMode.IPERF2 -> runIperf(s)
                        } ?: failed(s, mutableState.value.error ?: text(R.string.traffic_no_bearer))
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        failed(s, describe(e, s))
                    }
                    mutableState.update {
                        it.copy(
                            result = outcome.takeIf { r -> r !is TrafficResult.Failed } ?: it.result,
                            history = (listOf(outcome) + it.history).take(HISTORY_MAX_SEQUENCE),
                        )
                    }
                    index++
                }
            } finally {
                mutableState.update { it.copy(running = false, sequence = null) }
            }
        }
    }

    private fun failed(s: TrafficUiState, message: String) = TrafficResult.Failed(
        finishedAtMs = System.currentTimeMillis(),
        test = when (s.mode) {
            TrafficMode.PING -> "ping"
            TrafficMode.IPERF2 -> "iperf2"
            TrafficMode.IPERF3 -> "iperf3"
        },
        host = s.host,
        message = message,
    )

    /** The results on screen as a CSV file under the shareable exports directory. */
    fun exportCsv(): java.io.File? {
        val results = mutableState.value.history
        if (results.isEmpty()) return null
        val dir = java.io.File(getApplication<Application>().cacheDir, com.fieldtap.ui.common.FileSharer.EXPORTS_DIR)
        if (!dir.isDirectory && !dir.mkdirs()) return null
        dir.listFiles()?.filter { it.name.startsWith(CSV_PREFIX) }?.forEach { it.delete() }
        val stamp = java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.ROOT).apply {
            timeZone = java.util.TimeZone.getTimeZone("UTC")
        }.format(java.util.Date())
        return java.io.File(dir, "$CSV_PREFIX$stamp.csv").apply { writeText(TrafficCsv.of(results), Charsets.UTF_8) }
    }
    fun setProtocol(value: IperfProtocol) = edit { it.copy(protocol = value) }
    fun setDirection(value: IperfDirection) = edit { it.copy(direction = value) }
    fun setDuration(value: Int) = edit { it.copy(durationSec = value) }
    fun setParallel(value: Int) = edit { it.copy(parallel = value) }
    fun setUdpMbps(value: String) = edit { it.copy(udpMbps = value.filter { c -> c.isDigit() || c == '.' }.take(6)) }
    fun setPingCount(value: Int) = edit { it.copy(pingCount = value) }

    fun start() {
        val current = mutableState.value
        if (!current.canStart) return
        val slots = if (current.mode == TrafficMode.PING) current.pingCount else current.durationSec
        mutableState.update {
            it.copy(running = true, samples = emptyList(), sampled = SampledRun(current.mode, slots), result = null, error = null)
        }
        job = viewModelScope.launch {
            try {
                val result = when (current.mode) {
                    TrafficMode.IPERF3, TrafficMode.IPERF2 -> runIperf(current)
                    TrafficMode.PING -> runPing(current)
                }
                mutableState.update {
                    it.copy(
                        running = false,
                        result = result,
                        history = if (result != null) (listOf(result) + it.history).take(HISTORY_MAX_SEQUENCE) else it.history,
                    )
                }
            } catch (e: CancellationException) {
                mutableState.update { it.copy(running = false) }
                throw e
            } catch (e: Exception) {
                mutableState.update { it.copy(running = false, error = describe(e, current)) }
            }
        }
    }

    fun stop() {
        job?.cancel()
        mutableState.update { it.copy(running = false, sequence = null) }
    }

    private suspend fun runIperf(s: TrafficUiState): TrafficResult? {
        val options = IperfOptions(
            host = s.host,
            port = s.portNumber!!,
            protocol = s.protocol,
            direction = s.direction,
            durationSec = s.durationSec,
            parallel = s.parallel,
            udpBitrateBps = s.udpBitrateBps ?: IperfOptions("x").udpBitrateBps,
        )
        val version = s.mode.iperfVersion!!
        val result = iperf.run(s.mode.iperfVersion!!, options) { interval ->
            mutableState.update { it.copy(samples = it.samples + interval.mbps) }
        }
        if (result == null) {
            mutableState.update { it.copy(error = text(R.string.traffic_no_bearer)) }
            return null
        }
        // iperf2 over UDP ends by asking the server for its report. No answer means it never heard the
        // test — usually no `iperf -s -u` on that port, since UDP has no connection to be refused.
        if (version == IperfVersion.V2 && options.protocol == IperfProtocol.UDP && options.direction == IperfDirection.UPLOAD && result.receivedBytes == null) {
            mutableState.update { it.copy(error = text(R.string.traffic_error_iperf2_no_report, s.host, s.port)) }
        }
        return TrafficResult.Iperf(
            finishedAtMs = System.currentTimeMillis(),
            version = version,
            options = options,
            mbps = result.mbps,
            peakMbps = result.peakMbps,
            seconds = result.seconds,
            sentBytes = result.sentBytes,
            receivedBytes = result.receivedBytes,
            jitterMs = result.jitterMs,
            lossPercent = result.lossPercent,
            lostPackets = result.lostPackets,
            packets = result.packets,
        )
    }

    private suspend fun runPing(s: TrafficUiState): TrafficResult? {
        val outcome = transport.pingLive(s.host, s.pingCount, PING_TIMEOUT_MS) { _, rtt ->
            mutableState.update { it.copy(samples = it.samples + rtt) }
        }
        return when (outcome) {
            is PingOutcome.Failed -> {
                mutableState.update { it.copy(error = describe(outcome.failure, s.host)) }
                null
            }

            is PingOutcome.Replies -> {
                val summary = PingStats.summarize(outcome.sent, outcome.rttsMs)
                TrafficResult.Ping(
                    finishedAtMs = System.currentTimeMillis(),
                    host = s.host,
                    sent = outcome.sent,
                    received = outcome.rttsMs.size,
                    minMs = summary.rttMinMs,
                    avgMs = summary.rttAvgMs,
                    maxMs = summary.rttMaxMs,
                    mdevMs = mdev(outcome.rttsMs),
                )
            }
        }
    }

    /**
     * The spread iputils `ping` prints as mdev: sqrt(mean(rtt²) − mean(rtt)²), the population standard
     * deviation. The same formula, so the number matches a desktop ping to the same callbox.
     */
    private fun mdev(rtts: List<Double>): Double? {
        if (rtts.size < 2) return null
        val mean = rtts.average()
        val meanOfSquares = rtts.sumOf { it * it } / rtts.size
        return kotlin.math.sqrt((meanOfSquares - mean * mean).coerceAtLeast(0.0))
    }

    /** Says what went wrong in the terms someone at a callbox would check next. */
    private fun describe(e: Exception, s: TrafficUiState): String = when (e) {
        is Iperf3Failure.Busy -> text(R.string.traffic_error_busy, s.host)
        is Iperf2Failure.NoReverse -> text(R.string.traffic_error_iperf2_no_reverse, s.host, s.link.ipv4 ?: "<phone IP>")
        is Iperf3Failure -> e.message ?: text(R.string.traffic_error_broke_off)
        is ConnectException -> text(if (s.mode == TrafficMode.IPERF2) R.string.traffic_error_refused_iperf2 else R.string.traffic_error_refused, s.host, s.port)
        is NoRouteToHostException -> text(R.string.traffic_error_no_route, s.host)
        is SocketTimeoutException -> text(R.string.traffic_error_timeout, s.host, s.port)
        else -> e.message ?: e.javaClass.simpleName
    }

    private fun describe(failure: NetFailure, host: String): String = when (failure) {
        NetFailure.NO_CELLULAR_NETWORK -> text(R.string.traffic_no_bearer)
        NetFailure.DNS -> text(R.string.traffic_error_dns, host)
        NetFailure.SOCKET_NOT_PERMITTED -> text(R.string.traffic_error_ping_not_permitted)
        else -> text(R.string.traffic_error_ping, failure.errorText)
    }

    private fun text(id: Int, vararg args: Any): String = getApplication<Application>().getString(id, *args)

    private fun edit(change: (TrafficUiState) -> TrafficUiState) {
        mutableState.update(change)
        val s = mutableState.value
        prefs.edit()
            .putString(K_HOST, s.host)
            .putString(K_PORT, s.port)
            .putString(K_MODE, s.mode.name)
            .putString(K_PROTOCOL, s.protocol.name)
            .putString(K_DIRECTION, s.direction.name)
            .putInt(K_DURATION, s.durationSec)
            .putInt(K_PARALLEL, s.parallel)
            .putString(K_UDP, s.udpMbps)
            .putInt(K_PING_COUNT, s.pingCount)
            .putString(K_SEQ_STEPS, s.sequenceSteps.joinToString(",") { it.name })
            .putInt(K_SEQ_ROUNDS, s.sequenceRounds)
            .putInt(K_SEQ_GAP, s.sequenceGapSec)
            .putString(K_SEQ_IPERF, s.sequenceIperf.name)
            .apply()
    }

    private fun restore(): TrafficUiState {
        val d = TrafficUiState()
        return d.copy(
            host = prefs.getString(K_HOST, d.host) ?: d.host,
            port = prefs.getString(K_PORT, d.port) ?: d.port,
            // "IPERF" from before iperf2 existed was iperf3.
            mode = if (prefs.getString(K_MODE, null) == "IPERF") TrafficMode.IPERF3 else enumOr(prefs.getString(K_MODE, null), d.mode),
            protocol = enumOr(prefs.getString(K_PROTOCOL, null), d.protocol),
            direction = enumOr(prefs.getString(K_DIRECTION, null), d.direction),
            durationSec = prefs.getInt(K_DURATION, d.durationSec),
            parallel = prefs.getInt(K_PARALLEL, d.parallel),
            udpMbps = prefs.getString(K_UDP, d.udpMbps) ?: d.udpMbps,
            pingCount = prefs.getInt(K_PING_COUNT, d.pingCount),
            sequenceSteps = prefs.getString(K_SEQ_STEPS, null)
                ?.split(',')?.mapNotNull { name -> SequenceStep.entries.firstOrNull { it.name == name } }?.toSet()
                ?: d.sequenceSteps,
            sequenceRounds = prefs.getInt(K_SEQ_ROUNDS, d.sequenceRounds),
            sequenceGapSec = prefs.getInt(K_SEQ_GAP, d.sequenceGapSec),
            sequenceIperf = enumOr(prefs.getString(K_SEQ_IPERF, null), d.sequenceIperf).takeIf { it != TrafficMode.PING } ?: d.sequenceIperf,
        )
    }

    private companion object {
        const val PREFS = "traffic"
        const val K_HOST = "host"
        const val K_PORT = "port"
        const val K_MODE = "mode"
        const val K_PROTOCOL = "protocol"
        const val K_DIRECTION = "direction"
        const val K_DURATION = "duration"
        const val K_PARALLEL = "parallel"
        const val K_UDP = "udp_mbps"
        const val K_PING_COUNT = "ping_count"
        const val K_SEQ_STEPS = "sequence_steps"
        const val K_SEQ_ROUNDS = "sequence_rounds"
        const val K_SEQ_GAP = "sequence_gap"
        const val K_SEQ_IPERF = "sequence_iperf"
        const val PING_TIMEOUT_MS = 2_000L

        /** A sequence keeps more: an hour at one round a minute is 180 tests, and the CSV wants them all. */
        const val HISTORY_MAX_SEQUENCE = 500
        const val CSV_PREFIX = "traffic-"

        inline fun <reified E : Enum<E>> enumOr(name: String?, default: E): E =
            enumValues<E>().firstOrNull { it.name == name } ?: default
    }
}
