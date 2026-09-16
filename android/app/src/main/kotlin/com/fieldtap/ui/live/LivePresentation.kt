package com.fieldtap.ui.live

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.fieldtap.app.SessionStatus
import com.fieldtap.core.input.DataConnState
import com.fieldtap.core.input.DataStateSnapshot
import com.fieldtap.core.input.DeviceConditions
import com.fieldtap.core.input.DisplayInfoSnapshot
import com.fieldtap.core.input.FixSample
import com.fieldtap.core.input.ListenerOutcome
import com.fieldtap.core.input.RadioListener
import com.fieldtap.core.input.ServiceRegState
import com.fieldtap.core.input.ServiceStateSnapshot
import com.fieldtap.core.input.SignalSnapshot
import com.fieldtap.core.live.ChartPoint
import com.fieldtap.core.live.LiveCell
import com.fieldtap.core.live.LiveState
import com.fieldtap.core.live.LiveStateReducer
import com.fieldtap.core.radio.NetworkTypeNames
import com.fieldtap.core.radio.PciPlanning
import com.fieldtap.core.radio.ServingCellSelector
import com.fieldtap.format.Rat
import com.fieldtap.ui.components.ChartMath
import com.fieldtap.ui.components.SessionButtonState
import com.fieldtap.ui.theme.Sizes
import com.fieldtap.ui.theme.StatusTone

/** Why Android refreshes cell info at the interval shown (docs/APP-PLAN.md, the Android facts). */
enum class CadenceReason {
    /** 2 s: the screen is on and Wi-Fi is off. */
    SCREEN_ON_WIFI_OFF,

    /** 2 s: Wi-Fi is on, but the phone is charging. */
    CHARGING_WITH_WIFI,

    /** 10 s: the screen is off (pocket mode). */
    SCREEN_OFF,

    /** 10 s: Wi-Fi is on and the phone is not charging. */
    WIFI_ON_BATTERY,
}

/** The service-state chip. */
enum class ServiceChip(val tone: StatusTone) {
    WAITING(StatusTone.NEUTRAL),
    IN_SERVICE(StatusTone.SUCCESS),
    ROAMING(StatusTone.SUCCESS),
    EMERGENCY_ONLY(StatusTone.WARNING),
    NO_SERVICE(StatusTone.ERROR),
    RADIO_OFF(StatusTone.ERROR),
    UNKNOWN(StatusTone.NEUTRAL),
}

/** The mobile-data chip. */
enum class DataChip(val tone: StatusTone) {
    WAITING(StatusTone.NEUTRAL),
    CONNECTED(StatusTone.SUCCESS),
    CONNECTING(StatusTone.NEUTRAL),
    DISCONNECTED(StatusTone.WARNING),
    SUSPENDED(StatusTone.WARNING),
    UNKNOWN(StatusTone.NEUTRAL),
}

/** The GPS chip. */
sealed interface GpsChip {
    val tone: StatusTone

    /** No fix since the sources started. */
    data object Waiting : GpsChip {
        override val tone: StatusTone get() = StatusTone.NEUTRAL
    }

    /** A fix at most [LivePresentation.GPS_LOST_AFTER_MS] old. */
    data class Fix(val accuracyM: Double?) : GpsChip {
        override val tone: StatusTone get() = StatusTone.SUCCESS
    }

    /** The newest fix is older than that, as `gps_lost` counts it in a session. */
    data class Lost(val ageMs: Long) : GpsChip {
        override val tone: StatusTone get() = StatusTone.ERROR
    }
}

/** What the serving cell says about the network. */
enum class ServingNetwork { LTE, LTE_WITH_NR_LEG, NR_STANDALONE, OTHER }

/** A listener that did not register, for a line under the cadence. */
data class ListenerNote(val listener: RadioListener, val outcome: ListenerOutcome, val tone: StatusTone)

/** A signal-strength report newer than the serving cell's measurement (display only, never recorded). */
data class SignalReport(val rsrpDbm: Int, val ageMs: Long)

