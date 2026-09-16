package com.fieldtap.diag

/**
 * The log-mask commands that tell a modem which records to emit, and the mask file `diag_mdlog` reads.
 *
 * A mask is per equipment id: one command carries the id, the highest item the modem said it supports,
 * and a bitmap with a bit set for every item wanted. Codes are grouped by their equipment id and one
 * command is built for each, because the modem keeps one mask per id and the last command for an id
 * replaces the previous one.
 *
 * `diag_mdlog -f FILE` expects exactly these commands, HDLC-framed, end to end — the same bytes that
 * would go over USB. [file] builds that, beginning with a disable so a mask left behind by another
 * tool does not add records nobody asked for.
 *
 * The byte layout is `fieldtap/diag/protocol.py`'s, and the tests check it against that
 * implementation's output rather than against this one's reading of the spec.
 *
 * Owner: workstream `diag-on-handset`.
 */
object LogMask {

    private const val DIAG_LOG_CONFIG_F = 0x73
    private const val DISABLE_OP = 0
    private const val SET_MASK_OP = 3

    /** Turn every log off. */
    fun disable(): ByteArray = byteArrayOf(DIAG_LOG_CONFIG_F.toByte(), 0, 0, 0) + le32(DISABLE_OP.toLong())

    /**
     * Enable exactly [codes] within items `0..lastItem` of [equip].
     *
     * [lastItem] is what the modem reported for that equipment id; a code beyond it cannot be asked
     * for and is left out rather than silently widening the bitmap past what the modem accepts.
     */
    fun setMask(equip: Int, lastItem: Int, codes: Collection<Int>): ByteArray {
        require(lastItem >= 0) { "lastItem must not be negative" }
        val bytes = (lastItem + 8) / 8
        val mask = ByteArray(bytes)
        for (code in codes) {
            if (Protocol.equipId(code) != equip) continue
            val item = Protocol.logItem(code)
            if (item > lastItem) continue
            mask[item shr 3] = (mask[item shr 3].toInt() or (1 shl (item and 7))).toByte()
        }
        return byteArrayOf(DIAG_LOG_CONFIG_F.toByte(), 0, 0, 0) +
            le32(SET_MASK_OP.toLong()) + le32(equip.toLong()) + le32(lastItem.toLong()) + mask
    }

    /**
     * A mask file for `diag_mdlog -f`: a disable, then one set-mask command per equipment id present
     * in [codes], each HDLC-framed.
     *
     * [ranges] maps an equipment id to the highest item the modem supports there. An id missing from
     * it is skipped: without the modem's own range there is no honest bitmap width to send.
     */
    fun file(codes: Collection<Int>, ranges: Map<Int, Int>): ByteArray {
        val out = ArrayList<ByteArray>()
        out.add(Hdlc.encode(disable()))
        for ((equip, group) in codes.groupBy { Protocol.equipId(it) }.toSortedMap()) {
            val lastItem = ranges[equip] ?: continue
            if (lastItem <= 0) continue
            out.add(Hdlc.encode(setMask(equip, lastItem, group)))
        }
        var size = 0
        for (part in out) size += part.size
        val joined = ByteArray(size)
        var at = 0
        for (part in out) {
            part.copyInto(joined, at)
            at += part.size
        }
        return joined
    }

    /**
     * The equipment-id ranges a handset reports. These are the values the reference OnePlus 10 Pro
     * (SM8450, MPSS.DE.2.0) returned, used when the modem has not been asked directly.
     *
     * Asking costs a round trip over a diag port this path does not open — `diag_mdlog` owns it — so
     * the fallback is a recorded fact rather than a guess. A modem with a smaller range refuses the
     * command for that id and logs nothing extra; it cannot make the modem emit what it has not got.
     */
    val DEFAULT_RANGES: Map<Int, Int> = mapOf(
        0x1 to 0xDB2,
        0x4 to 0x910,
        0x5 to 0x420,
        0x7 to 0x4FF,
        0xA to 0x38A,
        0xB to 0x9FF,
        0xD to 0x1FF,
    )

    private fun le32(v: Long) = byteArrayOf(
        (v and 0xFF).toByte(), ((v ushr 8) and 0xFF).toByte(),
        ((v ushr 16) and 0xFF).toByte(), ((v ushr 24) and 0xFF).toByte(),
    )
}
