package com.fieldtap.diag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The reject vectors below are the real bytes a OnePlus 10 Pro produced on 2026-09-14 when a
 * T-Mobile SIM that is not provisioned tried to register. They carry a message type and a cause and
 * nothing else — no identity, no subscriber data — so they can live in the repository where the
 * capture they came from cannot.
 */
class NasTest {

    private fun bytes(hex: String) =
        ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test
    fun theLteAttachRejectFromTheHandsetGivesCauseSeven() {
        // 0xB0EC body: a 4-byte header, then the EMM PDU 07 44 07.
        val m = Nas.decode(bytes("01090500074407"), nr = false)!!
        assertEquals(4, m.offset)
        assertEquals(Nas.Located.TABLE, m.located)
        assertEquals("emm", m.sublayer)
        assertEquals(0, m.securityHeader)
        assertEquals(0x44, m.messageType)
        assertEquals("Attach reject", m.name)
        assertEquals("dl", m.direction)
        assertEquals(7, m.cause)
        assertEquals("EPS services not allowed", m.causeName)
        assertTrue(m.isReject)
    }

    @Test
    fun theFiveGRegistrationRejectFromTheHandsetGivesCauseTwentySeven() {
        // 0xB80A body: a 7-byte header, then the 5GMM PDU 7e 00 44 1b ...
        val m = Nas.decode(bytes("010000000f04007e00441b16012c"), nr = true)!!
        assertEquals(7, m.offset)
        assertEquals("5gmm", m.sublayer)
        assertEquals(0x44, m.messageType)
        assertEquals("Registration reject", m.name)
        assertEquals(27, m.cause)
        assertEquals("N1 mode not allowed", m.causeName)
    }

    @Test
    fun theFiveGRegistrationRequestFromTheHandsetIsReadAsUplink() {
        val m = Nas.decode(bytes("010000000f04007e00417900360113006200"), nr = true)!!
        assertEquals("5gmm", m.sublayer)
        assertEquals(0x41, m.messageType)
        assertEquals("Registration request", m.name)
        assertEquals("ul", m.direction)
        assertNull("a request carries no cause", m.cause)
        assertFalse(m.isReject)
    }

    @Test
    fun anLteAttachRequestIsReadAsUplinkWithNoCause() {
        val m = Nas.decode(bytes("010905000741720839016250940143"), nr = false)!!
        assertEquals("emm", m.sublayer)
        assertEquals(0x41, m.messageType)
        assertEquals("Attach request", m.name)
        assertEquals("ul", m.direction)
        assertNull(m.cause)
    }

    @Test
    fun aCipheredMessageReportsItsSecurityHeaderAndNoType() {
        // Security header 1, and the type octet is inside the ciphered part.
        val m = Nas.decode(bytes("01090500") + bytes("1701020304050607080910"), nr = false)!!
        assertEquals("emm", m.sublayer)
        assertEquals(1, m.securityHeader)
        assertNull("the type is not guessed", m.messageType)
        assertNull(m.name)
        assertNull("and so no cause is claimed", m.cause)
    }

    @Test
    fun theServiceRequestShortHeaderIsNamedWithoutATypeOctet() {
        val m = Nas.decode(bytes("01090500") + bytes("c7a1b2"), nr = false)!!
        assertEquals("emm", m.sublayer)
        assertEquals(12, m.securityHeader)
        assertEquals("Service request", m.name)
        assertEquals("ul", m.direction)
    }

    @Test
    fun aPduBehindAnUnexpectedHeaderLengthIsStillFound() {
        // Offset 6 is not the first candidate, so this is a probe rather than the table.
        val m = Nas.decode(bytes("010905001122") + bytes("074407"), nr = false)!!
        assertEquals(6, m.offset)
        assertEquals(Nas.Located.PROBED, m.located)
        assertEquals(7, m.cause)
    }

    @Test
    fun aBodyWithNoNasPduIsNull() {
        assertNull(Nas.decode(bytes("0000000000000000"), nr = false))
        assertNull(Nas.decode(ByteArray(0), nr = false))
    }

    @Test
    fun causesAreNamedPerSublayerAndUnknownOnesAreNotInvented() {
        assertEquals("Missing or unknown APN", NasNames.cause("esm", 27))
        assertEquals("N1 mode not allowed", NasNames.cause("5gmm", 27))
        assertEquals("Security mode rejected, unspecified", NasNames.cause("emm", 24))
        assertNull(NasNames.cause("emm", 200))
        assertNull(NasNames.cause("nonsense", 7))
    }

    @Test
    fun everyRejectMessageWeNameHasACauseTable() {
        // A reject whose cause we read must be one we can also name, or the screen says a number.
        for ((layer, type, pdu) in listOf(
            Triple("emm", 0x44, "074407"),
            Triple("5gmm", 0x44, "7e00441b"),
        )) {
            val m = Nas.decode(bytes("01090500") + bytes(pdu), nr = layer.startsWith("5"))
            checkNotNull(m) { "$layer 0x${type.toString(16)} did not decode" }
            assertEquals(layer, m.sublayer)
            assertTrue("cause is named for $layer", m.causeName != null)
        }
    }
}