/** Why the serving tiles show no serving cell, or no new measurement of it. */
sealed interface ServingAbsence {
    /** No cell-info answer has arrived since the sources started. */
    data object WaitingForAnswer : ServingAbsence

    /** Location services are off: Android returns no cell information and no fixes. */
    data object LocationOff : ServingAbsence

    /** The phone's radio is off, for example in airplane mode. */
    data object RadioOff : ServingAbsence

    /** Out of service: no network, not even for emergency calls. */
    data object NoService : ServingAbsence

    /** Only emergency calls: usually no SIM, or a SIM the network does not accept. Camped cells are still measured. */
    data object EmergencyOnly : ServingAbsence

    /**
     * Answers arrive, but none names an LTE or NR serving cell: the phone is on another network, as the API 31
     * emulator is (a GSM cell while its data runs on HSPA), or Android marks no cell as serving. [network] is
     * Android's data network type when it is known and is neither LTE nor NR, for example "HSPA".
     */
    data class NoLteOrNrServing(val network: String?) : ServingAbsence
}

/** What the running session is doing, for the status strip under the top bar. */
enum class RecordingState { RECORDING, PAUSED_IN_ZONE, WAITING_FOR_LOCATION, LOCATION_OFF, SAVING }

/** The GPS part of the status strip. */
enum class StripGps { WAITING, FIX, LOST }

/** The status strip shown, not scrolling, while a session runs: the facts that decide whether it is collecting. */
data class RecordingStrip(val state: RecordingState, val freshSamples: Long, val gps: StripGps)

/**
 * The decisions behind the Live screen's words and tones, pure so they are unit-tested; the composables
 * only look up strings.
 *
 * Owner: workstream `ui-session`.
 */
/**
 * A neighbour as Live draws it: the cell, which of [com.fieldtap.core.radio.PciPlanning.MODULI] it
 * reuses with the serving cell, and how far below the serving cell it is.
 */
data class NeighbourRow(val cell: LiveCell, val pciReuse: Set<Int>, val marginDb: Int?)

object LivePresentation {

    /**
     * [LiveState.neighbours] paired with their PCI reuse against the serving cell, in the order Live
     * draws them. A reuse is only reported for a neighbour on the serving cell's own RAT and carrier;
     * see [com.fieldtap.core.radio.PciPlanning].
     */
    fun neighbourRows(state: LiveState): List<NeighbourRow> {
        val serving = state.serving
        return state.neighbours.map { cell ->
            NeighbourRow(
                cell = cell,
                pciReuse = PciPlanning.collisions(
                    servingRat = serving?.rat,
                    servingPci = serving?.pci,
                    servingArfcn = serving?.arfcn,
                    neighbourRat = cell.rat,
                    neighbourPci = cell.pci,
                    neighbourArfcn = cell.arfcn,
                ),
                marginDb = PciPlanning.marginDb(serving?.rsrp, cell.rsrp),
            )
        }
    }
    /** A fix older than this is "GPS lost", as `GpsEventDeriver` reports it in a session. */
    const val GPS_LOST_AFTER_MS: Long = 5_000

    /** Listeners only the capability probe registers; the Live screen never mentions them. */
    val PROBE_ONLY_LISTENERS: Set<RadioListener> = setOf(
        RadioListener.PHYSICAL_CHANNEL_CONFIG,
        RadioListener.BARRING_INFO,
        RadioListener.REGISTRATION_FAILED,
    )

    /** The reason for the interval in force under [conditions]; null before the first answer. */
    fun cadenceReason(conditions: DeviceConditions?): CadenceReason? = when {
        conditions == null -> null
        !conditions.screenOn -> CadenceReason.SCREEN_OFF
        !conditions.wifiConnected -> CadenceReason.SCREEN_ON_WIFI_OFF
        conditions.charging -> CadenceReason.CHARGING_WITH_WIFI
        else -> CadenceReason.WIFI_ON_BATTERY
    }

