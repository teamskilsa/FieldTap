package com.fieldtap.core.nettest

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.random.Random
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class Iperf3WireTest {

    @Test
    fun theCookieIs36CharactersFromIperfsAlphabetAndANul() {
        val cookie = Iperf3Wire.cookie(Random(7))
        assertEquals(37, cookie.size)
        assertEquals(0, cookie[36].toInt())
        assertTrue(cookie.take(36).all { it.toInt().toChar() in "abcdefghijklmnopqrstuvwxyz234567" })
    }

    @Test
    fun jsonIsLengthPrefixedBigEndian() {
        val out = ByteArrayOutputStream()
        Iperf3Wire.writeJson(out, buildJsonObject { put("tcp", true) })
        val bytes = out.toByteArray()
        val body = """{"tcp":true}"""
        assertArrayEquals(byteArrayOf(0, 0, 0, body.length.toByte()), bytes.copyOfRange(0, 4))
        assertEquals(body, bytes.copyOfRange(4, bytes.size).toString(Charsets.UTF_8))
        assertEquals(true, Iperf3Wire.readJson(ByteArrayInputStream(bytes))["tcp"]!!.jsonPrimitive.boolean)
    }

    @Test
    fun aDownloadIsAReverseTest() {
        val params = Iperf3Wire.params(IperfOptions("10.0.0.1", direction = IperfDirection.DOWNLOAD, durationSec = 5, parallel = 2))
        assertEquals(true, params["tcp"]!!.jsonPrimitive.boolean)
        assertEquals(true, params["reverse"]!!.jsonPrimitive.boolean)
        assertEquals(5, params["time"]!!.jsonPrimitive.int)
        assertEquals(2, params["parallel"]!!.jsonPrimitive.int)
        assertNull("TCP has no target rate", params["bandwidth"])
    }

    @Test
    fun anUploadIsNotReversedAndUdpCarriesItsRate() {
        val params = Iperf3Wire.params(
            IperfOptions("10.0.0.1", protocol = IperfProtocol.UDP, direction = IperfDirection.UPLOAD, udpBitrateBps = 50_000_000),
        )
        assertEquals(true, params["udp"]!!.jsonPrimitive.boolean)
        assertNull(params["reverse"])
        assertEquals(50_000_000L, params["bandwidth"]!!.jsonPrimitive.long)
        assertEquals(IperfOptions.UDP_BLOCK_BYTES, params["len"]!!.jsonPrimitive.int)
    }

    @Test
    fun streamIdsSkipTwoTheWayIperf3Does() {
        assertEquals(listOf(1, 3, 4, 5), (0..3).map { Iperf3Wire.streamId(it) })
    }

    @Test
    fun theUdpHeaderRoundTrips() {
        val buffer = ByteArray(64)
        Iperf3Wire.writeUdpHeader(buffer, sequence = 42, nowMicros = 1_700_000_123_456_789L)
        val header = Iperf3Wire.readUdpHeader(buffer, buffer.size)!!
        assertEquals(42L, header.sequence)
        // Seconds and microseconds travel separately and come back as one instant.
        assertEquals(1_700_000_123_456_789L, header.sentMicros)
        assertNull("too short to hold a header", Iperf3Wire.readUdpHeader(buffer, 11))
    }

    @Test
    fun aSequenceAboveTwoToThe31IsReadUnsigned() {
        // The counter is an unsigned 32-bit field; a long test at high rate passes 2^31 and must not go negative.
        val buffer = ByteArray(Iperf3Wire.UDP_HEADER_BYTES)
        Iperf3Wire.writeUdpHeader(buffer, sequence = 3_000_000_000L, nowMicros = 0)
        assertEquals(3_000_000_000L, Iperf3Wire.readUdpHeader(buffer, buffer.size)!!.sequence)
    }

    @Test
    fun theUdpHelloIsANativeLittleEndianInt() {
        assertArrayEquals(byteArrayOf(0x39, 0x38, 0x37, 0x36), Iperf3Wire.nativeInt(Iperf3Wire.UDP_CONNECT_MSG))
    }

    @Test
    fun lossIsTheGapBelowTheHighestSequenceSeen() {
        val stats = UdpReceiveStats()
        listOf(1L, 2L, 4L, 5L, 7L).forEach { stats.onDatagram(Iperf3Wire.UdpHeader(0, it), 0) }
        assertEquals(5L, stats.packets)
        assertEquals("3 and 6 never came", 2L, stats.lost)
    }

    @Test
    fun aLateDatagramStopsCountingAsLostOnceItArrives() {
        val stats = UdpReceiveStats()
        listOf(1L, 3L, 2L).forEach { stats.onDatagram(Iperf3Wire.UdpHeader(0, it), 0) }
        assertEquals(0L, stats.lost)
    }

    @Test
    fun steadyArrivalsHaveNoJitterAndVariableOnesDo() {
        val steady = UdpReceiveStats()
        (1L..20L).forEach { steady.onDatagram(Iperf3Wire.UdpHeader(it * 1_000, it), it * 1_000 + 5_000) }
        assertEquals(0.0, steady.jitterSeconds, 1e-12)

        val bumpy = UdpReceiveStats()
        (1L..20L).forEach { bumpy.onDatagram(Iperf3Wire.UdpHeader(it * 1_000, it), it * 1_000 + if (it % 2 == 0L) 5_000 else 25_000) }
        assertTrue("20 ms swings give jitter", bumpy.jitterSeconds > 0.005)
    }

    @Test
    fun serverTotalsSumTheirStreams() {
        val json = buildJsonObject {
            put("streams", buildJsonArray {
                add(buildJsonObject { put("id", 1); put("bytes", 1_000); put("packets", 10); put("errors", 1); put("jitter", 0.002) })
                add(buildJsonObject { put("id", 3); put("bytes", 2_000); put("packets", 20); put("errors", 3); put("jitter", 0.004) })
            })
        }
        val totals = Iperf3Wire.serverTotals(json)
        assertEquals(3_000L, totals.bytes)
        assertEquals(30L, totals.packets)
        assertEquals(4L, totals.lost)
        assertEquals(0.004, totals.jitterSeconds!!, 1e-12)
    }
}

