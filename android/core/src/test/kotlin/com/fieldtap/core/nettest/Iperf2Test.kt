package com.fieldtap.core.nettest

import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** The iperf2 wire format, pinned to bytes captured from the real iperf 2.2.1 client and server. */
class Iperf2WireTest {

    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun aTcpUploadHeaderIsByteForByteWhatIperf221Sends() {
        // `iperf -c 127.0.0.1 -p 5303 -t 1 -l 1400`, first 64 bytes on the wire.
        val captured = hex("4001008000000001000014b70000057800000000ffffff9c00000000000000000000000000020002000100010000000000000000000000000000000000000000")
        val ours = Iperf2Wire.clientHeader(IperfOptions("x", port = 5303, protocol = IperfProtocol.TCP, direction = IperfDirection.UPLOAD, durationSec = 1, blockSize = 1400), streams = 1)
        assertArrayEquals(captured, ours)
    }

    @Test
    fun aTcpDownloadHeaderIsByteForByteWhatIperf221SendsForReverse() {
        // `iperf -c 127.0.0.1 -p 5304 -t 1 -R`.
        val captured = hex("4401008000000001000014b80000000000000000ffffff9c00000000000000000400000000020002000100010000000000000000000000000000000000000000")
        val ours = Iperf2Wire.clientHeader(IperfOptions("x", port = 5304, protocol = IperfProtocol.TCP, direction = IperfDirection.DOWNLOAD, durationSec = 1), streams = 1)
        assertArrayEquals(captured, ours)
    }

    @Test
    fun aUdpDownloadHeaderCarriesTheRateWhereIperf221PutsIt() {
        // `iperf -c 127.0.0.1 -u -R -p 5309 -t 3 -b 7M -l 1400`, datagram bytes 16..80. 7M is 7 x 2^20 in iperf2.
        val captured = hex(
            "6c0100a0" + "00000001" + "000014bd" + "00000578" + "00000000" + "fffffed4" + "00000000" + "00000000" +
                "04000000" + "00020002" + "00010001" + "00000000" + "00700000" + "00000000" + "00000000" + "00000000",
        )
        val ours = Iperf2Wire.clientHeader(
            IperfOptions("x", port = 5309, protocol = IperfProtocol.UDP, direction = IperfDirection.DOWNLOAD, durationSec = 3, udpBitrateBps = 7_340_032, blockSize = 1400),
            streams = 1,
        )
        assertArrayEquals(captured, ours)
    }

    @Test
    fun theUdpHeaderIsSixteenBytesWithA64BitSequence() {
        val buffer = ByteArray(16)
        Iperf2Wire.writeUdpHeader(buffer, sequence = 1, nowMicros = 1_789_600_756_296_020L)
        assertArrayEquals(hex("00000001" + "%08x".format(1_789_600_756) + "%08x".format(296_020) + "00000000"), buffer)
        assertEquals(1L, Iperf2Wire.readUdpHeader(buffer, 16)!!.sequence)
    }

    @Test
    fun aFinalDatagramHasANegativeSequenceAcrossBothWords() {
        // iperf 2.2.1's own final datagram: low word -12, high word -1.
        val buffer = ByteArray(16)
        Iperf2Wire.writeUdpHeader(buffer, sequence = -12, nowMicros = 0)
        assertArrayEquals(hex("fffffff4"), buffer.copyOfRange(0, 4))
        assertArrayEquals(hex("ffffffff"), buffer.copyOfRange(12, 16))
        assertEquals(-12L, Iperf2Wire.readUdpHeader(buffer, 16)!!.sequence)
    }

    @Test
    fun aSequencePast2To32KeepsCounting() {
        val buffer = ByteArray(16)
        Iperf2Wire.writeUdpHeader(buffer, sequence = 5_000_000_000L, nowMicros = 0)
        assertEquals(5_000_000_000L, Iperf2Wire.readUdpHeader(buffer, 16)!!.sequence)
    }

    @Test
    fun theIperf221ServerReportIsReadAfterSixteenBytes() {
        // The real server's answer: 280000 bytes, 1 lost of 201, jitter 7 µs, stopped at 0.458458 s.
        val reply = hex("000000000000000000000000000000008800000000000000000445c0000000000006feda0000000100000000000000c90000000000000007000000000000000f0000000000000063000000000000179d") + ByteArray(48)
        val report = Iperf2Wire.parseServerReport(reply, 128)!!
        assertEquals(280_000L, report.bytes)
        assertEquals(1L, report.lost)
        assertEquals(201L, report.datagrams)
        assertEquals(0.458458, report.seconds, 1e-9)
        assertEquals(0.000007, report.jitterSeconds, 1e-12)
    }

