package com.fieldtap.ui.common

import com.fieldtap.core.session.ExitReasons
import com.fieldtap.ui.components.SessionRowStatus
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class StopReasonsTest {

    @Test
    fun describesEveryKindOfEnd() {
        assertEquals(StopDescription(StopKind.RECORDING, "recording"), StopReasons.describe("recording", recording = true))
        assertEquals(StopKind.RECORDING, StopReasons.describe("low_memory", recording = true).kind)
        assertEquals(StopDescription(StopKind.NOT_CLOSED, null), StopReasons.describe(null))
        assertEquals(StopKind.NOT_CLOSED, StopReasons.describe(ExitReasons.RECORDING).kind)
        assertEquals(StopDescription(StopKind.USER, "user"), StopReasons.describe("user"))
        for (token in listOf("storage_full", "permission_revoked", "service_destroyed")) {
            assertEquals(StopDescription(StopKind.APP_STOP, token), StopReasons.describe(token))
        }
        assertEquals(StopDescription(StopKind.ANDROID_EXIT, "low_memory"), StopReasons.describe("low_memory"))
        assertEquals(StopKind.ANDROID_EXIT, StopReasons.describe("crash").kind)
        assertEquals("a token from a newer app version is still shown", StopKind.ANDROID_EXIT, StopReasons.describe("brand_new_token").kind)
    }

    @Test
    fun rowStatusPutsRecordingAndUnreadableFirst() {
        assertEquals(SessionRowStatus.RECORDING, StopReasons.rowStatus(TestData.summary(recording = true, stoppedBy = "recording", stoppedUtcMs = null)))
        assertEquals(SessionRowStatus.UNREADABLE, StopReasons.rowStatus(TestData.summary(readable = false, stoppedBy = null)))
        assertEquals(SessionRowStatus.COMPLETED, StopReasons.rowStatus(TestData.summary(stoppedBy = "user")))
        assertEquals(SessionRowStatus.COMPLETED, StopReasons.rowStatus(TestData.summary(stoppedBy = "storage_full")))
        assertEquals(SessionRowStatus.INTERRUPTED, StopReasons.rowStatus(TestData.summary(stoppedBy = "freezer")))
        assertEquals(SessionRowStatus.INTERRUPTED, StopReasons.rowStatus(TestData.summary(stoppedBy = "recording", stoppedUtcMs = null)))
    }

    @Test
    fun durationNeedsBothTimesInOrder() {
        assertEquals(754_000L, StopReasons.durationMs(1_000, 755_000))
        assertEquals(0L, StopReasons.durationMs(1_000, 1_000))
        assertNull(StopReasons.durationMs(null, 755_000))
        assertNull(StopReasons.durationMs(1_000, null))
        assertNull(StopReasons.durationMs(755_000, 1_000))
    }

    @Test
    fun everyAndroidExitReasonHasWords() {
        for (reason in 0..16) {
            val token = ExitReasons.token(reason)
            assertNotNull("no words for $token", exitReasonRes(token))
        }
        assertNotNull(exitReasonRes(ExitReasons.token(99)))
        assertNull(exitReasonRes("storage_full"))
        assertNull(exitReasonRes("made_up"))
    }
}

class DisplayTimeTest {
    private val started = 1_789_050_600_000L // 2026-09-10T14:30:00Z

    @Test
    fun timesAreShownInTheGivenZone() {
        assertEquals("14:30", DisplayTime.time(started, ZoneOffset.UTC, Locale.UK))
        assertEquals("14:30:00", DisplayTime.timeWithSeconds(started, ZoneOffset.UTC, Locale.UK))
        assertEquals("14:30:00.042", DisplayTime.timeWithMillis(started + 42, ZoneOffset.UTC, Locale.UK))
        assertEquals("2:30:00.042\u202FPM", DisplayTime.timeWithMillis(started + 42, ZoneOffset.UTC, Locale.US).replace(' ', '\u202F'))
        assertEquals("20:00", DisplayTime.time(started, ZoneId.of("Asia/Kolkata"), Locale.UK))
        val utc = DisplayTime.dateTime(started, ZoneOffset.UTC, Locale.UK)
        val kolkata = DisplayTime.dateTime(started, ZoneId.of("Asia/Kolkata"), Locale.UK)
        assertNotEquals(utc, kolkata)
        assert(utc.contains("2026") && utc.contains("14:30")) { utc }
    }

    @Test
    fun secondsAndPercentHaveOneDecimal() {
        assertEquals("2.0", DisplayTime.seconds(2_000, Locale.US))
        assertEquals("14.1", DisplayTime.seconds(14_050, Locale.US))
        assertEquals("2,0", DisplayTime.seconds(2_000, Locale.GERMANY))
        assertEquals("88.3", DisplayTime.percent(88.25, Locale.US))
        assertNull(DisplayTime.percent(null, Locale.US))
        assertNull(DisplayTime.percent(Double.NaN, Locale.US))
    }
}
