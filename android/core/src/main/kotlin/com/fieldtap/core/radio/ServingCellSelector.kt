package com.fieldtap.core.radio

import com.fieldtap.core.input.CellSnapshot
import com.fieldtap.core.input.ServiceRegState
import com.fieldtap.core.input.ServiceStateSnapshot
import com.fieldtap.format.Rat

/** The serving cells of one answer. */
data class ServingSelection(
    val primary: CellSnapshot?,
    val nsaSecondary: CellSnapshot?,
)

/** Positions in an answer's cell list of its serving cells, so duplicates of equal value stay apart. */
internal data class ServingIndices(
    val primary: Int?,
    val nsaSecondary: Int?,
)

/**
 * Picks the serving cells and reads service state.
 *
 * [select]:
 * - Primary: the first cell with `connectionStatus == 1` (primary serving). When no cell says that,
 *   the first registered LTE or NR cell that is not a secondary leg.
 *
 *   A registered cell is the one the phone is camped on; `connectionStatus` is the RRC state, and it
 *   is PRIMARY_SERVING only while a connection is up. An idle phone — attached, moving no data, which
 *   is most phones most of the time — reports CONNECTION_NONE on every cell, the camped one
 *   included. This used to return no primary whenever any cell reported a status, which made FieldTap
 *   say "no LTE or NR serving cell" on a OnePlus 10 Pro camped on PCI 1, EARFCN 3350, RSRP -91 dBm,
 *   with VoLTE in its status bar.
 * - NSA secondary: when the primary is LTE, the first NR cell with `connectionStatus == 2`
 *   (secondary serving). Never when the primary is NR (SA) or absent.
 * - A GSM, WCDMA, TD-SCDMA or CDMA primary is returned, but never yields a kpi.csv row.
 *
 * [isEmergencyOnly] comes from service state only (`state == EMERGENCY_ONLY` or `emergencyOnly`),
 * never from a cell: the SIM-less OnePlus reports its emergency-camped NR cell as registered.
 * Samples from an emergency-camped cell are still real measurements and still go to kpi.csv.
 *
 * [isOutOfService]: `OUT_OF_SERVICE` or `POWER_OFF`, and not emergency-only.
 *
 * Tests: NSA (LTE status 1, NR status 2, LTE neighbour status 0); SA; vendor without statuses; an idle
 * phone (every status 0); two primaries (first wins); emergency-only with a registered NR cell.
 *
 * Owner: workstream `radio-core`.
 */
object ServingCellSelector {
    fun select(cells: List<CellSnapshot>): ServingSelection {
        val indices = selectIndices(cells)
        return ServingSelection(
            primary = indices.primary?.let { cells[it] },
            nsaSecondary = indices.nsaSecondary?.let { cells[it] },
        )
    }

    fun isEmergencyOnly(state: ServiceStateSnapshot): Boolean =
        state.state == ServiceRegState.EMERGENCY_ONLY || state.emergencyOnly

    fun isOutOfService(state: ServiceStateSnapshot): Boolean =
        (state.state == ServiceRegState.OUT_OF_SERVICE || state.state == ServiceRegState.POWER_OFF) &&
            !isEmergencyOnly(state)

    /** [select], as positions in [cells]. */
    internal fun selectIndices(cells: List<CellSnapshot>): ServingIndices {
        val primary = primaryIndex(cells)
        val nsaSecondary = if (primary != null && cells[primary].rat == Rat.LTE) {
            cells.indexOfFirst {
                it.rat == Rat.NR && it.connectionStatus == CellSnapshot.CONNECTION_SECONDARY_SERVING
            }.takeIf { it >= 0 }
        } else {
            null
        }
        return ServingIndices(primary, nsaSecondary)
    }

    private fun primaryIndex(cells: List<CellSnapshot>): Int? {
        val byStatus = cells.indexOfFirst { it.connectionStatus == CellSnapshot.CONNECTION_PRIMARY_SERVING }
        if (byStatus >= 0) return byStatus
        return cells.indexOfFirst {
            it.registered &&
                (it.rat == Rat.LTE || it.rat == Rat.NR) &&
                it.connectionStatus != CellSnapshot.CONNECTION_SECONDARY_SERVING
        }.takeIf { it >= 0 }
    }
}
