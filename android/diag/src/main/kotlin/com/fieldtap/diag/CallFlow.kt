package com.fieldtap.diag

import kotlin.math.abs

/**
 * A capture read the way an engineer reads one: RRC and NAS on one timeline, grouped into the procedures
 * they make up, with the cells the phone moved through.
 *
 * Three things a list of log records does not give, and this does:
 *
 * - **One row per message.** The modem logs most NAS messages twice after security starts: once as sent
 *   over the air (with a MAC and a sequence number) and once in plain text. They are the same message. The
 *   plain copy is the row; the protected copy gives it its security header, MAC and sequence number, and is
 *   matched on content rather than guessed at by time.
 * - **Procedures.** "Attach", "PDN connectivity", "Handover" — each from the message that starts it to the
 *   one that answers it, with how long that took and whether it worked. A procedure the capture never saw
 *   answered says so instead of pretending to have succeeded.
 * - **The cell journey.** Every LTE RRC message carries the PCI and EARFCN it was logged on, so a change of
 *   cell is visible. What kind of change it was comes from what happened just before: a handover command, a
 *   release with a redirect, a re-establishment request on the new cell, or nothing at all while idle — a
 *   reselection.
 *
 * LTE and NR both: NR RRC is decoded by [NrRrc], and 5G NAS is read from the plain log or, failing that, out of
 * the RRC message that carried it. Records no decoder places are counted, and travel to Wireshark in the export.
 *
 * Owner: workstream `diag-on-handset`.
 */
object CallFlow {

    enum class Layer { RRC, NAS }

    /**
     * A cell, as the RRC header names it. [earfcn] is the EARFCN for LTE and the NR-ARFCN for NR: the two are
     * different number spaces, so [nr] travels with it.
     */
    data class Cell(val earfcn: Long, val pci: Int, val nr: Boolean = false)

    /** How a NAS message went over the air, from its security-protected copy. */
    data class Protection(val headerType: Int, val mac: Long, val sequence: Int) {
        val headerName: String
            get() = when (headerType) {
                1 -> "integrity protected"
                2 -> "integrity protected and ciphered"
                3 -> "integrity protected, new security context"
                4 -> "integrity protected and ciphered, new security context"
                else -> "type $headerType"
            }
    }

    /** One message. */
    class Event(
        val index: Int,
        /** 1-based position of the log record in the file, counting every record. */
        val record: Int,
        val logCode: Int,
        val timestampRaw: Long,
        /** Since the first record in the file. */
        val sinceStartMs: Double,
        val layer: Layer,
        /** "lte" or "nr". */
        val rat: String,
        val uplink: Boolean,
        /** What the message is called, for matching: the ASN.1 name for RRC, the 3GPP name for NAS. */
        val key: String,
        /** What the message is called, for reading. */
        val name: String,
        /** The one line under the name: a cause, an APN, a handover target. */
        val summary: String?,
        /** The cell it was on: from its own header for RRC, from the nearest RRC message for NAS. */
        val cell: Cell?,
        /** The logical channel, for RRC; the sublayer, upper-cased, for NAS. */
        val channel: String,
        val fields: List<Field>,
        val cause: Int?,
        val causeName: String?,
        val protection: Protection?,
        /** The type could not be read: ciphered, and no plain copy was logged. */
        val ciphered: Boolean,
        val pdu: ByteArray,
        /** For NAS pulled out of an RRC message: which one. On 5G the RRC message is the only copy there is. */
        val carrier: String? = null,
    ) {
        val isFailure: Boolean
            get() = cause != null || key.contains("reject", ignoreCase = true) || key.contains("failure", ignoreCase = true)

        val isHandoverCommand: Boolean get() = fields.any { it.label == LteRrc.HANDOVER }
    }

    enum class Outcome { SUCCEEDED, FAILED, UNANSWERED }

    /** A request and what answered it. [first] and [last] index [Flow.events]. */
    data class Procedure(
        val name: String,
        val layer: Layer,
        val detail: String?,
        val first: Int,
        val last: Int,
        val outcome: Outcome,
        val durationMs: Double,
        /** What the answer said, when it was a refusal: the reject's cause. */
        val refusal: String? = null,
    )

    enum class Move { FIRST_SEEN, HANDOVER, RESELECTION, REDIRECT, REESTABLISHMENT, CELL_CHANGE }

    /** The phone arrived on [to]. [event] is the first message logged there. */
    data class Step(val move: Move, val from: Cell?, val to: Cell, val event: Int, val sinceStartMs: Double)

