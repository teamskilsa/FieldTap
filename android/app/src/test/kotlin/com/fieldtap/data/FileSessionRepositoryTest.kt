package com.fieldtap.data

import com.fieldtap.core.export.ExportException
import com.fieldtap.core.export.SessionExporter
import com.fieldtap.core.session.HeartbeatRecord
import com.fieldtap.core.session.SessionPaths
import com.fieldtap.core.session.SessionRecovery
import com.fieldtap.core.session.SessionStore
import com.fieldtap.core.session.SignalSummary
import com.fieldtap.core.session.StoragePolicy
import com.fieldtap.core.time.ManualClock
import com.fieldtap.format.LocationPrecision
import com.fieldtap.format.ServingRat
import com.fieldtap.format.SessionFile
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FileSessionRepositoryTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var root: File
    private lateinit var exportDir: File
    private lateinit var paths: SessionPaths
    private lateinit var store: SessionStore

    @Before
    fun setUp() {
        assertTrue("golden session missing at ${GOLDEN.absolutePath}", GOLDEN.isDirectory)
        root = temp.newFolder("sessions")
        paths = SessionPaths(root = root, stateDir = temp.newFolder("session-state"))
        store = SessionStore(paths, ManualClock())
        exportDir = File(temp.root, "cache/exports")
    }

    @Test
    fun listIsNewestFirstAndKeepsUnreadableSessionsVisible() {
        copyGolden(GOLDEN_NAME)
        copyGolden(SECOND) { it.replace("\"name\": \"Mall walk (north path)\"", "\"name\": \"Second walk\"") }
        val broken = File(root, BROKEN).apply { mkdirs() }
        File(broken, SessionFile.SESSION_JSON.fileName).writeText("not json")
        File(root, "notes").mkdirs()
        File(root, ".trash").mkdirs()

        val sessions = runBlocking { repository().list() }

        assertEquals(listOf(BROKEN, SECOND, GOLDEN_NAME), sessions.map { it.dirName })
        with(sessions[0]) {
            assertFalse(readable)
            assertNull(name)
            assertEquals(1_789_207_200_000L, startedUtcMs)
            assertFalse(recording)
        }
        assertEquals("Second walk", sessions[1].name)
        with(sessions[2]) {
            assertTrue(readable)
            assertEquals("Mall walk (north path)", name)
            assertEquals(1_789_050_600_000L, startedUtcMs)
            assertEquals(1_789_050_720_000L, stoppedUtcMs)
            assertEquals("user", stoppedBy)
            assertFalse(recording)
            assertEquals("SM-S921U", handsetModel)
            assertEquals(listOf("311480"), plmns)
            assertEquals(54L, freshSamples)
            assertTrue(sizeBytes > 0)
        }
    }

    @Test
    fun recordingIsOnlyTheRunningOpenSession() {
        assertNotEquals("the open-session rewrite must match the golden text", goldenJson(), openJson(goldenJson()))
        copyGolden(OPEN_ACTIVE) { openJson(it) }
        copyGolden(OPEN_OTHER) { openJson(it) }
        copyGolden(GOLDEN_NAME)

        val sessions = runBlocking { repository(active = OPEN_ACTIVE).list() }.associateBy { it.dirName }

        with(sessions.getValue(OPEN_ACTIVE)) {
            assertTrue(recording)
            assertNull(stoppedUtcMs)
            assertEquals("recording", stoppedBy)
        }
        assertFalse("an open session left by a killed process is not recording", sessions.getValue(OPEN_OTHER).recording)
        assertFalse(sessions.getValue(GOLDEN_NAME).recording)
    }

    @Test
    fun detailReportsEveryFileSizeAndItsDataRows() {
        copyGolden(GOLDEN_NAME)

        val detail = runBlocking { repository().detail(GOLDEN_NAME) }

        assertNotNull(detail)
        detail!!
        assertEquals(GOLDEN_NAME, detail.summary.dirName)
        assertEquals("Mall walk (north path)", detail.meta?.name)
        assertEquals(SessionFile.BUNDLE, detail.fileSizes.keys.toList())
        for ((file, size) in detail.fileSizes) {
            assertEquals(file.fileName, File(GOLDEN, file.fileName).length(), size)
        }
        assertEquals(SessionFile.BUNDLE.drop(1), detail.rowCounts.keys.toList())
        for ((file, rows) in detail.rowCounts) {
            assertEquals(file.fileName, dataRows(File(GOLDEN, file.fileName)), rows)
        }
        // kpi.csv holds 100 rows: the golden session's 54 fresh answers give LTE rows plus NSA NR legs.
        assertEquals(100, detail.rowCounts[SessionFile.KPI])
        assertEquals(7, detail.rowCounts[SessionFile.EVENTS])
        assertEquals(2, detail.rowCounts[SessionFile.TRAFFIC])
    }

    @Test
    fun listAndDetailSummariseTheSignalOfEachStoppedSession() {
        copyGolden(GOLDEN_NAME)
        copyGolden(OPEN_ACTIVE) { openJson(it) }
        val repository = repository(active = OPEN_ACTIVE)

        val sessions = runBlocking { repository.list() }.associateBy { it.dirName }

        // The golden kpi.csv: 54 LTE values with median -89 dBm, none below -105 dBm, beside 46 NR leg values.
        val golden = SignalSummary(ServingRat.LTE, samples = 54, medianRsrpDbm = -89, belowFairPct = 0.0)
        // The trace is the chart's own business and is asserted in SignalSummaryTest; here only the
        // figures the list and the detail header show have to match.
        fun figures(summary: SignalSummary?) = summary?.copy(trace = emptyList())
        assertEquals(golden, figures(sessions.getValue(GOLDEN_NAME).signal))
        assertNull("the running session's kpi.csv is still growing", sessions.getValue(OPEN_ACTIVE).signal)
        assertEquals(golden, figures(runBlocking { repository.detail(GOLDEN_NAME) }?.summary?.signal))
        assertEquals(golden, figures(runBlocking { repository.detail(OPEN_ACTIVE) }?.summary?.signal))
        assertTrue(
            "the golden session carries a chart",
            (runBlocking { repository.detail(GOLDEN_NAME) }?.summary?.signal?.trace?.size ?: 0) == 54,
        )
    }

    @Test
    fun theSignalIsReadAgainWhenKpiCsvChanges() {
        val directory = copyGolden(GOLDEN_NAME)
        val repository = repository()
        assertEquals(ServingRat.LTE, runBlocking { repository.list() }.single().signal?.rat)

        val kpi = File(directory, SessionFile.KPI.fileName)
        val lines = kpi.readText(Charsets.UTF_8).split("\r\n").filter { it.isNotEmpty() }
        kpi.writeText((listOf(lines.first()) + lines.drop(1).filter { it.split(',')[2] == "nr" }).joinToString("") { it + "\r\n" })

        val signal = runBlocking { repository.list() }.single().signal
        assertEquals(ServingRat.NR, signal?.rat)
        assertEquals(-96, signal?.medianRsrpDbm)
    }

    @Test
    fun detailSaysHowManyMarkersTheSessionDropped() {
        copyGolden(GOLDEN_NAME)
        assertEquals(0, runBlocking { repository().detail(GOLDEN_NAME) }?.markersDropped)

        paths.markersDropped(GOLDEN_NAME).writeText("2\n")

        assertEquals(2, runBlocking { repository().detail(GOLDEN_NAME) }?.markersDropped)
    }

    @Test
    fun aTornLastRowIsNotCounted() {
        val directory = copyGolden(GOLDEN_NAME)
        File(directory, SessionFile.EVENTS.fileName).appendText("2026-09-10T14:31:50.000+00:00,-,marker,info,Mar")

        val detail = runBlocking { repository().detail(GOLDEN_NAME) }

        assertEquals(7, detail?.rowCounts?.get(SessionFile.EVENTS))
    }

    @Test
    fun detailOfAMissingOrForeignNameIsNull() {
        copyGolden(GOLDEN_NAME)
        val repository = repository()

        assertNull(runBlocking { repository.detail("20260101-000000_missing") })
        assertNull(runBlocking { repository.detail("../sessions") })
        assertNull(runBlocking { repository.detail("notes") })
    }

    @Test
    fun deleteRefusesTheRunningSessionAndForeignNames() {
        val directory = copyGolden(OPEN_ACTIVE) { openJson(it) }

        assertFalse(runBlocking { repository(active = OPEN_ACTIVE).delete(OPEN_ACTIVE) })
        assertTrue(directory.isDirectory)
        assertFalse(runBlocking { repository().delete("../session-state") })
        assertTrue(paths.stateDir.isDirectory)

        assertTrue(runBlocking { repository().delete(OPEN_ACTIVE) })
        assertFalse(directory.exists())
    }

    @Test
    fun anUnreadableSessionCanBeDeletedAndItsExportGoesWithIt() {
        val broken = File(root, BROKEN).apply { mkdirs() }
        File(broken, SessionFile.SESSION_JSON.fileName).writeText("{")
        exportDir.mkdirs()
        val zip = File(exportDir, "$BROKEN.zip").apply { writeText("zip") }

        assertTrue(runBlocking { repository().delete(BROKEN) })

        assertFalse(broken.exists())
        assertFalse(zip.exists())
    }

    @Test
    fun exportBuildsTheZipInTheExportDirectoryAndClearsOlderCopies() {
        copyGolden(GOLDEN_NAME)
        exportDir.mkdirs()
        val oldZip = File(exportDir, "20260101-000000_old.zip").apply { writeText("old") }
        val staleTemp = File(exportDir, "20260101-000000_old.zip.tmp").apply { writeText("partial") }
        // What SessionExporter leaves behind when the process dies mid-export.
        val stalePart = File(exportDir, "20260101-000000_old.8812736450.zip.part").apply { writeText("partial") }
        val probe = File(exportDir, "probe-google-pixel-20260910-120000.json").apply { writeText("{}") }
        val probeInFlight = File(exportDir, "probe-google-pixel-20260910-120500.json.tmp").apply { writeText("{") }

        val result = runBlocking { repository().export(GOLDEN_NAME, LocationPrecision.APPROX_110M) }

        assertEquals(File(exportDir, "$GOLDEN_NAME.zip").canonicalFile, result.zip.canonicalFile)
        assertTrue(result.zip.isFile)
        assertEquals(LocationPrecision.APPROX_110M, result.precision)
        assertEquals(SessionFile.SESSION_JSON.fileName, result.entries.first())
        assertFalse(oldZip.exists())
        assertFalse(staleTemp.exists())
        assertFalse(stalePart.exists())
        assertTrue("probe exports are not session zips", probe.exists())
        assertTrue("a probe report being written is left alone", probeInFlight.exists())
        assertTrue("the local session stays untouched", File(root, GOLDEN_NAME).isDirectory)
    }

    @Test
    fun exportRefusesTheRunningAndOpenSessionsAndForeignNames() {
        copyGolden(OPEN_ACTIVE) { openJson(it) }
        copyGolden(OPEN_OTHER) { openJson(it) }
        val repository = repository(active = OPEN_ACTIVE)

        assertReason(ExportException.Reason.SESSION_OPEN) { repository.export(OPEN_ACTIVE, LocationPrecision.FULL) }
        assertReason(ExportException.Reason.SESSION_OPEN) { repository.export(OPEN_OTHER, LocationPrecision.FULL) }
        assertReason(ExportException.Reason.MISSING_SESSION_JSON) { repository.export("../session-state", LocationPrecision.FULL) }
        assertReason(ExportException.Reason.MISSING_SESSION_JSON) { repository.export("20260101-000000_missing", LocationPrecision.FULL) }
        assertFalse(File(exportDir, "$OPEN_ACTIVE.zip").exists())
    }

    @Test
    fun listingClosesASessionTheAppStoppedButCouldNotFinishWriting() {
        copyGolden(GOLDEN_NAME) { openJson(it) }
        // 14:32:00.000, after the golden session's last row (14:31:59.900): a stop is never before a row it holds.
        val stoppedAt = 1_789_050_720_000L
        paths.heartbeat(GOLDEN_NAME).writeText(HeartbeatRecord(stoppedAt, 25_423_456L, 4242, stoppedBy = "storage_full").encode())
        val recovery = SessionRecovery(store, paths)
        val repository = FileSessionRepository(
            paths,
            store,
            SessionExporter(),
            StoragePolicy(),
            exportDir,
            closeStoppedSessions = { recovery.closeStoppedSessions(activeDirName = null) },
        ) { null }

        val summary = runBlocking { repository.list() }.single()

        assertEquals("storage_full", summary.stoppedBy)
        assertEquals(stoppedAt, summary.stoppedUtcMs)
        assertFalse(summary.recording)
        assertFalse(paths.heartbeat(GOLDEN_NAME).exists())
        assertNotNull("the session can be shared at once", runBlocking { repository.export(GOLDEN_NAME, LocationPrecision.FULL) })
    }

    @Test
    fun storageMeasuresTheSessionsRootAgainstThePolicy() {
        copyGolden(GOLDEN_NAME)

        val status = runBlocking { repository().storage() }

        assertEquals(GOLDEN.listFiles().orEmpty().sumOf { it.length() }, status.usedBytes)
        assertTrue(status.freeBytes > 0)
        assertEquals(StoragePolicy(), status.policy)
    }

    private fun repository(active: String? = null) =
        FileSessionRepository(paths, store, SessionExporter(), StoragePolicy(), exportDir) { active }

    private fun copyGolden(dirName: String, sessionJson: (String) -> String = { it }): File {
        val target = File(root, dirName)
        assertTrue(target.mkdirs())
        for (file in GOLDEN.listFiles().orEmpty()) {
            val copy = File(target, file.name)
            if (file.name == SessionFile.SESSION_JSON.fileName) {
                copy.writeText(sessionJson(file.readText(Charsets.UTF_8)), Charsets.UTF_8)
            } else {
                file.copyTo(copy)
            }
        }
        return target
    }

    private fun goldenJson(): String = File(GOLDEN, SessionFile.SESSION_JSON.fileName).readText(Charsets.UTF_8)

    /** The golden session.json as a session still recording: no stop time, stopped_by `recording`. */
    private fun openJson(json: String): String = json
        .replace("\"stopped_utc\": \"2026-09-10T14:32:00.000+00:00\"", "\"stopped_utc\": null")
        .replace("\"stopped_by\": \"user\"", "\"stopped_by\": \"recording\"")

    /** Records ending in CR LF, minus the header, counted independently of the repository. */
    private fun dataRows(file: File): Int = file.readText(Charsets.UTF_8).split("\r\n").count { it.isNotEmpty() } - 1

    private fun assertReason(expected: ExportException.Reason, block: suspend () -> Unit) {
        val error = runBlocking { runCatching { block() }.exceptionOrNull() }
        assertTrue("expected an ExportException, got $error", error is ExportException)
        assertEquals(expected, (error as ExportException).reason)
    }

    private companion object {
        val GOLDEN = File("../../tests/fixtures/android_session/20260910-143000_Mall-walk-north-path")
        const val GOLDEN_NAME = "20260910-143000_Mall-walk-north-path"
        const val SECOND = "20260911-090000_Second-walk"
        const val BROKEN = "20260912-100000_broken"
        const val OPEN_ACTIVE = "20260913-080000_open-active"
        const val OPEN_OTHER = "20260913-070000_open-other"
    }
}
