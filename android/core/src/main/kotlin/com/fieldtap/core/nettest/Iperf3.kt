package com.fieldtap.core.nettest

import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.random.Random
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put

/**
 * An iperf3 client, speaking the iperf3 wire protocol to a stock `iperf3 -s`.
 *
 * Written rather than bundled. The alternative is shipping a native iperf3 binary per ABI and running it
 * as a child process, which cannot bind to the cellular network: it would go out over whatever Android
 * picked as the default, which in a lab is usually the Wi-Fi. A client in the app opens its sockets
 * through [Iperf3Connector], and the Android connector opens them on the cellular `Network` — so the
 * throughput measured is the callbox's, not the building's.
 *
 * The protocol, as `iperf3` 3.x speaks it:
 *
 * 1. Control TCP connection; the client sends a 37-byte cookie (36 characters and a NUL).
 * 2. Server sends PARAM_EXCHANGE; client sends the test parameters as length-prefixed JSON.
 * 3. Server sends CREATE_STREAMS; client opens each data stream — a TCP connection that starts with the
 *    same cookie, or a UDP socket that sends a 4-byte hello and waits for the server's reply.
 * 4. Server sends TEST_START and TEST_RUNNING; data flows for the test's duration, client to server, or
 *    server to client when the test is reversed.
 * 5. Client sends TEST_END; server sends EXCHANGE_RESULTS; each side sends its results as JSON.
 * 6. Server sends DISPLAY_RESULTS; client sends IPERF_DONE.
 *
 * Every state is one signed byte on the control connection.
 *
 * Owner: workstream `service-and-tests`.
 */
enum class Iperf3Protocol { TCP, UDP }

/** Which way the data goes. UPLOAD is iperf3's default; DOWNLOAD is `-R`, the server sending. */
enum class Iperf3Direction { UPLOAD, DOWNLOAD }

data class Iperf3Options(
    val host: String,
    val port: Int = DEFAULT_PORT,
    val protocol: Iperf3Protocol = Iperf3Protocol.TCP,
    val direction: Iperf3Direction = Iperf3Direction.DOWNLOAD,
    val durationSec: Int = 10,
    val parallel: Int = 1,
    /** UDP only: the target rate, bits per second, across all streams. TCP ignores it and runs flat out. */
    val udpBitrateBps: Long = 10_000_000,
    val blockSize: Int = if (protocol == Iperf3Protocol.TCP) TCP_BLOCK_BYTES else UDP_BLOCK_BYTES,
) {
    companion object {
        const val DEFAULT_PORT: Int = 5201

        /** iperf3's own default TCP block, 128 KiB. */
        const val TCP_BLOCK_BYTES: Int = 131_072

        /**
         * 1400 bytes of payload. iperf3 defaults to 1460, sized for an Ethernet MTU; an LTE bearer adds a
         * GTP-U tunnel on the callbox side, and a datagram that fragments there is lost whole.
         */
        const val UDP_BLOCK_BYTES: Int = 1400
    }
}

/** One second of a test, as the client saw it. */
data class Iperf3Interval(val startSec: Double, val endSec: Double, val bytes: Long) {
    val mbps: Double get() = bytes * 8.0 / (endSec - startSec).coerceAtLeast(MIN_SECONDS) / 1_000_000.0
}

data class Iperf3Result(
    val options: Iperf3Options,
    val seconds: Double,
    /** What left the sender. */
    val sentBytes: Long,
    /** What arrived. Throughput is quoted from this, as iperf3's own "receiver" line is. */
    val receivedBytes: Long,
    val intervals: List<Iperf3Interval>,
    /** UDP only. */
    val jitterMs: Double? = null,
    val lostPackets: Long? = null,
    val packets: Long? = null,
) {
    val mbps: Double get() = receivedBytes * 8.0 / seconds.coerceAtLeast(MIN_SECONDS) / 1_000_000.0
    val peakMbps: Double get() = intervals.maxOfOrNull { it.mbps } ?: 0.0
    val lossPercent: Double? get() = if (packets != null && lostPackets != null && packets > 0) lostPackets * 100.0 / packets else null
}

