package com.fieldtap.ui.traffic

import com.fieldtap.core.nettest.IperfDirection
import com.fieldtap.core.nettest.IperfOptions
import com.fieldtap.core.nettest.IperfProtocol
import com.fieldtap.nettest.IperfVersion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrafficSequenceTest {

    @Test
    fun aRoundRunsItsStepsInTheSameOrderWhateverOrderTheyWerePicked() {
        val plan = SequencePlan(setOf(SequenceStep.UPLOAD, SequenceStep.PING), rounds = 2, gapSec = 10)
        assertEquals(
            listOf(1 to SequenceStep.PING, 1 to SequenceStep.UPLOAD, 2 to SequenceStep.PING, 2 to SequenceStep.UPLOAD),
            (0 until 4).map { plan.at(it) },
        )
        assertNull(plan.at(4))
        // The pause goes before each round after the first, never before the first test.
        assertEquals(listOf(false, false, true, false), (0 until 4).map { plan.startsRound(it) })
    }

    @Test
    fun untilStoppedNeverRunsOutAndAnEmptyPlanNeverStarts() {
        val forever = SequencePlan(SequenceStep.entries.toSet(), SequencePlan.UNTIL_STOPPED, 0)
        assertEquals(1_000 to SequenceStep.UPLOAD, forever.at(2_999))
        assertTrue(forever.runnable)
        assertFalse(SequencePlan(emptySet(), 5, 0).runnable)
        assertNull(SequencePlan(emptySet(), 5, 0).at(0))
    }

    private fun iperf(at: Long, direction: IperfDirection, mbps: Double) = TrafficResult.Iperf(
        finishedAtMs = at, version = IperfVersion.V2,
        options = IperfOptions(host = "192.168.2.1", port = 5001, protocol = IperfProtocol.TCP, direction = direction, durationSec = 10, parallel = 1),
        mbps = mbps, peakMbps = mbps + 5, seconds = 10.0, sentBytes = null, receivedBytes = 1_000,
        jitterMs = null, lossPercent = null, lostPackets = null, packets = null,
    )

    private fun ping(at: Long, received: Int, avg: Double) =
        TrafficResult.Ping(at, "192.168.2.1", sent = 10, received = received, minMs = avg - 2, avgMs = avg, maxMs = avg + 3, mdevMs = 1.2)

    @Test
    fun theSummaryIsTheMediansAndCountsTheFailures() {
        val results = listOf(
            ping(1, 10, 28.0), iperf(2, IperfDirection.DOWNLOAD, 40.0), iperf(3, IperfDirection.UPLOAD, 10.0),
            ping(4, 8, 30.0), iperf(5, IperfDirection.DOWNLOAD, 60.0),
            TrafficResult.Failed(6, "iperf2", "192.168.2.1", "Connection refused"),
        )
        val summary = SequenceStats.summarize(results)
        assertEquals(6, summary.tests)
        assertEquals(1, summary.failures)
        assertEquals(50.0, summary.downloadMbps!!, 0.0)
        assertEquals(10.0, summary.uploadMbps!!, 0.0)
        assertEquals(29.0, summary.rttMs!!, 0.0)
        assertEquals(10.0, summary.pingLossPercent!!, 0.0)
    }

    @Test
    fun theCsvIsOldestFirstWithEmptyFieldsNotZeroes() {
        val csv = TrafficCsv.of(
            listOf(
                TrafficResult.Failed(1_789_050_605_000, "iperf2", "192.168.2.1", "Refused, port 5001"),
                iperf(1_789_050_600_000, IperfDirection.DOWNLOAD, 41.234),
                ping(1_789_050_590_000, 9, 28.5),
            ),
        )
        val lines = csv.trimEnd().split("\r\n")
        assertEquals(TrafficCsv.HEADER.joinToString(","), lines[0])
        assertEquals(4, lines.size)
        assertTrue(lines[1].startsWith("2026-09-10T14:29:50Z,ping,192.168.2.1,icmp,"))
        assertTrue(lines[1].contains(",10,9,26.500,28.500,31.500,1.200,"))
        assertTrue(lines[2].startsWith("2026-09-10T14:30:00Z,iperf2,192.168.2.1,tcp,download,1,10.0,41.23,46.23,,,"))
        // A message with a comma is quoted, as Python's csv module writes it.
        assertTrue(lines[3].endsWith(",\"Refused, port 5001\""))
        assertTrue(lines.all { it.count { c -> c == ',' } >= TrafficCsv.HEADER.size - 1 })
    }
}