    /** Walk mode prompts to turn Wi-Fi off or plug in exactly when Wi-Fi forces the 10 s interval. */
    /**
     * Whether to warn that Wi-Fi is costing samples. Android refreshes cell information every 2 s
     * only while the display is on and the phone is either off Wi-Fi or charging; on Wi-Fi and on
     * battery it refreshes every 10 s. Shown only while recording, because that is the only time
     * the cadence changes what lands in the files.
     */
    fun showWifiCadencePrompt(recording: Boolean, conditions: DeviceConditions?): Boolean =
        recording && conditions != null && conditions.wifiConnected && !conditions.charging

    /** Emergency-only comes from service state only, as in a session; roaming counts as in service. */
    fun serviceChip(service: ServiceStateSnapshot?): ServiceChip = when {
        service == null -> ServiceChip.WAITING
        ServingCellSelector.isEmergencyOnly(service) -> ServiceChip.EMERGENCY_ONLY
        else -> when (service.state) {
            ServiceRegState.IN_SERVICE -> if (service.roaming == true) ServiceChip.ROAMING else ServiceChip.IN_SERVICE
            ServiceRegState.OUT_OF_SERVICE -> ServiceChip.NO_SERVICE
            ServiceRegState.POWER_OFF -> ServiceChip.RADIO_OFF
            ServiceRegState.EMERGENCY_ONLY -> ServiceChip.EMERGENCY_ONLY
            ServiceRegState.UNKNOWN -> ServiceChip.UNKNOWN
        }
    }

    fun dataChip(data: DataStateSnapshot?): DataChip = when (data?.state) {
        null -> DataChip.WAITING
        DataConnState.CONNECTED -> DataChip.CONNECTED
        DataConnState.CONNECTING, DataConnState.HANDOVER_IN_PROGRESS -> DataChip.CONNECTING
        DataConnState.DISCONNECTED, DataConnState.DISCONNECTING -> DataChip.DISCONNECTED
        DataConnState.SUSPENDED -> DataChip.SUSPENDED
        DataConnState.UNKNOWN -> DataChip.UNKNOWN
    }

    /** Android's name of the data network type ("LTE", "NR", "HSPAP"), or null when unknown. */
    fun dataNetworkName(data: DataStateSnapshot?): String? {
        if (data == null) return null
        val name = NetworkTypeNames.networkType(data.networkType)
        return if (name == NetworkTypeNames.UNKNOWN) null else name.replace('_', ' ')
    }

    /** Whether the status bar shows a 5G icon; null before Android reported it. An indicator, not a measurement. */
    fun fiveGIcon(display: DisplayInfoSnapshot?): Boolean? = display?.let { NetworkTypeNames.shows5g(it) }

    fun gpsChip(fix: FixSample?, nowElapsedMs: Long): GpsChip {
        if (fix == null) return GpsChip.Waiting
        val ageMs = (nowElapsedMs - fix.elapsedMs).coerceAtLeast(0)
        return if (ageMs <= GPS_LOST_AFTER_MS) GpsChip.Fix(fix.accuracyM) else GpsChip.Lost(ageMs)
    }

    /**
     * Listeners that did not register, in listener order. Missing precise location for the cell-info
     * requests is an error (no measurements at all); the optional push listener without the Phone
     * permission is information; any other refusal or failure is a warning.
     */
    fun listenerNotes(listeners: Map<RadioListener, ListenerOutcome>): List<ListenerNote> =
        listeners.entries
            .filter { (listener, outcome) ->
                listener !in PROBE_ONLY_LISTENERS && outcome != ListenerOutcome.REGISTERED && outcome != ListenerOutcome.UNREGISTERED
            }
            .sortedBy { it.key.ordinal }
            .map { (listener, outcome) -> ListenerNote(listener, outcome, noteTone(listener, outcome)) }

    /** LTE, LTE with its NR leg, NR standalone, or another RAT; null without a serving cell. */
    fun servingNetwork(serving: LiveCell?, nsaLeg: LiveCell?): ServingNetwork? = when (serving?.rat) {
        null -> null
        Rat.LTE -> if (nsaLeg != null) ServingNetwork.LTE_WITH_NR_LEG else ServingNetwork.LTE
        Rat.NR -> ServingNetwork.NR_STANDALONE
        else -> ServingNetwork.OTHER
    }