/** Why a test did not run to the end. */
sealed class Iperf3Failure(message: String) : IOException(message) {
    /** The server answered ACCESS_DENIED: it is already running a test for someone else. */
    class Busy : Iperf3Failure("the iperf3 server is busy with another test")

    /** The server sent SERVER_ERROR, or closed the connection mid-test. */
    class ServerError(detail: String) : Iperf3Failure(detail)

    /** The server said something the protocol does not allow at that point. */
    class Protocol(detail: String) : Iperf3Failure(detail)
}

/** Where the sockets come from. Android opens them on the cellular network; a test opens them on loopback. */
interface Iperf3Connector {
    fun openTcp(host: String, port: Int, timeoutMs: Int): Socket

    /** A UDP socket connected to [host]:[port]. */
    fun openUdp(host: String, port: Int): DatagramSocket
}

/** The wire format: states, cookies, framed JSON, and the UDP datagram header. Pure, so it is tested alone. */
object Iperf3Wire {
    const val TEST_START: Int = 1
    const val TEST_RUNNING: Int = 2
    const val TEST_END: Int = 4
    const val PARAM_EXCHANGE: Int = 9
    const val CREATE_STREAMS: Int = 10
    const val SERVER_TERMINATE: Int = 11
    const val CLIENT_TERMINATE: Int = 12
    const val EXCHANGE_RESULTS: Int = 13
    const val DISPLAY_RESULTS: Int = 14
    const val IPERF_DONE: Int = 16
    const val ACCESS_DENIED: Int = -1
    const val SERVER_ERROR: Int = -2

    const val COOKIE_BYTES: Int = 37
    private const val COOKIE_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"

    /** The client's hello on a UDP stream, and the server's answer. Written as a native int, which is little-endian on every phone. */
    const val UDP_CONNECT_MSG: Int = 0x36373839
    const val UDP_CONNECT_REPLY: Int = 0x39383736
    const val LEGACY_UDP_CONNECT_REPLY: Int = 987_654_321

    /** 36 characters from iperf3's alphabet and a NUL. */
    fun cookie(random: Random): ByteArray {
        val bytes = ByteArray(COOKIE_BYTES)
        for (i in 0 until COOKIE_BYTES - 1) bytes[i] = COOKIE_ALPHABET[random.nextInt(COOKIE_ALPHABET.length)].code.toByte()
        return bytes
    }

