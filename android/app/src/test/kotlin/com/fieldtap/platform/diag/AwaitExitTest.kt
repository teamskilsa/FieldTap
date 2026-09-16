package com.fieldtap.platform.diag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AwaitExitTest {

    private class FakeClock {
        var now = 0L
        val sleeps = mutableListOf<Long>()
        fun sleep(ms: Long) { sleeps += ms; now += ms }
    }

    @Test
    fun itWaitsForTheLoggerToExitRatherThanAFixedTime() {
        // The bench: the logger flushed at ~2.5 s after -k and exited at ~3.5 s. A fixed 1.5 s wait copied the
        // file before the flush; waiting for the exit copies after it.
        val clock = FakeClock()
        val exitsAt = 3_500L
        val stopped = awaitExit({ clock.now < exitsAt }, timeoutMs = 20_000, pollMs = 250, sleep = clock::sleep, nowMs = { clock.now })
        assertTrue(stopped)
        assertTrue("returned only once the process was gone: ${clock.now} ms", clock.now >= exitsAt)
        assertTrue("and not long after", clock.now < exitsAt + 250)
    }

    @Test
    fun anAlreadyStoppedLoggerDoesNotWaitAtAll() {
        val clock = FakeClock()
        assertTrue(awaitExit({ false }, timeoutMs = 20_000, pollMs = 250, sleep = clock::sleep, nowMs = { clock.now }))
        assertEquals(emptyList<Long>(), clock.sleeps)
    }

    @Test
    fun aLoggerThatNeverExitsGivesUpAtTheTimeout() {
        val clock = FakeClock()
        val stopped = awaitExit({ true }, timeoutMs = 20_000, pollMs = 250, sleep = clock::sleep, nowMs = { clock.now })
        assertFalse(stopped)
        assertTrue("gave up at the timeout, not before: ${clock.now}", clock.now in 20_000..20_250)
    }
}
