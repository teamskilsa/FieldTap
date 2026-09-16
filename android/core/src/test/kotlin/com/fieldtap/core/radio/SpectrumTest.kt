package com.fieldtap.core.radio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpectrumTest {

    @Test
    fun theLabCallboxCarrierIsBand7At2680() {
        // The Simnovus callbox the OnePlus is attached to: EARFCN 3350.
        val carrier = Spectrum.lte(3350)!!
        assertEquals(7, carrier.band)
        assertEquals(2680.0, carrier.dlMhz, 0.0)
        assertEquals(2560.0, carrier.ulMhz!!, 0.0)
        assertFalse(carrier.tdd)
    }

    @Test
    fun wellKnownCommercialCarriersMatchTheirPublishedFrequencies() {
        assertEquals(1815.0, Spectrum.lte(1300)!!.dlMhz, 0.0) // band 3
        assertEquals(806.0, Spectrum.lte(6300)!!.dlMhz, 0.0) // band 20
        assertEquals(751.0, Spectrum.lte(5230)!!.dlMhz, 0.0) // band 13, Verizon
        assertEquals(2145.0, Spectrum.lte(66786)!!.dlMhz, 0.0) // band 66
        assertEquals(739.0, Spectrum.lte(5110)!!.dlMhz, 0.0) // band 12
    }

    @Test
    fun theFirstAndLastEarfcnOfABandAreItsEdges() {
        assertEquals(2620.0, Spectrum.lte(2750)!!.dlMhz, 0.0)
        assertEquals(2689.9, Spectrum.lte(3449)!!.dlMhz, 0.0)
    }

    @Test
    fun aTddCarrierUsesOneFrequencyBothWays() {
        val carrier = Spectrum.lte(40_620)!! // band 41
        assertEquals(41, carrier.band)
        assertTrue(carrier.tdd)
        assertEquals(carrier.dlMhz, carrier.ulMhz!!, 0.0)
        assertEquals(2593.0, carrier.dlMhz, 0.0)
    }

    @Test
    fun aDownlinkOnlyBandHasNoUplink() {
        assertNull(Spectrum.lte(9_700)!!.ulMhz) // band 29
    }

    @Test
    fun anEarfcnInAGapBetweenBandsHasNoCarrier() {
        assertNull(Spectrum.lte(5_000)) // between band 11 and band 12
        assertNull(Spectrum.lte(Int.MAX_VALUE))
        assertNull(Spectrum.lte(null))
    }

    @Test
    fun nrArfcnsLandOnTheGlobalRaster() {
        assertEquals(3750.0, Spectrum.nrMhz(650_000)!!, 0.0) // 15 kHz raster
        assertEquals(3489.42, Spectrum.nrMhz(632_628)!!, 0.0)
        assertEquals(620.0, Spectrum.nrMhz(124_000)!!, 0.0) // 5 kHz raster, n71
        assertEquals(27_500.04, Spectrum.nrMhz(2_070_833)!!, 0.001) // 60 kHz raster, n258
    }

    @Test
    fun nrArfcnOutsideTheRasterHasNoFrequency() {
        assertNull(Spectrum.nrMhz(3_279_166))
        assertNull(Spectrum.nrMhz(-1))
        assertNull(Spectrum.nrMhz(null))
    }

    @Test
    fun theLabCellIdentitySplitsIntoEnbAndCell() {
        // ECI 27447297 from the OnePlus on the callbox.
        assertEquals(Spectrum.LteCellId(enb = 107_216, cell = 1), Spectrum.lteCellId(27_447_297))
    }

    @Test
    fun androidsUnknownCellIdentityIsNotSplit() {
        assertNull(Spectrum.lteCellId(Int.MAX_VALUE.toLong()))
        assertNull(Spectrum.lteCellId(-1))
        assertNull(Spectrum.lteCellId(null))
    }

    @Test
    fun timingAdvanceBecomesADistance() {
        assertEquals(78.12, Spectrum.lteTimingAdvanceMetres(1)!!, 0.0)
        assertEquals(0.0, Spectrum.lteTimingAdvanceMetres(0)!!, 0.0)
        assertNull(Spectrum.lteTimingAdvanceMetres(Int.MAX_VALUE))
        assertNull(Spectrum.lteTimingAdvanceMetres(null))
    }
}