    /** A JSON object on the control connection: a 4-byte big-endian length, then the UTF-8 text. */
    fun writeJson(out: OutputStream, json: JsonObject) {
        val body = json.toString().toByteArray(Charsets.UTF_8)
        out.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(body.size).array())
        out.write(body)
        out.flush()
    }

    fun readJson(input: InputStream): JsonObject {
        val data = DataInputStream(input)
        val length = data.readInt()
        if (length <= 0 || length > MAX_JSON_BYTES) throw Iperf3Failure.Protocol("a JSON block of $length bytes")
        val body = ByteArray(length)
        data.readFully(body)
        return Json.parseToJsonElement(body.toString(Charsets.UTF_8)).jsonObject
    }

    /** The parameters a stock server reads. Only what differs from its defaults is worth arguing about, but it does no harm to be explicit. */
    fun params(options: Iperf3Options): JsonObject = buildJsonObject {
        when (options.protocol) {
            Iperf3Protocol.TCP -> put("tcp", true)
            Iperf3Protocol.UDP -> put("udp", true)
        }
        put("omit", 0)
        put("time", options.durationSec)
        put("num", 0)
        put("blockcount", 0)
        put("parallel", options.parallel)
        if (options.direction == Iperf3Direction.DOWNLOAD) put("reverse", true)
        put("len", options.blockSize)
        if (options.protocol == Iperf3Protocol.UDP) put("bandwidth", options.udpBitrateBps)
        put("pacing_timer", 1000)
        put("client_version", CLIENT_VERSION)
    }

    /**
     * The client's results. The server matches streams by id, and iperf3 numbers them 1, 3, 4, 5 … — the
     * second stream is 3, a quirk its authors kept so old and new versions agree — so the ids here copy it.
     */
    fun clientResults(streams: List<StreamTotals>, seconds: Double): JsonObject = buildJsonObject {
        put("cpu_util_total", 0)
        put("cpu_util_user", 0)
        put("cpu_util_system", 0)
        // Android offers no TCP_INFO to an app, so retransmits cannot be counted here.
        put("sender_has_retransmits", 0)
        put("streams", buildJsonArray {
            streams.forEachIndexed { index, stream ->
                add(buildJsonObject {
                    put("id", streamId(index))
                    put("bytes", stream.bytes)
                    put("retransmits", -1)
                    put("jitter", stream.jitterSeconds)
                    put("errors", stream.lost)
                    put("omitted_errors", 0)
                    put("packets", stream.packets)
                    put("omitted_packets", 0)
                    put("start_time", 0)
                    put("end_time", seconds)
                })
            }
        })
    }

    fun streamId(index: Int): Int = if (index == 0) 1 else index + 2

    /** What the server says it sent or received, summed across its streams. */
    data class ServerTotals(val bytes: Long, val jitterSeconds: Double?, val lost: Long?, val packets: Long?)

    fun serverTotals(json: JsonObject): ServerTotals {
        val streams = json["streams"]?.let { it as? JsonArray } ?: JsonArray(emptyList())
        var bytes = 0L
        var lost = 0L
        var packets = 0L
        var jitter: Double? = null
        var sawUdp = false
        for (element in streams) {
            val stream = element.jsonObject
            bytes += stream["bytes"]?.jsonPrimitive?.longOrNull ?: 0
            stream["packets"]?.jsonPrimitive?.longOrNull?.let { if (it > 0) sawUdp = true; packets += it }
            lost += stream["errors"]?.jsonPrimitive?.longOrNull ?: 0
            stream["jitter"]?.jsonPrimitive?.doubleOrNull?.let { jitter = maxOf(jitter ?: 0.0, it) }
        }
        return ServerTotals(bytes, if (sawUdp) jitter else null, if (sawUdp) lost else null, if (sawUdp) packets else null)
    }

    /** A UDP datagram's first 12 bytes: send time (seconds, microseconds) and a sequence number from 1. */
    fun writeUdpHeader(buffer: ByteArray, sequence: Long, nowMicros: Long) {
        ByteBuffer.wrap(buffer, 0, UDP_HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
            .putInt((nowMicros / 1_000_000).toInt())
            .putInt((nowMicros % 1_000_000).toInt())
            .putInt(sequence.toInt())
    }

    data class UdpHeader(val sentMicros: Long, val sequence: Long)

    fun readUdpHeader(buffer: ByteArray, length: Int): UdpHeader? {
        if (length < UDP_HEADER_BYTES) return null
        val bb = ByteBuffer.wrap(buffer, 0, UDP_HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
        val sec = bb.int.toLong() and 0xFFFFFFFFL
        val usec = bb.int.toLong() and 0xFFFFFFFFL
        val seq = bb.int.toLong() and 0xFFFFFFFFL
        return UdpHeader(sec * 1_000_000 + usec, seq)
    }

    fun nativeInt(value: Int): ByteArray = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()

    const val UDP_HEADER_BYTES: Int = 12
    private const val MAX_JSON_BYTES = 1_048_576
    private const val CLIENT_VERSION = "3.16"
}

/** One stream's totals at the end of a test, as its receiver or sender counted them. */
data class StreamTotals(val bytes: Long, val packets: Long = 0, val lost: Long = 0, val jitterSeconds: Double = 0.0)

/**
 * Jitter and loss of a UDP stream, the way iperf3 counts them: RFC 3550 interarrival jitter, smoothed by
 * 1/16, and loss as the gap between the highest sequence seen and the datagrams that arrived.
 */
class UdpReceiveStats {
    var packets: Long = 0
        private set
    var highestSequence: Long = 0
        private set
    var jitterSeconds: Double = 0.0
        private set
    private var previousTransit: Double? = null

    fun onDatagram(header: Iperf3Wire.UdpHeader, arrivedMicros: Long) {
        packets++
        if (header.sequence > highestSequence) highestSequence = header.sequence
        val transit = (arrivedMicros - header.sentMicros) / 1_000_000.0
        previousTransit?.let { previous -> jitterSeconds += (abs(transit - previous) - jitterSeconds) / 16.0 }
        previousTransit = transit
    }

    /** A datagram that never came. Out-of-order arrivals are not loss; they are counted once they land. */
    val lost: Long get() = (highestSequence - packets).coerceAtLeast(0)
}

class Iperf3Client(
    private val connector: Iperf3Connector,
    private val random: Random = Random(SecureRandom().nextLong()),
    private val nowMicros: () -> Long = { System.nanoTime() / 1_000 },
) {
    /**
     * Runs one test and returns its result, calling [onInterval] once a second while it runs.
     *
     * Cancelling the coroutine closes every socket, which the server sees as the client going away —
     * the same thing a Ctrl-C on a desktop iperf3 does.
     */
    suspend fun run(options: Iperf3Options, onInterval: (Iperf3Interval) -> Unit = {}): Iperf3Result =
        withContext(Dispatchers.IO) {
            val control = connector.openTcp(options.host, options.port, CONNECT_TIMEOUT_MS)
            val dataSockets = mutableListOf<AutoCloseable>()
            try {
                control.soTimeout = CONTROL_TIMEOUT_MS
                control.tcpNoDelay = true
                val input = control.getInputStream()
                val output = control.getOutputStream()
                val cookie = Iperf3Wire.cookie(random)
                output.write(cookie)
                output.flush()

                expect(input, Iperf3Wire.PARAM_EXCHANGE)
                Iperf3Wire.writeJson(output, Iperf3Wire.params(options))
                expect(input, Iperf3Wire.CREATE_STREAMS)

                val streams = (0 until options.parallel.coerceIn(1, MAX_STREAMS)).map {
                    when (options.protocol) {
                        Iperf3Protocol.TCP -> DataStream.Tcp(openTcpStream(options, cookie)).also { dataSockets += it.socket }
                        Iperf3Protocol.UDP -> DataStream.Udp(openUdpStream(options)).also { dataSockets += it.socket }
                    }
                }

                expect(input, Iperf3Wire.TEST_START)
                expect(input, Iperf3Wire.TEST_RUNNING)

                val measured = transfer(options, streams, onInterval)

                output.write(Iperf3Wire.TEST_END)
                output.flush()
                // The server may drain a few last blocks before it answers; that is not an error.
                expect(input, Iperf3Wire.EXCHANGE_RESULTS)
                Iperf3Wire.writeJson(output, Iperf3Wire.clientResults(measured.streams, measured.seconds))
                val server = Iperf3Wire.serverTotals(Iperf3Wire.readJson(input))
                expect(input, Iperf3Wire.DISPLAY_RESULTS)
                output.write(Iperf3Wire.IPERF_DONE)
                output.flush()

                val clientBytes = measured.streams.sumOf { it.bytes }
                if (options.direction == Iperf3Direction.UPLOAD) {
                    Iperf3Result(
                        options = options,
                        seconds = measured.seconds,
                        sentBytes = clientBytes,
                        receivedBytes = server.bytes,
                        intervals = measured.intervals,
                        jitterMs = server.jitterSeconds?.times(1000),
                        lostPackets = server.lost,
                        packets = server.packets,
                    )
                } else {
                    val udp = options.protocol == Iperf3Protocol.UDP
                    Iperf3Result(
                        options = options,
                        seconds = measured.seconds,
                        sentBytes = server.bytes,
                        receivedBytes = clientBytes,
                        intervals = measured.intervals,
                        jitterMs = if (udp) measured.streams.maxOf { it.jitterSeconds } * 1000 else null,
                        lostPackets = if (udp) measured.streams.sumOf { it.lost } else null,
                        packets = if (udp) measured.streams.sumOf { it.packets + it.lost } else null,
                    )
                }
            } catch (e: EOFException) {
                throw Iperf3Failure.ServerError("the server closed the connection")
            } finally {
                dataSockets.forEach { runCatching { it.close() } }
                runCatching { control.close() }
            }
        }

    private sealed interface DataStream {
        val socket: AutoCloseable

        class Tcp(override val socket: Socket) : DataStream
        class Udp(override val socket: DatagramSocket) : DataStream
    }

    private class Measured(val streams: List<StreamTotals>, val intervals: List<Iperf3Interval>, val seconds: Double)

    private fun openTcpStream(options: Iperf3Options, cookie: ByteArray): Socket {
        val socket = connector.openTcp(options.host, options.port, CONNECT_TIMEOUT_MS)
        socket.tcpNoDelay = true
        socket.getOutputStream().apply { write(cookie); flush() }
        return socket
    }

    private fun openUdpStream(options: Iperf3Options): DatagramSocket {
        val socket = connector.openUdp(options.host, options.port)
        socket.soTimeout = UDP_HELLO_TIMEOUT_MS
        val hello = Iperf3Wire.nativeInt(Iperf3Wire.UDP_CONNECT_MSG)
        socket.send(DatagramPacket(hello, hello.size))
        val reply = ByteArray(4)
        try {
            socket.receive(DatagramPacket(reply, reply.size))
        } catch (e: SocketTimeoutException) {
            socket.close()
            throw Iperf3Failure.Protocol("the server did not answer the UDP stream's hello; is UDP port ${options.port} open?")
        }
        return socket
    }

    /** Moves data for the test's duration, one worker per stream, sampling byte counts once a second. */
    private suspend fun transfer(
        options: Iperf3Options,
        streams: List<DataStream>,
        onInterval: (Iperf3Interval) -> Unit,
    ): Measured = coroutineScope {
        val counters = streams.map { AtomicLong(0) }
        val udpStats = streams.map { UdpReceiveStats() }
        val udpSent = streams.map { AtomicLong(0) }
        val started = nowMicros()
        val endAt = started + options.durationSec * 1_000_000L
        val upload = options.direction == Iperf3Direction.UPLOAD

        val workers = streams.mapIndexed { index, stream ->
            launch(Dispatchers.IO) {
                when (stream) {
                    is DataStream.Tcp -> if (upload) tcpSend(stream.socket, options, counters[index], endAt) else tcpReceive(stream.socket, counters[index], endAt)
                    is DataStream.Udp -> if (upload) {
                        udpSend(stream.socket, options, counters[index], udpSent[index], endAt, streams.size)
                    } else {
                        udpReceive(stream.socket, options, counters[index], udpStats[index], endAt)
                    }
                }
            }
        }

        val intervals = mutableListOf<Iperf3Interval>()
        var lastBytes = 0L
        var lastMicros = started
        while (isActive && nowMicros() < endAt) {
            delay(INTERVAL_MS)
            val now = minOf(nowMicros(), endAt)
            val total = counters.sumOf { it.get() }
            val interval = Iperf3Interval((lastMicros - started) / 1e6, (now - started) / 1e6, total - lastBytes)
            if (interval.endSec > interval.startSec) {
                intervals += interval
                onInterval(interval)
            }
            lastBytes = total
            lastMicros = now
        }
        workers.forEach { it.join() }
        val seconds = ((minOf(nowMicros(), endAt) - started) / 1e6).coerceAtLeast(MIN_SECONDS)
        val totals = streams.mapIndexed { index, stream ->
            when {
                stream is DataStream.Udp && !upload ->
                    StreamTotals(counters[index].get(), udpStats[index].packets, udpStats[index].lost, udpStats[index].jitterSeconds)
                stream is DataStream.Udp -> StreamTotals(counters[index].get(), packets = udpSent[index].get())
                else -> StreamTotals(counters[index].get())
            }
        }
        Measured(totals, intervals, seconds)
    }

    private fun tcpSend(socket: Socket, options: Iperf3Options, counter: AtomicLong, endAt: Long) {
        val block = ByteArray(options.blockSize).also { random.nextBytes(it) }
        val out = socket.getOutputStream()
        try {
            while (nowMicros() < endAt) {
                out.write(block)
                counter.addAndGet(block.size.toLong())
            }
            out.flush()
        } catch (e: IOException) {
            // The server closes data streams when it ends the test; a write racing that is not a failure.
        }
    }

    private fun tcpReceive(socket: Socket, counter: AtomicLong, endAt: Long) {
        socket.soTimeout = READ_POLL_MS
        val buffer = ByteArray(RECEIVE_BUFFER_BYTES)
        val input = socket.getInputStream()
        while (nowMicros() < endAt) {
            val read = try {
                input.read(buffer)
            } catch (e: SocketTimeoutException) {
                continue
            } catch (e: IOException) {
                return
            }
            if (read < 0) return
            counter.addAndGet(read.toLong())
        }
    }

    private suspend fun udpSend(
        socket: DatagramSocket,
        options: Iperf3Options,
        counter: AtomicLong,
        sent: AtomicLong,
        endAt: Long,
        streamCount: Int,
    ) {
        val block = ByteArray(options.blockSize.coerceAtLeast(Iperf3Wire.UDP_HEADER_BYTES)).also { random.nextBytes(it) }
        // The rate is for the whole test; each stream carries its share of it.
        val bitsPerStream = options.udpBitrateBps.toDouble() / streamCount
        val microsPerDatagram = (block.size * 8.0 / bitsPerStream * 1_000_000).coerceAtLeast(1.0)
        val begin = nowMicros()
        var sequence = 0L
        while (nowMicros() < endAt) {
            val due = begin + (sequence * microsPerDatagram).toLong()
            val wait = due - nowMicros()
            if (wait > 2_000) delay(wait / 1_000)
            sequence++
            Iperf3Wire.writeUdpHeader(block, sequence, nowMicros())
            try {
                socket.send(DatagramPacket(block, block.size))
                counter.addAndGet(block.size.toLong())
                sent.incrementAndGet()
            } catch (e: IOException) {
                // ENOBUFS on a saturated uplink: the datagram is lost, which is what loss is.
            }
        }
    }

    private fun udpReceive(socket: DatagramSocket, options: Iperf3Options, counter: AtomicLong, stats: UdpReceiveStats, endAt: Long) {
        socket.soTimeout = READ_POLL_MS
        val buffer = ByteArray(maxOf(options.blockSize, Iperf3Wire.UDP_HEADER_BYTES) + 64)
        val packet = DatagramPacket(buffer, buffer.size)
        while (nowMicros() < endAt) {
            try {
                packet.length = buffer.size
                socket.receive(packet)
            } catch (e: SocketTimeoutException) {
                continue
            } catch (e: IOException) {
                return
            }
            val header = Iperf3Wire.readUdpHeader(buffer, packet.length) ?: continue
            counter.addAndGet(packet.length.toLong())
            stats.onDatagram(header, nowMicros())
        }
    }

    private fun expect(input: InputStream, wanted: Int) {
        val state = readState(input)
        when {
            state == wanted -> return
            state == Iperf3Wire.ACCESS_DENIED -> throw Iperf3Failure.Busy()
            state == Iperf3Wire.SERVER_ERROR -> throw Iperf3Failure.ServerError("the server reported an error")
            state == Iperf3Wire.SERVER_TERMINATE -> throw Iperf3Failure.ServerError("the server ended the test")
            else -> throw Iperf3Failure.Protocol("expected state $wanted, got $state")
        }
    }

    private fun readState(input: InputStream): Int {
        val value = input.read()
        if (value < 0) throw EOFException()
        return value.toByte().toInt()
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 8_000
        const val CONTROL_TIMEOUT_MS = 30_000
        const val UDP_HELLO_TIMEOUT_MS = 5_000
        const val READ_POLL_MS = 250
        const val INTERVAL_MS = 1_000L
        const val RECEIVE_BUFFER_BYTES = 262_144
        const val MAX_STREAMS = 16
    }
}

private const val MIN_SECONDS = 0.001
