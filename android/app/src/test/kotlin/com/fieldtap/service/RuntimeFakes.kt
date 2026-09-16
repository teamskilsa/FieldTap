@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.fieldtap.service

import com.fieldtap.app.SettingsRepository
import com.fieldtap.core.input.MeasurementInput
import com.fieldtap.core.nettest.DownloadOutcome
import com.fieldtap.core.nettest.UploadOutcome
import com.fieldtap.core.nettest.NetTestTransport
import com.fieldtap.core.nettest.PingOutcome
import com.fieldtap.core.nettest.TestSettings
import com.fieldtap.core.privacy.Consent
import com.fieldtap.core.privacy.ConsentRecord
import com.fieldtap.core.radio.ClassifiedAnswer
import com.fieldtap.core.session.RecorderCommand
import com.fieldtap.core.session.RecorderSnapshot
import com.fieldtap.core.session.SessionOutcome
import com.fieldtap.core.session.StartRequest
import com.fieldtap.core.session.StoragePolicy
import com.fieldtap.core.session.StorageStatus
import com.fieldtap.core.settings.AppSettings
import com.fieldtap.core.time.Clock
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope

/** 2026-09-10T14:30:00.000Z. */
internal const val WALL_BASE: Long = 1_789_050_600_000L
internal const val ELAPSED_BASE: Long = 25_323_456L

/** Both clocks follow the test scheduler's virtual time. */
internal class VirtualClock(private val scheduler: TestCoroutineScheduler) : Clock {
    override fun wallMillis(): Long = WALL_BASE + scheduler.currentTime

    override fun elapsedRealtimeMillis(): Long = ELAPSED_BASE + scheduler.currentTime
}

internal class FakePlatform : SessionPlatform {
    val started: MutableList<String> = Collections.synchronizedList(mutableListOf())
    val logs: MutableList<String> = Collections.synchronizedList(mutableListOf())
    var refuseStart: RuntimeException? = null
    var precise = true
    var locationOn = true
    var onStart: (String) -> Unit = {}

    override fun startService(action: String) {
        refuseStart?.let { throw it }
        started += action
        onStart(action)
    }

    override fun preciseLocationGranted(): Boolean = precise

    override fun locationEnabled(): Boolean = locationOn

    override fun log(message: String, error: Throwable?) {
        logs += message
    }
}

internal class FakeHost : ServiceHost {
    var stops = 0

    override fun stopHosting() {
        stops++
    }
}

internal class FakeSettings(initial: AppSettings) : SettingsRepository {
    private val state = MutableStateFlow(initial)

    val value: AppSettings get() = state.value

    override val settings: Flow<AppSettings> get() = state

    override suspend fun current(): AppSettings = state.value

    override suspend fun update(transform: (AppSettings) -> AppSettings): AppSettings {
        val next = transform(state.value)
        state.value = next
        return next
    }

    fun set(settings: AppSettings) {
        state.value = settings
    }
}

/**
 * A recorder that records its commands and finishes when told to stop (or by itself). Its files "exist" at the
 * start of [run], once [createGate] (when given) completes; with [createFailure] they never do.
 */
internal class FakeRecorder(
    val dirName: String,
    val startedUtcMs: Long,
    private val createGate: CompletableDeferred<Unit>? = null,
    private val createFailure: Exception? = null,
) : RecorderHandle {
    val commands: MutableList<RecorderCommand> = Collections.synchronizedList(mutableListOf())
    val runs = AtomicInteger()
    private val finish = CompletableDeferred<String>()

    override val snapshot = MutableStateFlow(
        RecorderSnapshot(
            dirName = dirName,
            startedUtcMs = startedUtcMs,
            elapsedMs = 0,
            servingRat = null,
            servingRsrpDbm = null,
            newestSampleAgeMs = null,
            paused = false,
            freshSamples = 0,
            repeatsDropped = 0,
            eventsWritten = 0,
            trackRows = 0,
            hasRecentFix = false,
            stopping = false,
        ),
    )

    override val outcome = MutableStateFlow<SessionOutcome?>(null)

    override fun submit(command: RecorderCommand) {
        commands += command
        if (command is RecorderCommand.Stop) finish.complete(command.cause.token)
    }

    /** Ends the recording as the recorder does after a storage stop. */
    fun stopByItself(token: String) {
        finish.complete(token)
    }

    /** Ends [run] with [error]; with [finalizedAs] the recorder first wrote that stop token, as SessionRecorder does for a crash. */
    fun crash(error: Exception, finalizedAs: String? = null) {
        if (finalizedAs != null) outcome.value = outcomeOf(finalizedAs)
        finish.completeExceptionally(error)
    }

    fun setPaused(paused: Boolean) {
        snapshot.value = snapshot.value.copy(paused = paused)
    }

    override suspend fun run(onFilesCreated: () -> Unit): SessionOutcome {
        runs.incrementAndGet()
        createGate?.await()
        createFailure?.let { throw it }
        onFilesCreated()
        val result = outcomeOf(finish.await())
        outcome.value = result
        return result
    }

    inline fun <reified T : RecorderCommand> commandsOf(): List<T> = synchronized(commands) { commands.filterIsInstance<T>() }

    private fun outcomeOf(token: String) = SessionOutcome(
        dirName = dirName,
        startedUtcMs = startedUtcMs,
        stoppedUtcMs = startedUtcMs + 60_000,
        stoppedBy = token,
        interrupted = false,
        freshSamples = 30,
    )
}

