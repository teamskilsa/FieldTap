package com.fieldtap.core.nettest

import com.fieldtap.format.Csv
import com.fieldtap.format.EventKind
import com.fieldtap.format.EventRat
import com.fieldtap.format.Severity
import com.fieldtap.format.TrafficCsv
import com.fieldtap.format.TrafficTest
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrafficRecordsTest {
    private val UPLOAD_URL = "https://speed.cloudflare.com/__up"
    private val delta = 1e-9

    /** 2026-09-10T14:30:00.000Z, the golden session's start. */
    private val sessionStart = 1_789_050_600_000L

    @Test
    fun goldenPingAndDownloadRowsAreReproducedByteForByte() {
        val golden = File(GOLDEN_DIR, "traffic.csv")
        assertTrue("golden traffic.csv missing at ${golden.absolutePath}", golden.isFile)
        val lines = golden.readText(Charsets.UTF_8).split(Csv.LINE_END).filter { it.isNotEmpty() }

        val ping = TrafficRecords.ping(
            startedWallMs = sessionStart + 30_000,
            target = "8.8.8.8",
            outcome = PingOutcome.Replies(sent = 5, rttsMs = listOf(38.2, 40.0, 44.7, 58.9, 41.7), seconds = 4.13),
        )
        val download = TrafficRecords.download(
            startedWallMs = sessionStart + 36_000,
            url = "https://probe.5gto6g.com/10MB.bin",
            outcome = DownloadOutcome.Completed(bytes = 10_031_250, seconds = 4.0, httpCode = 200, capped = false),
        )

        assertNull(ping.failure)
        assertNull(download.failure)
        assertEquals(lines[1] + Csv.LINE_END, TrafficCsv.encode(ping.row))
        assertEquals(lines[2] + Csv.LINE_END, TrafficCsv.encode(download.row))
    }

    @Test
    fun aPingWithRepliesIsASuccessWithLossAndRtts() {
        val record = TrafficRecords.ping(sessionStart, "8.8.8.8", PingOutcome.Replies(5, listOf(20.0, 30.0, 40.0), 5.2))

        with(record.row) {
            assertEquals(TrafficTest.PING, test)
            assertEquals("8.8.8.8", target)
            assertTrue(ok)
            assertEquals(5.2, seconds, delta)
            assertEquals(40.0, lossPct!!, delta)
            assertEquals(20.0, rttMinMs!!, delta)
            assertEquals(30.0, rttAvgMs!!, delta)
            assertEquals(40.0, rttMaxMs!!, delta)
            assertNull(mbps)
            assertNull(bytes)
            assertNull(httpCode)
            assertNull(error)
        }
        assertNull(record.failure)
    }

    @Test
    fun aPingWithZeroRepliesFailsWithNoReplyAndFullLoss() {
        val started = sessionStart + 10_000
        val record = TrafficRecords.ping(started, "8.8.8.8", PingOutcome.Replies(5, emptyList(), 10.0))

        with(record.row) {
            assertFalse(ok)
            assertEquals("no reply", error)
            assertEquals(100.0, lossPct!!, delta)
            assertNull(rttMinMs)
            assertNull(rttAvgMs)
            assertNull(rttMaxMs)
        }
        assertTestFailed(record, started, "Ping failed", "no reply")
    }

    @Test
    fun noCellularNetworkFailsWithoutMeasuredLoss() {
        val record = TrafficRecords.ping(sessionStart, "8.8.8.8", PingOutcome.Failed(NetFailure.NO_CELLULAR_NETWORK, null, 10.0))

        with(record.row) {
            assertFalse(ok)
            assertEquals("no cellular network", error)
            assertNull(lossPct)
            assertEquals(10.0, seconds, delta)
        }
        assertTestFailed(record, sessionStart, "Ping failed", "no cellular network")
    }

    @Test
    fun aDownloadWithoutCellularNetworkFailsWithTheSameWords() {
        val record = TrafficRecords.download(
            sessionStart, URL, DownloadOutcome.Failed(NetFailure.NO_CELLULAR_NETWORK, null, 10.0, null, null),
        )

        with(record.row) {
            assertEquals(TrafficTest.DOWNLOAD, test)
            assertFalse(ok)
            assertEquals("no cellular network", error)
            assertNull(mbps)
            assertNull(bytes)
            assertNull(httpCode)
        }
        assertTestFailed(record, sessionStart, "Download failed", "no cellular network")
    }

    @Test
    fun anHttpStatusFailureKeepsTheCodeAndNamesIt() {
        val record = TrafficRecords.download(
            sessionStart, URL, DownloadOutcome.Failed(NetFailure.HTTP_STATUS, "404", 0.35, 404, null),
        )

        with(record.row) {
            assertFalse(ok)
            assertEquals("http status not 200: 404", error)
            assertEquals(404, httpCode)
            assertNull(mbps)
        }
        assertTestFailed(record, sessionStart, "Download failed", "http status not 200: 404")
    }

    @Test
    fun aCompletedTransferWithAStatusOtherThan200IsAnHttpFailure() {
        val record = TrafficRecords.download(sessionStart, URL, DownloadOutcome.Completed(512, 1.0, 206, capped = false))

        assertFalse(record.row.ok)
        assertEquals("http status not 200: 206", record.row.error)
        assertEquals(206, record.row.httpCode)
        assertEquals(512L, record.row.bytes)
        assertNull(record.row.mbps)
        assertNotNull(record.failure)
    }

    @Test
    fun anIoFailureKeepsPartialBytesAndACleanOneLineDetail() {
        val record = TrafficRecords.download(
            sessionStart, URL, DownloadOutcome.Failed(NetFailure.IO, "SSLException\r\n  reset", 2.0, 200, 1_234),
        )

        with(record.row) {
            assertFalse(ok)
            assertEquals("network error: SSLException reset", error)
            assertEquals(1_234L, bytes)
            assertEquals(200, httpCode)
            assertNull(mbps)
        }
        assertTestFailed(record, sessionStart, "Download failed", "network error: SSLException reset")
    }

    @Test
    fun aTimeoutIsNamed() {
        val record = TrafficRecords.download(sessionStart, URL, DownloadOutcome.Failed(NetFailure.TIMEOUT, null, 60.0, 200, 0))
        assertEquals("timeout", record.row.error)
    }

    @Test
    fun anEmptyBodyIsNotASuccess() {
        val record = TrafficRecords.download(sessionStart, URL, DownloadOutcome.Completed(0, 0.2, 200, capped = false))
        assertFalse(record.row.ok)
        assertEquals("network error: empty body", record.row.error)
        assertEquals(0L, record.row.bytes)
    }

    @Test
    fun mbpsIsBitsPerSecondInMillionsAndAlwaysFinite() {
        assertEquals(20.0625, TrafficRecords.mbps(10_031_250, 4.0), delta)
        assertTrue(TrafficRecords.mbps(1_000, 0.0).isFinite())
        val instant = TrafficRecords.download(sessionStart, URL, DownloadOutcome.Completed(1_000, 0.0, 200, capped = true))
        assertTrue(instant.row.ok)
        assertTrue(instant.row.mbps!!.isFinite())
        assertEquals(0.0, instant.row.seconds, delta)
    }

    @Test
    fun secondsAreNeverNegativeOrNotANumber() {
        val negative = TrafficRecords.ping(sessionStart, "8.8.8.8", PingOutcome.Failed(NetFailure.IO, null, -3.0))
        val nan = TrafficRecords.ping(sessionStart, "8.8.8.8", PingOutcome.Failed(NetFailure.IO, null, Double.NaN))
        assertEquals(0.0, negative.row.seconds, delta)
        assertEquals(0.0, nan.row.seconds, delta)
    }

    @Test
    fun anHttpCodeOutsideTheSchemaRangeIsBlank() {
        val record = TrafficRecords.download(sessionStart, URL, DownloadOutcome.Failed(NetFailure.IO, null, 1.0, 999, null))
        assertNull(record.row.httpCode)
    }

    @Test
    fun errorTextKeepsTheReasonAndAShortDetail() {
        assertEquals("timeout", TrafficRecords.errorText(NetFailure.TIMEOUT, null))
        assertEquals("timeout", TrafficRecords.errorText(NetFailure.TIMEOUT, "  \n "))
        val long = TrafficRecords.errorText(NetFailure.IO, "x".repeat(500))
        assertEquals("network error: " + "x".repeat(TrafficRecords.MAX_DETAIL_LENGTH), long)
        assertFalse(long.contains('\n'))
    }

    private fun assertTestFailed(record: TrafficRecord, startedWallMs: Long, title: String, detail: String) {
        val event = record.failure
        assertNotNull("a failed test must carry a test_failed event", event)
        event!!
        assertEquals(EventKind.TEST_FAILED, event.kind)
        assertEquals(EventRat.NONE, event.rat)
        assertEquals(Severity.ERROR, event.severity)
        assertEquals(startedWallMs, event.timeUtcMs)
        assertEquals(title, event.title)
        assertEquals(detail, event.detail)
        assertEquals(record.row.error, event.detail)
    }

    private companion object {
        const val URL = "https://speed.cloudflare.com/__down?bytes=10000000"
        const val GOLDEN_DIR = "../../tests/fixtures/android_session/20260910-143000_Mall-walk-north-path"
    }

    @Test
    fun aCompletedUploadReportsMbpsFromTheBytesItSent() {
        val record = TrafficRecords.upload(sessionStart, UPLOAD_URL, UploadOutcome.Completed(2_000_000, 4.0, 200))

        with(record.row) {
            assertTrue(ok)
            assertEquals(TrafficTest.UPLOAD, test)
            assertEquals(UPLOAD_URL, target)
            assertEquals(2_000_000L, bytes)
            assertEquals(200, httpCode)
            // 2 000 000 bytes * 8 / 4 s / 1e6
            assertEquals(4.0, mbps!!, delta)
        }
        assertNull(record.failure)
    }

    @Test
    fun aPostAnsweredWithAnyTwoHundredCountsAsAccepted() {
        // A server may answer a POST with 204 and no body; that is a delivered upload, not a failure.
        for (code in listOf(200, 201, 202, 204)) {
            val record = TrafficRecords.upload(sessionStart, UPLOAD_URL, UploadOutcome.Completed(1_000, 1.0, code))
            assertTrue("http $code", record.row.ok)
            assertEquals(code, record.row.httpCode)
        }
    }

    @Test
    fun aPostAnsweredWithAnythingElseIsAnHttpFailure() {
        val record = TrafficRecords.upload(sessionStart, UPLOAD_URL, UploadOutcome.Completed(1_000, 1.0, 413))

        assertFalse(record.row.ok)
        assertEquals("http status not 200: 413", record.row.error)
        assertEquals(413, record.row.httpCode)
        assertNull(record.row.mbps)
        assertNotNull(record.failure)
    }

    @Test
    fun anUploadTheServerTookWithoutBytesIsAFailureNotAZeroRate() {
        val record = TrafficRecords.upload(sessionStart, UPLOAD_URL, UploadOutcome.Completed(0, 1.0, 200))

        assertFalse(record.row.ok)
        assertEquals("network error: nothing sent", record.row.error)
        assertEquals(0L, record.row.bytes)
        assertNull("no rate is claimed for nothing", record.row.mbps)
    }

    @Test
    fun aFailedUploadKeepsTheBytesItManagedToSend() {
        val record = TrafficRecords.upload(
            sessionStart, UPLOAD_URL, UploadOutcome.Failed(NetFailure.TIMEOUT, null, 60.0, null, 512_000),
        )

        with(record.row) {
            assertFalse(ok)
            assertEquals("timeout", error)
            assertEquals(512_000L, bytes)
            assertNull(httpCode)
            assertNull(mbps)
        }
        assertNotNull(record.failure)
        assertEquals(EventKind.TEST_FAILED, record.failure!!.kind)
    }
}
