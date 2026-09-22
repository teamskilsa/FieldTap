package com.fieldtap.ui.signalling

import com.fieldtap.core.radio.Spectrum
import com.fieldtap.diag.CallFlow
import java.util.Locale

/** Which messages the ladder shows. */
enum class FlowFilter { ALL, RRC, NAS }

/** One line of the ladder. */
sealed interface LadderRow {
    /** A stable key for the lazy list. */
    val key: String

    /** The phone moved to another cell here. */
    data class Move(val step: CallFlow.Step) : LadderRow {
        override val key: String get() = "move-${step.event}"
    }

    /** A procedure starts at the next message. */
    data class ProcedureStart(val procedure: CallFlow.Procedure, val ordinal: Int) : LadderRow {
        override val key: String get() = "procedure-$ordinal"
    }

    /**
     * One message, or a run of broadcast messages folded into one line. An idle phone reads SIB1 and paging
     * over and over, and a phone searching for service reads the system information of every cell it hears:
     * one overnight capture held 40,000 of them around 400 messages that mattered.
     */
    data class Message(val event: CallFlow.Event, val repeats: List<CallFlow.Event> = emptyList()) : LadderRow {
        override val key: String get() = "event-${event.index}"
        val count: Int get() = 1 + repeats.size
        val all: List<CallFlow.Event> get() = listOf(event) + repeats

        /** More than one kind of message, or more than one cell, in the run. */
        val mixed: Boolean get() = repeats.any { it.key != event.key || it.cell != event.cell }
    }
}

/**
 * Turns a [CallFlow.Flow] into what the call-flow screen draws, and formats the numbers on it. Kept apart from
 * the composables so the row building — what folds, where banners go — is tested without a device.
 *
 * Owner: workstream `diag-on-handset`.
 */
object CallFlowPresentation {

    private val BROADCAST = setOf("BCCH-BCH", "BCCH-DL-SCH", "MCCH", "PCCH")

    fun rows(flow: CallFlow.Flow, filter: FlowFilter): List<LadderRow> {
        val shown = flow.events.filter {
            when (filter) {
                FlowFilter.ALL -> true
                FlowFilter.RRC -> it.layer == CallFlow.Layer.RRC
                FlowFilter.NAS -> it.layer == CallFlow.Layer.NAS
            }
        }
        val moves = if (filter == FlowFilter.NAS) {
            emptyMap()
        } else {
            flow.journey.filter { it.move != CallFlow.Move.FIRST_SEEN }.associateBy { it.event }
        }
        val starts = flow.procedures.withIndex()
            .filter { (_, p) -> filter == FlowFilter.ALL || p.layer.name == filter.name }
            .groupBy { it.value.first }

        val rows = ArrayList<LadderRow>()
        var index = 0
        while (index < shown.size) {
            val event = shown[index]
            moves[event.index]?.let { rows += LadderRow.Move(it) }
            starts[event.index]?.forEach { rows += LadderRow.ProcedureStart(it.value, it.index) }
            var end = index + 1
            if (event.channel in BROADCAST) {
                while (end < shown.size && foldsInto(event, shown[end], moves, starts)) end++
            }
            rows += LadderRow.Message(event, shown.subList(index + 1, end).toList())
            index = end
        }
        return rows
    }

    private fun foldsInto(
        first: CallFlow.Event,
        next: CallFlow.Event,
        moves: Map<Int, CallFlow.Step>,
        starts: Map<Int, *>,
    ): Boolean = next.channel in BROADCAST && next.index !in moves && next.index !in starts &&
        // Paging is on the serving cell and says the phone is idle there; it does not join a search.
        (next.channel == "PCCH") == (first.channel == "PCCH")

    /** The ladder row a message is on, for scrolling to it. Folded messages land on their run. */
    fun rowOf(rows: List<LadderRow>, eventIndex: Int): Int = rows.indexOfFirst { row ->
        row is LadderRow.Message && (row.event.index == eventIndex || row.repeats.any { it.index == eventIndex })
    }

    /** The cells of a folded run, in the order first heard: "B3 PCI 3, B7 PCI 2 +14". */
    fun cellsOf(row: LadderRow.Message, shown: Int = 2): String {
        val cells = row.all.mapNotNull { it.cell }.distinct()
        val head = cells.take(shown).joinToString(", ") { shortCell(it) }
        return if (cells.size > shown) "$head +${cells.size - shown}" else head
    }

    fun cellCount(row: LadderRow.Message): Int = row.all.mapNotNull { it.cell }.distinct().size

    // MARK: - Procedures

    /** Every attempt at one kind of procedure, and how they went. */
    data class ProcedureGroup(val name: String, val layer: CallFlow.Layer, val items: List<CallFlow.Procedure>) {
        val succeeded: Int get() = items.count { it.outcome == CallFlow.Outcome.SUCCEEDED }
        val failed: Int get() = items.count { it.outcome == CallFlow.Outcome.FAILED }
        val unanswered: Int get() = items.count { it.outcome == CallFlow.Outcome.UNANSWERED }

        /** The median time of the ones that succeeded: what "how long does an attach take here" means. */
        val medianMs: Double?
            get() {
                val times = items.filter { it.outcome == CallFlow.Outcome.SUCCEEDED }.map { it.durationMs }.sorted()
                if (times.isEmpty()) return null
                val mid = times.size / 2
                return if (times.size % 2 == 1) times[mid] else (times[mid - 1] + times[mid]) / 2
            }
    }

