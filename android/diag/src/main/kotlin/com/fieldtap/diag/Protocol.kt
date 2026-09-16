package com.fieldtap.diag

/**
 * The diag packets FieldTap reads, and the containers a handset wraps them in.
 *
 * A port of the parts of `fieldtap/diag/protocol.py` the handset needs. Log packets are the only
 * thing carrying RRC and NAS, so this file covers them and leaves requests, responses and the debug
 * message formats to the desktop tool.
 *
 * Every multi-byte field is little-endian.
 *
 * Owner: workstream `diag-on-handset`.
 */
object Protocol {

    /** Asynchronous log packet, modem to host. */
    const val DIAG_LOG_F = 0x10

    /** A qmdl2 container holding one or more [DIAG_LOG_F] packets. */
    const val DIAG_MULTI_LOG_F = 0x98

    /** cmd, more, outer length, inner length, log code, timestamp. */
    const val LOG_HEADER_LEN = 16

    /** The entry header inside a log packet: length, code, timestamp. */
    const val LOG_ENTRY_HEADER_LEN = 12

    /** cmd, version, pad, packet count. */
    const val MULTI_LOG_HEADER_LEN = 8

    /** The top nibble of a log code: which subsystem emitted it. */
    fun equipId(logCode: Int): Int = (logCode shr 12) and 0xF

    /** The low 12 bits of a log code: its item within the equipment id. */
    fun logItem(logCode: Int): Int = logCode and 0xFFF

    private fun u16(data: ByteArray, at: Int): Int =
        (data[at].toInt() and 0xFF) or ((data[at + 1].toInt() and 0xFF) shl 8)

    private fun u32(data: ByteArray, at: Int): Long =
        (u16(data, at).toLong()) or (u16(data, at + 2).toLong() shl 16)

    private fun u64(data: ByteArray, at: Int): Long =
        u32(data, at) or (u32(data, at + 4) shl 32)

    /**
     * One log packet: its code, the modem's timestamp, and the body the decoders read.
     *
     * The inner length covers the 12-byte entry header and the body. It is trusted only when it
     * agrees with the bytes that actually arrived; a packet cut short by a truncated capture keeps
     * whatever it has rather than throwing, which is how the Python reader behaves.
     */
    fun parseLogPacket(payload: ByteArray): LogRecord {
        require(payload.size >= LOG_HEADER_LEN && (payload[0].toInt() and 0xFF) == DIAG_LOG_F) {
            "not a log packet"
        }
        val more = payload[1].toInt() and 0xFF
        val innerLen = u16(payload, 4)
        val code = u16(payload, 6)
        val timestampRaw = u64(payload, 8)
        val bodyLen = innerLen - LOG_ENTRY_HEADER_LEN
        val available = payload.size - LOG_HEADER_LEN
        val end = if (bodyLen in 0..available) LOG_HEADER_LEN + bodyLen else payload.size
        return LogRecord(
            code = code,
            timestampRaw = timestampRaw,
            body = payload.copyOfRange(LOG_HEADER_LEN, end),
            more = more,
        )
    }

    /**
     * Every [DIAG_LOG_F] packet inside a qmdl2 container, or nothing when [frame] is not one.
     *
     * `diag_mdlog` on a diag-router handset does not write bare log packets. It wraps them: `0x98`,
     * a version, two pad bytes and a 32-bit count, then that many ordinary log packets end to end.
     * The packets inside are byte-for-byte what the USB stream carries, so everything downstream is
     * unchanged once the wrapper is off.
     *
     * The count is trusted only as far as the bytes allow and each packet is measured by its own
     * length field, so a truncated file yields what it holds.
     */
    fun qmdl2LogPackets(frame: ByteArray): List<ByteArray> {
        if (frame.size < MULTI_LOG_HEADER_LEN || (frame[0].toInt() and 0xFF) != DIAG_MULTI_LOG_F) {
            return emptyList()
        }
        val count = u32(frame, 4)
        val out = ArrayList<ByteArray>()
        var offset = MULTI_LOG_HEADER_LEN
        while (offset + LOG_HEADER_LEN <= frame.size && (count == 0L || out.size < count)) {
            if ((frame[offset].toInt() and 0xFF) != DIAG_LOG_F) return out
            val innerLen = u16(frame, offset + 4)
            if (innerLen < LOG_ENTRY_HEADER_LEN) return out
            // A packet spans its 16-byte header plus the body, and innerLen counts the 12-byte
            // entry header and the body, so the step is innerLen + 4.
            val end = minOf(offset + innerLen + 4, frame.size)
            out.add(frame.copyOfRange(offset, end))
            offset = end
        }
        return out
    }

    /**
     * The log packets in one unframed diag frame, whether it is a bare log packet or a qmdl2
     * container. Anything else — a response, a debug message, an event — yields nothing.
     */
    fun logPacketsOf(frame: ByteArray): List<ByteArray> {
        if (frame.isEmpty()) return emptyList()
        return when (frame[0].toInt() and 0xFF) {
            DIAG_LOG_F -> listOf(frame)
            DIAG_MULTI_LOG_F -> qmdl2LogPackets(frame)
            else -> emptyList()
        }
    }
}

/** One decoded log packet header and its body. */
data class LogRecord(
    /** The 16-bit log code, e.g. 0xB0C0 for LTE RRC OTA. */
    val code: Int,
    /** The modem's own timestamp, in its raw 64-bit form. */
    val timestampRaw: Long,
    val body: ByteArray,
    /** Non-zero when the modem split one logical record across packets. */
    val more: Int = 0,
) {
    val equipId: Int get() = Protocol.equipId(code)

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is LogRecord) return false
        return code == other.code && timestampRaw == other.timestampRaw &&
            more == other.more && body.contentEquals(other.body)
    }

    override fun hashCode(): Int {
        var result = code
        result = 31 * result + timestampRaw.hashCode()
        result = 31 * result + more
        result = 31 * result + body.contentHashCode()
        return result
    }
}
