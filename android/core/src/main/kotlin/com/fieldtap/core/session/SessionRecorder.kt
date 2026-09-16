package com.fieldtap.core.session

import com.fieldtap.core.input.CellInfoAnswer
import com.fieldtap.core.input.CellInfoRequestFailed
import com.fieldtap.core.input.DataStateSnapshot
import com.fieldtap.core.input.DisplayInfoSnapshot
import com.fieldtap.core.input.FixSample
import com.fieldtap.core.input.GnssSnapshot
import com.fieldtap.core.input.ListenerReport
import com.fieldtap.core.input.LocationAvailability
import com.fieldtap.core.input.MeasurementInput
import com.fieldtap.core.input.ServiceStateSnapshot
import com.fieldtap.core.input.SignalSnapshot
import com.fieldtap.core.location.JoinResult
import com.fieldtap.core.location.LocationPipeline
import com.fieldtap.core.nettest.TrafficRecord
import com.fieldtap.core.privacy.ConsentRecord
import com.fieldtap.core.radio.CellInfoCandidate
import com.fieldtap.core.radio.ClassifiedCell
import com.fieldtap.core.radio.KpiCandidate
import com.fieldtap.core.radio.RadioPipeline
import com.fieldtap.core.time.Clock
import com.fieldtap.format.Capabilities
import com.fieldtap.format.CellRow
import com.fieldtap.format.CollectionMeta
import com.fieldtap.format.DeviceMeta
import com.fieldtap.format.EventKind
import com.fieldtap.format.EventRat
import com.fieldtap.format.EventRow
import com.fieldtap.format.HandsetMeta
import com.fieldtap.format.LatLon
import com.fieldtap.format.LocationPrecision
import com.fieldtap.format.PrivacyMeta
import com.fieldtap.format.Schema
import com.fieldtap.format.ServingRat
import com.fieldtap.format.SessionFile
import com.fieldtap.format.SessionMeta
import com.fieldtap.format.Severity
import com.fieldtap.format.SummaryMeta
import com.fieldtap.format.TrafficTest
import com.fieldtap.format.TransportMeta
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** The fixed facts of a session, known at start. [startedUtcMs] is the allocation time of its directory. */
data class SessionIdentity(
    val sessionId: String,
    val name: String,
    val note: String?,
    val location: String?,
    val startedUtcMs: Long,
    val transport: TransportMeta,
    val handset: HandsetMeta,
    val device: DeviceMeta,
    val consent: ConsentRecord,
)

/**
 * Builds [SessionMeta] values.
 *
 * - [open]: `stopped_utc` null, `summary.stopped_by` [ExitReasons.RECORDING], plmns `{}`,
 *   [CollectionMeta.EMPTY], precision `full`, zone pauses 0, consent from the identity.
 * - [snapshot]: the same with the given live values. [snapshot]'s `stoppedBy` must be a lower-case token
 *   and `zonePauses` must not be negative (IllegalArgumentException otherwise); plmns keep their order.
 *
 * Owner: workstream `session-core`.
 */
object SessionMetaFactory {
    fun open(identity: SessionIdentity): SessionMeta = snapshot(
        identity = identity,
        plmns = emptyMap(),
        collection = CollectionMeta.EMPTY,
        zonePauses = 0,
        stoppedUtcMs = null,
        stoppedBy = ExitReasons.RECORDING,
    )

    fun snapshot(
        identity: SessionIdentity,
        plmns: Map<String, Int>,
        collection: CollectionMeta,
        zonePauses: Int,
        stoppedUtcMs: Long?,
        stoppedBy: String,
    ): SessionMeta {
        require(ExitReasons.isToken(stoppedBy)) { "summary.stopped_by must be a lower-case token, was '$stoppedBy'" }
        require(zonePauses >= 0) { "privacy.zone_pauses must not be negative, was $zonePauses" }
        return SessionMeta(
            sessionId = identity.sessionId,
            groupId = null,
            name = identity.name,
            note = identity.note,
            location = identity.location,
            startedUtcMs = identity.startedUtcMs,
            stoppedUtcMs = stoppedUtcMs,
            transport = identity.transport,
            handset = identity.handset,
            device = identity.device,
            files = SessionFile.CSV,
            summary = SummaryMeta(stoppedBy = stoppedBy, plmns = LinkedHashMap(plmns)),
            capabilities = Capabilities(layer3 = false),
            collection = collection,
            privacy = PrivacyMeta(
                locationPrecision = LocationPrecision.FULL,
                zonePauses = zonePauses,
                consentVersion = identity.consent.version,
                consentSha256 = identity.consent.sha256,
            ),
        )
    }
}