    enum class ConnectionOutcome {
        /** Set up and released. */
        RELEASED,

        /** Still connected when the capture ended. */
        OPEN_AT_END,

        /** Set up, then the phone was idle again with no release logged: a radio link failure, typically. */
        LOST,

        /** The network answered the request with a reject. */
        REJECTED,

        /** Nothing answered the request. */
        NO_ANSWER,
    }

    /** One RRC connection or attempt at one, from its request (or the first connected-mode message) to its end. */
    data class Connection(
        val first: Int,
        /** The last message of it; null while the capture ended connected. */
        val last: Int?,
        val establishmentCause: String?,
        val releaseCause: String?,
        val outcome: ConnectionOutcome,
        val startMs: Double,
        val endMs: Double?,
    ) {
        val established: Boolean
            get() = outcome == ConnectionOutcome.RELEASED || outcome == ConnectionOutcome.OPEN_AT_END || outcome == ConnectionOutcome.LOST
    }

    class Flow(
        val events: List<Event>,
        val procedures: List<Procedure>,
        val journey: List<Step>,
        /**
         * Cells whose system information the phone read but never signalled on: what a cell search or a
         * reselection evaluation looks like. Not places the phone was.
         */
        val searched: List<Cell>,
        val connections: List<Connection>,
        /** What the modem's serving-cell records said about a cell: PLMN, tracking area, identity, bandwidth. */
        val cellDetails: Map<Cell, CellInfo.Serving> = emptyMap(),
        /** Every log record in the file. */
        val records: Int,
        /** Signalling records not shown: NR RRC, and NAS no decoder could place. */
        val undecoded: Int,
        val crcErrors: Int,
        /** From the first record to the last. */
        val durationMs: Double,
        /** Wall-clock time of the first record, or null when the modem had no network time. */
        val startUtcMs: Long?,
    ) {
        val failures: Int get() = events.count { it.isFailure }
    }

    // MARK: - Reading

    fun read(qmdl: ByteArray): Flow {
        val unframer = Unframer()
        val reading = Reading()
        for (frame in unframer.feed(qmdl)) {
            for (packet in Protocol.logPacketsOf(frame)) {
                try {
                    reading.add(Protocol.parseLogPacket(packet))
                } catch (e: IllegalArgumentException) {
                    continue
                }
            }
        }
        return reading.build(unframer.crcErrors)
    }

    /** The same, from records already parsed. */
    internal fun of(records: List<LogRecord>): Flow {
        val reading = Reading()
        records.forEach(reading::add)
        return reading.build(crcErrors = 0)
    }

    /** Keeps only the signalling records of a file, numbered as they came, so a long capture is not held whole. */
    private class Reading {
        val kept = ArrayList<Pair<Int, LogRecord>>()
        var count = 0
        var firstRaw = 0L
        var lastRaw = 0L
        var firstAny = 0L
        var lastAny = 0L
        var firstPlausible = 0L
        var lastPlausible = 0L

        fun add(record: LogRecord) {
            count++
            // Contract v1 (D1): an iPhone trace starts with records stamped before the modem had network time,
            // which put every event 46 years after the start. Measure from the first plausible (2005 or later)
            // timestamp when there is one; otherwise, as before, from the first non-zero one.
            if (record.timestampRaw > 0) {
                if (firstAny == 0L) firstAny = record.timestampRaw
                lastAny = record.timestampRaw
                if (utcMs(record.timestampRaw) != null) {
                    if (firstPlausible == 0L) firstPlausible = record.timestampRaw
                    lastPlausible = record.timestampRaw
                }
                firstRaw = if (firstPlausible != 0L) firstPlausible else firstAny
                lastRaw = if (firstPlausible != 0L) lastPlausible else lastAny
            }
            val category = LogCodes.of(record.code)?.category
            if (category == LogCodes.Category.NAS || category == LogCodes.Category.RRC || record.code == SERVING_CELL_INFO) {
                kept += count to record
            }
        }

        fun build(crcErrors: Int): Flow = build(kept, count, crcErrors, firstRaw, lastRaw)
    }

    /** Milliseconds since the GPS epoch, read the way `fieldtap/diag/protocol.py` and the Wireshark export read it. */
    fun modemMs(raw: Long): Double = (raw ushr 16) * 1.25 + (raw and 0xFFFF) / 39_321.6

    private const val GPS_EPOCH_UTC_MS = 315_964_800_000L

    /** 2005-01-01: a modem without network time counts from 1980, and that is not a date to show. */
    private const val PLAUSIBLE_UTC_MS = 1_104_537_600_000L

