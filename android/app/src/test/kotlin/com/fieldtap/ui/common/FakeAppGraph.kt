package com.fieldtap.ui.common

import com.fieldtap.app.AppGraph
import com.fieldtap.app.AppInfo
import com.fieldtap.app.CapabilityProbe
import com.fieldtap.app.LiveFeed
import com.fieldtap.app.ReadinessChecker
import com.fieldtap.app.RecoveryNotices
import com.fieldtap.app.SessionControl
import com.fieldtap.app.SessionDetail
import com.fieldtap.app.SessionRepository
import com.fieldtap.app.SessionStatus
import com.fieldtap.app.SessionSummary
import com.fieldtap.app.SettingsRepository
import com.fieldtap.app.SoakControl
import com.fieldtap.app.SoakState
import com.fieldtap.app.StartResult
import com.fieldtap.core.capability.CapabilitySnapshot
import com.fieldtap.core.capability.RootProbeResult
import com.fieldtap.core.export.ExportResult
import com.fieldtap.core.live.LiveState
import com.fieldtap.core.privacy.Consent
import com.fieldtap.core.probe.ProbeReport
import com.fieldtap.platform.capability.CapabilityInspector
import com.fieldtap.core.readiness.ReadinessCheck
import com.fieldtap.core.readiness.ReadinessItem
import com.fieldtap.core.readiness.ReadinessLevel
import com.fieldtap.core.readiness.ReadinessReport
import com.fieldtap.core.readiness.SettingsTarget
import com.fieldtap.core.session.RecorderSnapshot
import com.fieldtap.core.session.SessionOutcome
import com.fieldtap.core.session.StartRequest
import com.fieldtap.core.session.StoragePolicy
import com.fieldtap.core.session.StorageStatus
import com.fieldtap.core.settings.AppSettings
import com.fieldtap.core.time.ManualClock
import com.fieldtap.format.LocationPrecision
import com.fieldtap.format.ServingRat
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.TestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.Dispatchers
import org.junit.rules.TestWatcher
import org.junit.runner.Description

/** An [AppGraph] of fakes for the session screens' view model tests. Every fake records what it was asked. */
class FakeAppGraph(
    override val clock: ManualClock = ManualClock(),
    override val appInfo: AppInfo = AppInfo(versionName = "0.1.0", versionCode = 1, applicationId = "com.fieldtap", debuggable = true),
    override val settings: FakeSettingsRepository = FakeSettingsRepository(),
    override val sessions: FakeSessionRepository = FakeSessionRepository(),
    override val sessionControl: FakeSessionControl = FakeSessionControl(),
    override val live: FakeLiveFeed = FakeLiveFeed(),
    override val readiness: FakeReadinessChecker = FakeReadinessChecker(),
    override val probe: CapabilityProbe = UnusedProbe,
    override val capability: CapabilityInspector = UnusedCapability,
    override val soak: SoakControl = IdleSoak,
    override val recovery: FakeRecoveryNotices = FakeRecoveryNotices(),
) : AppGraph

class FakeSettingsRepository(initial: AppSettings = TestData.settings()) : SettingsRepository {
    val stored = MutableStateFlow(initial)
    var currentFailure: Exception? = null
    var flowFailure: Exception? = null

    override val settings: Flow<AppSettings>
        get() {
            val failure = flowFailure ?: return stored
            return flow { throw failure }
        }

    override suspend fun current(): AppSettings {
        currentFailure?.let { throw it }
        return stored.value
    }

    override suspend fun update(transform: (AppSettings) -> AppSettings): AppSettings {
        val next = transform(stored.value)
        stored.value = next
        return next
    }
}

class FakeSessionControl : SessionControl {
    override val status = MutableStateFlow<SessionStatus>(SessionStatus.Idle)
    override val lastOutcome = MutableStateFlow<SessionOutcome?>(null)
    var startResult: StartResult = StartResult.Accepted
    var startFailure: Exception? = null
    var markResult: Boolean = true
    val startRequests = mutableListOf<StartRequest>()
    val marks = mutableListOf<String?>()
    var stops = 0

    override suspend fun start(request: StartRequest): StartResult {
        startRequests += request
        startFailure?.let { throw it }
        val result = startResult
        if (result == StartResult.Accepted) status.value = SessionStatus.Starting(request)
        return result
    }

    override fun mark(note: String?): Boolean {
        marks += note
        return markResult
    }

    override fun stop() {
        stops += 1
    }
}

class FakeSessionRepository : SessionRepository {
    var summaries: List<SessionSummary> = emptyList()
    var details: Map<String, SessionDetail> = emptyMap()
    var storageStatus: StorageStatus = StorageStatus(usedBytes = 1_000_000, freeBytes = 50_000_000_000, policy = StoragePolicy())
    var listFailure: Exception? = null
    var storageFailure: Exception? = null
    var detailFailure: Exception? = null
    var exportFailure: Exception? = null
    var exportGate: CompletableDeferred<Unit>? = null
    var deleteResult: Boolean = true
    var listCalls = 0
    val exports = mutableListOf<Pair<String, LocationPrecision>>()
    val deletes = mutableListOf<String>()

    override suspend fun list(): List<SessionSummary> {
        listCalls += 1
        listFailure?.let { throw it }
        return summaries
    }

    override suspend fun detail(dirName: String): SessionDetail? {
        detailFailure?.let { throw it }
        return details[dirName]
    }

    override suspend fun delete(dirName: String): Boolean {
        deletes += dirName
        return deleteResult
    }

    override suspend fun export(dirName: String, precision: LocationPrecision): ExportResult {
        exports += dirName to precision
        exportGate?.await()
        exportFailure?.let { throw it }
        return TestData.exportResult(dirName, precision)
    }

