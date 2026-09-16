package com.fieldtap.diag

/**
 * NAS messages, and the cause when the network refuses something.
 *
 * NAS is why this can run on a handset at all. RRC is ASN.1 and needs a full decoder; NAS is a
 * protocol discriminator, a message type and type-length-value fields, so the message and its cause
 * can be read directly from the bytes. That covers the questions a field engineer actually asks of a
 * failing phone — did it attach, and if not, what did the network say.
 *
 * The PDU is found rather than assumed. The header in front of it differs by modem generation, so
 * [locate] tries the offsets those generations use and keeps the first one where a valid NAS header
 * starts, falling back to a short scan. This is the approach in `fieldtap/decode/nas.py` and the
 * reason a new modem does not silently produce nonsense.
 *
 * A ciphered message yields its sublayer and security header but no type: the type octet is inside
 * the encrypted part. That is reported as unknown rather than guessed.
 *
 * Owner: workstream `diag-on-handset`.
 */
object Nas {

    const val EPD_5GMM = 0x7E
    const val EPD_5GSM = 0x2E
    const val PD_EMM = 0x07
    const val PD_ESM = 0x02

    /** Header sizes seen in front of an LTE NAS PDU, most likely first. */
    private val LTE_OFFSETS = intArrayOf(4, 3, 5, 6, 8)

    /** Header sizes seen in front of an NR NAS PDU, most likely first. */
    private val NR_OFFSETS = intArrayOf(4, 7, 8, 5, 6, 12, 16)

    private val ESM_TYPES = 0xC1..0xEB
    private val FIVE_GSM_TYPES = 0xC1..0xD6

    /** How the PDU was found: straight from the table, by trying another offset, or by scanning. */
    enum class Located { TABLE, PROBED, SCANNED }

    /** What one NAS PDU says. */
    data class Message(
        /** "emm", "esm", "5gmm" or "5gsm". */
        val sublayer: String,
        /** The security header type; 0 is plain. */
        val securityHeader: Int,
        /** Null when the message is ciphered, so the type octet cannot be read. */
        val messageType: Int?,
        val name: String?,
        /** "ul", "dl", or null when the type alone does not say. */
        val direction: String?,
        /** The 3GPP cause, when this message carries one. */
        val cause: Int?,
        val causeName: String?,
        /** Where the PDU started inside the log record body. */
        val offset: Int,
        val located: Located,
    ) {
        /** True when the network refused something and said why. */
        val isReject: Boolean get() = cause != null
    }

    private fun looksLikeEps(p: ByteArray, from: Int): Boolean {
        if (p.size - from < 2) return false
        val head = p[from].toInt() and 0xFF
        val pd = head and 0x0F
        val sec = head shr 4
        return when (pd) {
            PD_EMM -> sec in intArrayOf(0, 1, 2, 3, 4, 12)
            PD_ESM -> p.size - from >= 3 && (p[from + 2].toInt() and 0xFF) in ESM_TYPES
            else -> false
        }
    }

    private fun looksLike5gs(p: ByteArray, from: Int): Boolean {
        if (p.size - from < 3) return false
        return when (p[from].toInt() and 0xFF) {
            EPD_5GMM -> (p[from + 1].toInt() and 0xFF) in intArrayOf(0, 1, 2, 3, 4)
            EPD_5GSM -> p.size - from >= 4 && (p[from + 3].toInt() and 0xFF) in FIVE_GSM_TYPES
            else -> false
        }
    }

    private fun Int.isIn(values: IntArray) = values.contains(this)

    /** Where the NAS PDU starts inside [body], or null when none is recognisable. */
    private fun locate(body: ByteArray, nr: Boolean): Pair<Int, Located>? {
        val offsets = if (nr) NR_OFFSETS else LTE_OFFSETS
        val looks: (ByteArray, Int) -> Boolean = if (nr) ::looksLike5gs else ::looksLikeEps
        for ((index, candidate) in offsets.withIndex()) {
            if (candidate < body.size && looks(body, candidate)) {
                return candidate to if (index == 0) Located.TABLE else Located.PROBED
            }
        }
        for (candidate in 1 until minOf(24, body.size)) {
            if (looks(body, candidate)) return candidate to Located.SCANNED
        }
        return null
    }