    fun utcMs(raw: Long): Long? {
        if (raw <= 0) return null
        val utc = GPS_EPOCH_UTC_MS + modemMs(raw).toLong()
        return utc.takeIf { it >= PLAUSIBLE_UTC_MS }
    }

    // MARK: - Building

    private class Draft(
        val record: Int,
        val logCode: Int,
        val timestampRaw: Long,
        val layer: Layer,
        val rat: String,
        val uplink: Boolean,
        val key: String,
        val name: String,
        var cell: Cell?,
        val channel: String,
        val fields: List<Field>,
        val cause: Int?,
        val causeName: String?,
        var protection: Protection?,
        val ciphered: Boolean,
        val pdu: ByteArray,
        /** For a security-protected copy: the message inside, to find its plain twin. */
        val inner: ByteArray? = null,
        val plain: Boolean = false,
        var carrier: String? = null,
    ) {
        var dropped = false
    }

    private fun build(records: List<Pair<Int, LogRecord>>, count: Int, crcErrors: Int, firstRaw: Long, lastRaw: Long): Flow {
        val drafts = ArrayList<Draft>()
        val cellDetails = LinkedHashMap<Cell, CellInfo.Serving>()
        var undecoded = 0
        for ((number, record) in records) {
            if (record.code == SERVING_CELL_INFO) {
                CellInfo.serving(record.body)?.let { cellDetails[Cell(it.downlinkEarfcn, it.pci)] = it }
                continue
            }
            val info = LogCodes.of(record.code) ?: continue
            val made = when {
                record.code == 0xB0C0 -> listOfNotNull(rrcDraft(number, record))
                record.code == 0xB821 -> nrDrafts(number, record)
                info.category == LogCodes.Category.RRC -> emptyList()
                else -> listOfNotNull(nasDraft(number, record, info))
            }
            if (made.isEmpty()) undecoded++ else drafts += made
        }
        pairProtectedCopies(drafts)
        pairCarriedCopies(drafts)

        val kept = drafts.filterNot { it.dropped }
        val rrcCells = kept.mapIndexedNotNull { i, d -> d.cell?.takeIf { d.channel in SERVING_CHANNELS }?.let { i to it } }
        val startMs = if (firstRaw > 0) modemMs(firstRaw) else 0.0
        val events = kept.mapIndexed { i, d ->
            val cell = d.cell ?: nearestCell(rrcCells, i, d.uplink)
            Event(
                index = i,
                record = d.record,
                logCode = d.logCode,
                timestampRaw = d.timestampRaw,
                sinceStartMs = if (d.timestampRaw > 0 && firstRaw > 0) modemMs(d.timestampRaw) - startMs else 0.0,
                layer = d.layer,
                rat = d.rat,
                uplink = d.uplink,
                key = d.key,
                name = d.name,
                summary = summaryOf(d.fields, d.cause, d.causeName),
                cell = cell,
                channel = d.channel,
                fields = d.fields,
                cause = d.cause,
                causeName = d.causeName,
                protection = d.protection,
                ciphered = d.ciphered,
                pdu = d.pdu,
                carrier = d.carrier,
            )
        }
        val journey = journey(events).map { step -> step.copy(event = firstOnCell(events, step)) }
        val visited = journey.map { it.to }.toSet()
        return Flow(
            events = events,
            procedures = procedures(events),
            journey = journey,
            searched = events.filter { it.layer == Layer.RRC && it.channel in BROADCAST_CHANNELS }
                .mapNotNull { it.cell }
                .filterNot { it in visited }
                .distinct(),
            connections = connections(events),
            cellDetails = cellDetails,
            records = count,
            undecoded = undecoded,
            crcErrors = crcErrors,
            durationMs = if (firstRaw > 0 && lastRaw > 0) modemMs(lastRaw) - startMs else 0.0,
            startUtcMs = utcMs(firstRaw),
        )
    }

    private fun rrcDraft(number: Int, record: LogRecord): Draft? {
        val message = LteRrc.decode(record.body) ?: return null
        val channel = message.channel ?: return null
        val asn1 = message.asn1Name ?: return null
        return Draft(
            record = number,
            logCode = record.code,
            timestampRaw = record.timestampRaw,
            layer = Layer.RRC,
            rat = "lte",
            uplink = channel.uplink,
            key = asn1,
            name = LteRrc.readable(asn1),
            cell = Cell(message.earfcn, message.pci),
            channel = channel.label,
            fields = message.fields,
            cause = null,
            causeName = null,
            protection = null,
            ciphered = false,
            pdu = message.payload,
        )
    }

