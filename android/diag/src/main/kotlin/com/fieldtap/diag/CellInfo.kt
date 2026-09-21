package com.fieldtap.diag

/**
 * 0xB0C2 LTE RRC Serving Cell Info: who the cell the phone is camped on actually is.
 *
 * The RRC OTA header names a cell by PCI and EARFCN, which is enough to tell two cells apart but not enough
 * to look one up: the PLMN, the tracking area and the cell identity are in this record instead. Ported from
 * `fieldtap/decode/cellinfo.py`, which reads the same two layouts.
 *
 * A record whose fields are out of range is rejected rather than shown: a layout that does not fit this modem
 * would otherwise produce a confident-looking PLMN that is noise.
 *
 * Owner: workstream `diag-on-handset`.
 */
object CellInfo {

    /** What the modem says about the cell it is camped on. */
    data class Serving(
        val pci: Int,
        val downlinkEarfcn: Long,
        val uplinkEarfcn: Long,
        val band: Int,
        val plmn: String,
        val tac: Int,
        /** E-UTRAN cell identity: the eNB and the sector within it. */
        val cellIdentity: Long,
        val bandwidthMhz: Double?,
    ) {
        val enb: Long get() = cellIdentity shr 8
        val sector: Int get() = (cellIdentity and 0xFF).toInt()
    }

    /** Older records index a table of bandwidths; newer ones count resource blocks. Both are unambiguous. */
    private val BANDWIDTH_INDEX = mapOf(0 to 1.4, 1 to 3.0, 2 to 5.0, 3 to 10.0, 4 to 15.0, 5 to 20.0)
    private val BANDWIDTH_PRBS = mapOf(6 to 1.4, 15 to 3.0, 25 to 5.0, 50 to 10.0, 75 to 15.0, 100 to 20.0)

    private fun bandwidth(raw: Int): Double? = BANDWIDTH_PRBS[raw] ?: BANDWIDTH_INDEX[raw]

    private fun u8(b: ByteArray, i: Int) = b[i].toInt() and 0xFF
    private fun u16(b: ByteArray, i: Int) = u8(b, i) or (u8(b, i + 1) shl 8)
    private fun u32(b: ByteArray, i: Int) = (u16(b, i).toLong()) or (u16(b, i + 2).toLong() shl 16)

    fun serving(body: ByteArray): Serving? {
        if (body.isEmpty()) return null
        // Version 2 keeps the EARFCNs in 16 bits; every modern modem uses the 32-bit layout.
        val wide = u8(body, 0) != 2
        val size = if (wide) 27 else 23
        if (body.size < 1 + size) return null
        var at = 1
        fun earfcn(): Long = if (wide) u32(body, at).also { at += 4 } else u16(body, at).toLong().also { at += 2 }
        val pci = u16(body, at).also { at += 2 }
        val downlink = earfcn()
        val uplink = earfcn()
        val downlinkBandwidth = u8(body, at).also { at += 1 }
        at += 1 // uplink bandwidth, always the same as the downlink on FDD
        val cellIdentity = u32(body, at).also { at += 4 }
        val tac = u16(body, at).also { at += 2 }
        val band = u32(body, at).also { at += 4 }
        val mcc = u16(body, at).also { at += 2 }
        val mncDigits = u8(body, at).also { at += 1 }
        val mnc = u16(body, at)
        if (pci > 1007 || band !in 1..256 || mcc > 999) return null
        return Serving(
            pci = pci,
            downlinkEarfcn = downlink,
            uplinkEarfcn = uplink,
            band = band.toInt(),
            plmn = mcc.toString().padStart(3, '0') + "-" + mnc.toString().padStart(if (mncDigits == 3) 3 else 2, '0'),
            tac = tac,
            cellIdentity = cellIdentity,
            bandwidthMhz = bandwidth(downlinkBandwidth),
        )
    }
}