/**
 * Events owned by the session itself.
 *
 * - [marker]: rat `-`, `info`, title `Marker`, detail the note trimmed (blank if none).
 * - [testFailed]: rat `-`, `error`, title `Ping failed` or `Download failed`, detail the error.
 * - [sessionInterrupted]: rat `-`, `error`, title `Session interrupted`, detail
 *   `Android stopped the app` plus `: <exit description>` when known, cause the stop token (`unknown` when
 *   the given value is not a token). The description is Android's text: white space is collapsed, it is
 *   cut to 200 characters, and runs of ten or more digits become `#`, so that no identifier-shaped number
 *   can reach the file.
 *
 * Owner: workstream `session-core`.
 */
object SessionEvents {
    const val MARKER_TITLE: String = "Marker"
    const val PING_FAILED_TITLE: String = "Ping failed"
    const val DOWNLOAD_FAILED_TITLE: String = "Download failed"
    const val UPLOAD_FAILED_TITLE: String = "Upload failed"
    const val INTERRUPTED_TITLE: String = "Session interrupted"
    const val INTERRUPTED_DETAIL: String = "Android stopped the app"

    private const val MAX_DESCRIPTION_CHARS: Int = 200
    private val LONG_DIGIT_RUN: Regex = Regex("[0-9]{10,}")
    private val WHITE_SPACE: Regex = Regex("\\s+")

    fun marker(wallMs: Long, note: String?): EventRow = EventRow(
        timeUtcMs = wallMs,
        rat = EventRat.NONE,
        kind = EventKind.MARKER,
        severity = Severity.INFO,
        title = MARKER_TITLE,
        detail = note?.trim()?.takeIf { it.isNotEmpty() },
    )

    fun testFailed(wallMs: Long, test: TrafficTest, error: String): EventRow = EventRow(
        timeUtcMs = wallMs,
        rat = EventRat.NONE,
        kind = EventKind.TEST_FAILED,
        severity = Severity.ERROR,
        title = when (test) {
            TrafficTest.PING -> PING_FAILED_TITLE
            TrafficTest.DOWNLOAD -> DOWNLOAD_FAILED_TITLE
            TrafficTest.UPLOAD -> UPLOAD_FAILED_TITLE
        },
        detail = error.trim().takeIf { it.isNotEmpty() },
    )

    fun sessionInterrupted(wallMs: Long, stoppedBy: String, description: String?): EventRow {
        val cleaned = description?.let { cleanDescription(it) }
        return EventRow(
            timeUtcMs = wallMs,
            rat = EventRat.NONE,
            kind = EventKind.SESSION_INTERRUPTED,
            severity = Severity.ERROR,
            title = INTERRUPTED_TITLE,
            detail = if (cleaned.isNullOrEmpty()) INTERRUPTED_DETAIL else "$INTERRUPTED_DETAIL: $cleaned",
            cause = ExitReasons.tokenOrUnknown(stoppedBy),
        )
    }

    private fun cleanDescription(text: String): String {
        val collapsed = WHITE_SPACE.replace(text, " ").trim()
        val masked = LONG_DIGIT_RUN.replace(collapsed, "#")
        return if (masked.length <= MAX_DESCRIPTION_CHARS) masked else masked.take(MAX_DESCRIPTION_CHARS).trimEnd()
    }
}

/** Everything the recorder is told, in one ordered stream. */
sealed interface RecorderCommand {
    data class Measurement(val input: MeasurementInput) : RecorderCommand

    data class Traffic(val record: TrafficRecord) : RecorderCommand

    data class Mark(val note: String?, val wallMs: Long) : RecorderCommand

    data class Stop(val cause: StopCause) : RecorderCommand

    /** Once a second, from the recorder's own ticker. */
    data object Tick : RecorderCommand
}

/** What the notification, the Live screen and the automation hook show about the running session. */
data class RecorderSnapshot(
    val dirName: String,
    val startedUtcMs: Long,
    val elapsedMs: Long,
    val servingRat: ServingRat?,
    val servingRsrpDbm: Int?,
    /** Age now of the newest primary serving sample, or null before the first. */
    val newestSampleAgeMs: Long?,
    val paused: Boolean,
    val freshSamples: Long,
    val repeatsDropped: Long,
    val eventsWritten: Int,
    val trackRows: Long,
    val hasRecentFix: Boolean,
    val stopping: Boolean,
    /**
     * True while nothing is written because no location fix shows where the phone is: the session has privacy zones,
     * and inputs have been held back for more than a few seconds, or logging paused because no fix came.
     */
    val waitingForLocation: Boolean = false,
    /** False while location services are switched off: Android then returns no cell information and no fixes. */
    val locationEnabled: Boolean = true,
    /**
     * True while inputs, a marker among them, wait for a location fix that shows the phone outside its privacy zones:
     * they are written when one does, and dropped if logging pauses first.
     */
    val holdingInputs: Boolean = false,
    /** Markers this session accepted and then dropped, because logging paused in a privacy zone before they could be written. */
    val markersDropped: Int = 0,
)

