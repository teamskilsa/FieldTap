package com.fieldtap.core.radio

import com.fieldtap.format.Rat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PciPlanningTest {

    private fun collisions(
        servingPci: Int?,
        neighbourPci: Int?,
        servingRat: Rat? = Rat.LTE,
        neighbourRat: Rat? = Rat.LTE,
        servingArfcn: Int? = 1850,
        neighbourArfcn: Int? = 1850,
    ): Set<Int> = PciPlanning.collisions(
        servingRat = servingRat,
        servingPci = servingPci,
        servingArfcn = servingArfcn,
        neighbourRat = neighbourRat,
        neighbourPci = neighbourPci,
        neighbourArfcn = neighbourArfcn,
    )

    @Test
    fun congruentModuloThreeOnly() {
        // 101 % 3 == 2, 104 % 3 == 2; 101 % 6 == 5, 104 % 6 == 2.
        assertEquals(setOf(3), collisions(101, 104))
    }

    @Test
    fun congruentModuloSixIsAlsoCongruentModuloThree() {
        // 101 % 6 == 5 and 107 % 6 == 5, so both 3 and 6 hold.
        assertEquals(setOf(3, 6), collisions(101, 107))
    }

    @Test
    fun congruentModuloThirtyImpliesSixAndThree() {
        // 30 is a multiple of both 6 and 3, so congruence at 30 forces the others.
        assertEquals(setOf(3, 6, 30), collisions(101, 131))
    }

    @Test
    fun everyModuloThirtyReuseAlsoReportsTheSmallerModuli() {
        for (serving in 0 until 100) {
            val neighbour = serving + 30
            val found = collisions(serving, neighbour)
            assertEquals("pci $serving vs $neighbour", setOf(3, 6, 30), found)
        }
    }

    @Test
    fun noReuseIsAnEmptySet() {
        // 100 % 3 == 1, 101 % 3 == 2.
        assertTrue(collisions(100, 101).isEmpty())
    }

    @Test
    fun theSamePciIsNotReportedAsAReuse() {
        assertTrue("one cell seen twice is not a collision", collisions(212, 212).isEmpty())
    }

    @Test
    fun aNeighbourOnAnotherCarrierReusesNothing() {
        assertTrue(collisions(101, 131, neighbourArfcn = 66_786).isEmpty())
    }

    @Test
    fun aNeighbourOnAnotherRatReusesNothing() {
        assertTrue(collisions(101, 131, neighbourRat = Rat.NR).isEmpty())
    }

    @Test
    fun anUnknownCarrierOnEitherSideIsNotAssumedToMatch() {
        assertTrue(collisions(101, 131, servingArfcn = null).isEmpty())
        assertTrue(collisions(101, 131, neighbourArfcn = null).isEmpty())
    }

    @Test
    fun anUnknownIdentityYieldsNothing() {
        assertTrue(collisions(null, 131).isEmpty())
        assertTrue(collisions(101, null).isEmpty())
        assertTrue(collisions(101, 131, servingRat = null).isEmpty())
        assertTrue(collisions(101, 131, neighbourRat = null).isEmpty())
    }

    @Test
    fun theMarginIsServingMinusNeighbour() {
        assertEquals(20, PciPlanning.marginDb(-90, -110))
        assertEquals("a stronger neighbour is a negative margin", -6, PciPlanning.marginDb(-96, -90))
        assertEquals(0, PciPlanning.marginDb(-90, -90))
    }

    @Test
    fun anUnknownLevelHasNoMargin() {
        assertNull(PciPlanning.marginDb(null, -110))
        assertNull(PciPlanning.marginDb(-90, null))
    }
}