    private const val SERVING_CELL_INFO = 0xB0C2

    /**
     * An NR RRC message, and the 5G NAS message inside it when it carried one. The NAS row takes the RRC
     * message's direction and cell, and says which message carried it.
     */
    private fun nrDrafts(number: Int, record: LogRecord): List<Draft> {
        val message = NrRrc.decode(record.body) ?: return emptyList()
        val channel = message.channel ?: return emptyList()
        val asn1 = message.asn1Name ?: return emptyList()
        val cell = Cell(message.arfcn, message.pci, nr = true)
        val rrc = Draft(
            record = number,
            logCode = record.code,
            timestampRaw = record.timestampRaw,
            layer = Layer.RRC,
            rat = "nr",
            uplink = channel.uplink,
            key = asn1,
            name = NrRrc.readable(asn1),
            cell = cell,
            channel = channel.label,
            fields = message.fields,
            cause = null,
            causeName = null,
            protection = null,
            ciphered = false,
            pdu = message.payload,
        )
        val nas = message.nas ?: return listOf(rrc)
        return listOfNotNull(rrc, carriedNas(number, record, nas, channel.uplink, cell, NrRrc.readable(asn1)))
    }

    /**
     * 5G NAS as it went over the air. After security starts it is protected: the 5GS header is EPD, security
     * header, MAC (4) and sequence number, then the message — readable when only integrity-protected, ciphered
     * otherwise, and with no plain copy logged on this modem to fall back on.
     */
    private fun carriedNas(number: Int, record: LogRecord, pdu: ByteArray, uplink: Boolean, cell: Cell, carrier: String): Draft? {
        val outer = Nas.decodePdu(pdu, nr = true) ?: return null
        var protection: Protection? = null
        var message = outer
        var body = pdu
        if (outer.sublayer == "5gmm" && outer.securityHeader in 1..4 && pdu.size > 7) {
            protection = Protection(
                headerType = outer.securityHeader,
                mac = ((pdu[2].toLong() and 0xFF) shl 24) or ((pdu[3].toLong() and 0xFF) shl 16) or
                    ((pdu[4].toLong() and 0xFF) shl 8) or (pdu[5].toLong() and 0xFF),
                sequence = pdu[6].toInt() and 0xFF,
            )
            val inner = pdu.copyOfRange(7, pdu.size)
            Nas.decodePdu(inner, nr = true)?.takeIf { it.securityHeader == 0 && it.name != null }?.let {
                message = it
                body = inner
            }
        }
        val readable = message.securityHeader == 0 && message.messageType != null
        return Draft(
            record = number,
            logCode = record.code,
            timestampRaw = record.timestampRaw,
            layer = Layer.NAS,
            rat = "nr",
            uplink = uplink,
            key = if (readable) message.name ?: "unnamed" else "ciphered",
            name = if (readable) message.name ?: "5GS message 0x%02X".format(message.messageType)
            else "Ciphered ${outer.sublayer.uppercase()} message",
            cell = cell,
            channel = message.sublayer.uppercase(),
            fields = if (readable) NasFields.fiveGs(message.sublayer, 0, message.messageType, body, uplink) else emptyList(),
            cause = message.cause,
            causeName = message.causeName,
            protection = protection,
            ciphered = !readable,
            pdu = pdu,
            inner = body.takeIf { it !== pdu },
            carrier = carrier,
        )
    }

    private fun nasDraft(number: Int, record: LogRecord, info: LogCodes.Info): Draft? {
        val nr = info.isNr
        val message = Nas.decode(record.body, nr) ?: return null
        val pdu = record.body.copyOfRange(message.offset, record.body.size)
        val logged = info.nasDirection ?: message.direction ?: "ul"

        // A protected copy: header, MAC (4), sequence number (1), then the message. 5GS puts the EPD first.
        val headerAt = if (nr) 1 else 0
        val sec = message.securityHeader
        if (info.nasProtected && sec in 1..4 && pdu.size > headerAt + 6) {
            val macAt = headerAt + 1
            val protection = Protection(
                headerType = sec,
                mac = ((pdu[macAt].toLong() and 0xFF) shl 24) or ((pdu[macAt + 1].toLong() and 0xFF) shl 16) or
                    ((pdu[macAt + 2].toLong() and 0xFF) shl 8) or (pdu[macAt + 3].toLong() and 0xFF),
                sequence = pdu[macAt + 4].toInt() and 0xFF,
            )
            val inner = pdu.copyOfRange(macAt + 5, pdu.size)
            // Qualcomm logs the protected copy after deciphering, so the message inside is usually readable.
            val readable = Nas.decodePdu(inner, nr)?.takeIf { it.name != null && it.securityHeader == 0 }
            return if (readable != null) {
                nasOf(number, record, info, readable, inner, logged, nr).copyAs(protection = protection, inner = inner)
            } else {
                Draft(
                    record = number, logCode = record.code, timestampRaw = record.timestampRaw, layer = Layer.NAS,
                    rat = info.rat, uplink = logged == "ul", key = "ciphered",
                    name = "Ciphered ${message.sublayer.uppercase()} message", cell = null,
                    channel = message.sublayer.uppercase(), fields = emptyList(), cause = null, causeName = null,
                    protection = protection, ciphered = true, pdu = pdu, inner = inner,
                )
            }
        }
        return nasOf(number, record, info, message, pdu, logged, nr)
    }

