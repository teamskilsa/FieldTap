package com.fieldtap.diag

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The expected byte strings are what `fieldtap/output/gsmtap.py` and `pcap.py` produce for the same
 * input. A file written on the handset and one written on a computer have to be the same file, so
 * the test compares against the other implementation's output rather than against this one's idea
 * of the format.
 */
class GsmtapTest {

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private val pdu = byteArrayOf(0x68, 0xCC.toByte(), 0x42, 0x82.toByte())

    @Test
    fun theHeaderMatchesTheDesktopToolByteForByte() {
        val h = Gsmtap.header(
            Gsmtap.TYPE_LTE_RRC, Gsmtap.LteRrcChannel.BCCH_DL_SCH,
            arfcn = 5110, uplink = false, frameNumber = 792, subSlot = 5,
        )
        assertEquals("02040d0013f600000000031801000500", h.hex())
        assertEquals("a GSMTAP header is 16 bytes", 16, h.size)
    }

    @Test
    fun aDownlinkRrcFrameMatchesTheDesktopTool() {
        val f = Gsmtap.frame(
            Gsmtap.TYPE_LTE_RRC, Gsmtap.LteRrcChannel.BCCH_DL_SCH, pdu,
            arfcn = 5110, frameNumber = 792, subSlot = 5,
        )
        assertEquals(
            "450000300000000040117cbb7f0000017f00000112791279001c000002040d0013f6000000000318010005" +
                "0068cc4282",
            f.hex(),
        )
    }

    @Test
    fun anUplinkNasFrameSetsTheUplinkFlagInTheArfcnField() {
        val f = Gsmtap.frame(Gsmtap.TYPE_LTE_NAS, 0, pdu, arfcn = 5110, uplink = true)
        assertEquals(
            "450000300000000040117cbb7f0000017f00000112791279001c0000020412005" +
                "3f6000000000000000000" + "0068cc4282",
            f.hex(),
        )
        // 0x53F6 is 5110 with the uplink bit set; without it the field reads 0x13F6.
        assertTrue(f.hex().contains("53f6"))
    }

    @Test
    fun aPcapFileMatchesTheDesktopToolIncludingItsHeader() {
        val out = ByteArrayOutputStream()
        val w = PcapWriter(out, Gsmtap.LINKTYPE_RAW)
        val f = Gsmtap.frame(
            Gsmtap.TYPE_LTE_RRC, Gsmtap.LteRrcChannel.BCCH_DL_SCH, pdu,
            arfcn = 5110, frameNumber = 792, subSlot = 5,
        )
        w.write(f, epochMicros = 1_500_000_000_123_456L)
        assertEquals(
            "d4c3b2a10200040000000000000000000000040065000000002f685940e2010030000000300000004500003" +
                "00000000040117cbb7f0000017f00000112791279001c000002040d0013f6000000000318010005006" +
                "8cc4282",
            out.toByteArray().hex(),
        )
        assertEquals(1, w.packets)
    }

    @Test
    fun anArfcnTooLargeForTheFieldIsDroppedRatherThanTruncated() {
        // The field is 14 bits; a value that does not fit would otherwise alias onto another channel.
        val f = Gsmtap.header(Gsmtap.TYPE_LTE_RRC, 0, arfcn = 66_786)
        assertEquals("the arfcn field reads zero", "0000", f.hex().substring(8, 12))
    }

    @Test
    fun theIpv4ChecksumIsCorrectForTheHeaderWeEmit() {
        // A correct IPv4 header sums to 0xFFFF across its 16-bit words, checksum included.
        val frame = Gsmtap.frame(Gsmtap.TYPE_LTE_RRC, 0, pdu, arfcn = 100)
        var total = 0
        for (i in 0 until 20 step 2) {
            total += ((frame[i].toInt() and 0xFF) shl 8) or (frame[i + 1].toInt() and 0xFF)
        }
        while (total ushr 16 != 0) total = (total and 0xFFFF) + (total ushr 16)
        assertEquals(0xFFFF, total)
    }

    @Test
    fun timestampsSplitIntoSecondsAndMicroseconds() {
        val out = ByteArrayOutputStream()
        val w = PcapWriter(out, Gsmtap.LINKTYPE_RAW)
        w.write(byteArrayOf(1, 2, 3), epochMicros = 2_000_000L + 500L)
        val body = out.toByteArray()
        // After the 24-byte file header: seconds, then microseconds, little-endian.
        val secs = (body[24].toInt() and 0xFF) or ((body[25].toInt() and 0xFF) shl 8)
        val micros = (body[28].toInt() and 0xFF) or ((body[29].toInt() and 0xFF) shl 8)
        assertEquals(2, secs)
        assertEquals(500, micros)
    }
}