    /** Procedures by kind, in the order each kind first happened. */
    fun procedureGroups(flow: CallFlow.Flow): List<ProcedureGroup> =
        flow.procedures.groupBy { it.name }.map { (name, items) -> ProcedureGroup(name, items.first().layer, items) }

    // MARK: - Lanes

    data class Lanes(val phone: String, val ran: String, val core: String)

    fun lanes(flow: CallFlow.Flow): Lanes {
        val rats = flow.events.map { it.rat }.toSet()
        return when {
            rats == setOf("nr") -> Lanes("UE", "gNB", "AMF")
            "nr" in rats -> Lanes("UE", "RAN", "Core")
            else -> Lanes("UE", "eNB", "MME")
        }
    }

    // MARK: - Cells

    /**
     * "B3" for an LTE cell, or null when the EARFCN is in no band this app knows. Always null for NR: NR bands
     * overlap (n77 contains n78), so the ARFCN alone does not name one, and a guessed band would be wrong often.
     */
    fun band(cell: CallFlow.Cell): String? = if (cell.nr) null else Spectrum.lte(cell.earfcn.toInt())?.let { "B${it.band}" }

    /** Downlink centre frequency in MHz, one decimal: TS 36.101 for an EARFCN, the TS 38.104 raster for NR. */
    fun downlinkMhz(cell: CallFlow.Cell): String? {
        val mhz = if (cell.nr) Spectrum.nrMhz(cell.earfcn.toInt()) else Spectrum.lte(cell.earfcn.toInt())?.dlMhz
        return mhz?.let { String.format(Locale.ROOT, "%.1f MHz", it) }
    }

    /** What the cell's channel number is called: EARFCN on LTE, NR-ARFCN on NR. */
    fun channelLabel(cell: CallFlow.Cell): String = if (cell.nr) "NR-ARFCN" else "EARFCN"

    /** "B3 PCI 3", "NR PCI 417", or "EARFCN 70000 PCI 3" when an LTE band is unknown. */
    fun shortCell(cell: CallFlow.Cell): String = when {
        // Contract v1 (D4): an NR RRC header logged before the SCG cell is assigned carries 0xFFFF / 0xFFFFFFFF.
        cell.nr && (cell.pci == 0xFFFF || cell.earfcn == 0xFFFFFFFFL) -> "NR cell pending"
        cell.nr -> "NR PCI ${cell.pci}"
        else -> "${band(cell) ?: "EARFCN ${cell.earfcn}"} PCI ${cell.pci}"
    }

    // MARK: - Time

    /**
     * Since the start of the capture, as a clock: "0:00.064", "1:58.338", "1:02:03.004". Tabular and sortable
     * by eye, which a mix of "64 ms" and "2 min" is not.
     */
    fun sinceStart(ms: Double): String {
        val total = Math.round(ms.coerceAtLeast(0.0))
        val millis = total % 1000
        val seconds = (total / 1000) % 60
        val minutes = (total / 60_000) % 60
        val hours = total / 3_600_000
        return if (hours > 0) {
            String.format(Locale.ROOT, "%d:%02d:%02d.%03d", hours, minutes, seconds, millis)
        } else {
            String.format(Locale.ROOT, "%d:%02d.%03d", minutes, seconds, millis)
        }
    }

    /** A span: "0.4 ms", "67.5 ms", "1.24 s", "2 min 3 s". */
    fun duration(ms: Double): String = when {
        ms < 0 -> duration(0.0)
        ms < 100 -> String.format(Locale.ROOT, "%.1f ms", ms)
        ms < 1000 -> String.format(Locale.ROOT, "%.0f ms", ms)
        ms < 10_000 -> String.format(Locale.ROOT, "%.2f s", ms / 1000)
        ms < 60_000 -> String.format(Locale.ROOT, "%.1f s", ms / 1000)
        ms < 3_600_000 -> "${(ms / 60_000).toLong()} min ${((ms % 60_000) / 1000).toLong()} s"
        else -> "${(ms / 3_600_000).toLong()} h ${((ms % 3_600_000) / 60_000).toLong()} min"
    }

    /** The gap to the message before, or null for the first. */
    fun gap(events: List<CallFlow.Event>, index: Int): Double? =
        if (index <= 0) null else events[index].sinceStartMs - events[index - 1].sinceStartMs

    // MARK: - Bytes

    /** Eight bytes a line — what fits a phone in monospace — with the offset and the printable characters. */
    fun hexDump(bytes: ByteArray, perLine: Int = 8): String = bytes.toList().chunked(perLine).withIndex().joinToString("\n") { (line, chunk) ->
        val hex = chunk.joinToString(" ") { String.format(Locale.ROOT, "%02x", it.toInt() and 0xFF) }.padEnd(perLine * 3 - 1)
        val text = chunk.joinToString("") { b -> (b.toInt() and 0xFF).let { if (it in 0x20..0x7E) it.toChar().toString() else "." } }
        String.format(Locale.ROOT, "%04x  %s  %s", line * perLine, hex, text)
    }

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { String.format(Locale.ROOT, "%02x", it.toInt() and 0xFF) }
}
