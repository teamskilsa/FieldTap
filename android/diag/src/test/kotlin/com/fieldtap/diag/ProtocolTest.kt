package com.fieldtap.diag

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {

    /** A log packet as the modem emits it: header, then body. */
    private fun logPacket(code: Int, timestampRaw: Long, body: ByteArray): ByteArray {
        val inner = Protocol.LOG_ENTRY_HEADER_LEN + body.size
        val out = ByteArray(Protocol.LOG_HEADER_LEN + body.size)
        out[0] = Protocol.DIAG_LOG_F.toByte()
        out[1] = 0
        fun putU16(at: Int, v: Int) {
            out[at] = (v and 0xFF).toByte(); out[at + 1] = ((v ushr 8) and 0xFF).toByte()
        }
        putU16(2, inner)
        putU16(4, inner)
        putU16(6, code)
        for (i in 0 until 8) out[8 + i] = ((timestampRaw ushr (8 * i)) and 0xFF).toByte()
        body.copyInto(out, Protocol.LOG_HEADER_LEN)
        return out
    }

    private fun container(packets: List<ByteArray>, count: Int = -1, version: Int = 1): ByteArray {
        val n = if (count >= 0) count else packets.size
        val head = byteArrayOf(
            Protocol.DIAG_MULTI_LOG_F.toByte(), version.toByte(), 0, 0,
            (n and 0xFF).toByte(), ((n ushr 8) and 0xFF).toByte(),
            ((n ushr 16) and 0xFF).toByte(), ((n ushr 24) and 0xFF).toByte(),
        )
        return head + packets.fold(ByteArray(0)) { acc, p -> acc + p }
    }

    @Test
    fun aLogPacketYieldsItsCodeTimestampAndBody() {
        val rec = Protocol.parseLogPacket(logPacket(0xB0C0, 0x1234_5678L, byteArrayOf(1, 2, 3, 4)))
        assertEquals(0xB0C0, rec.code)
        assertEquals(0x1234_5678L, rec.timestampRaw)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), rec.body)
    }

    @Test
    fun theEquipmentIdIsTheTopNibble() {
        assertEquals(0xB, Protocol.equipId(0xB0C0))
        assertEquals(0x1, Protocol.equipId(0x1C98))
        assertEquals(0x0C0, Protocol.logItem(0xB0C0))
    }

    @Test
    fun aTruncatedLogPacketKeepsWhatItHas() {
        val full = logPacket(0xB821, 9, ByteArray(40) { it.toByte() })
        val cut = full.copyOf(full.size - 10)
        val rec = Protocol.parseLogPacket(cut)
        assertEquals(0xB821, rec.code)
        assertEquals("the body is short rather than the parse failing", 30, rec.body.size)
    }

    @Test
    fun theContainerShapeTheHandsetWritesIsUnwrapped() {
        // Exactly the bytes diag_mdlog produced on the reference handset: 0x98, version 1,
        // two pad bytes, count 1, then one log packet.
        val packet = logPacket(0xB0C0, 0x41, byteArrayOf(0x1B, 0x10))
        val frame = container(listOf(packet))
        assertArrayEquals(
            byteArrayOf(0x98.toByte(), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00),
            frame.copyOf(8),
        )
        val got = Protocol.qmdl2LogPackets(frame)
        assertEquals(1, got.size)
        assertArrayEquals(packet, got[0])
        assertEquals(0xB0C0, Protocol.parseLogPacket(got[0]).code)
    }

    @Test
    fun aContainerHoldingSeveralPacketsYieldsThemAll() {
        val packets = listOf(
            logPacket(0xB0C0, 1, ByteArray(10)),
            logPacket(0xB821, 2, ByteArray(3)),
            logPacket(0xB0EC, 3, ByteArray(0)),
        )
        val got = Protocol.qmdl2LogPackets(container(packets))
        assertEquals(listOf(0xB0C0, 0xB821, 0xB0EC), got.map { Protocol.parseLogPacket(it).code })
    }

    @Test
    fun theDeclaredCountBoundsWhatIsRead() {
        val packets = listOf(logPacket(0xB0C0, 1, ByteArray(4)), logPacket(0xB821, 2, ByteArray(4)))
        assertEquals(1, Protocol.qmdl2LogPackets(container(packets, count = 1)).size)
    }

    @Test
    fun aTruncatedContainerYieldsWhatItHolds() {
        val packet = logPacket(0xB0C0, 1, ByteArray(20))
        val frame = container(listOf(packet))
        val got = Protocol.qmdl2LogPackets(frame.copyOf(frame.size - 5))
        assertEquals(1, got.size)
        assertTrue(got[0].size < packet.size)
    }

    @Test
    fun aFrameThatIsNotAContainerYieldsNothing() {
        assertTrue(Protocol.qmdl2LogPackets(ByteArray(0)).isEmpty())
        assertTrue(Protocol.qmdl2LogPackets(byteArrayOf(0x98.toByte(), 0x01)).isEmpty())
        assertTrue(Protocol.qmdl2LogPackets(logPacket(0xB0C0, 1, ByteArray(2))).isEmpty())
    }

    @Test
    fun logPacketsOfAcceptsBothShapesAndRejectsTheRest() {
        val packet = logPacket(0xB0C0, 1, ByteArray(2))
        assertEquals(1, Protocol.logPacketsOf(packet).size)
        assertEquals(1, Protocol.logPacketsOf(container(listOf(packet))).size)
        // A response, not a log packet.
        assertTrue(Protocol.logPacketsOf(byteArrayOf(0x73, 0x00, 0x00, 0x00)).isEmpty())
        assertTrue(Protocol.logPacketsOf(ByteArray(0)).isEmpty())
    }
}
