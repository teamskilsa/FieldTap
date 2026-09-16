package com.fieldtap.core.radio

/**
 * Channel numbers as frequencies, and cell identities as the parts an engineer reads.
 *
 * Android reports an EARFCN or NR-ARFCN and a 28- or 36-bit cell identity. What someone standing in a
 * lab checks against the callbox configuration is "2680.0 MHz" and "eNB 107216, cell 1". These are
 * computed from 3GPP tables, not looked up from a carrier database, so they are right for a test
 * network on PLMN 001-01 exactly as for a commercial one.
 *
 * Owner: workstream `radio-core`.
 */
object Spectrum {

    /** A downlink and, for FDD, uplink carrier frequency. TDD bands have the same frequency both ways. */
    data class Carrier(val band: Int, val dlMhz: Double, val ulMhz: Double?, val tdd: Boolean)

    /**
     * One LTE band: the first downlink EARFCN (N_Offs-DL) and its frequency (F_DL_low), and the same
     * for uplink when the band has one. TS 36.101 table 5.7.3-1.
     */
    private class LteBand(
        val band: Int,
        val dlOffset: Int,
        val dlLast: Int,
        val dlLowMhz: Double,
        val ulOffset: Int?,
        val ulLowMhz: Double?,
        val tdd: Boolean = false,
    )

    private val LTE_BANDS: List<LteBand> = listOf(
        LteBand(1, 0, 599, 2110.0, 18_000, 1920.0),
        LteBand(2, 600, 1_199, 1930.0, 18_600, 1850.0),
        LteBand(3, 1_200, 1_949, 1805.0, 19_200, 1710.0),
        LteBand(4, 1_950, 2_399, 2110.0, 19_950, 1710.0),
        LteBand(5, 2_400, 2_649, 869.0, 20_400, 824.0),
        LteBand(6, 2_650, 2_749, 875.0, 20_650, 830.0),
        LteBand(7, 2_750, 3_449, 2620.0, 20_750, 2500.0),
        LteBand(8, 3_450, 3_799, 925.0, 21_450, 880.0),
        LteBand(9, 3_800, 4_149, 1844.9, 21_800, 1749.9),
        LteBand(10, 4_150, 4_749, 2110.0, 22_150, 1710.0),
        LteBand(11, 4_750, 4_949, 1475.9, 22_750, 1427.9),
        LteBand(12, 5_010, 5_179, 729.0, 23_010, 699.0),
        LteBand(13, 5_180, 5_279, 746.0, 23_180, 777.0),
        LteBand(14, 5_280, 5_379, 758.0, 23_280, 788.0),
        LteBand(17, 5_730, 5_849, 734.0, 23_730, 704.0),
        LteBand(18, 5_850, 5_999, 860.0, 23_850, 815.0),
        LteBand(19, 6_000, 6_149, 875.0, 24_000, 830.0),
        LteBand(20, 6_150, 6_449, 791.0, 24_150, 832.0),
        LteBand(21, 6_450, 6_599, 1495.9, 24_450, 1447.9),
        LteBand(22, 6_600, 7_399, 3510.0, 24_600, 3410.0),
        LteBand(23, 7_500, 7_699, 2180.0, 25_500, 2000.0),
        LteBand(24, 7_700, 8_039, 1525.0, 25_700, 1626.5),
        LteBand(25, 8_040, 8_689, 1930.0, 26_040, 1850.0),
        LteBand(26, 8_690, 9_039, 859.0, 26_690, 814.0),
        LteBand(27, 9_040, 9_209, 852.0, 27_040, 807.0),
        LteBand(28, 9_210, 9_659, 758.0, 27_210, 703.0),
        LteBand(29, 9_660, 9_769, 717.0, null, null),
        LteBand(30, 9_770, 9_869, 2350.0, 27_660, 2305.0),
        LteBand(31, 9_870, 9_919, 462.5, 27_760, 452.5),
        LteBand(32, 9_920, 10_359, 1452.0, null, null),
        LteBand(33, 36_000, 36_199, 1900.0, null, null, tdd = true),
        LteBand(34, 36_200, 36_349, 2010.0, null, null, tdd = true),
        LteBand(35, 36_350, 36_949, 1850.0, null, null, tdd = true),
        LteBand(36, 36_950, 37_549, 1930.0, null, null, tdd = true),
        LteBand(37, 37_550, 37_749, 1910.0, null, null, tdd = true),
        LteBand(38, 37_750, 38_249, 2570.0, null, null, tdd = true),
        LteBand(39, 38_250, 38_649, 1880.0, null, null, tdd = true),
        LteBand(40, 38_650, 39_649, 2300.0, null, null, tdd = true),
        LteBand(41, 39_650, 41_589, 2496.0, null, null, tdd = true),
        LteBand(42, 41_590, 43_589, 3400.0, null, null, tdd = true),
        LteBand(43, 43_590, 45_589, 3600.0, null, null, tdd = true),
        LteBand(44, 45_590, 46_589, 703.0, null, null, tdd = true),
        LteBand(45, 46_590, 46_789, 1447.0, null, null, tdd = true),
        LteBand(46, 46_790, 54_539, 5150.0, null, null, tdd = true),
        LteBand(47, 54_540, 55_239, 5855.0, null, null, tdd = true),
        LteBand(48, 55_240, 56_739, 3550.0, null, null, tdd = true),
        LteBand(49, 56_740, 58_239, 3550.0, null, null, tdd = true),
        LteBand(50, 58_240, 59_089, 1432.0, null, null, tdd = true),
        LteBand(51, 59_090, 59_139, 1427.0, null, null, tdd = true),
        LteBand(52, 59_140, 60_139, 3300.0, null, null, tdd = true),
        LteBand(53, 60_140, 60_254, 2483.5, null, null, tdd = true),
        LteBand(65, 65_536, 66_435, 2110.0, 131_072, 1920.0),
        LteBand(66, 66_436, 67_335, 2110.0, 131_972, 1710.0),
        LteBand(67, 67_336, 67_535, 738.0, null, null),
        LteBand(68, 67_536, 67_835, 753.0, 132_672, 698.0),
        LteBand(69, 67_836, 68_335, 2570.0, null, null),
        LteBand(70, 68_336, 68_585, 1995.0, 132_972, 1695.0),
        LteBand(71, 68_586, 68_935, 617.0, 133_122, 663.0),
        LteBand(72, 68_936, 68_985, 461.0, 133_472, 451.0),
        LteBand(73, 68_986, 69_035, 460.0, 133_522, 450.0),
        LteBand(74, 69_036, 69_465, 1475.0, 133_572, 1427.0),
        LteBand(85, 70_366, 70_545, 728.0, 134_002, 698.0),
        LteBand(87, 70_546, 70_595, 420.0, 134_182, 410.0),
        LteBand(88, 70_596, 70_645, 422.0, 134_232, 412.0),
    )

