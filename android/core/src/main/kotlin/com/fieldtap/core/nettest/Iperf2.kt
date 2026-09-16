package com.fieldtap.core.nettest

import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * An iperf2 client, for the many callboxes and lab servers that run `iperf -s` rather than `iperf3 -s`.
 *
 * iperf2 and iperf3 share a name and nothing else: different protocol, different default port (5001 vs
 * 5201). An iperf3 client pointed at an iperf2 server fails, and the other way round.
 *
 * The wire format here was not written from memory. Every header was captured from the real iperf 2.2.1
 * client and replayed at the real iperf 2.2.1 server, and the tests pin the captured bytes:
 *
 * - **TCP** opens with a 64-byte client header — flags, thread count, port, buffer length, duration as
 *   −(seconds × 100), then a version block — and either sends data (upload) or, with the reverse bits set,
 *   waits while the server sends on the same connection for the requested time and closes it (download).
 *   A TCP test returns no report: iperf2's own client prints what it sent, and so does this.
 * - **UDP** datagrams carry a 16-byte header — sequence from 1 (low 32 bits), send time in seconds and
 *   microseconds, high 32 bits of the sequence — and the client header after it. An upload ends with
 *   datagrams whose sequence is negative; the server answers with a report of what it received. A download
 *   sends the reverse request until datagrams arrive, at the rate carried in the header, and the server
 *   ends with one negative sequence and expects no answer.
 *
 * Reverse (download) arrived in iperf 2.1. A 2.0.x server reads the reverse request as an upload with no
 * data and never sends; that is reported as such rather than as a silent zero.
 *
 * Owner: workstream `service-and-tests`.
 */
object Iperf2Wire {
    const val DEFAULT_PORT: Int = 5001
    const val UDP_HEADER_BYTES: Int = 16
    const val CLIENT_HEADER_BYTES: Int = 64

    // As iperf 2.2.1 sends them. The bits are not all documented; they are copied, not reasoned about.
    const val FLAGS_TCP: Int = 0x40010080
    const val FLAGS_TCP_REVERSE: Int = 0x44010080
    const val FLAGS_UDP: Int = 0x480100A0
    const val FLAGS_UDP_REVERSE: Int = 0x6C0100A0
    const val UPPER_REVERSE: Short = 0x0400
    private const val VERSION_UPPER = 0x00020002
    private const val VERSION_LOWER = 0x00010001

    /** Set in a server report's flags. Its position tells a 2.1+ report (after 16 bytes) from a 2.0 one (after 12). */
    const val HEADER_VERSION1: Int = 0x80000000.toInt()

