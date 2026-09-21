package com.fieldtap.data

import com.fieldtap.app.SessionDetail
import com.fieldtap.app.SessionRepository
import com.fieldtap.app.SessionSummary
import com.fieldtap.core.export.ExportException
import com.fieldtap.core.export.ExportResult
import com.fieldtap.core.export.SessionExporter
import com.fieldtap.core.session.SessionListing
import com.fieldtap.core.session.SessionPaths
import com.fieldtap.core.session.SessionStore
import com.fieldtap.core.session.SignalSummaries
import com.fieldtap.core.session.SignalSummary
import com.fieldtap.core.session.StoragePolicy
import com.fieldtap.core.session.StorageStatus
import com.fieldtap.core.session.StorageUsage
import com.fieldtap.format.LocationPrecision
import com.fieldtap.format.SessionDirName
import com.fieldtap.format.SessionFile
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * [SessionRepository] over the session directories, on `Dispatchers.IO`.
 *
 * - [list]: every session directory, newest first, including unreadable ones (`readable` false) so they can
 *   be deleted; `recording` only for the running session.
 * - [detail]: the summary, the decoded session.json, the size of each of the seven files present, the
 *   data rows of each CSV (records ending in a line feed, header excluded; a torn last row is not counted), and the
 *   markers the session dropped, from its note beside the heartbeat ([SessionStore.markersDropped]).
 * - [delete]: refuses the running session and any name that is not a session directory name; also removes
 *   that session's export zip.
 * - [export] deletes older zips (and stale temporary files) in [exportDir] first, so shared copies do not
 *   pile up, then builds `<exportDir>/<dirName>.zip`. It refuses the running session and a name that is not a
 *   session directory name, and turns IO failures into [ExportException] with reason IO. One export at a time.
 * - [storage]: bytes used under the sessions root and free space, against [storagePolicy].
 * - [list], [detail] and [export] first call [closeStoppedSessions], which closes sessions the app stopped but could
 *   not finish writing (a full disk, say), so they do not wait for the next launch to become shareable. A failure
 *   there is ignored: the session stays open and the next call tries again.
 * - `SessionSummary.signal` ([SignalSummaries.read] of kpi.csv) is kept in memory per session while kpi.csv keeps its
 *   size and modification time, so a refresh reads only the sessions that changed. [list] leaves it null for the
 *   running session; [detail] reads it for every session.
 *
 * Names always pass `SessionDirName.PATTERN` before they touch the file system, so a route argument can never
 * reach outside the sessions root.
 *
 * Owner: workstream `service-and-tests`.
 */
