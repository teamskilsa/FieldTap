package com.fieldtap.diag

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HdlcTest {

    @Test
    fun crc16MatchesThePublishedX25CheckValue() {
        // The one number that pins the whole table: CRC-16/X-25 over "123456789".
        assertEquals(0x906E, Hdlc.crc16("123456789".toByteArray()))
    }

    @Test
    fun aFrameIncludingItsOwnCrcChecksToTheResidue() {
        for (payload in listOf(ByteArray(0), byteArrayOf(0x10), ByteArray(40) { it.toByte() })) {
            val crc = Hdlc.crc16(payload)
            val withCrc = payload + byteArrayOf((crc and 0xFF).toByte(), (crc ushr 8).toByte())
            assertEquals("residue for ${payload.size} bytes", Hdlc.GOOD_CRC, Hdlc.crc16(withCrc))
        }
    }

    @Test
    fun encodeThenUnframeReturnsThePayload() {
        val payload = byteArrayOf(0x10, 0x00, 0x7E, 0x7D, 0x42)
        val frames = Unframer().feed(Hdlc.encode(payload))
        assertEquals(1, frames.size)
        assertArrayEquals(payload, frames[0])
    }

    @Test
    fun flagAndEscapeBytesSurviveTheRoundTrip() {
        // 0x7E and 0x7D are the two bytes that cannot appear raw inside a frame.
        val payload = byteArrayOf(0x7E, 0x7D, 0x7E, 0x7D, 0x7D, 0x7E)
        val encoded = Hdlc.encode(payload)
        assertTrue("no raw flag inside the frame", encoded.dropLast(1).none { it == Hdlc.FLAG })
        assertArrayEquals(payload, Unframer().feed(encoded)[0])
    }

    @Test
    fun aStreamSplitAnywhereYieldsTheSameFrames() {
        val a = Hdlc.encode(byteArrayOf(0x10, 0x01))
        val b = Hdlc.encode(byteArrayOf(0x10, 0x02, 0x7E))
        val stream = a + b
        val whole = Unframer().feed(stream)

        val oneByteAtATime = Unframer().let { u -> stream.flatMap { u.feed(byteArrayOf(it)) } }
        assertEquals(whole.size, oneByteAtATime.size)
        whole.indices.forEach { assertArrayEquals(whole[it], oneByteAtATime[it]) }
    }

    @Test
    fun aCorruptFrameIsCountedAndDroppedRatherThanThrown() {
        val good = Hdlc.encode(byteArrayOf(0x10, 0x01))
        val bad = Hdlc.encode(byteArrayOf(0x10, 0x02)).copyOf()
        bad[0] = (bad[0] + 1).toByte()   // break the payload, leaving the CRC stale
        val unframer = Unframer()
        val frames = unframer.feed(bad + good)
        assertEquals("the good frame still arrives", 1, frames.size)
        assertEquals(1, unframer.crcErrors)
    }

    @Test
    fun anUnfinishedFrameIsHeldUntilItEnds() {
        val encoded = Hdlc.encode(byteArrayOf(0x10, 0x05, 0x06))
        val unframer = Unframer()
        assertTrue(unframer.feed(encoded.copyOf(encoded.size - 1)).isEmpty())
        assertTrue("bytes are held, not lost", unframer.pending > 0)
        assertEquals(1, unframer.feed(byteArrayOf(Hdlc.FLAG)).size)
    }

    @Test
    fun repeatedFlagsAreNotEmptyFrames() {
        assertTrue(Unframer().feed(byteArrayOf(Hdlc.FLAG, Hdlc.FLAG, Hdlc.FLAG)).isEmpty())
    }
}