    @Test
    fun anIperf20ServerReportIsReadAfterTwelveBytes() {
        // 2.0.x writes the same report after a 12-byte datagram header.
        val body = hex("80000000" + "00000000" + "000445c0" + "00000002" + "00000000" + "00000003" + "00000000" + "00000064" + "00000000" + "000003e8")
        val reply = ByteArray(12) + body
        val report = Iperf2Wire.parseServerReport(reply, reply.size)!!
        assertEquals(280_000L, report.bytes)
        assertEquals(3L, report.lost)
        assertEquals(100L, report.datagrams)
        assertEquals(0.001, report.jitterSeconds, 1e-12)
    }

    @Test
    fun aReplyWithoutTheVersionBitIsNotAReport() {
        assertNull(Iperf2Wire.parseServerReport(ByteArray(128), 128))
        assertNull(Iperf2Wire.parseServerReport(ByteArray(20), 20))
    }

    @Test
    fun thePayloadIsIperfsDigitPattern() {
        assertEquals("0123456789012", String(Iperf2Wire.pattern(13)))
    }
}

/**
 * The client against real iperf 2 servers. Skipped unless both ports are set:
 *
 *     iperf -s -p 5401 &          # TCP
 *     iperf -s -u -p 5402 &       # UDP
 *     IPERF2_TCP_PORT=5401 IPERF2_UDP_PORT=5402 ./gradlew :core:test --tests '*Iperf2RealServerTest*'
 */
class Iperf2RealServerTest {
    private val tcpPort = System.getenv("IPERF2_TCP_PORT")?.toIntOrNull()
    private val udpPort = System.getenv("IPERF2_UDP_PORT")?.toIntOrNull()

    private val loopback = object : IperfConnector {
        override fun openTcp(host: String, port: Int, timeoutMs: Int): Socket =
            Socket().apply { connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port), timeoutMs) }

        override fun openUdp(host: String, port: Int): DatagramSocket =
            DatagramSocket().apply { connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port)) }
    }

    private fun run(options: IperfOptions): IperfResult = runBlocking {
        val port = if (options.protocol == IperfProtocol.TCP) tcpPort else udpPort
        assumeTrue("no real iperf2 server; set IPERF2_TCP_PORT and IPERF2_UDP_PORT", port != null)
        Iperf2Client(loopback).run(options.copy(port = port!!)).also {
            println("REAL2 ${options.protocol} ${options.direction} x${options.parallel}: sent=${it.sentBytes} received=${it.receivedBytes} " +
                "${"%.2f".format(it.mbps)} Mbps intervals=${it.intervals.size} jitter=${it.jitterMs} lost=${it.lostPackets}/${it.packets}")
        }
    }

    @Test fun tcpUpload() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.TCP, direction = IperfDirection.UPLOAD, durationSec = 2))
        assertTrue(r.sentBytes!! > 0)
        assertNull("iperf2 TCP returns no report", r.receivedBytes)
    }

    @Test fun tcpDownload() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.TCP, direction = IperfDirection.DOWNLOAD, durationSec = 2))
        assertTrue(r.receivedBytes!! > 0)
    }

    @Test fun tcpDownloadTwoStreams() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.TCP, direction = IperfDirection.DOWNLOAD, durationSec = 2, parallel = 2))
        assertTrue(r.receivedBytes!! > 0)
    }

    @Test fun udpUploadGetsTheServersReport() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.UDP, direction = IperfDirection.UPLOAD, durationSec = 2, udpBitrateBps = 5_000_000))
        assertNotNull("the server answered the final datagrams", r.receivedBytes)
        assertTrue((r.packets ?: 0) > 800)
        assertTrue("rate held near 5 Mbit/s: ${r.mbps}", r.mbps in 4.5..5.5)
    }

    @Test fun udpDownloadAtTheRequestedRate() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.UDP, direction = IperfDirection.DOWNLOAD, durationSec = 2, udpBitrateBps = 5_000_000))
        assertTrue(r.receivedBytes!! > 0)
        assertTrue("the server honoured the rate: ${r.mbps}", r.mbps in 4.5..5.5)
    }
}