    private fun nasOf(number: Int, record: LogRecord, info: LogCodes.Info, message: Nas.Message, pdu: ByteArray, logged: String, nr: Boolean): Draft {
        val uplink = (message.direction ?: logged) == "ul"
        val fields = if (nr) {
            NasFields.fiveGs(message.sublayer, message.securityHeader, message.messageType, pdu, uplink)
        } else {
            NasFields.eps(message.sublayer, message.securityHeader, message.messageType, pdu, uplink)
        }
        val name = message.name ?: if (message.messageType == null) {
            "Ciphered ${message.sublayer.uppercase()} message"
        } else {
            "${message.sublayer.uppercase()} message 0x%02X".format(message.messageType)
        }
        return Draft(
            record = number,
            logCode = record.code,
            timestampRaw = record.timestampRaw,
            layer = Layer.NAS,
            rat = info.rat,
            uplink = uplink,
            key = message.name ?: "unnamed",
            name = name,
            cell = null,
            channel = message.sublayer.uppercase(),
            fields = fields,
            cause = message.cause,
            causeName = message.causeName,
            protection = null,
            ciphered = message.messageType == null && message.securityHeader != 12,
            pdu = pdu,
            plain = !info.nasProtected,
        )
    }

    private fun Draft.copyAs(protection: Protection, inner: ByteArray) = Draft(
        record, logCode, timestampRaw, layer, rat, uplink, key, name, cell, channel, fields, cause, causeName,
        protection, ciphered, pdu, inner, plain = false,
    )

    /**
     * The modem logs a protected copy and a plain copy of the same message, in either order and a few records
     * apart. The plain copy stays and takes the protection; the protected copy goes. A protected copy with no
     * plain twin stays as its own row.
     */
    private fun pairProtectedCopies(drafts: List<Draft>) {
        for ((i, secured) in drafts.withIndex()) {
            val inner = secured.inner ?: continue
            if (secured.plain) continue
            val window = (maxOf(0, i - WINDOW) until minOf(drafts.size, i + WINDOW + 1))
            val twin = window.asSequence()
                .map { drafts[it] }
                .firstOrNull { plain ->
                    plain.plain && plain.protection == null && plain.uplink == secured.uplink &&
                        plain.pdu.contentEquals(inner) && closeInTime(plain, secured)
                } ?: continue
            twin.protection = secured.protection
            secured.dropped = true
        }
    }

    private const val WINDOW = 8

    /**
     * 5G NAS pulled out of an RRC message is usually also logged plain (0xB80A/0xB80B) a record or two away.
     * The plain copy stays — after security starts it is the only readable one — and takes from the carried
     * copy what only it knows: which RRC message carried it, on which cell, and its protection. A carried copy
     * with no plain twin stays as its own row.
     */
    private fun pairCarriedCopies(drafts: List<Draft>) {
        for ((i, carried) in drafts.withIndex()) {
            if (carried.carrier == null || carried.plain || carried.dropped) continue
            val window = (maxOf(0, i - WINDOW) until minOf(drafts.size, i + WINDOW + 1))
            val twin = window.asSequence()
                .map { drafts[it] }
                .firstOrNull { plain ->
                    plain !== carried && plain.plain && plain.carrier == null && plain.uplink == carried.uplink &&
                        (plain.pdu.contentEquals(carried.pdu) || plain.pdu.contentEquals(carried.inner ?: ByteArray(0))) &&
                        closeInTime(plain, carried)
                } ?: continue
            twin.carrier = carried.carrier
            twin.cell = carried.cell
            if (twin.protection == null) twin.protection = carried.protection
            carried.dropped = true
        }
    }

