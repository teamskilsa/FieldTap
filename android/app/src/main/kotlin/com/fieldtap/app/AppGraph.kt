package com.fieldtap.app

import com.fieldtap.core.export.ExportResult
import com.fieldtap.core.live.LiveState
import com.fieldtap.core.probe.ProbeReport
import com.fieldtap.core.readiness.ReadinessReport
import com.fieldtap.core.session.RecorderSnapshot
import com.fieldtap.core.session.SessionOutcome
import com.fieldtap.core.session.SignalSummary
import com.fieldtap.core.session.StartRefusal
import com.fieldtap.core.session.StartRequest
import com.fieldtap.core.session.StorageStatus
import com.fieldtap.core.settings.AppSettings
import com.fieldtap.core.soak.SoakEvaluator
import com.fieldtap.core.soak.SoakResult
import com.fieldtap.core.time.Clock
import com.fieldtap.format.LocationPrecision
import com.fieldtap.format.SessionFile
import com.fieldtap.format.SessionMeta
import com.fieldtap.platform.capability.CapabilityInspector
import java.io.File
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/*
 * The facades the screens and the debug hook use. Frozen shapes: the UI workstreams code against
 * them while service-and-tests and platform-adapters implement them. No Android type appears here,
 * so view models can be unit-tested with fakes on a JVM.
 *
 * Owner: workstream `service-and-tests` (implementations: DefaultAppGraph and the classes it builds).
 */

/** The process-wide dependency graph. Get it with `Context.appGraph`. */
interface AppGraph {
    val clock: Clock
    val appInfo: AppInfo
    val settings: SettingsRepository
    val sessions: SessionRepository
    val sessionControl: SessionControl
    val live: LiveFeed
    val readiness: ReadinessChecker
    val probe: CapabilityProbe
    val capability: CapabilityInspector
    val soak: SoakControl
    val recovery: RecoveryNotices
}

/** From PackageManager, read by com.fieldtap.platform.AppInfoReader. */
data class AppInfo(
    val versionName: String,
    val versionCode: Long,
    val applicationId: String,
    /** `ApplicationInfo.FLAG_DEBUGGABLE`. */
    val debuggable: Boolean,
)

sealed interface SessionStatus {
    data object Idle : SessionStatus

    data class Starting(val request: StartRequest) : SessionStatus

    data class Recording(val snapshot: RecorderSnapshot) : SessionStatus

    data class Stopping(val snapshot: RecorderSnapshot) : SessionStatus
}

sealed interface StartResult {
    data object Accepted : StartResult

    data class Refused(val refusal: StartRefusal) : StartResult
}

/**
 * Start, mark and stop the one session.
 *
 * - [start] must be called while an activity of the app is visible: it checks preconditions with
 *   `SessionStateMachine`, then starts `SessionService` in the foreground. [status] then moves
 *   Starting -> Recording. Refusals come back as [StartResult.Refused] and nothing starts.
 * - [mark] returns false (and writes nothing) when not recording or while paused in a privacy zone.
 * - [stop] is idempotent; [status] moves Stopping -> Idle and [lastOutcome] is set.
 */
interface SessionControl {
    val status: StateFlow<SessionStatus>
    val lastOutcome: StateFlow<SessionOutcome?>

    suspend fun start(request: StartRequest): StartResult

    fun mark(note: String?): Boolean

    fun stop()
}

/** A row of the Sessions list. */
data class SessionSummary(
    val dirName: String,
    val name: String?,
    val startedUtcMs: Long?,
    val stoppedUtcMs: Long?,
    val stoppedBy: String?,
    /** `stopped_utc` is null and it is the running session. */
    val recording: Boolean,
    /** session.json decoded. */
    val readable: Boolean,
    val handsetModel: String?,
    val plmns: List<String>,
    val freshSamples: Long?,
    val sizeBytes: Long,
    /**
     * The median RSRP of kpi.csv and its share below -105 dBm, of one RAT; null when kpi.csv holds no RSRP value. The
     * Sessions list leaves it null for the running session, whose kpi.csv is still growing.
     */
    val signal: SignalSummary? = null,
)

data class SessionDetail(
    val summary: SessionSummary,
    val meta: SessionMeta?,
    val fileSizes: Map<SessionFile, Long>,
    /** Data rows per CSV (header excluded). */
    val rowCounts: Map<SessionFile, Int>,
    /** Markers the session accepted and then dropped, because no location fix showed they were tapped outside its privacy zones. */
    val markersDropped: Int = 0,
)

/**
 * The sessions on this phone. All calls do their IO off the main thread.
 * [export] builds `<cacheDir>/exports/<dirName>.zip` with the chosen precision (and throws
 * `ExportException`); [delete] refuses the running session.
 */
interface SessionRepository {
    suspend fun list(): List<SessionSummary>

    suspend fun detail(dirName: String): SessionDetail?

    suspend fun delete(dirName: String): Boolean

    /**
     * The session as a KML map at [precision], written beside the export zip; null when there is nothing to
     * put on a map (precision "none", or no located sample and no track).
     */
    suspend fun exportMap(dirName: String, precision: LocationPrecision, name: String): java.io.File? = null

    suspend fun export(dirName: String, precision: LocationPrecision): ExportResult

    suspend fun storage(): StorageStatus
}

/** Settings, persisted. [settings] emits the current value first. */
interface SettingsRepository {
    val settings: Flow<AppSettings>

    suspend fun current(): AppSettings

    suspend fun update(transform: (AppSettings) -> AppSettings): AppSettings
}

interface ReadinessChecker {
    /** Runs every check now and records `readinessLastRunUtcMs`. */
    suspend fun check(): ReadinessReport
}

interface CapabilityProbe {
    /** Exercises each API for [durationMs] while the Probe screen is visible. */
    suspend fun run(durationMs: Long = 30_000, onProgress: (String) -> Unit = {}): ProbeReport

    /** Writes `<cacheDir>/exports/probe-<manufacturer>-<model>-<yyyyMMdd-HHmmss>.json` and returns it. */
    suspend fun export(report: ProbeReport): File
}

/** The Live screen's state. Collecting [state] starts the radio and location sources; they stop 5 s after the last collector leaves, unless a session runs. */
interface LiveFeed {
    val state: StateFlow<LiveState>
}

sealed interface SoakState {
    data object Idle : SoakState

    data class Running(val elapsedMs: Long, val durationMs: Long) : SoakState

    data class Done(val result: SoakResult) : SoakState
}

/** The readiness soak test. [start] must be called while an activity is visible; refused while a session runs. */
interface SoakControl {
    val state: StateFlow<SoakState>

    fun start(durationMs: Long = SoakEvaluator.DEFAULT_DURATION_MS)

    fun cancel()
}

/** Sessions closed by launch recovery, until the user has seen them. */
interface RecoveryNotices {
    val closed: StateFlow<List<SessionOutcome>>

    fun acknowledge(dirName: String)
}
