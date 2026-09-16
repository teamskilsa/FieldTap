package com.fieldtap.diag

/** One line of a call flow, as the handset can honestly describe it. */
data class SignallingEntry(
    /** The modem's own timestamp, raw; 0 when it did not give one. */
    val timestampRaw: Long,
    val logCode: Int,
    /** "lte" or "nr". */
    val rat: String,
    /** "emm", "esm", "5gmm", "5gsm", or null for a record that is not NAS. */
    val sublayer: String?,
    /** The 3GPP message name, or null when the message was ciphered or is not one we name. */
    val name: String?,
    /** "ul" when the phone sent it, "dl" when it received it. */
    val direction: String?,
    val cause: Int?,
    val causeName: String?,
    /** True when the message was security protected on the air, so its type could not be read. */
    val ciphered: Boolean,
) {
    val isReject: Boolean get() = cause != null

    /** What the row says when there is no message name: why, rather than a blank. */
    val fallback: String
        get() = when {
            ciphered -> "Ciphered ${sublayer ?: "NAS"} message"
            sublayer != null -> "Unnamed $sublayer message"
            else -> LogCodes.of(logCode)?.name ?: "Log 0x%04X".format(logCode)
        }
}

/** What one capture held. */
data class SignallingSummary(
    val entries: List<SignallingEntry>,
    /** Log packets read, including ones with nothing to show. */
    val records: Int,
    /** Frames the CRC rejected. */
    val crcErrors: Int,
) {
    val rejects: List<SignallingEntry> get() = entries.filter { it.isReject }
}

/**
 * Turns a `.qmdl` into a call flow.
 *
 * Reads NAS only. RRC is ASN.1 and needs a decoder this project does not have, so an RRC record is
 * counted and left for the exported file to carry to Wireshark rather than being guessed at on screen.
 * That is the honest split: the phone says what it can read, and hands over what it cannot.
 *
 * A ciphered message keeps its place in the flow with its sublayer and direction, marked as ciphered.
 * Dropping it would make the flow look shorter than it was, and naming it would be invention: the type
 * octet is inside the encryption.
 *
 * Owner: workstream `diag-on-handset`.
 */
object SignallingReader {

    fun read(qmdl: ByteArray): SignallingSummary {
        val unframer = Unframer()
        val entries = ArrayList<SignallingEntry>()
        var records = 0
        for (frame in unframer.feed(qmdl)) {
            for (packet in Protocol.logPacketsOf(frame)) {
                val record = try {
                    Protocol.parseLogPacket(packet)
                } catch (e: IllegalArgumentException) {
                    continue
                }
                records++
                entryOf(record)?.let { entries.add(it) }
            }
        }
        return SignallingSummary(entries, records, unframer.crcErrors)
    }

    private fun entryOf(record: LogRecord): SignallingEntry? {
        val info = LogCodes.of(record.code) ?: return null
        if (info.category != LogCodes.Category.NAS) return null
        val message = Nas.decode(record.body, nr = info.isNr)
        return SignallingEntry(
            timestampRaw = record.timestampRaw,
            logCode = record.code,
            rat = info.rat,
            // The modem's claim stands in when the PDU could not be read at all.
            sublayer = message?.sublayer ?: info.nasSublayer,
            name = message?.name,
            direction = message?.direction ?: info.nasDirection,
            cause = message?.cause,
            causeName = message?.causeName,
            ciphered = info.nasProtected && message?.messageType == null,
        )
    }
}