    /**
     * The RSRP of a signal-strength report for the serving cell's RAT that is newer than the serving
     * measurement (Android's signal reports come between cell-info answers), with its age; else null.
     */
    fun newerSignalReport(serving: LiveCell?, signal: SignalSnapshot?, nowElapsedMs: Long): SignalReport? {
        if (serving == null || signal == null) return null
        val rsrp = when (serving.rat) {
            Rat.LTE -> signal.lteRsrp
            Rat.NR -> signal.nrSsRsrp
            else -> null
        } ?: return null
        val measuredAtMs = signal.modemTimestampMs ?: signal.observedElapsedMs
        if (measuredAtMs <= serving.timestampMs) return null
        return SignalReport(rsrp, (nowElapsedMs - measuredAtMs).coerceAtLeast(0))
    }

    /**
     * Why there is no serving cell to show: null while there is one. Otherwise the first that applies: location off
     * (Android then answers with no cells at all), the radio off, emergency calls only, out of service; then
     * [ServingAbsence.WaitingForAnswer] before the first cell-info answer; otherwise answers arrive without an LTE or
     * NR serving cell, which the tiles must say instead of "waiting", because measurements are arriving.
     */
    fun servingAbsence(live: LiveState): ServingAbsence? = when {
        live.serving != null -> null
        else -> servingProblem(live) ?: if (live.shortInterval == null) {
            ServingAbsence.WaitingForAnswer
        } else {
            ServingAbsence.NoLteOrNrServing(dataNetworkName(live.data)?.takeUnless { it.startsWith("LTE") || it.startsWith("NR") })
        }
    }

    /**
     * A condition that stops or limits measurements, whether or not a serving cell is still on screen: location off,
     * the radio off, emergency calls only, or out of service, in that order; null when none applies. With a serving
     * cell on screen it explains why that cell is ageing, or that it is an emergency-only camp.
     */
    fun servingProblem(live: LiveState): ServingAbsence? {
        val service = live.service
        return when {
            live.locationEnabled == false -> ServingAbsence.LocationOff
            service == null -> null
            service.state == ServiceRegState.POWER_OFF -> ServingAbsence.RadioOff
            ServingCellSelector.isEmergencyOnly(service) -> ServingAbsence.EmergencyOnly
            service.state == ServiceRegState.OUT_OF_SERVICE -> ServingAbsence.NoService
            else -> null
        }
    }

    /**
     * The serving cell does not report SINR: RSRP samples fall in the chart's window and no SINR sample does. Both come
     * from the same samples, so this is not "no fresh samples yet"; before any RSRP it is.
     */
    fun sinrNotReported(rsrp: List<ChartPoint>, sinr: List<ChartPoint>, nowElapsedMs: Long, windowMs: Long = LiveStateReducer.WINDOW_MS): Boolean =
        ChartMath.stats(rsrp, nowElapsedMs, windowMs) != null && ChartMath.stats(sinr, nowElapsedMs, windowMs) == null

    /**
     * A wide window too low for a bottom action bar under two panes, a phone in landscape: Start, Stop and Mark sit in a
     * column beside the content, so the serving cell's value stays in view.
     */
    fun actionsBesideContent(width: Dp, height: Dp): Boolean = width >= Sizes.WideLayoutMinWidth && height < Sizes.ShortWindowMaxHeight

    /**
     * Two panes when the width left beside the session buttons, if they sit there, still holds two: on a small phone in
     * landscape, one pane beside the buttons reads better than two narrow ones that cut labels and wrap every chip.
     */
    fun twoPanes(width: Dp, actionsBeside: Boolean): Boolean =
        width >= Sizes.WideLayoutMinWidth + if (actionsBeside) Sizes.ActionRailWidth else 0.dp

    /** Mark writes an event only while recording outside a privacy zone. */
    fun markAllowed(status: SessionStatus): Boolean = status is SessionStatus.Recording && !status.snapshot.paused