/**
 * The client against a loopback server that speaks the iperf3 server side. It proves the client walks
 * the protocol in order, frames what it sends, and counts what moves. It does not prove agreement with
 * the real `iperf3 -s`, which only running against one can.
 */
class Iperf3ClientTest {

    private val loopback = object : IperfConnector {
        override fun openTcp(host: String, port: Int, timeoutMs: Int): Socket =
            Socket().apply { connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port), timeoutMs) }

        override fun openUdp(host: String, port: Int): DatagramSocket =
            DatagramSocket().apply { connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port)) }
    }

    @Test
    fun aTcpDownloadReceivesWhatTheServerSends() = runBlocking {
        val server = FakeIperf3Server()
        val intervals = mutableListOf<IperfInterval>()
        val result = Iperf3Client(loopback).run(
            IperfOptions("localhost", server.port, IperfProtocol.TCP, IperfDirection.DOWNLOAD, durationSec = 2),
        ) { intervals += it }
        server.join()

        assertEquals("the params arrived as sent", true, server.params.get()!!["reverse"]!!.jsonPrimitive.boolean)
        assertTrue("bytes flowed", result.receivedBytes!! > 0)
        assertEquals("the server's count is the sent side", server.sentBytes.get(), result.sentBytes)
        assertTrue("the client counted no more than was sent", result.receivedBytes!! <= server.sentBytes.get())
        assertTrue("an interval a second", intervals.size in 1..3)
        assertTrue(result.mbps > 0)
        assertEquals(listOf("cookie", "params", "streams", "running", "end", "results", "done"), server.log)
    }

    @Test
    fun aTcpUploadIsQuotedFromWhatTheServerReceived() = runBlocking {
        val server = FakeIperf3Server()
        val result = Iperf3Client(loopback).run(
            IperfOptions("localhost", server.port, IperfProtocol.TCP, IperfDirection.UPLOAD, durationSec = 1),
        )
        server.join()
        assertNull(server.params.get()!!["reverse"])
        assertEquals(server.receivedBytes.get(), result.receivedBytes)
        assertTrue(result.sentBytes!! >= result.receivedBytes!!)
    }

    @Test
    fun parallelTcpStreamsEachGetTheCookie() = runBlocking {
        val server = FakeIperf3Server()
        Iperf3Client(loopback).run(
            IperfOptions("localhost", server.port, IperfProtocol.TCP, IperfDirection.DOWNLOAD, durationSec = 1, parallel = 3),
        )
        server.join()
        assertEquals(3, server.streamCookiesMatched.get().toInt())
    }

    @Test
    fun aUdpDownloadCountsDatagramsAndLoss() = runBlocking {
        val server = FakeIperf3Server(udpDropEvery = 10)
        val result = Iperf3Client(loopback).run(
            IperfOptions("localhost", server.port, IperfProtocol.UDP, IperfDirection.DOWNLOAD, durationSec = 2, udpBitrateBps = 2_000_000),
        )
        server.join()
        assertTrue("datagrams arrived", (result.packets ?: 0) > 0)
        assertTrue("every tenth was dropped on purpose", (result.lostPackets ?: 0) > 0)
        assertTrue(result.lossPercent!! in 5.0..20.0)
        assertTrue(result.jitterMs != null)
    }

    @Test
    fun aBusyServerIsReportedAsBusy() = runBlocking {
        val server = FakeIperf3Server(refuse = true)
        try {
            Iperf3Client(loopback).run(IperfOptions("localhost", server.port, durationSec = 1))
            fail("expected Busy")
        } catch (e: Iperf3Failure.Busy) {
            // expected
        }
        server.join()
    }

    @Test
    fun aServerThatHangsUpMidTestIsAServerError() = runBlocking {
        val server = FakeIperf3Server(hangUpAfterStart = true)
        try {
            Iperf3Client(loopback).run(IperfOptions("localhost", server.port, durationSec = 1))
            fail("expected ServerError")
        } catch (e: Iperf3Failure.ServerError) {
            // expected
        }
        server.join()
    }
}