    /** (sublayer, security header, message type) for an EPS PDU. */
    private fun classifyEps(p: ByteArray): Triple<String, Int, Int?> {
        val head = p[0].toInt() and 0xFF
        val pd = head and 0x0F
        val sec = head shr 4
        if (pd == PD_ESM) return Triple("esm", 0, if (p.size > 2) p[2].toInt() and 0xFF else null)
        if (sec == 0) return Triple("emm", 0, if (p.size > 1) p[1].toInt() and 0xFF else null)
        // Service request carries a short header and no type octet.
        if (sec == 12) return Triple("emm", 12, null)
        val innerAt = 6
        if (sec == 1 || sec == 3) {
            if (p.size - innerAt >= 2) {
                val ih = p[innerAt].toInt() and 0xFF
                if (ih and 0x0F == PD_EMM && ih shr 4 == 0) {
                    return Triple("emm", sec, p[innerAt + 1].toInt() and 0xFF)
                }
                if (p.size - innerAt >= 3 && ih and 0x0F == PD_ESM) {
                    return Triple("esm", sec, p[innerAt + 2].toInt() and 0xFF)
                }
            }
        }
        return Triple("emm", sec, null)
    }

    /** (sublayer, security header, message type) for a 5GS PDU. */
    private fun classify5gs(p: ByteArray): Triple<String, Int, Int?> {
        if ((p[0].toInt() and 0xFF) == EPD_5GSM) {
            return Triple("5gsm", 0, if (p.size > 3) p[3].toInt() and 0xFF else null)
        }
        val sec = p[1].toInt() and 0xFF
        if (sec == 0) return Triple("5gmm", 0, if (p.size > 2) p[2].toInt() and 0xFF else null)
        val innerAt = 7
        if (sec == 1 || sec == 3) {
            if (p.size - innerAt >= 3) {
                val ih = p[innerAt].toInt() and 0xFF
                if (ih == EPD_5GMM && (p[innerAt + 1].toInt() and 0xFF) == 0) {
                    return Triple("5gmm", sec, p[innerAt + 2].toInt() and 0xFF)
                }
                if (p.size - innerAt >= 4 && ih == EPD_5GSM) {
                    return Triple("5gsm", sec, p[innerAt + 3].toInt() and 0xFF)
                }
            }
        }
        return Triple("5gmm", sec, null)
    }

    /**
     * The cause carried by a plain reject, or null.
     *
     * In every message below the cause is the mandatory octet straight after the message type, so it
     * is read from a fixed place rather than by walking the IEs: EMM and ESM put the type second in
     * the PDU, 5GMM and 5GSM third and fourth. A ciphered message has no readable type and so no
     * readable cause.
     */
    private fun causeOf(sublayer: String, securityHeader: Int, msgType: Int?, pdu: ByteArray): Int? {
        if (securityHeader != 0 || msgType == null) return null
        val at = when (sublayer) {
            "emm" -> if (msgType in intArrayOf(0x44, 0x4B, 0x4E)) 2 else return null
            "esm" -> if (msgType in intArrayOf(0xC3, 0xC7, 0xCB, 0xD1, 0xD3, 0xD5, 0xD7)) 3 else return null
            "5gmm" -> if (msgType in intArrayOf(0x44, 0x4D)) 3 else return null
            "5gsm" -> if (msgType in intArrayOf(0xC5, 0xC7, 0xCA)) 4 else return null
            else -> return null
        }
        return if (at < pdu.size) pdu[at].toInt() and 0xFF else null
    }

    private operator fun IntArray.contains(v: Int): Boolean {
        for (x in this) if (x == v) return true
        return false
    }

    /**
     * Read the NAS PDU out of a log record [body], or null when there is none.
     *
     * [nr] selects the 5GS reading; false reads EPS.
     */
    fun decode(body: ByteArray, nr: Boolean): Message? {
        val found = locate(body, nr) ?: return null
        val (offset, located) = found
        val pdu = body.copyOfRange(offset, body.size)
        val (sublayer, sec, msgType) = if (nr) classify5gs(pdu) else classifyEps(pdu)
        val named = if (sublayer == "emm" && sec == 12) {
            "Service request" to "ul"
        } else {
            NasNames.message(sublayer, msgType)
        }
        val cause = causeOf(sublayer, sec, msgType, pdu)
        return Message(
            sublayer = sublayer,
            securityHeader = sec,
            messageType = msgType,
            name = named.first,
            direction = named.second,
            cause = cause,
            causeName = cause?.let { NasNames.cause(sublayer, it) },
            offset = offset,
            located = located,
        )
    }
}
