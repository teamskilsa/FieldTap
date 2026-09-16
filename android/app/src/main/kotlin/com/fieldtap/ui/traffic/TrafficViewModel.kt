package com.fieldtap.ui.traffic

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.fieldtap.R
import com.fieldtap.core.nettest.Iperf3Direction
import com.fieldtap.core.nettest.Iperf3Failure
import com.fieldtap.core.nettest.Iperf3Options
import com.fieldtap.core.nettest.Iperf3Protocol
import com.fieldtap.core.nettest.NetFailure
import com.fieldtap.core.nettest.PingOutcome
import com.fieldtap.core.nettest.PingStats
import com.fieldtap.nettest.CellularIperf3
import com.fieldtap.nettest.CellularLink
import com.fieldtap.nettest.CellularNetworks
import com.fieldtap.nettest.CellularTestTransport
import com.fieldtap.nettest.cellularLinks
import com.fieldtap.platform.clock.AndroidClock
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What the Traffic tab can run. */
enum class TrafficMode { IPERF, PING }

/** One finished run, for the result card and the history under it. */
sealed interface TrafficResult {
    val finishedAtMs: Long

    data class Iperf(
        override val finishedAtMs: Long,
        val options: Iperf3Options,
        val mbps: Double,
        val peakMbps: Double,
        val seconds: Double,
        val sentBytes: Long,
        val receivedBytes: Long,
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
}

data class TrafficUiState(
    val host: String = "",
    val port: String = Iperf3Options.DEFAULT_PORT.toString(),
    val mode: TrafficMode = TrafficMode.IPERF,
    val protocol: Iperf3Protocol = Iperf3Protocol.TCP,
    val direction: Iperf3Direction = Iperf3Direction.DOWNLOAD,
    val durationSec: Int = 10,
    val parallel: Int = 1,
    val udpMbps: String = "10",
    val pingCount: Int = 10,
    val link: CellularLink = CellularLink(up = false),
    val running: Boolean = false,
    /** iPerf3: Mbps per second so far. Ping: round trip per echo so far, null where it was lost. */
    val samples: List<Double?> = emptyList(),
    val result: TrafficResult? = null,
    val error: String? = null,
    val history: List<TrafficResult> = emptyList(),
) {
    val portNumber: Int? get() = port.toIntOrNull()?.takeIf { it in 1..65_535 }
    val udpBitrateBps: Long? get() = udpMbps.toDoubleOrNull()?.takeIf { it > 0 && it <= 10_000 }?.let { (it * 1_000_000).toLong() }

    /** Start is offered only for something that can run: a server, a port, and for UDP a rate. */
    val canStart: Boolean
        get() = !running && host.isNotBlank() &&
            (mode == TrafficMode.PING || (portNumber != null && (protocol == Iperf3Protocol.TCP || udpBitrateBps != null)))
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
    fun setMode(value: TrafficMode) = edit { it.copy(mode = value) }
    fun setProtocol(value: Iperf3Protocol) = edit { it.copy(protocol = value) }
    fun setDirection(value: Iperf3Direction) = edit { it.copy(direction = value) }
    fun setDuration(value: Int) = edit { it.copy(durationSec = value) }
    fun setParallel(value: Int) = edit { it.copy(parallel = value) }
    fun setUdpMbps(value: String) = edit { it.copy(udpMbps = value.filter { c -> c.isDigit() || c == '.' }.take(6)) }
    fun setPingCount(value: Int) = edit { it.copy(pingCount = value) }

    fun start() {
        val current = mutableState.value
        if (!current.canStart) return
        mutableState.update { it.copy(running = true, samples = emptyList(), result = null, error = null) }
        job = viewModelScope.launch {
            try {
                val result = when (current.mode) {
                    TrafficMode.IPERF -> runIperf(current)
                    TrafficMode.PING -> runPing(current)
                }
                mutableState.update {
                    it.copy(
                        running = false,
                        result = result,
                        history = if (result != null) (listOf(result) + it.history).take(HISTORY_MAX) else it.history,
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
        mutableState.update { it.copy(running = false) }
    }

    private suspend fun runIperf(s: TrafficUiState): TrafficResult? {
        val options = Iperf3Options(
            host = s.host,
            port = s.portNumber!!,
            protocol = s.protocol,
            direction = s.direction,
            durationSec = s.durationSec,
            parallel = s.parallel,
            udpBitrateBps = s.udpBitrateBps ?: Iperf3Options("x").udpBitrateBps,
        )
        val result = iperf.run(options) { interval ->
            mutableState.update { it.copy(samples = it.samples + interval.mbps) }
        }
        if (result == null) {
            mutableState.update { it.copy(error = text(R.string.traffic_no_bearer)) }
            return null
        }
        return TrafficResult.Iperf(
            finishedAtMs = System.currentTimeMillis(),
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
        is Iperf3Failure -> e.message ?: text(R.string.traffic_error_broke_off)
        is ConnectException -> text(R.string.traffic_error_refused, s.host, s.port)
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
            .apply()
    }

    private fun restore(): TrafficUiState {
        val d = TrafficUiState()
        return d.copy(
            host = prefs.getString(K_HOST, d.host) ?: d.host,
            port = prefs.getString(K_PORT, d.port) ?: d.port,
            mode = enumOr(prefs.getString(K_MODE, null), d.mode),
            protocol = enumOr(prefs.getString(K_PROTOCOL, null), d.protocol),
            direction = enumOr(prefs.getString(K_DIRECTION, null), d.direction),
            durationSec = prefs.getInt(K_DURATION, d.durationSec),
            parallel = prefs.getInt(K_PARALLEL, d.parallel),
            udpMbps = prefs.getString(K_UDP, d.udpMbps) ?: d.udpMbps,
            pingCount = prefs.getInt(K_PING_COUNT, d.pingCount),
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
        const val PING_TIMEOUT_MS = 2_000L
        const val HISTORY_MAX = 20

        inline fun <reified E : Enum<E>> enumOr(name: String?, default: E): E =
            enumValues<E>().firstOrNull { it.name == name } ?: default
    }
}
