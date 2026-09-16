@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.fieldtap.core.nettest

import com.fieldtap.core.time.Clock
import com.fieldtap.format.TrafficTest
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NetTestRunnerTest {

    @Test
    fun pingAtTenSecondsDownloadAtThirtyThenPingSixtySecondsAfterTheFirst() = runTest {
        val transport = FakeTransport { testScheduler.currentTime }
        val records = mutableListOf<TrafficRecord>()
        val runner = NetTestRunner(TestSettings(), transport, VirtualClock(testScheduler))

        val job = launch { runner.run(isPaused = { false }) { records += it } }
        advanceTimeBy(95_001)
        job.cancel()

        assertEquals(
            listOf(TrafficTest.PING to 10_000L, TrafficTest.DOWNLOAD to 30_000L, TrafficTest.PING to 70_000L),
            transport.calls,
        )
        assertEquals(3, records.size)
        assertEquals(WALL_BASE + 10_000, records[0].row.timeUtcMs)
        assertEquals(WALL_BASE + 30_000, records[1].row.timeUtcMs)
        assertTrue(records.all { it.row.ok })
        assertEquals(Triple("8.8.8.8", 5, 2_000L), transport.pings[0])
        assertEquals(
            Triple(TestSettings.DEFAULT_DOWNLOAD_URL, 10_000_000L, NetTestRunner.DOWNLOAD_TIMEOUT_MS),
            transport.downloads[0],
        )
    }

    @Test
    fun testsNeverOverlap() = runTest {
        val transport = FakeTransport { testScheduler.currentTime }.apply { pingMs = 25_000 }
        val runner = NetTestRunner(TestSettings(), transport, VirtualClock(testScheduler))

        val job = launch { runner.run(isPaused = { false }) {} }
        advanceTimeBy(40_000)
        job.cancel()

        // The download fell due at 30 s while the ping ran until 35 s; it starts only after.
        assertEquals(listOf(TrafficTest.PING to 10_000L, TrafficTest.DOWNLOAD to 35_000L), transport.calls)
    }

    @Test
    fun aDueTestIsSkippedWhilePausedInAPrivacyZone() = runTest {
        val transport = FakeTransport { testScheduler.currentTime }
        val records = mutableListOf<TrafficRecord>()
        val runner = NetTestRunner(TestSettings(), transport, VirtualClock(testScheduler))

        val job = launch { runner.run(isPaused = { testScheduler.currentTime < 20_000 }) { records += it } }
        advanceTimeBy(95_001)
        job.cancel()

        assertEquals(listOf(TrafficTest.DOWNLOAD to 30_000L, TrafficTest.PING to 70_000L), transport.calls)
        assertEquals(2, records.size)
    }

    @Test
    fun downloadsStopWhenTheBudgetCannotHoldAnotherCap() = runTest {
        val settings = TestSettings(
            pingTarget = "",
            downloadIntervalMs = 10_000,
            downloadCapBytes = 10_000_000,
            sessionBudgetBytes = 25_000_000,
        )
        val transport = FakeTransport { testScheduler.currentTime }
        val runner = NetTestRunner(settings, transport, VirtualClock(testScheduler))

        val job = launch { runner.run(isPaused = { false }) {} }
        advanceTimeBy(300_000)

        assertEquals(listOf(TrafficTest.DOWNLOAD to 30_000L, TrafficTest.DOWNLOAD to 40_000L), transport.calls)
        assertTrue("the runner waits for cancellation once no test can run", job.isActive)
        job.cancel()
    }

    @Test
    fun partialBytesOfAFailedDownloadSpendTheBudget() = runTest {
        val settings = TestSettings(pingTarget = "", downloadIntervalMs = 10_000, sessionBudgetBytes = 25_000_000)
        val transport = FakeTransport { testScheduler.currentTime }.apply {
            download = { DownloadOutcome.Failed(NetFailure.TIMEOUT, null, 60.0, 200, 16_000_000) }
        }
        val records = mutableListOf<TrafficRecord>()
        val runner = NetTestRunner(settings, transport, VirtualClock(testScheduler))

        val job = launch { runner.run(isPaused = { false }) { records += it } }
        advanceTimeBy(300_000)
        job.cancel()

        assertEquals(1, transport.calls.size)
        assertFalse(records.single().row.ok)
        assertEquals(16_000_000L, records.single().row.bytes)
    }

    @Test
    fun aTransportThatThrowsBecomesAFailedRowAndTheRunnerContinues() = runTest {
        val transport = FakeTransport { testScheduler.currentTime }.apply {
            ping = { throw IllegalStateException("socket exploded") }
        }
        val records = mutableListOf<TrafficRecord>()
        val runner = NetTestRunner(TestSettings(), transport, VirtualClock(testScheduler))

        val job = launch { runner.run(isPaused = { false }) { records += it } }
        advanceTimeBy(35_000)
        job.cancel()

        val failed = records.first()
        assertFalse(failed.row.ok)
        assertEquals("network error: IllegalStateException", failed.row.error)
        assertEquals(4.0, failed.row.seconds, 1e-9)
        assertNotNull(failed.failure)
        assertEquals(TrafficTest.DOWNLOAD, transport.calls[1].first)
    }

    @Test
    fun nothingRunsWhenNoTestIsConfigured() = runTest {
        val transport = FakeTransport { testScheduler.currentTime }
        val runner = NetTestRunner(TestSettings(pingTarget = "", downloadUrl = null), transport, VirtualClock(testScheduler))

        val job = launch { runner.run(isPaused = { false }) {} }
        advanceTimeBy(1_000_000)

        assertTrue(transport.calls.isEmpty())
        assertTrue(job.isActive)
        job.cancel()
    }

    @Test
    fun cancellingDuringATestEmitsNothing() = runTest {
        val transport = FakeTransport { testScheduler.currentTime }
        val records = mutableListOf<TrafficRecord>()
        val runner = NetTestRunner(TestSettings(), transport, VirtualClock(testScheduler))

        val job = launch { runner.run(isPaused = { false }) { records += it } }
        advanceTimeBy(12_000)
        job.cancel()
        advanceTimeBy(10_000)

        assertEquals(1, transport.calls.size)
        assertTrue(records.isEmpty())
    }

    private class VirtualClock(private val scheduler: TestCoroutineScheduler) : Clock {
        override fun wallMillis(): Long = WALL_BASE + scheduler.currentTime

        override fun elapsedRealtimeMillis(): Long = ELAPSED_BASE + scheduler.currentTime
    }

    private class FakeTransport(private val now: () -> Long) : NetTestTransport {
        val calls = mutableListOf<Pair<TrafficTest, Long>>()
        val pings = mutableListOf<Triple<String, Int, Long>>()
        val downloads = mutableListOf<Triple<String, Long, Long>>()
        val uploads = mutableListOf<Triple<String, Long, Long>>()
        var pingMs = 4_000L
        var downloadMs = 4_000L
        var uploadMs = 4_000L
        var ping: () -> PingOutcome = { PingOutcome.Replies(5, listOf(40.0, 42.0, 44.0, 46.0, 48.0), 4.0) }
        var download: () -> DownloadOutcome = { DownloadOutcome.Completed(10_000_000, 4.0, 200, capped = true) }
        var upload: () -> UploadOutcome = { UploadOutcome.Completed(2_000_000, 4.0, 200) }

        override suspend fun ping(target: String, count: Int, timeoutMs: Long): PingOutcome {
            calls += TrafficTest.PING to now()
            pings += Triple(target, count, timeoutMs)
            delay(pingMs)
            return ping.invoke()
        }

        override suspend fun download(url: String, capBytes: Long, timeoutMs: Long): DownloadOutcome {
            calls += TrafficTest.DOWNLOAD to now()
            downloads += Triple(url, capBytes, timeoutMs)
            delay(downloadMs)
            return download.invoke()
        }

        override suspend fun upload(url: String, capBytes: Long, timeoutMs: Long): UploadOutcome {
            calls += TrafficTest.UPLOAD to now()
            uploads += Triple(url, capBytes, timeoutMs)
            delay(uploadMs)
            return upload.invoke()
        }
    }

    private companion object {
        const val WALL_BASE = 1_789_050_600_000L
        const val ELAPSED_BASE = 25_323_456L
    }
}