    override suspend fun storage(): StorageStatus {
        storageFailure?.let { throw it }
        return storageStatus
    }
}

class FakeLiveFeed : LiveFeed {
    override val state = MutableStateFlow(LiveState())
}

class FakeReadinessChecker : ReadinessChecker {
    var report: ReadinessReport = TestData.readiness()
    var failure: Exception? = null
    var checks = 0

    override suspend fun check(): ReadinessReport {
        checks += 1
        failure?.let { throw it }
        return report
    }
}

class FakeRecoveryNotices : RecoveryNotices {
    override val closed = MutableStateFlow<List<SessionOutcome>>(emptyList())
    val acknowledged = mutableListOf<String>()

    override fun acknowledge(dirName: String) {
        acknowledged += dirName
        closed.value = closed.value.filterNot { it.dirName == dirName }
    }
}

object UnusedProbe : CapabilityProbe {
    override suspend fun run(durationMs: Long, onProgress: (String) -> Unit): ProbeReport =
        throw UnsupportedOperationException("The session screens never run the probe")

    override suspend fun export(report: ProbeReport): File =
        throw UnsupportedOperationException("The session screens never export a probe report")
}

object UnusedCapability : CapabilityInspector {
    override suspend fun passive(): CapabilitySnapshot =
        throw UnsupportedOperationException("The session screens never inspect capability")

    override suspend fun checkWithRoot(): RootProbeResult =
        throw UnsupportedOperationException("The session screens never inspect capability")
}

object IdleSoak : SoakControl {
    override val state = MutableStateFlow<SoakState>(SoakState.Idle)

    override fun start(durationMs: Long) = Unit

    override fun cancel() = Unit
}

/** Sets `Dispatchers.Main` to [dispatcher] for each test, as `viewModelScope` needs. */
@OptIn(ExperimentalCoroutinesApi::class)
class MainDispatcherRule(val dispatcher: TestDispatcher = UnconfinedTestDispatcher()) : TestWatcher() {
    override fun starting(description: Description) {
        Dispatchers.setMain(dispatcher)
    }

    override fun finished(description: Description) {
        Dispatchers.resetMain()
    }
}

/** Values shared by the session screens' tests. */
object TestData {
    const val DIR: String = "20260910-143000_Mall-walk"
    const val STARTED_UTC_MS: Long = 1_789_050_600_000L

    fun settings(
        consent: Boolean = true,
        testsDefaultOn: Boolean = false,
    ): AppSettings = AppSettings(
        installId = "7b0f6c1e-2a4d-4f0e-9a51-0c3f5d2e8b17",
        consent = if (consent) Consent.record(STARTED_UTC_MS - 86_400_000) else null,
        testsDefaultOn = testsDefaultOn,
    )

    /** A report with every check OK except [levels]; every item links to app details. */
    fun readiness(vararg levels: Pair<ReadinessCheck, ReadinessLevel>, manufacturer: String = "Google"): ReadinessReport {
        val byCheck = levels.toMap()
        return ReadinessReport(
            checkedUtcMs = STARTED_UTC_MS,
            manufacturer = manufacturer,
            items = ReadinessCheck.entries.map { check ->
                ReadinessItem(check, byCheck[check] ?: ReadinessLevel.OK, "Detail of $check.", SettingsTarget.APP_DETAILS)
            },
        )
    }

    fun snapshot(dirName: String = DIR, paused: Boolean = false, elapsedMs: Long = 60_000): RecorderSnapshot = RecorderSnapshot(
        dirName = dirName,
        startedUtcMs = STARTED_UTC_MS,
        elapsedMs = elapsedMs,
        servingRat = ServingRat.LTE,
        servingRsrpDbm = -92,
        newestSampleAgeMs = 1_000,
        paused = paused,
        freshSamples = 30,
        repeatsDropped = 30,
        eventsWritten = 2,
        trackRows = 60,
        hasRecentFix = true,
        stopping = false,
    )

    fun summary(
        dirName: String = DIR,
        recording: Boolean = false,
        readable: Boolean = true,
        stoppedBy: String? = "user",
        startedUtcMs: Long? = STARTED_UTC_MS,
        stoppedUtcMs: Long? = STARTED_UTC_MS + 600_000,
    ): SessionSummary = SessionSummary(
        dirName = dirName,
        name = "Mall walk",
        startedUtcMs = startedUtcMs,
        stoppedUtcMs = stoppedUtcMs,
        stoppedBy = stoppedBy,
        recording = recording,
        readable = readable,
        handsetModel = "Pixel 8",
        plmns = listOf("311480"),
        freshSamples = 54,
        sizeBytes = 120_000,
    )

    fun detail(summary: SessionSummary = summary()): SessionDetail =
        SessionDetail(summary = summary, meta = null, fileSizes = emptyMap(), rowCounts = emptyMap())

    fun exportResult(dirName: String, precision: LocationPrecision): ExportResult = ExportResult(
        zip = File("exports", "$dirName.zip"),
        sha256 = "3f9a0c5e2b7d41a8c6e0f1b2d3a4c5e6f708192a3b4c5d6e7f8091a2b3c4d5e6",
        bytes = 4_096,
        precision = precision,
        entries = listOf("session.json", "kpi.csv"),
    )

    fun outcome(dirName: String = DIR, stoppedBy: String = "low_memory"): SessionOutcome =
        SessionOutcome(dirName, STARTED_UTC_MS, STARTED_UTC_MS + 600_000, stoppedBy, interrupted = true, freshSamples = 54)
}