data class RecorderConfig(
    val identity: SessionIdentity,
    val session: AllocatedSession,
    /** `android.os.Process.myPid()`, for the heartbeat. */
    val pid: Int,
    val writePolicy: WritePolicy = WritePolicy(),
)

/**
 * The session recorder: the only writer of a session, running on one dispatcher.
 *
 * Contract:
 * - [submit] is thread-safe and never blocks: commands go into an unbounded channel. After Stop has
 *   been processed, further commands are ignored.
 * - [run] is called once, on the dispatcher from [SessionDispatchers.newSessionDispatcher]. It creates
 *   the files ([SessionFiles.create] with [SessionMetaFactory.open]), writes the first heartbeat at once
 *   (so a session killed in its first seconds still names its pid), starts a 1 s ticker that submits
 *   [RecorderCommand.Tick], processes commands in order until Stop, finalizes, and returns the outcome.
 *   Cancelling the coroutine finalizes with [StopCause.SERVICE_DESTROYED] and rethrows the cancellation;
 *   [outcome] then holds the result.
 * - When [SessionFiles.create] fails, [run] closes the files and rethrows: nothing was recorded, and the
 *   caller removes the empty directory.
 * - Measurement(CellInfoAnswer): `radio.onCellInfo(answer, writing = !location.paused)`; rows go to a
 *   FIFO of pending rows; events are appended at once. A `cached` answer (Android's `getAllCellInfo` list,
 *   read for the Live screen) is ignored: it is not a measurement of this session.
 * - Pending rows are released in order, on every command, while `location.join(...)` is Resolved for
 *   the head row; each released row gets its position, is appended, and each KPI row is reported with
 *   `radio.onKpiWritten`. Only rows measured by `location.outsideUntilMs` are released.
 * - Inputs are cell-info answers, service, data and display snapshots, traffic results, marks and the gps events,
 *   each with the elapsed time it was observed (a traffic result or mark: when the recorder receives it). An input
 *   observed after `location.outsideUntilMs` (the session has privacy zones and no fix yet shows the phone outside
 *   them then) is kept back, in arrival order, and so is every input after it. When a fix confirms the phone outside
 *   every zone, the kept inputs observed by the new `outsideUntilMs` are handled as if they had just arrived; a pause
 *   (a fix inside a zone, a fix outside after a stretch in which the phone could have been inside one, or a wait that
 *   lasted too long) lets the pipelines learn them with `writing` false and writes nothing of them. A marker dropped
 *   so is counted in [RecorderSnapshot.markersDropped], and each new count is left with [SessionFiles.writeMarkersDropped]
 *   outside the session files, so the Session detail screen can say so later; a failure to write it stops nothing.
 * - Measurement(FixSample): `location.onFix`; its track row appended, its time raised to the row above's when the wall
 *   clock was set back since; its privacy_zone events always appended; its gps events handled as inputs unless paused;
 *   when `location.zonePauses` changed, session.json and cells.csv written at once. On a pause change to "not paused",
 *   `radio.onResume` events are appended, stamped with the fix's observed time. On a pause change to
 *   "paused", from a fix or from a tick, the pending rows measured by the newest fix outside every zone (for a pause
 *   without a fix inside a zone, by the `outsideUntilMs` before it) are written with `location.joinFinal` and the
 *   later ones, which may have been measured inside a zone, are dropped, so nothing is left to write during the pause.
 * - Service, data and display snapshots: to radio with `writing = !paused`, events appended. Location
 *   availability: [RecorderSnapshot.locationEnabled], and `location.onLocationAvailability`'s `gps_lost` when location
 *   services are switched off, handled as an input observed at the switch like the other gps events. Signal, GNSS,
 *   listener reports and request failures: snapshot only.
 * - Traffic: row and failure event appended unless paused. Mark: [SessionEvents.marker] unless paused.
 * - While paused nothing but privacy_zone events is appended, whatever the pipelines return.
 * - Tick: `radio.onTick`, `location.onTick` (privacy_zone events always, the others as inputs unless paused), pending
 *   rows released, then [WriteSchedule] actions in order: flush, sync, snapshot (session.json + cells.csv from
 *   radio and location), heartbeat, storage check (stop with [StopCause.STORAGE_FULL] when
 *   [StorageStatus.mustStop]; a storage lambda that throws IOException or SecurityException does not stop the
 *   session).
 * - [snapshot] is updated after every command; it reads only the pipelines' cheap counters.
 * - Stop: handle the kept inputs observed by `location.outsideUntilMs` and drop the rest, then release every pending
 *   row measured by it with `location.joinFinal` (while paused, none), sync the CSVs, write the final snapshot
 *   with `stopped_utc` = the wall clock now (never before `started_utc` nor before a time a written row carries) and
 *   `stopped_by` = the cause's
 *   token, close the files. Each finalization step runs even when an earlier one failed; when the final
 *   session.json could not be written a heartbeat with the stop time and the stop token is left behind, so
 *   recovery closes the session as this stop.
 * - An IOException from the files stops the session with [StopCause.STORAGE_FULL], the only stop token
 *   for a write failure. Any other exception from a pipeline finalizes with [ExitReasons.CRASH] and is
 *   rethrown; [outcome] then holds the result.
 *
 * Owner: workstream `session-core`.
 */