    /**
     * The carrier an LTE downlink EARFCN is on. The band comes from the EARFCN itself — the downlink
     * ranges do not overlap — so a modem that reports band -1, as the OnePlus does for one of its two
     * copies of the same cell, still gets a frequency.
     */
    fun lte(dlEarfcn: Int?): Carrier? {
        if (dlEarfcn == null) return null
        val band = LTE_BANDS.firstOrNull { dlEarfcn in it.dlOffset..it.dlLast } ?: return null
        val dl = band.dlLowMhz + 0.1 * (dlEarfcn - band.dlOffset)
        val ul = if (band.tdd) {
            dl
        } else if (band.ulOffset != null && band.ulLowMhz != null) {
            // FDD: the uplink EARFCN sits the same distance into its range as the downlink one.
            band.ulLowMhz + 0.1 * (dlEarfcn - band.dlOffset)
        } else {
            null
        }
        return Carrier(band.band, round1(dl), ul?.let(::round1), band.tdd)
    }

    /**
     * The frequency of an NR-ARFCN on the global raster, TS 38.104 table 5.4.2.1-1. The band is not
     * derivable from the ARFCN alone — NR bands overlap, n77 contains n78 — so it is not guessed.
     */
    fun nrMhz(nrArfcn: Int?): Double? = when (nrArfcn) {
        null -> null
        in 0..599_999 -> round3(0.005 * nrArfcn)
        in 600_000..2_016_666 -> round3(3000.0 + 0.015 * (nrArfcn - 600_000))
        in 2_016_667..3_279_165 -> round3(24_250.08 + 0.06 * (nrArfcn - 2_016_667))
        else -> null
    }

    /** An LTE E-UTRAN cell identity split into its eNB and cell parts. */
    data class LteCellId(val enb: Int, val cell: Int)

    /**
     * ECI is 28 bits: a 20-bit eNB ID and an 8-bit cell ID, fixed by TS 36.413. Android reports
     * `Integer.MAX_VALUE` when it does not know, which is out of range and gives null.
     *
     * No equivalent is offered for NR: the gNB ID is 22 to 32 bits long and the split is the
     * operator's choice, so any NCI split would be a guess shown as a fact.
     */
    fun lteCellId(eci: Long?): LteCellId? {
        if (eci == null || eci < 0 || eci > MAX_ECI) return null
        return LteCellId(enb = (eci shr 8).toInt(), cell = (eci and 0xFF).toInt())
    }

    /**
     * How far away the eNB is, from the LTE timing advance: each step is 16 Ts of round-trip delay,
     * 78.12 m of distance. A rough figure — multipath inflates it — but a callbox on the bench reading
     * TA 1 is a sanity check that the phone is talking to the box in the room.
     */
    fun lteTimingAdvanceMetres(ta: Int?): Double? = when {
        ta == null || ta < 0 || ta > MAX_LTE_TA -> null
        else -> ta * LTE_TA_METRES
    }

    private const val MAX_ECI = (1L shl 28) - 1
    private const val MAX_LTE_TA = 1282
    const val LTE_TA_METRES = 78.12

    private fun round1(value: Double) = Math.round(value * 10) / 10.0
    private fun round3(value: Double) = Math.round(value * 1000) / 1000.0
}