    /** Paused because a fix showed the phone inside a privacy zone (not because no fix shows where it is). */
    fun pausedInZone(status: SessionStatus): Boolean =
        status is SessionStatus.Recording && status.snapshot.paused && !status.snapshot.waitingForLocation

    /** The running session writes nothing until a location fix shows the phone outside its privacy zones. */
    fun waitingForLocation(status: SessionStatus): Boolean = status is SessionStatus.Recording && status.snapshot.waitingForLocation

    /**
     * A mark accepted now waits, with every other input, for a location fix that shows the phone outside its privacy
     * zones, and a pause may still drop it: the confirmation must say so.
     */
    fun markWaitsForLocation(status: SessionStatus): Boolean =
        status is SessionStatus.Recording && !status.snapshot.paused &&
            (status.snapshot.holdingInputs || status.snapshot.waitingForLocation)

    /** Paused because no location fix showed the phone outside its privacy zones. */
    fun pausedWaitingForLocation(status: SessionStatus): Boolean =
        status is SessionStatus.Recording && status.snapshot.paused && status.snapshot.waitingForLocation

    /** Location services are off, as the Live feed or the running session learnt it: nothing new can be measured. */
    fun locationOff(live: LiveState, status: SessionStatus): Boolean =
        live.locationEnabled == false || (status is SessionStatus.Recording && !status.snapshot.locationEnabled)

    /** The status strip while a session records or saves; null otherwise. */
    fun recordingStrip(status: SessionStatus, live: LiveState): RecordingStrip? {
        val snapshot = when (status) {
            is SessionStatus.Recording -> status.snapshot
            is SessionStatus.Stopping -> status.snapshot
            else -> return null
        }
        val state = when {
            status is SessionStatus.Stopping || snapshot.stopping -> RecordingState.SAVING
            locationOff(live, status) -> RecordingState.LOCATION_OFF
            snapshot.waitingForLocation -> RecordingState.WAITING_FOR_LOCATION
            snapshot.paused -> RecordingState.PAUSED_IN_ZONE
            else -> RecordingState.RECORDING
        }
        val gps = when {
            snapshot.hasRecentFix -> StripGps.FIX
            snapshot.trackRows == 0L && live.lastFix == null -> StripGps.WAITING
            else -> StripGps.LOST
        }
        return RecordingStrip(state = state, freshSamples = snapshot.freshSamples, gps = gps)
    }

    /**
     * A running session that is collecting nothing right now — location off, waiting for a first fix, or paused inside a
     * privacy zone — so the timer button reads "Paused", not "Recording". This keeps the button from saying "Recording"
     * while the status strip says the session is not collecting: the two never contradict each other in one view.
     */
    fun recordingPaused(status: SessionStatus, live: LiveState): Boolean =
        when (recordingStrip(status, live)?.state) {
            RecordingState.LOCATION_OFF, RecordingState.WAITING_FOR_LOCATION, RecordingState.PAUSED_IN_ZONE -> true
            RecordingState.RECORDING, RecordingState.SAVING, null -> false
        }

    /** The session button: busy while the checks or the start call run, then the session's own state. */
    fun buttonState(status: SessionStatus, prestart: PrestartState): SessionButtonState = when (status) {
        is SessionStatus.Idle ->
            if (prestart is PrestartState.Checking || prestart is PrestartState.Starting) SessionButtonState.STARTING else SessionButtonState.IDLE
        is SessionStatus.Starting -> SessionButtonState.STARTING
        is SessionStatus.Recording -> SessionButtonState.RECORDING
        is SessionStatus.Stopping -> SessionButtonState.STOPPING
    }

    private fun noteTone(listener: RadioListener, outcome: ListenerOutcome): StatusTone = when {
        listener == RadioListener.CELL_INFO_REQUEST -> StatusTone.ERROR
        listener == RadioListener.CELL_INFO_PUSH && outcome == ListenerOutcome.MISSING_PERMISSION -> StatusTone.INFO
        else -> StatusTone.WARNING
    }
}
