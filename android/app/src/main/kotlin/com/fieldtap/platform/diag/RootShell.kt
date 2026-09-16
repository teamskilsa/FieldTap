package com.fieldtap.platform.diag

import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Runs a command and waits for it no longer than it is told to.
 *
 * The runner this replaces read the whole of the process's output first and only then called
 * `waitFor(timeout)`. Reading to the end of the stream blocks until the process exits, so the timeout
 * after it could never fire: a `su` stuck behind a Magisk prompt, or a logger that never returned, hung
 * the capture for good. Here the output is read on its own thread while the caller waits with the clock
 * running, and a process past its time is destroyed.
 *
 * Owner: workstream `diag-on-handset`.
 */
object RootShell {

    data class Outcome(
        val output: String,
        /** False when the program could not be started at all — for `su`, there is no root on the phone. */
        val started: Boolean,
        val timedOut: Boolean,
        val exitCode: Int?,
    )

    fun exec(argv: List<String>, waitMs: Long): Outcome {
        val process = try {
            ProcessBuilder(argv).redirectErrorStream(true).start()
        } catch (e: IOException) {
            return Outcome(output = "", started = false, timedOut = false, exitCode = null)
        }
        val output = StringBuilder()
        val reader = Thread {
            try {
                process.inputStream.bufferedReader().use { input ->
                    val buffer = CharArray(4_096)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        synchronized(output) { output.append(buffer, 0, read) }
                    }
                }
            } catch (e: IOException) {
                // The stream closes when the process is destroyed; what arrived before that stands.
            }
        }.apply {
            isDaemon = true
            start()
        }
        return try {
            val finished = process.waitFor(waitMs, TimeUnit.MILLISECONDS)
            if (!finished) process.destroy()
            // A process that exited may still have output in the pipe; give the reader a moment to drain it.
            reader.join(DRAIN_MS)
            Outcome(
                output = synchronized(output) { output.toString() },
                started = true,
                timedOut = !finished,
                exitCode = if (finished) process.exitValue() else null,
            )
        } catch (e: InterruptedException) {
            process.destroy()
            Thread.currentThread().interrupt()
            Outcome(synchronized(output) { output.toString() }, started = true, timedOut = true, exitCode = null)
        } finally {
            process.destroy()
        }
    }

    /** What asking `su` for root came to. */
    enum class Root {
        GRANTED,

        /** No `su` to run. Magisk is not active — a root started with `fastboot boot` is gone after any restart. */
        NO_SU,

        /** `su` ran and did not give root: refused in Magisk, or not allowed for this app. */
        DENIED,

        /** `su` did not answer in time, usually a Magisk prompt nobody tapped. */
        TIMED_OUT,
    }

    fun root(outcome: Outcome): Root = when {
        !outcome.started -> Root.NO_SU
        outcome.output.contains("uid=0") -> Root.GRANTED
        outcome.timedOut -> Root.TIMED_OUT
        // A shell that exists but has no su prints "not found" and exits 127: the same as no su at all.
        outcome.exitCode == 127 || outcome.output.contains("not found") -> Root.NO_SU
        else -> Root.DENIED
    }

    private const val DRAIN_MS = 500L
}