class FileSessionRepository(
    private val paths: SessionPaths,
    private val store: SessionStore,
    private val exporter: SessionExporter,
    private val storagePolicy: StoragePolicy,
    private val exportDir: File,
    private val closeStoppedSessions: () -> Unit = {},
    private val activeDirName: () -> String?,
) : SessionRepository {
    private val exportLock = Mutex()
    private val signalCache = ConcurrentHashMap<String, CachedSignal>()

    override suspend fun list(): List<SessionSummary> = withContext(Dispatchers.IO) {
        closeStoppedQuietly()
        val active = activeDirName()
        val listings = store.list().sortedByDescending { it.dirName }
        signalCache.keys.retainAll(listings.map { it.dirName }.toSet())
        listings.map { listing ->
            val summary = summaryOf(listing, active)
            if (summary.recording) summary else summary.copy(signal = signalOf(listing))
        }
    }

    override suspend fun detail(dirName: String): SessionDetail? = withContext(Dispatchers.IO) {
        if (!isSessionName(dirName)) return@withContext null
        closeStoppedQuietly()
        val listing = store.read(dirName) ?: return@withContext null
        val sizes = LinkedHashMap<SessionFile, Long>()
        val rows = LinkedHashMap<SessionFile, Int>()
        for (file in SessionFile.BUNDLE) {
            val onDisk = File(listing.directory, file.fileName)
            if (!onDisk.isFile) continue
            sizes[file] = onDisk.length()
            if (file != SessionFile.SESSION_JSON) rows[file] = dataRows(onDisk)
        }
        SessionDetail(
            summary = summaryOf(listing, activeDirName()).copy(signal = signalOf(listing)),
            meta = listing.meta,
            fileSizes = sizes,
            rowCounts = rows,
            markersDropped = store.markersDropped(dirName),
        )
    }

    override suspend fun delete(dirName: String): Boolean = withContext(Dispatchers.IO) {
        if (!isSessionName(dirName)) return@withContext false
        val deleted = store.delete(dirName, activeDirName())
        if (deleted) {
            File(exportDir, zipName(dirName)).delete()
            signalCache.remove(dirName)
        }
        deleted
    }

    override suspend fun export(dirName: String, precision: LocationPrecision): ExportResult =
        withContext(Dispatchers.IO) {
            exportLock.withLock {
                if (!isSessionName(dirName)) {
                    throw ExportException(ExportException.Reason.MISSING_SESSION_JSON, "Not a session directory name")
                }
                if (dirName == activeDirName()) {
                    throw ExportException(ExportException.Reason.SESSION_OPEN, "The session is still recording")
                }
                closeStoppedQuietly()
                val directory = paths.directory(dirName)
                if (!File(directory, SessionFile.SESSION_JSON.fileName).isFile) {
                    throw ExportException(ExportException.Reason.MISSING_SESSION_JSON, "The session has no session.json")
                }
                try {
                    if (!exportDir.isDirectory && !exportDir.mkdirs()) {
                        throw IOException("Could not create the export directory")
                    }
                    deleteOlderExports(keep = zipName(dirName))
                    exporter.export(directory, precision, exportDir)
                } catch (e: IOException) {
                    throw ExportException(ExportException.Reason.IO, "Could not build the export zip", e)
                } catch (e: SecurityException) {
                    throw ExportException(ExportException.Reason.IO, "Could not build the export zip", e)
                }
            }
        }

    override suspend fun exportMap(dirName: String, precision: LocationPrecision, name: String): File? =
        withContext(Dispatchers.IO) {
            exportLock.withLock {
                if (!isSessionName(dirName) || dirName == activeDirName()) return@withLock null
                val kml = com.fieldtap.core.export.SessionKml.build(paths.directory(dirName), name, precision)
                    ?: return@withLock null
                if (!exportDir.isDirectory && !exportDir.mkdirs()) return@withLock null
                exportDir.listFiles()?.filter { it.isFile && it.name.endsWith(KML_SUFFIX) }?.forEach { it.delete() }
                File(exportDir, dirName + KML_SUFFIX).apply { writeText(kml, Charsets.UTF_8) }
            }
        }

    override suspend fun storage(): StorageStatus = withContext(Dispatchers.IO) {
        StorageStatus(
            usedBytes = StorageUsage.usedBytes(paths.root),
            freeBytes = StorageUsage.freeBytes(paths.root),
            policy = storagePolicy,
        )
    }

    private fun closeStoppedQuietly() {
        try {
            closeStoppedSessions()
        } catch (e: IOException) {
            // It stays open; the next listing tries again.
        } catch (e: RuntimeException) {
            // As above: listing sessions must never fail because one could not be closed.
        }
    }

    /** kpi.csv's signal summary, read again only when the file's size or modification time changed since the last read. */
    private fun signalOf(listing: SessionListing): SignalSummary? {
        val kpi = File(listing.directory, SessionFile.KPI.fileName)
        val bytes = kpi.length()
        val modifiedMs = kpi.lastModified()
        signalCache[listing.dirName]?.let { cached ->
            if (cached.bytes == bytes && cached.modifiedMs == modifiedMs) return cached.signal
        }
        val signal = SignalSummaries.read(kpi)
        signalCache[listing.dirName] = CachedSignal(bytes, modifiedMs, signal)
        return signal
    }

    private data class CachedSignal(val bytes: Long, val modifiedMs: Long, val signal: SignalSummary?)

    private fun summaryOf(listing: SessionListing, active: String?): SessionSummary {
        val meta = listing.meta
        return SessionSummary(
            dirName = listing.dirName,
            name = meta?.name,
            startedUtcMs = meta?.startedUtcMs ?: SessionDirName.startedSecondMs(listing.dirName),
            stoppedUtcMs = meta?.stoppedUtcMs,
            stoppedBy = meta?.summary?.stoppedBy,
            recording = listing.dirName == active && meta?.stoppedUtcMs == null,
            readable = meta != null,
            handsetModel = meta?.handset?.model,
            plmns = meta?.summary?.plmns?.keys?.toList().orEmpty(),
            freshSamples = meta?.collection?.freshSamples,
            sizeBytes = listing.sizeBytes,
        )
    }

    private fun deleteOlderExports(keep: String) {
        val files = exportDir.listFiles() ?: return
        for (file in files) {
            if (!file.isFile || file.name == keep) continue
            // Older zips, and the temporary files of an export that died with the process. The export lock
            // guarantees no export is writing now; a probe report and its temporary file are never touched.
            val exportFile = file.name.endsWith(ZIP_SUFFIX) || file.name.endsWith(PART_SUFFIX) ||
                file.name.endsWith(TMP_SUFFIX) || file.name.endsWith(KML_SUFFIX)
            if (exportFile) file.delete()
        }
    }

    private companion object {
        const val ZIP_SUFFIX = ".zip"
        const val KML_SUFFIX = ".kml"
        /** `SessionExporter` writes `<dirName>.<random>.zip.part` and renames it when the zip is complete. */
        const val PART_SUFFIX = ".zip.part"

        /** A zip's temporary name from before `SessionExporter` used [PART_SUFFIX]. */
        const val TMP_SUFFIX = ".zip.tmp"
        const val LINE_FEED: Byte = 0x0A

        fun isSessionName(dirName: String): Boolean = SessionDirName.PATTERN.matches(dirName)

        fun zipName(dirName: String): String = dirName + ZIP_SUFFIX

        /** Records that end in a line feed, minus the header; 0 when the file cannot be read. */
        fun dataRows(file: File): Int {
            var lineEnds = 0L
            try {
                file.inputStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        for (i in 0 until read) {
                            if (buffer[i] == LINE_FEED) lineEnds++
                        }
                    }
                }
            } catch (e: IOException) {
                return 0
            }
            return (lineEnds - 1).coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
        }
    }
}