/**
 * Just enough of `iperf3 -s` to walk one test: TCP or UDP, either direction, any number of streams.
 */
private class FakeIperf3Server(
    private val refuse: Boolean = false,
    private val hangUpAfterStart: Boolean = false,
    private val udpDropEvery: Int = 0,
) {
    private val listener = ServerSocket(0, 16, InetAddress.getLoopbackAddress())
    private val udp = DatagramSocket(listener.localPort, InetAddress.getLoopbackAddress())
    val port: Int = listener.localPort
    val params = AtomicReference<JsonObject?>(null)
    val sentBytes = AtomicLong(0)
    val receivedBytes = AtomicLong(0)
    val streamCookiesMatched = AtomicLong(0)
    val log = java.util.Collections.synchronizedList(mutableListOf<String>())
    private val worker = thread(isDaemon = true) { serve() }

    fun join() {
        worker.join(15_000)
        runCatching { listener.close() }
        runCatching { udp.close() }
    }

    private fun serve() {
        listener.accept().use { control ->
            val input = DataInputStream(control.getInputStream())
            val output = control.getOutputStream()
            val cookie = ByteArray(Iperf3Wire.COOKIE_BYTES).also { input.readFully(it) }
            log += "cookie"
            if (refuse) {
                output.write(Iperf3Wire.ACCESS_DENIED)
                output.flush()
                return
            }
            state(output, Iperf3Wire.PARAM_EXCHANGE)
            val p = Iperf3Wire.readJson(input)
            params.set(p)
            log += "params"
            val parallel = p["parallel"]!!.jsonPrimitive.int
            val reverse = p["reverse"]?.jsonPrimitive?.boolean == true
            val isUdp = p["udp"]?.jsonPrimitive?.boolean == true
            val len = p["len"]!!.jsonPrimitive.int
            state(output, Iperf3Wire.CREATE_STREAMS)

            val tcpStreams = mutableListOf<Socket>()
            var udpPeer: InetSocketAddress? = null
            repeat(parallel) {
                if (isUdp) {
                    val hello = DatagramPacket(ByteArray(4), 4)
                    udp.receive(hello)
                    udpPeer = hello.socketAddress as InetSocketAddress
                    val reply = Iperf3Wire.nativeInt(Iperf3Wire.UDP_CONNECT_REPLY)
                    udp.send(DatagramPacket(reply, 4, hello.socketAddress))
                } else {
                    val stream = listener.accept()
                    val streamCookie = ByteArray(Iperf3Wire.COOKIE_BYTES).also { DataInputStream(stream.getInputStream()).readFully(it) }
                    if (streamCookie.contentEquals(cookie)) streamCookiesMatched.incrementAndGet()
                    tcpStreams += stream
                }
            }
            log += "streams"
            state(output, Iperf3Wire.TEST_START)
            state(output, Iperf3Wire.TEST_RUNNING)
            log += "running"
            if (hangUpAfterStart) return

            val stop = java.util.concurrent.atomic.AtomicBoolean(false)
            val movers = if (isUdp) {
                listOf(thread { if (reverse) udpSend(udpPeer!!, len, stop) else udpReceive(stop) })
            } else {
                tcpStreams.map { s -> thread { if (reverse) tcpSend(s, len, stop) else tcpReceive(s, stop) } }
            }

            val end = input.read()
            log += if (end == Iperf3Wire.TEST_END) "end" else "unexpected:$end"
            stop.set(true)
            tcpStreams.forEach { runCatching { it.shutdownOutput() } }
            movers.forEach { it.join(3_000) }
            tcpStreams.forEach { runCatching { it.close() } }

            state(output, Iperf3Wire.EXCHANGE_RESULTS)
            Iperf3Wire.readJson(input)
            val bytes = if (reverse) sentBytes.get() else receivedBytes.get()
            Iperf3Wire.writeJson(output, buildJsonObject {
                put("streams", buildJsonArray { add(buildJsonObject { put("id", 1); put("bytes", bytes) }) })
            })
            log += "results"
            state(output, Iperf3Wire.DISPLAY_RESULTS)
            if (input.read() == Iperf3Wire.IPERF_DONE) log += "done"
        }
    }

    private fun state(out: OutputStream, value: Int) {
        out.write(value)
        out.flush()
    }

    private fun tcpSend(socket: Socket, len: Int, stop: java.util.concurrent.atomic.AtomicBoolean) {
        val block = ByteArray(len)
        val out = socket.getOutputStream()
        try {
            while (!stop.get()) {
                out.write(block)
                sentBytes.addAndGet(len.toLong())
            }
        } catch (e: Exception) {
        }
    }

    private fun tcpReceive(socket: Socket, stop: java.util.concurrent.atomic.AtomicBoolean) {
        val buffer = ByteArray(65_536)
        val input: InputStream = socket.getInputStream()
        socket.soTimeout = 200
        while (!stop.get()) {
            val n = try { input.read(buffer) } catch (e: java.net.SocketTimeoutException) { continue } catch (e: Exception) { return }
            if (n < 0) return
            receivedBytes.addAndGet(n.toLong())
        }
    }

    private fun udpSend(peer: InetSocketAddress, len: Int, stop: java.util.concurrent.atomic.AtomicBoolean) {
        val block = ByteArray(len)
        var seq = 0L
        while (!stop.get()) {
            seq++
            Iperf3Wire.writeUdpHeader(block, seq, System.nanoTime() / 1_000)
            sentBytes.addAndGet(len.toLong())
            if (udpDropEvery > 0 && seq % udpDropEvery == 0L) continue
            runCatching { udp.send(DatagramPacket(block, len, peer)) }
            Thread.sleep(1)
        }
    }

    private fun udpReceive(stop: java.util.concurrent.atomic.AtomicBoolean) {
        val buffer = ByteArray(2048)
        udp.soTimeout = 200
        while (!stop.get()) {
            val packet = DatagramPacket(buffer, buffer.size)
            try { udp.receive(packet) } catch (e: Exception) { continue }
            receivedBytes.addAndGet(packet.length.toLong())
        }
    }
}
