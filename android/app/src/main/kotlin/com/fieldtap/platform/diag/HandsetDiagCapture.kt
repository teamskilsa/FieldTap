package com.fieldtap.platform.diag

import android.util.Log
import com.fieldtap.diag.LogCodes
import com.fieldtap.diag.LogMask
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible

/** What a capture attempt did, or why it could not. */
sealed interface DiagCaptureResult {
    /** Running, writing into [outputDir] on the handset. */
    data class Started(val outputDir: String) : DiagCaptureResult

    /** Stopped; [qmdl] is the file that was written, or null when the logger produced none. */
    data class Stopped(val qmdl: File?) : DiagCaptureResult

    /** Root was not available; [why] says whether there is no `su`, it refused, or it never answered. */
    data class NoRoot(val why: RootShell.Root) : DiagCaptureResult

    /** `diag_mdlog` is not on this phone: its modem does not use the diag-router path. */
    data object NoLogger : DiagCaptureResult

    data class Failed(val reason: String) : DiagCaptureResult
}

/**
 * Signalling capture on the handset itself, through the phone's own `diag_mdlog`.
 *
 * On a diag-router platform the modem's logs do not come from `/dev/diag` — that node does not exist —
 * they come from `/vendor/bin/diag-router`, which `diag_mdlog` talks to through libdiag. Driving the
 * vendor's own logger is what makes this work on a stock modem: it already knows how to reach the modem
 * peripheral, which FieldTap's USB path does not.
 *
 * Root is required and is asked for through the superuser app already on the phone, the same way the
 * capability probe asks. Nothing is installed and no exploit is run.
 *
 * The mask comes from [LogCodes.signallingCodes] via [LogMask.file], so the handset asks for exactly the
 * records the decoder can read rather than everything the modem can emit — a full-mask capture is tens of
 * megabytes a minute and almost all of it is debug text this app cannot decode.
 *
 * `diag_mdlog` writes as root. The output goes to shared storage rather than the app's own directory
 * because the logger falls back to `/sdcard/diag_logs` when it cannot create what it was given, and a
 * fallback nobody reads is worse than a location chosen on purpose. [collect] copies what it finds into
 * the session and then removes the source, so nothing is left behind.
 *
 * Owner: workstream `diag-on-handset`.
 */
class HandsetDiagCapture(
    private val timeoutMs: Long = 10_000,
    /**
     * The wait for the very first `su`, which is the one that raises the superuser prompt: long enough for
     * a person to notice it, read it and tap Grant.
     */
    private val grantTimeoutMs: Long = 90_000,
) {

    /** Where the logger writes on the handset; readable by the app, removed after [collect]. */
    private val outputDir = "/sdcard/diag_logs"
    private val maskPath = "/data/local/tmp/fieldtap-signalling.cfg"

    /** True when `diag_mdlog` exists on this phone. */
    suspend fun available(): Boolean = runInterruptible(Dispatchers.IO) {
        File(LOGGER).canRead() || run("ls $LOGGER").contains(LOGGER)
    }

    /**
     * Writes the mask and starts the logger. Safe to call when one is already running: the previous
     * instance is stopped first, because two would fight over the same diag session.
     */
    suspend fun start(): DiagCaptureResult = runInterruptible(Dispatchers.IO) {
        val root = RootShell.root(RootShell.exec(listOf("su", "-c", "id"), grantTimeoutMs))
        if (root != RootShell.Root.GRANTED) return@runInterruptible DiagCaptureResult.NoRoot(root)
        if (!File(LOGGER).let { it.exists() || run("ls $LOGGER").contains(LOGGER) }) {
            return@runInterruptible DiagCaptureResult.NoLogger
        }
        run("$LOGGER -k")
        val mask = LogMask.file(LogCodes.signallingCodes(), LogMask.DEFAULT_RANGES)
        val hex = mask.joinToString("") { "%02x".format(it) }
        // Written through the shell so the file lands with root's ownership, where the logger reads it.
        val wrote = run("rm -f $maskPath; printf '%s' $hex | xxd -r -p > $maskPath; ls -l $maskPath")
        if (!wrote.contains(maskPath)) {
            return@runInterruptible DiagCaptureResult.Failed("could not write the log mask")
        }
        run("rm -rf $outputDir")
        run("(nohup $LOGGER -f $maskPath -o $outputDir >/dev/null 2>&1 &)")
        Thread.sleep(SETTLE_MS)
        if (!running()) {
            return@runInterruptible DiagCaptureResult.Failed("the logger did not stay running")
        }
        DiagCaptureResult.Started(outputDir)
    }

    /** True while the handset's logger is recording. */
    suspend fun isRunning(): Boolean = runInterruptible(Dispatchers.IO) { running() }

    /** Stops the logger. Idempotent. */
    suspend fun stop(): DiagCaptureResult = runInterruptible(Dispatchers.IO) {
        run("$LOGGER -k")
        Thread.sleep(SETTLE_MS)
        DiagCaptureResult.Stopped(null)
    }

    /**
     * Copies the largest `.qmdl` the logger wrote into [into], removes the source, and returns the copy.
     *
     * The largest is the main processor's; a second, much smaller one is the remote modem's and holds
     * nothing this app decodes.
     */
    suspend fun collect(into: File): File? = runInterruptible(Dispatchers.IO) {
        val listing = run("ls -S $outputDir/*.qmdl 2>/dev/null").lines()
            .map { it.trim() }
            .filter { it.endsWith(".qmdl") }
        val source = listing.firstOrNull() ?: return@runInterruptible null
        into.parentFile?.mkdirs()
        // cat through the shell: the file is root's, and a copy is cheaper than changing its owner.
        val copied = run("cat ${quote(source)} > ${quote(into.absolutePath)}; ls -l ${quote(into.absolutePath)}")
        run("rm -rf $outputDir")
        if (!into.isFile || into.length() == 0L) {
            Log.w(TAG, "nothing collected: $copied")
            null
        } else {
            into
        }
    }

    private fun running(): Boolean = run("pidof diag_mdlog").trim().isNotEmpty()

    /** One `su -c` command and its combined output, or "" when su is absent or the wait ran out. */
    private fun run(command: String, waitMs: Long = timeoutMs): String =
        RootShell.exec(listOf("su", "-c", command), waitMs).output

    private fun quote(path: String) = "'" + path.replace("'", "'\\''") + "'"

    private companion object {
        const val LOGGER = "/vendor/bin/diag_mdlog"
        const val SETTLE_MS = 1_500L
        const val TAG = "HandsetDiagCapture"
    }
}
