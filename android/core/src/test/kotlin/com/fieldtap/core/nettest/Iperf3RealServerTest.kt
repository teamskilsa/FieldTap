package com.fieldtap.core.nettest

import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The client against a real `iperf3 -s`, not a fake. Skipped unless IPERF3_PORT names a port where one is
 * listening on localhost:
 *
 *     iperf3 -s -p 5210 &
 *     IPERF3_PORT=5210 ./gradlew :core:test --tests '*Iperf3RealServerTest*'
 *
 * The fake server in Iperf3ClientTest proves the client agrees with itself. This proves it agrees with iperf3.
 */
class Iperf3RealServerTest {
    private val port = System.getenv("IPERF3_PORT")?.toIntOrNull()

    private val loopback = object : IperfConnector {
        override fun openTcp(host: String, port: Int, timeoutMs: Int): Socket =
            Socket().apply { connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port), timeoutMs) }

        override fun openUdp(host: String, port: Int): DatagramSocket =
            DatagramSocket().apply { connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port)) }
    }

    private fun run(options: IperfOptions): IperfResult = runBlocking {
        assumeTrue("no real iperf3 server; set IPERF3_PORT", port != null)
        Iperf3Client(loopback).run(options.copy(port = port!!)).also {
            println("REAL ${options.protocol} ${options.direction} x${options.parallel}: " +
                "sent=${it.sentBytes} received=${it.receivedBytes} ${"%.1f".format(it.mbps)} Mbps " +
                "jitter=${it.jitterMs} lost=${it.lostPackets}/${it.packets}")
        }
    }

    @Test fun tcpDownload() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.TCP, direction = IperfDirection.DOWNLOAD, durationSec = 2))
        assertTrue(r.receivedBytes!! > 0 && r.sentBytes!! > 0)
    }

    @Test fun tcpUpload() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.TCP, direction = IperfDirection.UPLOAD, durationSec = 2))
        assertTrue(r.receivedBytes!! > 0 && r.sentBytes!! > 0)
    }

    @Test fun tcpDownloadTwoStreams() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.TCP, direction = IperfDirection.DOWNLOAD, durationSec = 2, parallel = 2))
        assertTrue(r.receivedBytes!! > 0)
    }

    @Test fun udpDownload() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.UDP, direction = IperfDirection.DOWNLOAD, durationSec = 2, udpBitrateBps = 5_000_000))
        assertTrue(r.receivedBytes!! > 0)
        assertTrue((r.packets ?: 0) > 0)
    }

    @Test fun udpUpload() {
        val r = run(IperfOptions("localhost", protocol = IperfProtocol.UDP, direction = IperfDirection.UPLOAD, durationSec = 2, udpBitrateBps = 5_000_000))
        assertTrue(r.sentBytes!! > 0)
        assertTrue("the server saw the datagrams", r.receivedBytes!! > 0)
    }
}
