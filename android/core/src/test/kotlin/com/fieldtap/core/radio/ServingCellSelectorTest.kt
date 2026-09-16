package com.fieldtap.core.radio

import com.fieldtap.core.input.CellSnapshot
import com.fieldtap.core.input.ServiceRegState
import com.fieldtap.core.radio.RadioFixtures.gsm
import com.fieldtap.core.radio.RadioFixtures.lte
import com.fieldtap.core.radio.RadioFixtures.nr
import com.fieldtap.core.radio.RadioFixtures.serviceState
import com.fieldtap.format.Rat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ServingCellSelectorTest {

    @Test
    fun nsaPicksTheLteAnchorAndTheSecondaryNrLeg() {
        val anchor = lte(0)
        val leg = nr(0)
        val neighbour = lte(0, pci = 213, status = CellSnapshot.CONNECTION_NONE)
        val selection = ServingCellSelector.select(listOf(neighbour, leg, anchor))
        assertEquals(anchor, selection.primary)
        assertEquals(leg, selection.nsaSecondary)
    }

    @Test
    fun saHasNoSecondaryLeg() {
        val primary = nr(0, status = CellSnapshot.CONNECTION_PRIMARY_SERVING)
        val other = nr(0, pci = 394, status = CellSnapshot.CONNECTION_SECONDARY_SERVING)
        val selection = ServingCellSelector.select(listOf(primary, other))
        assertEquals(primary, selection.primary)
        assertNull(selection.nsaSecondary)
    }

    @Test
    fun anLteSecondaryIsNotAnNsaLeg() {
        val selection = ServingCellSelector.select(
            listOf(lte(0), lte(0, pci = 300, status = CellSnapshot.CONNECTION_SECONDARY_SERVING)),
        )
        assertNull(selection.nsaSecondary)
    }

    @Test
    fun withoutAnyStatusTheFirstRegisteredLteOrNrCellIsPrimary() {
        val unregistered = lte(0, status = null, registered = false)
        val registeredGsm = gsm(0, status = null)
        val registeredNr = nr(0, pci = 500, status = null, registered = true)
        val registeredLte = lte(0, pci = 100, status = null, registered = true)
        val selection = ServingCellSelector.select(listOf(unregistered, registeredGsm, registeredNr, registeredLte))
        assertEquals(registeredNr, selection.primary)
        assertNull(selection.nsaSecondary)
    }

    @Test
    fun anIdlePhoneIsServedByTheCellItIsCampedOn() {
        // The OnePlus 10 Pro on a Simnovus callbox, attached with no data bearer: RRC idle, so every
        // cell reports CONNECTION_NONE — the camped one included. Captured from `dumpsys
        // telephony.registry`: mRegistered=YES mCellConnectionStatus=0 PCI 1 EARFCN 3350 RSRP -91.
        val camped = lte(0, pci = 1, earfcn = 3350, status = CellSnapshot.CONNECTION_NONE, registered = true)
        val neighbour = lte(0, pci = 2, earfcn = 3350, status = CellSnapshot.CONNECTION_NONE, registered = false)
        val selection = ServingCellSelector.select(listOf(neighbour, camped))
        assertEquals(camped, selection.primary)
        assertNull(selection.nsaSecondary)
    }

    @Test
    fun anIdlePhoneWithNoRegisteredCellHasNoPrimary() {
        // Statuses reported and nothing camped: a genuine out-of-service answer, not a guess.
        val selection = ServingCellSelector.select(
            listOf(lte(0, status = CellSnapshot.CONNECTION_NONE, registered = false), lte(0, pci = 1, status = CellSnapshot.CONNECTION_NONE, registered = false)),
        )
        assertNull(selection.primary)
    }

    @Test
    fun aRegisteredSecondaryLegIsNotPromotedToPrimary() {
        val leg = nr(0, status = CellSnapshot.CONNECTION_SECONDARY_SERVING, registered = true)
        assertNull(ServingCellSelector.select(listOf(leg)).primary)
    }

    @Test
    fun aPrimaryByStatusStillBeatsARegisteredIdleCell() {
        val idle = lte(0, pci = 1, status = CellSnapshot.CONNECTION_NONE, registered = true)
        val connected = lte(0, pci = 7, status = CellSnapshot.CONNECTION_PRIMARY_SERVING, registered = false)
        assertEquals(connected, ServingCellSelector.select(listOf(idle, connected)).primary)
    }

    @Test
    fun aGsmPrimaryIsReturned() {
        val cell = gsm(0, status = CellSnapshot.CONNECTION_PRIMARY_SERVING)
        val selection = ServingCellSelector.select(listOf(cell, nr(0)))
        assertEquals(Rat.GSM, selection.primary!!.rat)
        assertNull(selection.nsaSecondary)
    }

    @Test
    fun theFirstOfTwoPrimariesWins() {
        val first = lte(0, pci = 1)
        val second = lte(0, pci = 2)
        assertEquals(first, ServingCellSelector.select(listOf(first, second)).primary)
    }

    @Test
    fun equalCellsStayApartByPosition() {
        val cell = lte(0)
        assertEquals(ServingIndices(primary = 0, nsaSecondary = null), ServingCellSelector.selectIndices(listOf(cell, cell)))
    }

    @Test
    fun anEmptyListHasNoServingCells() {
        assertEquals(ServingSelection(null, null), ServingCellSelector.select(emptyList()))
    }

    @Test
    fun emergencyOnlyComesFromServiceStateNeverFromACell() {
        assertTrue(ServingCellSelector.isEmergencyOnly(serviceState(0, ServiceRegState.EMERGENCY_ONLY)))
        assertTrue(ServingCellSelector.isEmergencyOnly(serviceState(0, ServiceRegState.OUT_OF_SERVICE, emergencyOnly = true)))
        assertFalse(ServingCellSelector.isEmergencyOnly(serviceState(0, ServiceRegState.IN_SERVICE)))
        assertFalse(ServingCellSelector.isEmergencyOnly(serviceState(0, ServiceRegState.OUT_OF_SERVICE)))

        // The SIM-less phone's emergency-camped NR cell is registered and primary: still a serving cell.
        val camped = nr(0, pci = 55, status = CellSnapshot.CONNECTION_PRIMARY_SERVING, registered = true)
        assertEquals(camped, ServingCellSelector.select(listOf(camped)).primary)
    }

    @Test
    fun outOfServiceIsOutOfServiceOrRadioOffButNotEmergencyOnly() {
        assertTrue(ServingCellSelector.isOutOfService(serviceState(0, ServiceRegState.OUT_OF_SERVICE)))
        assertTrue(ServingCellSelector.isOutOfService(serviceState(0, ServiceRegState.POWER_OFF)))
        assertFalse(ServingCellSelector.isOutOfService(serviceState(0, ServiceRegState.OUT_OF_SERVICE, emergencyOnly = true)))
        assertFalse(ServingCellSelector.isOutOfService(serviceState(0, ServiceRegState.EMERGENCY_ONLY)))
        assertFalse(ServingCellSelector.isOutOfService(serviceState(0, ServiceRegState.IN_SERVICE)))
        assertFalse(ServingCellSelector.isOutOfService(serviceState(0, ServiceRegState.UNKNOWN)))
    }
}
