package com.fieldtap.platform.diag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Runs real processes on the test machine's own shell; no phone involved. */
class RootShellTest {

    @Test
    fun aHungProcessIsKilledAtTheTimeoutInsteadOfWaitingForIt() {
        // The bug this replaced: reading output to the end blocked until the process exited, so a 90 s
        // timeout never fired and a stuck su hung the capture for good.
        val started = System.nanoTime()
        val outcome = RootShell.exec(listOf("sh", "-c", "echo waiting; sleep 30"), waitMs = 300)
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertTrue("took $elapsedMs ms", elapsedMs < 5_000)
        assertTrue(outcome.timedOut)
        assertTrue("output before the kill is kept", outcome.output.contains("waiting"))
    }

    @Test
    fun aProgramThatDoesNotExistIsNotStarted() {
        val outcome = RootShell.exec(listOf("definitely-no-such-program-fieldtap"), waitMs = 1_000)
        assertFalse(outcome.started)
        assertEquals(RootShell.Root.NO_SU, RootShell.root(outcome))
    }

    @Test
    fun aFinishedProcessKeepsItsOutputAndExitCode() {
        val outcome = RootShell.exec(listOf("sh", "-c", "echo 'uid=0(root) gid=0(root)'; exit 0"), waitMs = 5_000)
        assertFalse(outcome.timedOut)
        assertEquals(0, outcome.exitCode)
        assertEquals(RootShell.Root.GRANTED, RootShell.root(outcome))
    }

    @Test
    fun outputLargerThanAPipeBufferDoesNotDeadlock() {
        // A process that fills its pipe blocks until someone reads; reading only after waitFor would deadlock.
        val outcome = RootShell.exec(listOf("sh", "-c", "head -c 300000 /dev/zero | tr '\\000' 'x'"), waitMs = 5_000)
        assertFalse(outcome.timedOut)
        assertEquals(300_000, outcome.output.length)
    }

    @Test
    fun aShellWithoutSuIsNoSuNotADenial() {
        // What the OnePlus said once Magisk was gone: "/system/bin/sh: su: inaccessible or not found", exit 127.
        val outcome = RootShell.Outcome(output = "/system/bin/sh: su: inaccessible or not found", started = true, timedOut = false, exitCode = 127)
        assertEquals(RootShell.Root.NO_SU, RootShell.root(outcome))
    }

    @Test
    fun suThatRunsAndGivesNoRootIsADenial() {
        val outcome = RootShell.Outcome(output = "Permission denied", started = true, timedOut = false, exitCode = 1)
        assertEquals(RootShell.Root.DENIED, RootShell.root(outcome))
    }

    @Test
    fun suThatNeverAnsweredIsATimeout() {
        val outcome = RootShell.Outcome(output = "", started = true, timedOut = true, exitCode = null)
        assertEquals(RootShell.Root.TIMED_OUT, RootShell.root(outcome))
    }
}
