package com.fieldtap.core.nettest

import com.fieldtap.format.TrafficTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NetTestSchedulerTest {
    private val start = 25_000_000L

    @Test
    fun firstPingIsDueTenSecondsAfterStartThenEverySixtySecondsAfterThePreviousStart() {
        val scheduler = NetTestScheduler(TestSettings(downloadUrl = null), start)

        assertNull(scheduler.nextDue(start))
        assertNull(scheduler.nextDue(start + 9_999))
        assertEquals(TrafficTest.PING, scheduler.nextDue(start + 10_000))

        // Started late, at 12 s: the next one is 60 s after that start, not after the due time.
        scheduler.markStarted(TrafficTest.PING, start + 12_000)
        assertNull(scheduler.nextDue(start + 71_999))
        assertEquals(TrafficTest.PING, scheduler.nextDue(start + 72_000))
    }

    @Test
    fun firstDownloadIsDueThirtySecondsAfterStartThenEveryFiveMinutes() {
        val scheduler = NetTestScheduler(TestSettings(pingTarget = ""), start)

        assertNull(scheduler.nextDue(start + 29_999))
        assertEquals(TrafficTest.DOWNLOAD, scheduler.nextDue(start + 30_000))
        scheduler.markStarted(TrafficTest.DOWNLOAD, start + 30_000)
        assertNull(scheduler.nextDue(start + 329_999))
        assertEquals(TrafficTest.DOWNLOAD, scheduler.nextDue(start + 330_000))
    }

    @Test
    fun atMostOneTestIsDueAndPingComesFirst() {
        val scheduler = NetTestScheduler(TestSettings(), start)

        assertEquals(TrafficTest.PING, scheduler.nextDue(start + 40_000))
        scheduler.markStarted(TrafficTest.PING, start + 40_000)
        assertEquals(TrafficTest.DOWNLOAD, scheduler.nextDue(start + 40_000))
        scheduler.markStarted(TrafficTest.DOWNLOAD, start + 40_000)
        assertNull(scheduler.nextDue(start + 40_000))
    }

    @Test
    fun noDownloadWithoutUrl() {
        for (url in listOf(null, "", "   ")) {
            val scheduler = NetTestScheduler(TestSettings(pingTarget = "", downloadUrl = url), start)
            assertNull(scheduler.nextDue(start + 1_000_000))
            assertFalse(scheduler.hasWork)
            assertEquals(Long.MAX_VALUE, scheduler.millisUntilNext(start))
        }
    }

    @Test
    fun noDownloadOnceTheRemainingBudgetIsBelowTheCap() {
        val settings = TestSettings(pingTarget = "", downloadCapBytes = 10_000_000, sessionBudgetBytes = 25_000_000)
        val scheduler = NetTestScheduler(settings, start)

        scheduler.addBytes(10_000_000)
        assertEquals(TrafficTest.DOWNLOAD, scheduler.nextDue(start + 30_000))
        scheduler.addBytes(5_000_000)
        assertEquals(15_000_000, scheduler.budgetUsedBytes)
        // 10 MB left: exactly one cap still fits.
        assertEquals(TrafficTest.DOWNLOAD, scheduler.nextDue(start + 30_000))
        scheduler.addBytes(1)
        assertNull(scheduler.nextDue(start + 30_000))
        assertFalse(scheduler.hasWork)
    }

    @Test
    fun negativeBytesAreIgnoredAndTheBudgetNeverOverflows() {
        val scheduler = NetTestScheduler(TestSettings(), start)
        scheduler.addBytes(-5)
        assertEquals(0, scheduler.budgetUsedBytes)
        scheduler.addBytes(Long.MAX_VALUE)
        scheduler.addBytes(Long.MAX_VALUE)
        assertEquals(Long.MAX_VALUE, scheduler.budgetUsedBytes)
    }

    @Test
    fun aCapLargerThanTheBudgetNeverDownloads() {
        val settings = TestSettings(pingTarget = "", downloadCapBytes = 200_000_000, sessionBudgetBytes = 100_000_000)
        assertNull(NetTestScheduler(settings, start).nextDue(start + 600_000))
    }

    @Test
    fun pingIsDisabledByABlankTargetOrNoEchoes() {
        assertNull(NetTestScheduler(TestSettings(pingTarget = " ", downloadUrl = null), start).nextDue(start + 60_000))
        assertNull(NetTestScheduler(TestSettings(pingCount = 0, downloadUrl = null), start).nextDue(start + 60_000))
    }

    @Test
    fun millisUntilNextCountsDownToTheEarliestTest() {
        val scheduler = NetTestScheduler(TestSettings(), start)

        assertEquals(10_000, scheduler.millisUntilNext(start))
        assertEquals(1, scheduler.millisUntilNext(start + 9_999))
        assertEquals(0, scheduler.millisUntilNext(start + 12_000))
        scheduler.markStarted(TrafficTest.PING, start + 12_000)
        assertEquals(18_000, scheduler.millisUntilNext(start + 12_000))
    }

    @Test
    fun intervalsBelowOneSecondAreRaised() {
        val scheduler = NetTestScheduler(TestSettings(pingIntervalMs = 0, downloadUrl = null), start)
        scheduler.markStarted(TrafficTest.PING, start + 10_000)
        assertNull(scheduler.nextDue(start + 10_999))
        assertEquals(TrafficTest.PING, scheduler.nextDue(start + 11_000))
        assertTrue(scheduler.hasWork)
    }

    @Test
    fun defaultsFollowTheLeadDecision() {
        val defaults = TestSettings()
        assertEquals("8.8.8.8", defaults.pingTarget)
        assertEquals(5, defaults.pingCount)
        assertEquals(60_000, defaults.pingIntervalMs)
        assertEquals("https://speed.cloudflare.com/__down?bytes=10000000", defaults.downloadUrl)
        assertEquals(300_000, defaults.downloadIntervalMs)
        assertEquals(10_000_000, defaults.downloadCapBytes)
        assertEquals(100_000_000, defaults.sessionBudgetBytes)
    }

    @Test
    fun noUploadWithoutUrl() {
        // Upload is off unless asked for: it spends the user's data uplink.
        val scheduler = NetTestScheduler(TestSettings(pingTarget = "", downloadUrl = null), 0)
        assertNull(scheduler.nextDue(NetTestScheduler.FIRST_UPLOAD_DELAY_MS + 10_000))
        assertFalse(scheduler.hasWork)
    }

    @Test
    fun theFirstUploadIsDueAfterTheFirstDownloadThenEveryInterval() {
        val settings = TestSettings(
            pingTarget = "",
            downloadUrl = null,
            uploadUrl = "https://example.test/__up",
            uploadIntervalMs = 120_000,
        )
        val scheduler = NetTestScheduler(settings, 0)

        assertNull(scheduler.nextDue(NetTestScheduler.FIRST_UPLOAD_DELAY_MS - 1))
        assertEquals(TrafficTest.UPLOAD, scheduler.nextDue(NetTestScheduler.FIRST_UPLOAD_DELAY_MS))

        scheduler.markStarted(TrafficTest.UPLOAD, NetTestScheduler.FIRST_UPLOAD_DELAY_MS)
        assertNull(scheduler.nextDue(NetTestScheduler.FIRST_UPLOAD_DELAY_MS + 119_999))
        assertEquals(TrafficTest.UPLOAD, scheduler.nextDue(NetTestScheduler.FIRST_UPLOAD_DELAY_MS + 120_000))
    }

    @Test
    fun uploadAndDownloadSpendOneSharedBudget() {
        val settings = TestSettings(
            pingTarget = "",
            downloadUrl = "https://example.test/__down",
            downloadCapBytes = 10_000_000,
            uploadUrl = "https://example.test/__up",
            uploadCapBytes = 2_000_000,
            sessionBudgetBytes = 11_000_000,
        )
        val scheduler = NetTestScheduler(settings, 0)
        assertEquals(TrafficTest.DOWNLOAD, scheduler.nextDue(NetTestScheduler.FIRST_DOWNLOAD_DELAY_MS))

        // One download leaves 1 MB, which is under the upload's 2 MB cap, so neither may run again.
        scheduler.addBytes(10_000_000)
        assertNull(scheduler.nextDue(NetTestScheduler.FIRST_UPLOAD_DELAY_MS + 600_000))
        assertFalse(scheduler.hasWork)
    }

    @Test
    fun anUploadAloneStillEndsTheBudget() {
        val settings = TestSettings(
            pingTarget = "",
            downloadUrl = null,
            uploadUrl = "https://example.test/__up",
            uploadCapBytes = 2_000_000,
            sessionBudgetBytes = 3_000_000,
        )
        val scheduler = NetTestScheduler(settings, 0)
        assertTrue(scheduler.hasWork)
        scheduler.addBytes(2_000_000)
        assertFalse("1 MB left cannot hold another 2 MB upload", scheduler.hasWork)
    }
}
