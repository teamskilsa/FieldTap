package com.fieldtap.diag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SignallingReaderTest {

    private fun bytes(hex: String) =
        ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    /** One log packet, HDLC-framed as a capture holds it. */
    private fun framed(code: Int, body: ByteArray, timestampRaw: Long = 42): ByteArray {
        val inner = Protocol.LOG_ENTRY_HEADER_LEN + body.size
        val out = ByteArray(Protocol.LOG_HEADER_LEN + body.size)
        out[0] = Protocol.DIAG_LOG_F.toByte()
        fun putU16(at: Int, v: Int) {
            out[at] = (v and 0xFF).toByte(); out[at + 1] = ((v ushr 8) and 0xFF).toByte()
        }
        putU16(2, inner); putU16(4, inner); putU16(6, code)
        for (i in 0 until 8) out[8 + i] = ((timestampRaw ushr (8 * i)) and 0xFF).toByte()
        body.copyInto(out, Protocol.LOG_HEADER_LEN)
        return Hdlc.encode(out)
    }

    @Test
    fun theLteAttachRejectIsReadAsARejectWithItsCause() {
        // 0xB0EC, the real body from the reference handset.
        val summary = SignallingReader.read(framed(0xB0EC, bytes("01090500074407")))

        val entry = summary.entries.single()
        assertEquals("Attach reject", entry.name)
        assertEquals("emm", entry.sublayer)
        assertEquals("dl", entry.direction)
        assertEquals(7, entry.cause)
        assertEquals("EPS services not allowed", entry.causeName)
        assertTrue(entry.isReject)
        assertEquals(listOf(entry), summary.rejects)
    }

    @Test
    fun theFiveGRegistrationRejectIsReadWithItsCause() {
        val summary = SignallingReader.read(framed(0xB80A, bytes("010000000f04007e00441b16012c")))

        val entry = summary.entries.single()
        assertEquals("Registration reject", entry.name)
        assertEquals("5gmm", entry.sublayer)
        assertEquals(27, entry.cause)
        assertEquals("N1 mode not allowed", entry.causeName)
        assertEquals("nr", entry.rat)
    }

    @Test
    fun aCipheredMessageKeepsItsPlaceAndSaysWhyItHasNoName() {
        // 0xB80C is security protected; the type octet is inside the encryption.
        val summary = SignallingReader.read(framed(0xB80C, bytes("01000000010200000000ffffffffffff")))

        val entry = summary.entries.single()
        assertTrue("it is still a line of the flow", entry.ciphered)
        assertNull("and its type is not guessed", entry.name)
        assertEquals("5gmm", entry.sublayer)
        assertEquals("Ciphered 5gmm message", entry.fallback)
        assertFalse(entry.isReject)
    }

    @Test
    fun rrcIsCountedButNotDecoded() {
        // 0xB0C0 is RRC: ASN.1, which the handset cannot read, so it makes no entry.
        val summary = SignallingReader.read(framed(0xB0C0, bytes("1b1010106000eb00f613000085310302000000290068")))

        assertEquals("the record is still read", 1, summary.records)
        assertTrue("but it makes no call-flow line", summary.entries.isEmpty())
    }

    @Test
    fun aFlowKeepsTheOrderTheMessagesArrivedIn() {
        val capture = framed(0xB80B, bytes("010000000f04007e004179")) +
            framed(0xB80A, bytes("010000000f04007e00441b16012c")) +
            framed(0xB0ED, bytes("0109050007417208")) +
            framed(0xB0EC, bytes("01090500074407"))

        val summary = SignallingReader.read(capture)

        assertEquals(
            listOf("Registration request", "Registration reject", "Attach request", "Attach reject"),
            summary.entries.map { it.name },
        )
        assertEquals(listOf("ul", "dl", "ul", "dl"), summary.entries.map { it.direction })
        assertEquals(2, summary.rejects.size)
    }

    @Test
    fun aCorruptFrameIsCountedAndTheRestStillRead() {
        val good = framed(0xB0EC, bytes("01090500074407"))
        val bad = framed(0xB0EC, bytes("01090500074407")).copyOf()
        bad[1] = (bad[1] + 1).toByte()

        val summary = SignallingReader.read(bad + good)

        assertEquals(1, summary.entries.size)
        assertEquals(1, summary.crcErrors)
    }

    @Test
    fun anEmptyCaptureIsAnEmptyFlowRatherThanAFailure() {
        val summary = SignallingReader.read(ByteArray(0))
        assertEquals(0, summary.records)
        assertTrue(summary.entries.isEmpty())
    }
}