class SessionRecorder(
    private val config: RecorderConfig,
    private val clock: Clock,
    private val files: SessionFiles,
    private val radio: RadioPipeline,
    private val location: LocationPipeline,
    private val storage: () -> StorageStatus,
) {
    private val commands = Channel<RecorderCommand>(Channel.UNLIMITED)
    private val accepting = AtomicBoolean(true)
    private val runCalled = AtomicBoolean(false)
    private val mutableSnapshot = MutableStateFlow(initialSnapshot())
    private val mutableOutcome = MutableStateFlow<SessionOutcome?>(null)

    // Everything below is read and written only inside run(), on the session dispatcher.
    private val pending = ArrayDeque<PendingRow>()

    /** Inputs kept back until a fix shows they were observed outside every privacy zone, in arrival order. */
    private val held = ArrayDeque<Held>()
    private var markersDropped = 0

    /** The dropped-marker count last written with [SessionFiles.writeMarkersDropped]. */
    private var markersDroppedNoted = 0

    /** The latest time any written row or event carries, so the session never stops before one; MIN_VALUE before any. */
    private var newestRowUtcMs = Long.MIN_VALUE

    /** The newest track.csv time written: a wall clock set back mid-session must not put a fix before the one above it. */
    private var lastTrackUtcMs = Long.MIN_VALUE
    private var locationEnabled = true
    private var schedule = WriteSchedule(config.writePolicy, 0L)
    private var startElapsedMs = 0L
    private var newestPrimary: ClassifiedCell? = null
    private var eventsWritten = 0
    private var trackRows = 0L
    private var lastCollection: CollectionMeta = CollectionMeta.EMPTY
    private var lastPlmns: Map<String, Int> = emptyMap()
    private var lastZonePauses = 0
    private var lastCells: List<CellRow> = emptyList()
    private var stopping = false
    private var finished: SessionOutcome? = null

    /** The running session as the notification, the Live screen and the automation hook show it; updated after every command. */
    val snapshot: StateFlow<RecorderSnapshot> = mutableSnapshot.asStateFlow()

    /** Null until the session has been finalized, however [run] ended. */
    val outcome: StateFlow<SessionOutcome?> = mutableOutcome.asStateFlow()

    /** Queues [command] for [run]. Thread-safe and never blocks; ignored once the session has been finalized. */
    fun submit(command: RecorderCommand) {
        if (!accepting.get()) return
        commands.trySend(command)
    }

    /**
     * Records the session until Stop, a storage stop, a write failure or cancellation, and returns how it
     * ended. Call it once, on [SessionDispatchers.newSessionDispatcher]; the class KDoc is the full contract.
     *
     * @throws IOException when the session files cannot be created; nothing was recorded.
     * @throws IllegalStateException when called a second time.
     */
    suspend fun run(): SessionOutcome {
        check(runCalled.compareAndSet(false, true)) { "SessionRecorder.run() may be called only once" }
        startElapsedMs = clock.elapsedRealtimeMillis()
        schedule = WriteSchedule(config.writePolicy, startElapsedMs)
        var created = false
        try {
            files.create(SessionMetaFactory.open(config.identity))
            created = true
        } finally {
            if (!created) {
                accepting.set(false)
                commands.cancel()
                closeFilesQuietly()
            }
        }
        return coroutineScope {
            val ticker = launch {
                while (true) {
                    delay(TICK_MS)
                    commands.trySend(RecorderCommand.Tick)
                }
            }
            try {
                record()
            } catch (e: CancellationException) {
                finish(StopCause.SERVICE_DESTROYED.token)
                throw e
            } finally {
                ticker.cancel()
            }
        }
    }

    private suspend fun record(): SessionOutcome {
        val firstStop = stopOnFailure {
            files.writeHeartbeat(HeartbeatRecord(clock.wallMillis(), clock.elapsedRealtimeMillis(), config.pid))
            publishSnapshot()
            null
        }
        if (firstStop != null) return finish(firstStop)
        for (command in commands) {
            val stoppedBy = stopOnFailure {
                val token = process(command)
                noteMarkersDropped()
                publishSnapshot()
                token
            }
            if (stoppedBy != null) return finish(stoppedBy)
        }
        // Only finish() closes the channel, and it returns first; a cancelled receive throws instead.
        return finish(StopCause.SERVICE_DESTROYED.token)
    }

    /** Runs one step; a write failure becomes a storage stop, a bug finalizes the session and propagates. */
    private inline fun stopOnFailure(block: () -> String?): String? =
        try {
            block()
        } catch (e: IOException) {
            StopCause.STORAGE_FULL.token
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // A bug, or an Error such as running out of memory: the session is closed as a crash, then it propagates.
            try {
                finish(ExitReasons.CRASH)
            } catch (suppressed: Throwable) {
                e.addSuppressed(suppressed)
            }
            throw e
        }

    /** Handles one command; returns the stop token when the session must stop now. */
    private fun process(command: RecorderCommand): String? {
        when (command) {
            is RecorderCommand.Measurement -> onInput(command)
            is RecorderCommand.Traffic, is RecorderCommand.Mark -> holdOrApply(Held.Input(command, clock.elapsedRealtimeMillis()))
            is RecorderCommand.Stop -> return command.cause.token
            RecorderCommand.Tick -> return onTick()
        }
        releasePending(clock.elapsedRealtimeMillis())
        return null
    }

    private fun onInput(command: RecorderCommand.Measurement) {
        when (val input = command.input) {
            is FixSample -> onFix(input)
            is CellInfoAnswer -> if (!input.cached) holdOrApply(Held.Input(command, input.observedElapsedMs))
            is ServiceStateSnapshot, is DataStateSnapshot, is DisplayInfoSnapshot ->
                holdOrApply(Held.Input(command, input.observedElapsedMs))
            is LocationAvailability -> {
                locationEnabled = input.locationEnabled
                // gps_lost when location services go off: held with the other inputs, and dropped while paused.
                for (event in location.onLocationAvailability(input)) holdOrApply(Held.Event(event, input.observedElapsedMs))
            }
            is SignalSnapshot, is GnssSnapshot, is ListenerReport, is CellInfoRequestFailed -> Unit
        }
    }

    /** Leaves the dropped-marker count beside the heartbeat whenever it grew; a note that cannot be written stops nothing. */
    private fun noteMarkersDropped() {
        if (markersDropped == markersDroppedNoted) return
        try {
            files.writeMarkersDropped(markersDropped)
            markersDroppedNoted = markersDropped
        } catch (e: IOException) {
            // Not part of the session files: the recording goes on, the outcome still carries the count, and the next
            // command tries again.
        }
    }

    /** Handles [item] now when it was observed outside every zone and nothing waits before it; else keeps it back. */
    private fun holdOrApply(item: Held) {
        if (location.paused) {
            apply(item, writing = false)
            return
        }
        val outsideUntil = location.outsideUntilMs
        if (held.isEmpty() && outsideUntil != null && item.observedElapsedMs <= outsideUntil) {
            apply(item, writing = true)
            return
        }
        held.addLast(item)
        // A bound no real hold reaches (a hold ends within its limit): past it the oldest input is learnt, never written.
        while (held.size > MAX_HELD_COMMANDS) apply(held.removeFirst(), writing = false)
    }

    /** Handles, in order, the kept inputs a fix now shows were observed outside every zone; drops them all while paused. */
    private fun settleHeld() {
        while (held.isNotEmpty()) {
            if (location.paused) {
                dropHeld()
                return
            }
            val outsideUntil = location.outsideUntilMs ?: return
            if (held.first().observedElapsedMs > outsideUntil) return
            apply(held.removeFirst(), writing = true)
        }
    }

    /** Lets the pipelines learn every kept input and writes none of them. */
    private fun dropHeld() {
        while (held.isNotEmpty()) apply(held.removeFirst(), writing = false)
    }

    /** One kept or arriving input; with [writing] false the pipelines learn it and nothing is written. */
    private fun apply(item: Held, writing: Boolean) {
        when (item) {
            is Held.Event -> if (writing && !location.paused) appendEvent(item.row)
            is Held.Input -> when (val command = item.command) {
                is RecorderCommand.Measurement -> when (val input = command.input) {
                    is CellInfoAnswer -> onCellInfo(input, writing)
                    is ServiceStateSnapshot -> radio.onServiceState(input, writing).let { if (writing) appendEvents(it) }
                    is DataStateSnapshot -> radio.onDataState(input, writing).let { if (writing) appendEvents(it) }
                    is DisplayInfoSnapshot -> radio.onDisplayInfo(input, writing).let { if (writing) appendEvents(it) }
                    else -> Unit
                }
                is RecorderCommand.Traffic -> if (writing) onTraffic(command.record)
                is RecorderCommand.Mark -> if (writing && !location.paused) onMark(command) else markersDropped++
                is RecorderCommand.Stop, RecorderCommand.Tick -> Unit
            }
        }
    }

    private fun onCellInfo(answer: CellInfoAnswer, writing: Boolean) {
        val step = radio.onCellInfo(answer, writing)
        rememberServing()
        if (!writing) return
        appendEvents(step.events)
        for (candidate in step.cellInfo) pending.addLast(PendingRow.CellInfo(candidate))
        for (candidate in step.kpi) pending.addLast(PendingRow.Kpi(candidate))
    }

    private fun onFix(fix: FixSample) {
        val wasPaused = location.paused
        val writtenByMs = pauseBoundMs()
        val step = location.onFix(fix)
        val pausedNow = location.paused
        if (!wasPaused && pausedNow) {
            enterPause(writtenByMs)
        } else if (step.confirmsOutside) {
            settleHeld()
        }
        for (event in step.events) {
            when {
                event.kind == EventKind.PRIVACY_ZONE -> appendEvent(event)
                !pausedNow -> holdOrApply(Held.Event(event, fix.observedElapsedMs))
            }
        }
        if (wasPaused && !pausedNow) appendEvents(radio.onResume(fix.observedWallMs, fix.observedElapsedMs))
        val track = step.track
        if (track != null && !pausedNow) {
            // Fixes arrive in time order, but their wall times follow the clock, which Android or the user may set back.
            val row = if (track.timeUtcMs < lastTrackUtcMs) track.copy(timeUtcMs = lastTrackUtcMs) else track
            files.appendTrack(row)
            lastTrackUtcMs = row.timeUtcMs
            newestRowUtcMs = maxOf(newestRowUtcMs, row.timeUtcMs)
            trackRows++
        }
        // A pause is rare and recovery keeps the last snapshot's count: write the count down now, not within 60 s.
        if (location.zonePauses != lastZonePauses) writeSnapshotNow()
    }

    private fun onTraffic(record: TrafficRecord) {
        if (location.paused) return
        files.appendTraffic(record.row)
        newestRowUtcMs = maxOf(newestRowUtcMs, record.row.timeUtcMs)
        record.failure?.let { appendEvent(it) }
    }

    /** session.json and cells.csv as they stand now, as the periodic snapshot writes them. */
    private fun writeSnapshotNow() {
        refreshTotals()
        val cells = radio.cells()
        files.writeSnapshot(meta(stoppedUtcMs = null, stoppedBy = ExitReasons.RECORDING), cells)
        lastCells = cells
    }

    private fun onMark(mark: RecorderCommand.Mark) {
        if (location.paused) return
        appendEvent(SessionEvents.marker(mark.wallMs, mark.note))
    }

    private fun onTick(): String? {
        val nowElapsed = clock.elapsedRealtimeMillis()
        val nowWall = clock.wallMillis()
        radio.onTick(nowElapsed)
        val wasPaused = location.paused
        val writtenByMs = pauseBoundMs()
        val locationEvents = location.onTick(nowWall, nowElapsed)
        val pausedNow = location.paused
        if (!wasPaused && pausedNow) enterPause(writtenByMs)
        for (event in locationEvents) {
            when {
                event.kind == EventKind.PRIVACY_ZONE -> appendEvent(event)
                !pausedNow -> holdOrApply(Held.Event(event, nowElapsed))
            }
        }
        releasePending(nowElapsed)
        val due = schedule.due(nowElapsed)
        if (WriteAction.FLUSH in due) files.flush()
        if (WriteAction.SYNC in due) files.sync()
        if (WriteAction.SNAPSHOT in due) writeSnapshotNow()
        if (WriteAction.HEARTBEAT in due) files.writeHeartbeat(HeartbeatRecord(nowWall, nowElapsed, config.pid))
        if (WriteAction.STORAGE_CHECK in due && storageMustStop()) return StopCause.STORAGE_FULL.token
        return null
    }

    private fun releasePending(nowElapsedMs: Long) {
        if (location.paused) return
        // A row measured after the time fixes show the phone outside every zone may have been measured inside one.
        val measuredByMs = location.outsideUntilMs ?: return
        while (pending.isNotEmpty()) {
            val head = pending.first()
            if (head.measurementElapsedMs > measuredByMs) return
            val position = when (val joined = location.join(head.measurementElapsedMs, nowElapsedMs)) {
                JoinResult.Pending -> return
                is JoinResult.Resolved -> joined.position
            }
            pending.removeFirst()
            write(head, position)
        }
    }

    /**
     * Of the rows waiting for a position, how late a row may have been measured and still be written if logging pauses
     * next: for a pause at a fix inside a zone, the newest fix outside every zone; for a pause without such a fix, the
     * time up to which fixes showed the phone outside every zone, if later.
     */
    private fun pauseBoundMs(): PauseBound = PauseBound(location.lastFix()?.elapsedMs, location.outsideUntilMs)

    /**
     * Logging has just paused. What was held is learnt by the pipelines and never written. Of the rows still waiting
     * for a position, those measured by [bound] are written with what the track knows; later ones may have been
     * measured inside a zone and are dropped.
     */
    private fun enterPause(bound: PauseBound) {
        dropHeld()
        val measuredByMs = if (location.pausedWithoutFix) {
            maxOf(bound.newestOutsideFixMs ?: Long.MIN_VALUE, bound.outsideUntilMs ?: Long.MIN_VALUE).takeIf { it != Long.MIN_VALUE }
        } else {
            bound.newestOutsideFixMs
        }
        writePendingMeasuredBy(measuredByMs)
    }

    /** Empties the pending rows: those measured at or before [newestOutsideMs] are written, the others dropped. */
    private fun writePendingMeasuredBy(newestOutsideMs: Long?) {
        while (pending.isNotEmpty()) {
            val head = pending.removeFirst()
            if (newestOutsideMs != null && head.measurementElapsedMs <= newestOutsideMs) {
                write(head, location.joinFinal(head.measurementElapsedMs))
            }
        }
    }

    private fun write(row: PendingRow, position: LatLon?) {
        when (row) {
            is PendingRow.CellInfo -> {
                val written = row.candidate.row.copy(position = position)
                files.appendCellInfo(written)
                newestRowUtcMs = maxOf(newestRowUtcMs, written.seenUtcMs, written.timeEpochMs)
            }
            is PendingRow.Kpi -> {
                val written = row.candidate.copy(row = row.candidate.row.copy(position = position))
                files.appendKpi(written.row)
                newestRowUtcMs = maxOf(newestRowUtcMs, written.row.timeEpochMs)
                radio.onKpiWritten(written)
            }
        }
    }

    private fun appendEvents(events: List<EventRow>) {
        for (event in events) appendEvent(event)
    }

    private fun appendEvent(event: EventRow) {
        files.appendEvent(event)
        newestRowUtcMs = maxOf(newestRowUtcMs, event.timeUtcMs)
        eventsWritten++
    }

    private fun rememberServing() {
        val primary = radio.latest()?.primary ?: return
        val current = newestPrimary
        if (current == null || primary.cell.timestampMs >= current.cell.timestampMs) newestPrimary = primary
    }

    private fun refreshTotals() {
        lastCollection = radio.collection()
        lastPlmns = radio.plmns()
        lastZonePauses = location.zonePauses
    }

    private fun meta(stoppedUtcMs: Long?, stoppedBy: String): SessionMeta =
        SessionMetaFactory.snapshot(config.identity, lastPlmns, lastCollection, lastZonePauses, stoppedUtcMs, stoppedBy)

    private fun storageMustStop(): Boolean {
        val status = try {
            storage()
        } catch (e: IOException) {
            return false
        } catch (e: SecurityException) {
            return false
        }
        return status.mustStop
    }

    /** Finalizes once: every step is attempted even when an earlier one failed. */
    private fun finish(stoppedBy: String): SessionOutcome {
        finished?.let { return it }
        accepting.set(false)
        commands.cancel()
        stopping = true

        attempt {
            if (location.paused) {
                pending.clear()
            } else {
                // Nothing shows where inputs observed after outsideUntilMs, and rows measured after it, were taken.
                settleHeld()
                writePendingMeasuredBy(location.outsideUntilMs)
            }
        }
        markersDropped += held.count { it is Held.Input && it.command is RecorderCommand.Mark }
        held.clear()
        pending.clear()
        attempt { noteMarkersDropped() }
        // Never before the start, nor before a row already written: the wall clock may have been set back meanwhile.
        val stoppedUtcMs = maxOf(clock.wallMillis(), config.identity.startedUtcMs, newestRowUtcMs)
        attempt { refreshTotals() }
        attempt { files.sync() }
        val cells = attemptOrNull { radio.cells() } ?: lastCells
        val finalSnapshotWritten = attempt { files.writeSnapshot(meta(stoppedUtcMs, stoppedBy), cells) }
        attempt { files.close() }
        if (!finalSnapshotWritten) {
            attempt {
                files.writeHeartbeat(HeartbeatRecord(stoppedUtcMs, clock.elapsedRealtimeMillis(), config.pid, stoppedBy = stoppedBy))
            }
        }

        val result = SessionOutcome(
            dirName = config.session.dirName,
            startedUtcMs = config.identity.startedUtcMs,
            stoppedUtcMs = stoppedUtcMs,
            stoppedBy = stoppedBy,
            interrupted = false,
            freshSamples = lastCollection.freshSamples,
            name = config.identity.name,
            markersDropped = markersDropped,
        )
        finished = result
        mutableOutcome.value = result
        attempt { publishSnapshot() }
        return result
    }

    // Finalization must go on past any failure, so these two catch every Exception on purpose.
    private inline fun attempt(block: () -> Unit): Boolean =
        try {
            block()
            true
        } catch (e: Exception) {
            false
        }

    private inline fun <T : Any> attemptOrNull(block: () -> T): T? =
        try {
            block()
        } catch (e: Exception) {
            null
        }

    private fun closeFilesQuietly() {
        try {
            files.close()
        } catch (e: IOException) {
            // Nothing was recorded; the failure that matters is the one being rethrown.
        }
    }

    private fun publishSnapshot() {
        val nowElapsed = clock.elapsedRealtimeMillis()
        val primary = newestPrimary
        val fix = location.lastFix()
        val counts = radio.sampleCounts()
        mutableSnapshot.value = RecorderSnapshot(
            dirName = config.session.dirName,
            startedUtcMs = config.identity.startedUtcMs,
            elapsedMs = (nowElapsed - startElapsedMs).coerceAtLeast(0L),
            servingRat = primary?.cell?.rat?.servingRat,
            servingRsrpDbm = primary?.cell?.rsrp,
            newestSampleAgeMs = primary?.let { (nowElapsed - it.cell.timestampMs).coerceAtLeast(0L) },
            paused = location.paused,
            freshSamples = counts.freshSamples,
            repeatsDropped = counts.repeatsDropped,
            eventsWritten = eventsWritten,
            trackRows = trackRows,
            hasRecentFix = fix != null && nowElapsed - fix.elapsedMs <= RECENT_FIX_MS,
            stopping = stopping,
            waitingForLocation = location.pausedWithoutFix || (location.holdAgeMs(nowElapsed) ?: 0L) > WAITING_NOTICE_MS,
            locationEnabled = locationEnabled,
            holdingInputs = !location.paused && (held.isNotEmpty() || (location.outsideUntilMs ?: Long.MIN_VALUE) < nowElapsed),
            markersDropped = markersDropped,
        )
    }

    private fun initialSnapshot(): RecorderSnapshot = RecorderSnapshot(
        dirName = config.session.dirName,
        startedUtcMs = config.identity.startedUtcMs,
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
    )

    private companion object {
        const val TICK_MS: Long = 1_000

        /** A fix at most this old counts as recent: the GPS join's own limit. */
        const val RECENT_FIX_MS: Long = Schema.GPS_MATCH_MS

        /** Inputs held back longer than this make the snapshot say the session is waiting for a location fix. */
        const val WAITING_NOTICE_MS: Long = 5_000

        /** More held commands than a minute's hold could gather; the oldest beyond it are learnt and never written. */
        const val MAX_HELD_COMMANDS: Int = 10_000
    }
}