    private fun closeInTime(a: Draft, b: Draft): Boolean =
        a.timestampRaw <= 0 || b.timestampRaw <= 0 || abs(modemMs(a.timestampRaw) - modemMs(b.timestampRaw)) <= 2_000

    /**
     * The cell a NAS message went over. The modem logs an uplink NAS message just before the RRC message that
     * carries it, and a downlink one just after, so uplink looks forward and downlink back. Looking back for an
     * uplink message put the tracking area update that followed a reselection on the cell the phone had left.
     */
    private fun nearestCell(cells: List<Pair<Int, Cell>>, index: Int, uplink: Boolean): Cell? {
        val before = cells.lastOrNull { it.first < index }?.second
        val after = cells.firstOrNull { it.first > index }?.second
        return if (uplink) after ?: before else before ?: after
    }

    // MARK: - The line under the name

    private fun summaryOf(fields: List<Field>, cause: Int?, causeName: String?): String? {
        if (cause != null) return listOfNotNull("#$cause", causeName).joinToString(" ")
        val parts = fields.mapNotNull { f ->
            when (f.label) {
                "Establishment cause", "Release cause", "Attach type", "Detach type", "Update type",
                "Identity requested", "APN", "PDN address", "Wait time", "Cause", "Ciphering", "Integrity",
                "Carries", "Registration type", "Registration result", "Service type", "Deregistration",
                "PDU session type",
                -> f.value

                "T3502", "T3346" -> "${f.label} ${f.value}"

                "Redirected to" -> "redirect to ${f.value}"
                LteRrc.HANDOVER -> if (f.value == "command") "handover command" else "handover ${f.value}"
                "Serving RSRP" -> "RSRP ${f.value}"
                "Neighbours" -> "${f.value.substringBefore(' ')} neighbours"
                "QCI" -> "QCI ${f.value}"
                "Switch off" -> "switch off".takeIf { f.value == "yes" }
                else -> null
            }
        }
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }

    // MARK: - Procedures

    private class Rule(
        val name: String,
        val starts: Set<String>,
        val succeeds: Set<String>,
        val fails: Set<String> = emptySet(),
    )

    // The same moments of a connection under their LTE and NR names.
    private val REQUESTS = setOf("rrcConnectionRequest", "rrcSetupRequest", "rrcResumeRequest", "rrcResumeRequest1")
    private val SETUPS = setOf("rrcConnectionSetup", "rrcSetup", "rrcResume")
    private val RELEASES = setOf("rrcConnectionRelease", "rrcRelease")
    private val REJECTS = setOf("rrcConnectionReject", "rrcReject")
    private val REESTABLISHMENT_REQUESTS = setOf("rrcConnectionReestablishmentRequest", "rrcReestablishmentRequest")
    private val REESTABLISHMENTS = setOf("rrcConnectionReestablishment", "rrcReestablishment")

