package com.fieldtap.diag

import java.io.OutputStream

/**
 * GSMTAP in a pcap file: how a capture leaves the phone in a form Wireshark reads.
 *
 * The handset can name a message and its cause, but it cannot dissect an RRC body — that is ASN.1
 * and needs a decoder this project does not have. Wrapping each PDU in GSMTAP and writing a pcap
 * gives the whole capture to a tool that can, so what the phone cannot explain is still not lost.
 *
 * The bytes match `fieldtap/output/gsmtap.py` and `pcap.py`, so a file written here and one written
 * by the desktop tool are the same file.
 *
 * GSMTAP defines payload types for LTE RRC and LTE NAS only. An NR message has no GSMTAP type, so
 * it is counted as skipped rather than written under a type that would make Wireshark dissect it as
 * something it is not. NR travels in the raw `.qmdl` instead, which the desktop tool decodes.
 *
 * Owner: workstream `diag-on-handset`.
 */
object Gsmtap {

    const val VERSION = 2
    const val HDR_WORDS = 4
    const val UDP_PORT = 4729

    const val TYPE_LTE_RRC = 0x0D
    const val TYPE_LTE_NAS = 0x12

    private const val ARFCN_F_UPLINK = 0x4000
    private const val ARFCN_MASK = 0x3FFF

    /** pcap link type 101: the frame is a bare IPv4 packet. */
    const val LINKTYPE_RAW = 101

    /** GSMTAP sub-types for LTE RRC, matching Wireshark's `lte-rrc.*` dissectors. */
    object LteRrcChannel {
        const val BCCH_BCH = 0
        const val BCCH_DL_SCH = 1
        const val MCCH = 2
        const val PCCH = 3
        const val DL_CCCH = 4
        const val DL_DCCH = 5
        const val UL_CCCH = 6
        const val UL_DCCH = 7
    }

    private fun be16(v: Int) = byteArrayOf(((v ushr 8) and 0xFF).toByte(), (v and 0xFF).toByte())
    private fun be32(v: Long) = byteArrayOf(
        ((v ushr 24) and 0xFF).toByte(), ((v ushr 16) and 0xFF).toByte(),
        ((v ushr 8) and 0xFF).toByte(), (v and 0xFF).toByte(),
    )

    private fun clampSigned(v: Int) = maxOf(-128, minOf(127, v)).toByte()

    /** The 16-byte GSMTAP header. */
    fun header(
        type: Int,
        subType: Int,
        arfcn: Int? = null,
        uplink: Boolean = false,
        frameNumber: Long = 0,
        subSlot: Int = 0,
        signalDbm: Int = 0,
        snrDb: Int = 0,
    ): ByteArray {
        var arfcnField = if (arfcn != null && arfcn in 0..ARFCN_MASK) arfcn else 0
        if (uplink) arfcnField = arfcnField or ARFCN_F_UPLINK
        return byteArrayOf(VERSION.toByte(), HDR_WORDS.toByte(), type.toByte(), 0) +
            be16(arfcnField) +
            byteArrayOf(clampSigned(signalDbm), clampSigned(snrDb)) +
            be32(frameNumber and 0xFFFFFFFFL) +
            byteArrayOf(subType.toByte(), 0, (subSlot and 0xFF).toByte(), 0)
    }

    private fun ipv4Checksum(header: ByteArray): Int {
        var total = 0
        var i = 0
        while (i + 1 < header.size) {
            total += ((header[i].toInt() and 0xFF) shl 8) or (header[i + 1].toInt() and 0xFF)
            i += 2
        }
        while (total ushr 16 != 0) total = (total and 0xFFFF) + (total ushr 16)
        return total.inv() and 0xFFFF
    }

    /** [payload] inside UDP 4729 inside IPv4, loopback to loopback. */
    fun ipUdp(payload: ByteArray): ByteArray {
        val udpLen = 8 + payload.size
        val udp = be16(UDP_PORT) + be16(UDP_PORT) + be16(udpLen) + be16(0) + payload
        val total = 20 + udpLen
        val loopback = byteArrayOf(127, 0, 0, 1)
        val head = byteArrayOf(0x45, 0) + be16(total) + be16(0) + be16(0) +
            byteArrayOf(64, 17) + be16(0) + loopback + loopback
        val checksum = ipv4Checksum(head)
        return head.copyOf(10) + be16(checksum) + head.copyOfRange(12, head.size) + udp
    }

    /** A complete raw-IP frame carrying one GSMTAP message. */
    fun frame(
        type: Int,
        subType: Int,
        payload: ByteArray,
        arfcn: Int? = null,
        uplink: Boolean = false,
        frameNumber: Long = 0,
        subSlot: Int = 0,
    ): ByteArray = ipUdp(header(type, subType, arfcn, uplink, frameNumber, subSlot) + payload)
}

/**
 * A classic pcap file, written a packet at a time.
 *
 * Microsecond magic and the same header layout the desktop tool writes. The stream is not closed
 * here: whoever opened it decides, which on Android is a `use {}` around a content-resolver stream.
 */
class PcapWriter(private val out: OutputStream, linkType: Int, snapLen: Int = 262_144) {

    var packets: Int = 0
        private set

    init {
        out.write(le32(0xA1B2C3D4L))
        out.write(le16(2)); out.write(le16(4))
        out.write(le32(0)); out.write(le32(0))
        out.write(le32(snapLen.toLong())); out.write(le32(linkType.toLong()))
    }

    /** One packet, stamped [epochMicros]. */
    fun write(data: ByteArray, epochMicros: Long) {
        val micros = maxOf(0L, epochMicros)
        out.write(le32(micros / 1_000_000))
        out.write(le32(micros % 1_000_000))
        out.write(le32(data.size.toLong()))
        out.write(le32(data.size.toLong()))
        out.write(data)
        packets++
    }

    fun flush() = out.flush()

    private fun le16(v: Int) = byteArrayOf((v and 0xFF).toByte(), ((v ushr 8) and 0xFF).toByte())
    private fun le32(v: Long) = byteArrayOf(
        (v and 0xFF).toByte(), ((v ushr 8) and 0xFF).toByte(),
        ((v ushr 16) and 0xFF).toByte(), ((v ushr 24) and 0xFF).toByte(),
    )
}