internal class FakeFactory(private val dispatcher: CoroutineDispatcher) : SessionFactory {
    val prepared: MutableList<StartRequest> = Collections.synchronizedList(mutableListOf())
    val recorders: MutableList<FakeRecorder> = Collections.synchronizedList(mutableListOf())
    val discarded: MutableList<String> = Collections.synchronizedList(mutableListOf())
    var failure: Exception? = null
    var gate: CompletableDeferred<Unit>? = null

    /** When set, each new recorder's files exist only once this completes. */
    var createGate: CompletableDeferred<Unit>? = null

    /** When set, each new recorder fails to create its files with this. */
    var createFailure: Exception? = null
    var tests: TestSettings = TestSettings()

    override suspend fun prepare(request: StartRequest): PreparedSession {
        prepared += request
        gate?.await()
        failure?.let { throw it }
        val dirName = "20260910-143000_" + request.name.trim().replace(' ', '-')
        val recorder = FakeRecorder(dirName, WALL_BASE, createGate, createFailure)
        recorders += recorder
        return PreparedSession(dirName, WALL_BASE, recorder, dispatcher, tests, discard = { discarded += dirName })
    }
}

internal class FakeTransport : NetTestTransport {
    val pings = AtomicInteger()
    val downloads = AtomicInteger()
    val uploads = AtomicInteger()

    override suspend fun ping(target: String, count: Int, timeoutMs: Long): PingOutcome {
        pings.incrementAndGet()
        delay(4_000)
        return PingOutcome.Replies(count, List(count) { 40.0 }, 4.0)
    }

    override suspend fun download(url: String, capBytes: Long, timeoutMs: Long): DownloadOutcome {
        downloads.incrementAndGet()
        delay(4_000)
        return DownloadOutcome.Completed(capBytes, 4.0, 200, capped = true)
    }

    override suspend fun upload(url: String, capBytes: Long, timeoutMs: Long): UploadOutcome {
        uploads.incrementAndGet()
        delay(4_000)
        return UploadOutcome.Completed(capBytes, 4.0, 200)
    }
}

/** A [SessionRuntime] wired to fakes on the test scheduler, with the real `SessionStateMachine`. */
internal class RuntimeHarness(
    scope: TestScope,
    gate: suspend () -> Unit = {},
    /** The inputs the runtime subscribes to; by default [inputs]. */
    inputsFrom: Flow<MeasurementInput>? = null,
) {
    val dispatcher = StandardTestDispatcher(scope.testScheduler)
    val clock = VirtualClock(scope.testScheduler)
    val platform = FakePlatform()
    val host = FakeHost()
    val settings = FakeSettings(AppSettings(installId = "test-install", consent = currentConsent()))
    val factory = FakeFactory(dispatcher)
    val inputs = MutableSharedFlow<MeasurementInput>(extraBufferCapacity = 64)
    val radioInputs = MutableSharedFlow<MeasurementInput>(extraBufferCapacity = 64)
    val transport = FakeTransport()
    var storage = StorageStatus(usedBytes = 0, freeBytes = 50_000_000_000, policy = StoragePolicy())

    val runtime = SessionRuntime(
        scope = scope.backgroundScope,
        clock = clock,
        platform = platform,
        settings = settings,
        storage = { storage },
        sessions = factory,
        inputs = inputsFrom ?: inputs,
        radioInputs = radioInputs,
        transport = transport,
        recoveryGate = gate,
        io = dispatcher,
        newClassifier = { { answer -> ClassifiedAnswer(answer, emptyList(), null, null, fresh = true, repeat = false) } },
    )

    /** What SessionService does after `startForeground` succeeded. */
    fun serviceStarts(action: String): Boolean {
        runtime.attachHost(host)
        return runtime.onServiceStartCommand(action)
    }

    fun recorder(): FakeRecorder = factory.recorders.last()

    companion object {
        fun currentConsent(): ConsentRecord =
            ConsentRecord(version = Consent.CURRENT.version, sha256 = Consent.CURRENT.sha256, grantedUtcMs = WALL_BASE - 86_400_000)
    }
}