    fun clientHeader(options: IperfOptions, streams: Int): ByteArray {
        val udp = options.protocol == IperfProtocol.UDP
        val reverse = options.direction == IperfDirection.DOWNLOAD
        val flags = when {
            udp && reverse -> FLAGS_UDP_REVERSE
            udp -> FLAGS_UDP
            reverse -> FLAGS_TCP_REVERSE
            else -> FLAGS_TCP
        }
        val bb = ByteBuffer.allocate(CLIENT_HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
        bb.putInt(flags)
        bb.putInt(streams)
        bb.putInt(options.port)
        // A TCP download asks for no buffer length; the captured client leaves it 0 and the server picks.
        bb.putInt(if (!udp && reverse) 0 else options.blockSize)
        bb.putInt(0) // window/band
        bb.putInt(-options.durationSec * 100) // negative: a time, in hundredths of a second
        bb.putInt(0) // extension type
        bb.putInt(0) // extension length
        bb.putShort(if (reverse) UPPER_REVERSE else 0)
        bb.putShort(0)
        bb.putInt(VERSION_UPPER)
        bb.putInt(VERSION_LOWER)
        bb.putInt(0) // reserved, TOS
        val rate = if (udp) options.udpBitrateBps else 0L
        bb.putInt((rate and 0xFFFFFFFFL).toInt()) // rate, bits per second, low
        bb.putInt((rate ushr 32).toInt()) // high
        return bb.array()
    }

    data class UdpHeader(val sequence: Long, val sentMicros: Long)

    fun writeUdpHeader(buffer: ByteArray, sequence: Long, nowMicros: Long) {
        ByteBuffer.wrap(buffer, 0, UDP_HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
            .putInt((sequence and 0xFFFFFFFFL).toInt())
            .putInt((nowMicros / 1_000_000).toInt())
            .putInt((nowMicros % 1_000_000).toInt())
            .putInt((sequence shr 32).toInt())
    }

    fun readUdpHeader(buffer: ByteArray, length: Int): UdpHeader? {
        if (length < UDP_HEADER_BYTES) return null
        val bb = ByteBuffer.wrap(buffer, 0, UDP_HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
        val low = bb.int.toLong() and 0xFFFFFFFFL
        val sec = bb.int.toLong() and 0xFFFFFFFFL
        val usec = bb.int.toLong() and 0xFFFFFFFFL
        val high = bb.int.toLong()
        return UdpHeader(sequence = (high shl 32) or low, sentMicros = sec * 1_000_000 + usec)
    }

    /** What an iperf2 server says it received, from its answer to an upload's final datagrams. */
    data class ServerReport(
        val bytes: Long,
        val seconds: Double,
        val lost: Long,
        val outOfOrder: Long,
        val datagrams: Long,
        val jitterSeconds: Double,
    )

    fun parseServerReport(buffer: ByteArray, length: Int): ServerReport? {
        // 2.1+ writes the report after its 16-byte datagram header; 2.0.x after a 12-byte one.
        for (offset in intArrayOf(UDP_HEADER_BYTES, 12)) {
            if (length < offset + 40) continue
            val bb = ByteBuffer.wrap(buffer, offset, 40).order(ByteOrder.BIG_ENDIAN)
            val flags = bb.int
            if (flags and HEADER_VERSION1 == 0) continue
            val high = bb.int.toLong()
            val low = bb.int.toLong() and 0xFFFFFFFFL
            val stopSec = bb.int
            val stopUsec = bb.int
            val errors = bb.int.toLong()
            val outOfOrder = bb.int.toLong()
            val datagrams = bb.int.toLong()
            val jitterSec = bb.int
            val jitterUsec = bb.int
            return ServerReport(
                bytes = (high shl 32) or low,
                seconds = stopSec + stopUsec / 1e6,
                lost = errors,
                outOfOrder = outOfOrder,
                datagrams = datagrams,
                jitterSeconds = jitterSec + jitterUsec / 1e6,
            )
        }
        return null
    }

    /** The payload iperf2 fills its buffers with, so a packet capture of this client looks like iperf's own. */
    fun pattern(size: Int): ByteArray = ByteArray(size) { ('0'.code + it % 10).toByte() }
}

/** Why an iperf2 test did not produce a result. */
sealed class Iperf2Failure(message: String) : IOException(message) {
    /** The server accepted a download request and never sent. The usual reason is a server older than 2.1. */
    class NoReverse : Iperf2Failure("the server accepted the download request but sent nothing")
}

class Iperf2Client(
    private val connector: IperfConnector,
    private val nowMicros: () -> Long = { System.nanoTime() / 1_000 },
) {
    suspend fun run(options: IperfOptions, onInterval: (IperfInterval) -> Unit = {}): IperfResult = withContext(Dispatchers.IO) {
        val streams = options.parallel.coerceIn(1, MAX_STREAMS)
        val header = Iperf2Wire.clientHeader(options, streams)
        val sockets = mutableListOf<AutoCloseable>()
        try {
            when (options.protocol) {
                IperfProtocol.TCP -> {
                    val tcp = (0 until streams).map { connector.openTcp(options.host, options.port, CONNECT_TIMEOUT_MS).also(sockets::add) }
                    if (options.direction == IperfDirection.UPLOAD) tcpUpload(options, tcp, header, onInterval) else tcpDownload(options, tcp, header, onInterval)
                }
                IperfProtocol.UDP -> {
                    val udp = (0 until streams).map { connector.openUdp(options.host, options.port).also(sockets::add) }
                    if (options.direction == IperfDirection.UPLOAD) udpUpload(options, udp, header, onInterval) else udpDownload(options, udp, header, onInterval)
                }
            }
        } finally {
            sockets.forEach { runCatching { it.close() } }
        }
    }

    // MARK: - TCP

    private suspend fun tcpUpload(options: IperfOptions, sockets: List<Socket>, header: ByteArray, onInterval: (IperfInterval) -> Unit): IperfResult {
        val counters = sockets.map { AtomicLong(0) }
        val measured = sample(options, counters, onInterval) { endAt ->
            sockets.forEachIndexed { index, socket ->
                launch(Dispatchers.IO) {
                    val block = Iperf2Wire.pattern(options.blockSize)
                    try {
                        socket.tcpNoDelay = true
                        val out = socket.getOutputStream()
                        out.write(header)
                        while (nowMicros() < endAt) {
                            out.write(block)
                            counters[index].addAndGet(block.size.toLong())
                        }
                        out.flush()
                        // Let the stack hand over what is buffered before the close, so the sent count and
                        // the server's received count are the same bytes.
                        socket.shutdownOutput()
                    } catch (e: IOException) {
                        // The server going away mid-test ends the stream; what was sent still counts.
                    }
                }
            }
        }
        val sent = counters.sumOf { it.get() }
        return IperfResult(options, measured.seconds, sentBytes = sent, receivedBytes = null, intervals = measured.intervals)
    }

    private suspend fun tcpDownload(options: IperfOptions, sockets: List<Socket>, header: ByteArray, onInterval: (IperfInterval) -> Unit): IperfResult {
        val counters = sockets.map { AtomicLong(0) }
        val measured = sample(options, counters, onInterval, graceMicros = END_GRACE_MICROS) { endAt ->
            sockets.forEachIndexed { index, socket ->
                launch(Dispatchers.IO) {
                    val buffer = ByteArray(RECEIVE_BUFFER_BYTES)
                    try {
                        socket.getOutputStream().apply { write(header); flush() }
                        socket.soTimeout = READ_POLL_MS
                        val input = socket.getInputStream()
                        // The server stops at the requested time and closes; the grace covers a slow link.
                        while (nowMicros() < endAt + END_GRACE_MICROS) {
                            val read = try {
                                input.read(buffer)
                            } catch (e: SocketTimeoutException) {
                                continue
                            }
                            if (read < 0) break
                            counters[index].addAndGet(read.toLong())
                        }
                    } catch (e: IOException) {
                        // Reset at the end is how some servers close; the bytes already read stand.
                    }
                }
            }
        }
        val received = counters.sumOf { it.get() }
        if (received == 0L) throw Iperf2Failure.NoReverse()
        return IperfResult(options, measured.seconds, sentBytes = null, receivedBytes = received, intervals = measured.intervals)
    }

    // MARK: - UDP

    private suspend fun udpUpload(options: IperfOptions, sockets: List<DatagramSocket>, header: ByteArray, onInterval: (IperfInterval) -> Unit): IperfResult {
        val counters = sockets.map { AtomicLong(0) }
        val lastSequence = sockets.map { AtomicLong(0) }
        val size = options.blockSize.coerceAtLeast(Iperf2Wire.UDP_HEADER_BYTES + Iperf2Wire.CLIENT_HEADER_BYTES)
        val measured = sample(options, counters, onInterval) { endAt ->
            sockets.forEachIndexed { index, socket ->
                launch(Dispatchers.IO) {
                    val datagram = Iperf2Wire.pattern(size)
                    header.copyInto(datagram, Iperf2Wire.UDP_HEADER_BYTES)
                    val microsPer = (size * 8.0 / (options.udpBitrateBps.toDouble() / sockets.size) * 1_000_000).coerceAtLeast(1.0)
                    val begin = nowMicros()
                    var sequence = 0L
                    while (nowMicros() < endAt) {
                        val wait = begin + (sequence * microsPer).toLong() - nowMicros()
                        if (wait > 2_000) delay(wait / 1_000)
                        sequence++
                        Iperf2Wire.writeUdpHeader(datagram, sequence, nowMicros())
                        try {
                            socket.send(DatagramPacket(datagram, datagram.size))
                            counters[index].addAndGet(datagram.size.toLong())
                        } catch (e: IOException) {
                            // A full send queue drops the datagram; the server will count it lost, as it should.
                        }
                    }
                    lastSequence[index].set(sequence)
                }
            }
        }
        // End each stream the way iperf2 does: negative sequences, up to ten times, until the server reports.
        val reports = sockets.mapIndexed { index, socket -> finish(socket, size, lastSequence[index].get()) }
        val known = reports.filterNotNull()
        return IperfResult(
            options = options,
            seconds = measured.seconds,
            sentBytes = counters.sumOf { it.get() },
            receivedBytes = if (known.isEmpty()) null else known.sumOf { it.bytes },
            intervals = measured.intervals,
            jitterMs = known.maxOfOrNull { it.jitterSeconds * 1000 },
            lostPackets = if (known.isEmpty()) null else known.sumOf { it.lost },
            packets = if (known.isEmpty()) null else known.sumOf { it.datagrams },
        )
    }

    private fun finish(socket: DatagramSocket, size: Int, lastSequence: Long): Iperf2Wire.ServerReport? {
        val datagram = ByteArray(size)
        val reply = ByteArray(REPORT_BUFFER_BYTES)
        socket.soTimeout = FIN_WAIT_MS
        for (attempt in 0 until FIN_TRIES) {
            Iperf2Wire.writeUdpHeader(datagram, -(lastSequence + 1 + attempt), nowMicros())
            try {
                socket.send(DatagramPacket(datagram, datagram.size))
                val packet = DatagramPacket(reply, reply.size)
                socket.receive(packet)
                Iperf2Wire.parseServerReport(reply, packet.length)?.let { return it }
            } catch (e: SocketTimeoutException) {
                // Try again, as iperf2 does.
            } catch (e: IOException) {
                return null
            }
        }
        return null
    }

    private suspend fun udpDownload(options: IperfOptions, sockets: List<DatagramSocket>, header: ByteArray, onInterval: (IperfInterval) -> Unit): IperfResult {
        val counters = sockets.map { AtomicLong(0) }
        val stats = sockets.map { UdpReceiveStats() }
        val started = sockets.map { java.util.concurrent.atomic.AtomicBoolean(false) }
        val request = Iperf2Wire.pattern(options.blockSize.coerceAtLeast(Iperf2Wire.UDP_HEADER_BYTES + Iperf2Wire.CLIENT_HEADER_BYTES))
        header.copyInto(request, Iperf2Wire.UDP_HEADER_BYTES)
        Iperf2Wire.writeUdpHeader(request, 1, nowMicros())

        // Ask until the server starts sending; the clock starts when it does, not when the request left.
        coroutineScope {
            sockets.forEachIndexed { index, socket ->
                launch(Dispatchers.IO) {
                    runCatching { socket.receiveBufferSize = UDP_RECEIVE_BUFFER_BYTES }
                    socket.soTimeout = REQUEST_RETRY_MS
                    val probe = ByteArray(64_000)
                    val giveUp = nowMicros() + START_TIMEOUT_MICROS
                    while (nowMicros() < giveUp && isActive) {
                        socket.send(DatagramPacket(request, request.size))
                        try {
                            val packet = DatagramPacket(probe, probe.size)
                            socket.receive(packet)
                            val first = Iperf2Wire.readUdpHeader(probe, packet.length) ?: continue
                            if (first.sequence > 0) {
                                counters[index].addAndGet(packet.length.toLong())
                                stats[index].onDatagram(Iperf3Wire.UdpHeader(first.sentMicros, first.sequence), nowMicros())
                                started[index].set(true)
                                break
                            }
                        } catch (e: SocketTimeoutException) {
                            continue
                        }
                    }
                }
            }
        }
        if (started.none { it.get() }) throw Iperf2Failure.NoReverse()

        val measured = sample(options, counters, onInterval, graceMicros = END_GRACE_MICROS) { endAt ->
            sockets.forEachIndexed { index, socket ->
                if (!started[index].get()) return@forEachIndexed
                launch(Dispatchers.IO) {
                    socket.soTimeout = READ_POLL_MS
                    val buffer = ByteArray(65_535)
                    val packet = DatagramPacket(buffer, buffer.size)
                    while (nowMicros() < endAt + END_GRACE_MICROS) {
                        try {
                            packet.length = buffer.size
                            socket.receive(packet)
                        } catch (e: SocketTimeoutException) {
                            continue
                        } catch (e: IOException) {
                            return@launch
                        }
                        val h = Iperf2Wire.readUdpHeader(buffer, packet.length) ?: continue
                        if (h.sequence < 0) return@launch // the server's final datagram
                        counters[index].addAndGet(packet.length.toLong())
                        stats[index].onDatagram(Iperf3Wire.UdpHeader(h.sentMicros, h.sequence), nowMicros())
                    }
                }
            }
        }
        return IperfResult(
            options = options,
            seconds = measured.seconds,
            sentBytes = null,
            receivedBytes = counters.sumOf { it.get() },
            intervals = measured.intervals,
            jitterMs = stats.maxOf { it.jitterSeconds } * 1000,
            lostPackets = stats.sumOf { it.lost },
            packets = stats.sumOf { it.packets + it.lost },
        )
    }

    // MARK: - Sampling

    private class Measured(val intervals: List<IperfInterval>, val seconds: Double)

    /**
     * Runs [work] for the test's duration and samples [counters] once a second. [graceMicros] lets a
     * download's last bytes, which a server sends right up to its own clock's end, still be counted.
     */
    private suspend fun sample(
        options: IperfOptions,
        counters: List<AtomicLong>,
        onInterval: (IperfInterval) -> Unit,
        graceMicros: Long = 0,
        work: suspend kotlinx.coroutines.CoroutineScope.(endAt: Long) -> Unit,
    ): Measured = coroutineScope {
        val started = nowMicros()
        val endAt = started + options.durationSec * 1_000_000L
        val workers = launch { work(endAt) }
        val intervals = mutableListOf<IperfInterval>()
        var lastBytes = 0L
        var lastAt = started
        while (isActive && nowMicros() < endAt) {
            delay(1_000)
            val now = minOf(nowMicros(), endAt)
            val total = counters.sumOf { it.get() }
            val interval = IperfInterval((lastAt - started) / 1e6, (now - started) / 1e6, total - lastBytes)
            if (interval.endSec > interval.startSec) {
                intervals += interval
                onInterval(interval)
            }
            lastBytes = total
            lastAt = now
        }
        workers.join()
        val tail = counters.sumOf { it.get() } - lastBytes
        if (graceMicros > 0 && tail > 0 && intervals.isNotEmpty()) {
            // Bytes that landed in the grace window belong to the last second the server was sending.
            val last = intervals.removeAt(intervals.size - 1)
            intervals += last.copy(bytes = last.bytes + tail)
        }
        Measured(intervals, ((endAt - started) / 1e6))
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 8_000
        const val READ_POLL_MS = 250
        const val RECEIVE_BUFFER_BYTES = 262_144
        const val UDP_RECEIVE_BUFFER_BYTES = 4_194_304
        const val REPORT_BUFFER_BYTES = 2_048
        const val FIN_TRIES = 10
        const val FIN_WAIT_MS = 250
        const val REQUEST_RETRY_MS = 250
        const val START_TIMEOUT_MICROS = 5_000_000L
        const val END_GRACE_MICROS = 3_000_000L
        const val MAX_STREAMS = 16
    }
}