    private val RULES = listOf(
        Rule(
            "RRC connection setup",
            setOf("rrcConnectionRequest", "rrcSetupRequest"),
            setOf("rrcConnectionSetupComplete", "rrcSetupComplete"),
            setOf("rrcConnectionReject", "rrcReject"),
        ),
        Rule(
            "RRC re-establishment",
            REESTABLISHMENT_REQUESTS,
            setOf("rrcConnectionReestablishmentComplete", "rrcReestablishmentComplete"),
            setOf("rrcConnectionReestablishmentReject"),
        ),
        Rule("RRC resume", setOf("rrcResumeRequest", "rrcResumeRequest1"), setOf("rrcResumeComplete"), setOf("rrcReject")),
        Rule("AS security", setOf("securityModeCommand"), setOf("securityModeComplete"), setOf("securityModeFailure")),
        Rule("UE capability", setOf("ueCapabilityEnquiry"), setOf("ueCapabilityInformation")),
        Rule(
            RECONFIGURATION,
            setOf("rrcConnectionReconfiguration", "rrcReconfiguration"),
            setOf("rrcConnectionReconfigurationComplete", "rrcReconfigurationComplete"),
            REESTABLISHMENT_REQUESTS,
        ),
        Rule("Attach", setOf("Attach request"), setOf("Attach accept"), setOf("Attach reject")),
        // An EPS service request is answered by the RAN starting security, not by a NAS accept.
        Rule(
            "Service request",
            setOf("Service request", "Extended service request"),
            setOf("Service accept", "securityModeCommand"),
            setOf("Service reject"),
        ),
        Rule("Tracking area update", setOf("Tracking area update request"), setOf("Tracking area update accept"), setOf("Tracking area update reject")),
        Rule("Detach", setOf("Detach request"), setOf("Detach accept")),
        Rule("Authentication", setOf("Authentication request"), setOf("Authentication response"), setOf("Authentication failure", "Authentication reject")),
        Rule("NAS security", setOf("Security mode command"), setOf("Security mode complete"), setOf("Security mode reject")),
        Rule("Identity", setOf("Identity request"), setOf("Identity response")),
        Rule(
            "PDN connectivity",
            setOf("PDN connectivity request"),
            setOf("Activate default EPS bearer context accept"),
            setOf("PDN connectivity reject", "Activate default EPS bearer context reject"),
        ),
        Rule(
            "Dedicated bearer",
            setOf("Activate dedicated EPS bearer context request"),
            setOf("Activate dedicated EPS bearer context accept"),
            setOf("Activate dedicated EPS bearer context reject"),
        ),
        Rule("Bearer modification", setOf("Modify EPS bearer context request"), setOf("Modify EPS bearer context accept"), setOf("Modify EPS bearer context reject")),
        Rule("Bearer deactivation", setOf("Deactivate EPS bearer context request"), setOf("Deactivate EPS bearer context accept")),
        Rule("PDN disconnect", setOf("PDN disconnect request"), setOf("Deactivate EPS bearer context accept"), setOf("PDN disconnect reject")),
        Rule("ESM information", setOf("ESM information request"), setOf("ESM information response")),
        Rule("Registration", setOf("Registration request"), setOf("Registration accept"), setOf("Registration reject")),
        Rule(
            "Deregistration",
            setOf("Deregistration request (UE originating)", "Deregistration request (UE terminated)"),
            setOf("Deregistration accept (UE originating)", "Deregistration accept (UE terminated)"),
        ),
        Rule("PDU session establishment", setOf("PDU session establishment request"), setOf("PDU session establishment accept"), setOf("PDU session establishment reject")),
        Rule("PDU session release", setOf("PDU session release request"), setOf("PDU session release command")),
    )

    private const val RECONFIGURATION = "RRC reconfiguration"


    private class Open(val rule: Rule, val name: String, val start: Event)

    private fun procedures(events: List<Event>): List<Procedure> {
        val done = ArrayList<Procedure>()
        val open = ArrayList<Open>()
        fun close(o: Open, end: Event, outcome: Outcome) {
            open.remove(o)
            done += Procedure(
                name = o.name,
                layer = o.start.layer,
                detail = o.start.summary,
                first = o.start.index,
                last = end.index,
                outcome = outcome,
                durationMs = end.sinceStartMs - o.start.sinceStartMs,
                refusal = if (outcome == Outcome.FAILED) end.summary ?: end.name else null,
            )
        }
        for (event in events) {
            for (o in open.toList()) {
                // Contract v1 (D3): a procedure is answered only on the RAT it started on. On EN-DC the NR
                // RRCReconfiguration rides inside the LTE one; without this it closed the LTE one as unanswered.
                if (o.start.rat != event.rat) continue
                when (event.key) {
                    in o.rule.succeeds -> close(o, event, Outcome.SUCCEEDED)
                    in o.rule.fails -> close(o, event, Outcome.FAILED)
                }
            }
            val rule = RULES.firstOrNull { event.key in it.starts } ?: continue
            // A second start before the first was answered: the first never was.
            open.filter { it.rule === rule && it.start.rat == event.rat }.forEach { close(it, it.start, Outcome.UNANSWERED) }
            val name = if (rule.name == RECONFIGURATION && event.isHandoverCommand) "Handover" else rule.name
            val started = Open(rule, name, event)
            open += started
            // A phone switching off does not wait to be told it may.
            if (rule.name == "Detach" && event.uplink && event.fields.any { it.label == "Switch off" && it.value == "yes" }) {
                close(started, event, Outcome.SUCCEEDED)
            }
        }
        open.toList().forEach { close(it, it.start, Outcome.UNANSWERED) }
        return done.sortedBy { it.first }
    }

    // MARK: - Cells and connections

    private val CONNECTED_CHANNELS = setOf("UL-DCCH", "DL-DCCH")

    /**
     * Channels a phone only uses on the cell it is camped on or connected to. System information is not one:
     * a phone searching for service reads SIB1 from every cell it can hear, and counting those as cells it
     * was on turned one lost-coverage minute into forty "cell changes".
     */
    private val SERVING_CHANNELS = setOf("UL-CCCH", "DL-CCCH", "UL-DCCH", "DL-DCCH", "PCCH")

