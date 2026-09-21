package com.fieldtap.diag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The serving-cell record of the lab callbox, read off a real capture. */
class CellInfoTest {

    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private val callbox = hex("0308009c180000ec5e0000646408d0a201010014000000010002010000")

    @Test
    fun theCallboxCellIsReadWhole() {
        // The same record as `fieldtap/decode/cellinfo.py` reads: PCI 8 on B20, PLMN 001-01, TAC 1.
        val cell = CellInfo.serving(callbox)!!
        assertEquals(8, cell.pci)
        assertEquals(6_300L, cell.downlinkEarfcn)
        assertEquals(24_300L, cell.uplinkEarfcn)
        assertEquals(20, cell.band)
        assertEquals("001-01", cell.plmn)
        assertEquals(1, cell.tac)
        assertEquals(27_447_304L, cell.cellIdentity)
        assertEquals(107_216L, cell.enb)
        assertEquals(8, cell.sector)
        // 100 resource blocks is 20 MHz.
        assertEquals(20.0, cell.bandwidthMhz!!, 0.0)
    }

    @Test
    fun aRecordThatDoesNotFitTheLayoutIsRefusedRatherThanGuessedAt() {
        assertNull(CellInfo.serving(ByteArray(0)))
        assertNull(CellInfo.serving(hex("03")))
        // A PCI of 4095 and band 0: the layout does not fit, so there is nothing honest to report.
        assertNull(CellInfo.serving(hex("03ff0f9c180000ec5e0000646408d0a201010000000000010002010000")))
    }
}
