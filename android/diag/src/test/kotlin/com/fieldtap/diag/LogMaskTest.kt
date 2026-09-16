package com.fieldtap.diag

import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The expected bytes are `fieldtap/diag/protocol.py`'s output for the same input. A mask built on the
 * handset and one built on a computer have to be the same bytes, so the test compares against the
 * other implementation rather than against this one's reading of the layout.
 */
class LogMaskTest {

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    private fun sha256(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

    @Test
    fun theDisableCommandMatchesTheDesktopTool() {
        assertEquals("7300000000000000", LogMask.disable().hex())
    }

    @Test
    fun aSetMaskCommandMatchesTheDesktopTool() {
        val cmd = LogMask.setMask(0xB, 0x9FF, listOf(0xB0C0, 0xB0EC))
        assertEquals("73000000030000000b000000ff09000000000000", cmd.hex().substring(0, 40))
        assertEquals("the bitmap covers items 0..0x9FF", 336, cmd.size)
    }

    @Test
    fun onlyTheRequestedItemsHaveTheirBitSet() {
        val cmd = LogMask.setMask(0xB, 0x0FF, listOf(0xB000, 0xB007, 0xB008))
        val mask = cmd.copyOfRange(16, cmd.size)
        // Items 0 and 7 are in the first byte, item 8 is the low bit of the second.
        assertEquals(0x81, mask[0].toInt() and 0xFF)
        assertEquals(0x01, mask[1].toInt() and 0xFF)
        assertTrue("nothing else is asked for", mask.drop(2).all { it.toInt() == 0 })
    }

    @Test
    fun aCodeOfAnotherEquipmentIdIsNotSetInThisMask() {
        val cmd = LogMask.setMask(0xB, 0x0FF, listOf(0xB001, 0x1001))
        val mask = cmd.copyOfRange(16, cmd.size)
        assertEquals(0x02, mask[0].toInt() and 0xFF)
        assertTrue(mask.drop(1).all { it.toInt() == 0 })
    }

    @Test
    fun aCodeBeyondTheModemsRangeIsLeftOutRatherThanWideningTheMask() {
        val cmd = LogMask.setMask(0xB, 0x00F, listOf(0xB001, 0xB0C0))
        // 16 bytes of header, then (0x0F + 8) / 8 = 2 bytes of bitmap.
        assertEquals("the width follows the modem's range", 18, cmd.size)
        val mask = cmd.copyOfRange(16, cmd.size)
        assertEquals(0x02, mask[0].toInt() and 0xFF)
    }

    @Test
    fun theSignallingMaskFileIsByteForByteTheDesktopTools() {
        val file = LogMask.file(LogCodes.signallingCodes(), LogMask.DEFAULT_RANGES)
        // fieldtap/diag/protocol.py over the same 22 codes and the same ranges.
        assertEquals(350, file.size)
        assertEquals("00751fc0aee76e3a", sha256(file).substring(0, 16))
    }

    @Test
    fun theFileStartsWithADisableSoALeftoverMaskIsNotInherited() {
        val file = LogMask.file(listOf(0xB0C0), LogMask.DEFAULT_RANGES)
        val frames = Unframer().feed(file)
        assertEquals(2, frames.size)
        assertEquals(LogMask.disable().hex(), frames[0].hex())
    }

    @Test
    fun anEquipmentIdTheModemDidNotReportIsSkipped() {
        // 0x2 is not in DEFAULT_RANGES: without the modem's width there is no honest bitmap to send.
        val file = LogMask.file(listOf(0x2001, 0xB0C0), LogMask.DEFAULT_RANGES)
        val frames = Unframer().feed(file)
        assertEquals("the disable and equipment 0xB only", 2, frames.size)
    }

    @Test
    fun everyFrameInTheFileSurvivesItsOwnCrc() {
        val unframer = Unframer()
        val frames = unframer.feed(LogMask.file(LogCodes.signallingCodes(), LogMask.DEFAULT_RANGES))
        assertEquals(0, unframer.crcErrors)
        assertTrue(frames.isNotEmpty())
    }
}
