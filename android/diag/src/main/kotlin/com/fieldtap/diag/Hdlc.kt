package com.fieldtap.diag

/**
 * The framing Qualcomm's diag protocol uses on the wire and in a `.qmdl` file.
 *
 * A frame is its payload, then a 16-bit CRC, then `0x7E`. Inside, `0x7D` and `0x7E` are escaped as
 * `0x7D 0x5D` and `0x7D 0x5E`. The CRC is CRC-16/X-25: reflected, initial value `0xFFFF`, final XOR
 * `0xFFFF`, so a frame including its own CRC checks to the constant [GOOD_CRC].
 *
 * This is a port of `fieldtap/diag/hdlc.py` and must stay byte-for-byte compatible with it: the
 * handset writes files the desktop tool reads, and the same capture has to decode identically on
 * both. [crc16] is checked against the published CRC-16/X-25 check value in the tests, which is the
 * one number that pins the whole table.
 *
 * Owner: workstream `diag-on-handset`.
 */
object Hdlc {

    const val FLAG: Byte = 0x7E
    const val ESCAPE: Byte = 0x7D
    private const val ESCAPE_MASK = 0x20

    /** What [crc16] returns for a buffer that already ends in its own correct CRC. */
    const val GOOD_CRC = 0x0F47

    private val TABLE = IntArray(256).also { table ->
        for (byte in 0 until 256) {
            var crc = byte
            repeat(8) { crc = if (crc and 1 != 0) (crc ushr 1) xor 0x8408 else crc ushr 1 }
            table[byte] = crc
        }
    }

    /** CRC-16/X-25 over [data]. */
    fun crc16(data: ByteArray, from: Int = 0, until: Int = data.size): Int {
        var crc = 0xFFFF
        for (i in from until until) {
            crc = (crc ushr 8) xor TABLE[(crc xor (data[i].toInt() and 0xFF)) and 0xFF]
        }
        return crc.inv() and 0xFFFF
    }

    /** [payload] as a complete frame: payload, CRC, trailing flag, with escaping applied. */
    fun encode(payload: ByteArray): ByteArray {
        val crc = crc16(payload)
        val body = payload + byteArrayOf((crc and 0xFF).toByte(), ((crc ushr 8) and 0xFF).toByte())
        val out = ArrayList<Byte>(body.size + 8)
        for (b in body) {
            if (b == FLAG || b == ESCAPE) {
                out.add(ESCAPE)
                out.add((b.toInt() xor ESCAPE_MASK).toByte())
            } else {
                out.add(b)
            }
        }
        out.add(FLAG)
        return ByteArray(out.size) { out[it] }
    }

    /** [data] with escape sequences resolved. A trailing lone escape is dropped. */
    fun unescape(data: ByteArray, from: Int = 0, until: Int = data.size): ByteArray {
        val out = ByteArray(until - from)
        var n = 0
        var i = from
        while (i < until) {
            val b = data[i]
            if (b == ESCAPE) {
                if (i + 1 >= until) break
                out[n++] = (data[i + 1].toInt() xor ESCAPE_MASK).toByte()
                i += 2
            } else {
                out[n++] = b
                i++
            }
        }
        return out.copyOf(n)
    }
}

/** A frame that did not survive its own CRC. */
class HdlcError(message: String) : IllegalArgumentException(message)

/**
 * Splits a byte stream into frames, keeping whatever is incomplete until more arrives.
 *
 * [feed] may be called with any split of the stream — one byte at a time or a whole file — and
 * returns the same frames either way. Frames whose CRC fails are counted in [crcErrors] and dropped
 * rather than thrown, because one corrupt frame must not end a capture.
 */
class Unframer {
    private val buffer = ArrayList<Byte>(4096)

    /** Frames dropped because their CRC did not check. */
    var crcErrors: Int = 0
        private set

    /** Bytes held for a frame that has not ended yet. */
    val pending: Int get() = buffer.size

    fun feed(data: ByteArray): List<ByteArray> {
        val frames = ArrayList<ByteArray>()
        for (b in data) {
            if (b == Hdlc.FLAG) {
                if (buffer.isNotEmpty()) {
                    decodeOrNull(ByteArray(buffer.size) { buffer[it] })?.let { frames.add(it) }
                    buffer.clear()
                }
            } else {
                buffer.add(b)
            }
        }
        return frames
    }

    /** The payload of one escaped frame body, or null when its CRC does not check. */
    private fun decodeOrNull(escaped: ByteArray): ByteArray? {
        val raw = Hdlc.unescape(escaped)
        if (raw.size < 3) {
            crcErrors++
            return null
        }
        if (Hdlc.crc16(raw) != Hdlc.GOOD_CRC) {
            crcErrors++
            return null
        }
        return raw.copyOf(raw.size - 2)
    }
}
