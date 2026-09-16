package com.fieldtap.core.radio

import com.fieldtap.format.Rat

/**
 * PCI reuse between a serving cell and a neighbour, and how far down the neighbour is.
 *
 * Two cells on the same carrier whose physical cell identities are congruent modulo 3, 6 or 30 reuse
 * the same reference-signal resources, so each raises the other's noise floor:
 *
 * | Modulus | What is reused |
 * | --- | --- |
 * | 3 | The downlink reference-signal frequency shift (LTE CRS, NR PSS and SSB DM-RS) |
 * | 6 | The shift together with the CRS antenna-port pairing, on LTE |
 * | 30 | The uplink DM-RS base sequence group |
 *
 * The moduli nest: congruent modulo 30 is also congruent modulo 6 and modulo 3, and modulo 6 is also
 * modulo 3. [collisions] therefore returns every modulus that holds, not just the largest, and the
 * caller decides what to draw. This code states which resources are reused; it does not rank them,
 * because which one hurts depends on the load, the antenna configuration and the duplex mode, none of
 * which the public telephony API reports.
 *
 * **A reuse only matters if the neighbour is actually heard.** A cell 30 dB down interferes with
 * nothing. [marginDb] is the serving RSRP minus the neighbour's: small or negative is the dangerous
 * case, and a reuse with no margin to report is not evidence of a problem.
 *
 * Cells are only compared when they share a RAT and an ARFCN. A neighbour on another carrier reuses
 * no resources with the serving cell, so flagging it would be a false alarm.
 *
 * All of this is arithmetic on values `CellInfo` already gives an unprivileged app. Nothing here
 * needs root, a privileged permission or a site database.
 *
 * Owner: workstream `radio-core`.
 */
object PciPlanning {

    /** The moduli checked, smallest first. Congruence at a larger one implies every smaller one. */
    val MODULI: List<Int> = listOf(3, 6, 30)

    /**
     * Every modulus in [MODULI] at which [servingPci] and [neighbourPci] are congruent, or empty when
     * either identity is unknown, when the two are not on the same carrier, or when nothing is reused.
     *
     * [servingArfcn] and [neighbourArfcn] must both be known to compare: an unknown carrier is not
     * evidence of a shared one.
     */
    fun collisions(
        servingRat: Rat?,
        servingPci: Int?,
        servingArfcn: Int?,
        neighbourRat: Rat?,
        neighbourPci: Int?,
        neighbourArfcn: Int?,
    ): Set<Int> {
        if (servingPci == null || neighbourPci == null) return emptySet()
        if (servingRat == null || neighbourRat == null || servingRat != neighbourRat) return emptySet()
        if (servingArfcn == null || neighbourArfcn == null || servingArfcn != neighbourArfcn) return emptySet()
        // The same cell seen twice is not a reuse.
        if (servingPci == neighbourPci) return emptySet()
        return MODULI.filter { servingPci % it == neighbourPci % it }.toSet()
    }

    /**
     * How far below the serving cell the neighbour is, in dB: serving RSRP minus neighbour RSRP.
     * Null when either is unknown. Negative means the neighbour is the stronger of the two.
     */
    fun marginDb(servingRsrp: Int?, neighbourRsrp: Int?): Int? {
        if (servingRsrp == null || neighbourRsrp == null) return null
        return servingRsrp - neighbourRsrp
    }
}