    private val BROADCAST_CHANNELS = setOf("BCCH-BCH", "BCCH-DL-SCH", "MCCH")

    /** A step starts at the RRC message that showed the new cell; the NAS messages just before it were on that cell too. */
    private fun firstOnCell(events: List<Event>, step: Step): Int {
        var first = step.event
        while (first > 0 && events[first - 1].layer == Layer.NAS && events[first - 1].cell == step.to) first--
        return first
    }

    private fun journey(events: List<Event>): List<Step> {
        val steps = ArrayList<Step>()
        var current: Cell? = null
        var connected = false
        var handoverPending = false
        var redirectPending = false
        for (event in events) {
            if (event.layer != Layer.RRC || event.channel !in SERVING_CHANNELS) continue
            val cell = event.cell ?: continue
            if (current == null) {
                steps += Step(Move.FIRST_SEEN, null, cell, event.index, event.sinceStartMs)
            } else if (cell != current) {
                val move = when {
                    event.key in REESTABLISHMENT_REQUESTS -> Move.REESTABLISHMENT
                    handoverPending -> Move.HANDOVER
                    redirectPending -> Move.REDIRECT
                    // A phone asks for a connection, and listens for paging, only when it has none — whatever
                    // the log last showed. Connections end without a logged release more often than not.
                    !connected || event.key in REQUESTS || event.channel == "PCCH" -> Move.RESELECTION
                    else -> Move.CELL_CHANGE
                }
                steps += Step(move, current, cell, event.index, event.sinceStartMs)
                handoverPending = false
                redirectPending = false
                // A request on a new cell after an unanswered one on the old: the phone was idle all along.
                if (move == Move.RESELECTION || move == Move.REDIRECT) connected = false
            }
            current = cell
            when {
                event.key in RELEASES -> {
                    connected = false
                    handoverPending = false
                    redirectPending = event.fields.any { it.label == "Redirected to" }
                }
                event.key in REJECTS || event.channel == "PCCH" -> connected = false
                event.isHandoverCommand -> handoverPending = true
                // A request alone is not a connection: plenty go unanswered.
                event.key in SETUPS || event.key in REESTABLISHMENTS || event.channel in CONNECTED_CHANNELS -> connected = true
            }
        }
        return steps
    }

    private fun connections(events: List<Event>): List<Connection> {
        val out = ArrayList<Connection>()
        var request: Event? = null
        var requestCause: String? = null
        var open: Event? = null
        var openCause: String? = null
        var lastOfOpen: Event? = null

        fun causeOf(e: Event) = e.fields.firstOrNull { it.label == "Establishment cause" }?.value
        fun unanswered() {
            request?.let { out += Connection(it.index, it.index, requestCause, null, ConnectionOutcome.NO_ANSWER, it.sinceStartMs, it.sinceStartMs) }
            request = null
        }
        fun lost() {
            val start = open ?: return
            val end = lastOfOpen ?: start
            out += Connection(start.index, end.index, openCause, null, ConnectionOutcome.LOST, start.sinceStartMs, end.sinceStartMs)
            open = null
        }

        for (event in events) {
            if (event.layer != Layer.RRC) continue
            when (event.key) {
                in REQUESTS -> {
                    unanswered()
                    lost()
                    request = event
                    requestCause = causeOf(event)
                }
                in SETUPS -> {
                    lost()
                    open = request ?: event
                    openCause = if (request != null) requestCause else null
                    lastOfOpen = event
                    request = null
                }
                in REJECTS -> request?.let {
                    out += Connection(it.index, event.index, requestCause, null, ConnectionOutcome.REJECTED, it.sinceStartMs, event.sinceStartMs)
                    request = null
                }
                in RELEASES -> {
                    val start = open ?: event
                    out += Connection(
                        start.index, event.index, if (open != null) openCause else null,
                        event.fields.firstOrNull { it.label == "Release cause" }?.value,
                        ConnectionOutcome.RELEASED, start.sinceStartMs, event.sinceStartMs,
                    )
                    open = null
                }
                else -> if (event.channel in CONNECTED_CHANNELS) {
                    // Connected-mode traffic with no setup seen: the connection began before the capture did.
                    if (open == null) {
                        open = event
                        openCause = null
                    }
                    lastOfOpen = event
                }
            }
        }
        unanswered()
        open?.let { out += Connection(it.index, null, openCause, null, ConnectionOutcome.OPEN_AT_END, it.sinceStartMs, null) }
        return out.sortedBy { it.first }
    }
}
