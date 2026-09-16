package com.fieldtap.data

import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** One saved signalling capture, as the list shows it. */
data class SavedCapture(
    /** The directory name, which is also its time: `20260915-084412`. */
    val name: String,
    val startedUtcMs: Long,
    val bytes: Long,
    /** Log records read when it was saved. */
    val records: Int,
    /** NAS messages found. */
    val messages: Int,
    /** How many of those were the network refusing something. */
    val rejects: Int,
) {
    val hasSignalling: Boolean get() = messages > 0
}

/**
 * Signalling captures kept on the phone, so one can be opened again instead of being read once and lost.
 *
 * A capture is a directory under `filesDir/signalling/`, named for the time it started, holding the raw
 * `capture.qmdl` and a small `summary.txt`. The summary exists so the list can be drawn without decoding
 * every capture — a 7 MB file takes a moment to walk, and a list of ten should not take ten moments.
 *
 * The `.qmdl` stays the source of truth: opening a capture decodes it again rather than reading a stored
 * copy of the flow. A decode that drifts from the file it claims to describe is worse than a slow screen,
 * and it is the file, not the summary, that goes to Wireshark.
 *
 * Captures are not part of `fieldtap-session/1`. They hold layer-3 signalling, which a session promises
 * not to contain, so they live in their own directory and are shared one at a time.
 *
 * Owner: workstream `diag-on-handset`.
 */
class CaptureStore(private val root: File) {

    /** Newest first. A directory without a readable capture is left out rather than shown as empty. */
    fun list(): List<SavedCapture> {
        val dirs = root.listFiles { f: File -> f.isDirectory } ?: return emptyList()
        return dirs.mapNotNull { read(it) }.sortedByDescending { it.startedUtcMs }
    }

    /** The saved capture called [name], or null when it is gone or unreadable. */
    fun find(name: String): SavedCapture? = read(File(root, name))

    /** The raw capture file of [name], or null when it is missing. */
    fun qmdl(name: String): File? = File(root, name).let { dir ->
        File(dir, QMDL).takeIf { it.isFile && it.length() > 0 }
    }

    /**
     * Moves [source] into a new capture directory stamped [startedUtcMs] and records its counts.
     *
     * The file is moved rather than copied when it can be: a capture is megabytes, and the source is a
     * scratch file nobody else needs. A rename across filesystems fails, so a copy is the fallback.
     */
    fun save(source: File, startedUtcMs: Long, records: Int, messages: Int, rejects: Int): SavedCapture? {
        if (!source.isFile || source.length() == 0L) return null
        val name = stamp(startedUtcMs)
        val dir = File(root, name)
        if (!dir.mkdirs() && !dir.isDirectory) return null
        val target = File(dir, QMDL)
        try {
            if (!source.renameTo(target)) {
                source.copyTo(target, overwrite = true)
                source.delete()
            }
            File(dir, SUMMARY).writeText(
                listOf(
                    "$KEY_STARTED=$startedUtcMs",
                    "$KEY_RECORDS=$records",
                    "$KEY_MESSAGES=$messages",
                    "$KEY_REJECTS=$rejects",
                ).joinToString("\n") + "\n",
                Charsets.UTF_8,
            )
        } catch (e: IOException) {
            return null
        } catch (e: SecurityException) {
            return null
        }
        return read(dir)
    }

    /** Removes [name] and everything in it. True when it is gone afterwards. */
    fun delete(name: String): Boolean {
        val dir = File(root, name)
        if (!dir.exists()) return true
        return try {
            dir.deleteRecursively()
        } catch (e: SecurityException) {
            false
        }
    }

    private fun read(dir: File): SavedCapture? {
        val qmdl = File(dir, QMDL)
        if (!qmdl.isFile || qmdl.length() == 0L) return null
        val fields = try {
            File(dir, SUMMARY).takeIf { it.isFile }?.readLines(Charsets.UTF_8)
                ?.mapNotNull { line ->
                    val at = line.indexOf('=')
                    if (at <= 0) null else line.substring(0, at) to line.substring(at + 1)
                }?.toMap().orEmpty()
        } catch (e: IOException) {
            emptyMap()
        }
        // A capture whose summary is gone is still a capture: its file is what matters, and the counts
        // are recomputed the moment it is opened.
        return SavedCapture(
            name = dir.name,
            startedUtcMs = fields[KEY_STARTED]?.toLongOrNull() ?: qmdl.lastModified(),
            bytes = qmdl.length(),
            records = fields[KEY_RECORDS]?.toIntOrNull() ?: 0,
            messages = fields[KEY_MESSAGES]?.toIntOrNull() ?: 0,
            rejects = fields[KEY_REJECTS]?.toIntOrNull() ?: 0,
        )
    }

    private fun stamp(utcMs: Long): String {
        val format = SimpleDateFormat(STAMP, Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val base = format.format(Date(utcMs))
        // Two captures in the same second would collide; the second gets a suffix rather than the first
        // being overwritten.
        if (!File(root, base).exists()) return base
        var n = 2
        while (File(root, "$base-$n").exists() && n < MAX_COLLISIONS) n++
        return "$base-$n"
    }

    companion object {
        const val QMDL: String = "capture.qmdl"
        const val SUMMARY: String = "summary.txt"
        private const val STAMP = "yyyyMMdd-HHmmss"
        private const val KEY_STARTED = "started_utc_ms"
        private const val KEY_RECORDS = "records"
        private const val KEY_MESSAGES = "messages"
        private const val KEY_REJECTS = "rejects"
        private const val MAX_COLLISIONS = 100
    }
}