/** An input kept back until a fix shows it was observed outside every privacy zone. */
private sealed interface Held {
    /** When it was observed, on the elapsed clock. */
    val observedElapsedMs: Long

    /** A cell-info answer, a service, data or display snapshot, a traffic result or a mark. */
    class Input(val command: RecorderCommand, override val observedElapsedMs: Long) : Held

    /** A `gps_lost` or `gps_restored` event. */
    class Event(val row: EventRow, override val observedElapsedMs: Long) : Held
}

/** What [SessionRecorder] reads before a pause changes, to decide which waiting rows it still writes. */
private class PauseBound(val newestOutsideFixMs: Long?, val outsideUntilMs: Long?)

/** A row waiting in the recorder's FIFO for its GPS join. */
private sealed interface PendingRow {
    val measurementElapsedMs: Long

    class Kpi(val candidate: KpiCandidate) : PendingRow {
        override val measurementElapsedMs: Long get() = candidate.measurementElapsedMs
    }

    class CellInfo(val candidate: CellInfoCandidate) : PendingRow {
        override val measurementElapsedMs: Long get() = candidate.measurementElapsedMs
    }
}

/** Owner: workstream `session-core`. */
object SessionDispatchers {
    /** A dispatcher that runs one task at a time on the IO pool: `Dispatchers.IO.limitedParallelism(1)`. */
    fun newSessionDispatcher(): CoroutineDispatcher = Dispatchers.IO.limitedParallelism(1, "fieldtap-session")
}
