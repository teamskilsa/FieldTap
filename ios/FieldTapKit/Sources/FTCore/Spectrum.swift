// Port of android/core/src/main/kotlin/com/fieldtap/core/radio/Spectrum.kt.

/// Channel numbers as frequencies, and cell identities as the parts an engineer reads.
///
/// Computed from 3GPP tables, not a carrier database, so they are as right for a test network on PLMN 001-01
/// as for a commercial one.
public enum Spectrum {
    /// A downlink and, for FDD, uplink carrier frequency. TDD bands have the same frequency both ways.
    public struct Carrier: Hashable, Sendable {
        public var band: Int
        public var dlMhz: Double
        public var ulMhz: Double?
        public var tdd: Bool

        public init(band: Int, dlMhz: Double, ulMhz: Double?, tdd: Bool) {
            self.band = band
            self.dlMhz = dlMhz
            self.ulMhz = ulMhz
            self.tdd = tdd
        }
    }

    /// One LTE band: the first downlink EARFCN (N_Offs-DL) and its frequency (F_DL_low), and the same for
    /// uplink when the band has one. TS 36.101 table 5.7.3-1.
    struct LteBand: Sendable {
        var band: Int
        var dlOffset: Int
        var dlLast: Int
        var dlLowMhz: Double
        var ulOffset: Int?
        var ulLowMhz: Double?
        var tdd = false
    }

    private static func b(_ band: Int, _ dlOffset: Int, _ dlLast: Int, _ dlLowMhz: Double, _ ulOffset: Int?,
                          _ ulLowMhz: Double?, tdd: Bool = false) -> LteBand {
        LteBand(band: band, dlOffset: dlOffset, dlLast: dlLast, dlLowMhz: dlLowMhz, ulOffset: ulOffset,
                ulLowMhz: ulLowMhz, tdd: tdd)
    }

    static let lteBands: [LteBand] = [
        b(1, 0, 599, 2110.0, 18_000, 1920.0),
        b(2, 600, 1_199, 1930.0, 18_600, 1850.0),
        b(3, 1_200, 1_949, 1805.0, 19_200, 1710.0),
        b(4, 1_950, 2_399, 2110.0, 19_950, 1710.0),
        b(5, 2_400, 2_649, 869.0, 20_400, 824.0),
        b(6, 2_650, 2_749, 875.0, 20_650, 830.0),
        b(7, 2_750, 3_449, 2620.0, 20_750, 2500.0),
        b(8, 3_450, 3_799, 925.0, 21_450, 880.0),
        b(9, 3_800, 4_149, 1844.9, 21_800, 1749.9),
        b(10, 4_150, 4_749, 2110.0, 22_150, 1710.0),
        b(11, 4_750, 4_949, 1475.9, 22_750, 1427.9),
        b(12, 5_010, 5_179, 729.0, 23_010, 699.0),
        b(13, 5_180, 5_279, 746.0, 23_180, 777.0),
        b(14, 5_280, 5_379, 758.0, 23_280, 788.0),
        b(17, 5_730, 5_849, 734.0, 23_730, 704.0),
        b(18, 5_850, 5_999, 860.0, 23_850, 815.0),
        b(19, 6_000, 6_149, 875.0, 24_000, 830.0),
        b(20, 6_150, 6_449, 791.0, 24_150, 832.0),
        b(21, 6_450, 6_599, 1495.9, 24_450, 1447.9),
        b(22, 6_600, 7_399, 3510.0, 24_600, 3410.0),
        b(23, 7_500, 7_699, 2180.0, 25_500, 2000.0),
        b(24, 7_700, 8_039, 1525.0, 25_700, 1626.5),
        b(25, 8_040, 8_689, 1930.0, 26_040, 1850.0),
        b(26, 8_690, 9_039, 859.0, 26_690, 814.0),
        b(27, 9_040, 9_209, 852.0, 27_040, 807.0),
        b(28, 9_210, 9_659, 758.0, 27_210, 703.0),
        b(29, 9_660, 9_769, 717.0, nil, nil),
        b(30, 9_770, 9_869, 2350.0, 27_660, 2305.0),
        b(31, 9_870, 9_919, 462.5, 27_760, 452.5),
        b(32, 9_920, 10_359, 1452.0, nil, nil),
        b(33, 36_000, 36_199, 1900.0, nil, nil, tdd: true),
        b(34, 36_200, 36_349, 2010.0, nil, nil, tdd: true),
        b(35, 36_350, 36_949, 1850.0, nil, nil, tdd: true),
        b(36, 36_950, 37_549, 1930.0, nil, nil, tdd: true),
        b(37, 37_550, 37_749, 1910.0, nil, nil, tdd: true),
        b(38, 37_750, 38_249, 2570.0, nil, nil, tdd: true),
        b(39, 38_250, 38_649, 1880.0, nil, nil, tdd: true),
        b(40, 38_650, 39_649, 2300.0, nil, nil, tdd: true),
        b(41, 39_650, 41_589, 2496.0, nil, nil, tdd: true),
        b(42, 41_590, 43_589, 3400.0, nil, nil, tdd: true),
        b(43, 43_590, 45_589, 3600.0, nil, nil, tdd: true),
        b(44, 45_590, 46_589, 703.0, nil, nil, tdd: true),
        b(45, 46_590, 46_789, 1447.0, nil, nil, tdd: true),
        b(46, 46_790, 54_539, 5150.0, nil, nil, tdd: true),
        b(47, 54_540, 55_239, 5855.0, nil, nil, tdd: true),
        b(48, 55_240, 56_739, 3550.0, nil, nil, tdd: true),
        b(49, 56_740, 58_239, 3550.0, nil, nil, tdd: true),
        b(50, 58_240, 59_089, 1432.0, nil, nil, tdd: true),
        b(51, 59_090, 59_139, 1427.0, nil, nil, tdd: true),
        b(52, 59_140, 60_139, 3300.0, nil, nil, tdd: true),
        b(53, 60_140, 60_254, 2483.5, nil, nil, tdd: true),
        b(65, 65_536, 66_435, 2110.0, 131_072, 1920.0),
        b(66, 66_436, 67_335, 2110.0, 131_972, 1710.0),
        b(67, 67_336, 67_535, 738.0, nil, nil),
        b(68, 67_536, 67_835, 753.0, 132_672, 698.0),
        b(69, 67_836, 68_335, 2570.0, nil, nil),
        b(70, 68_336, 68_585, 1995.0, 132_972, 1695.0),
        b(71, 68_586, 68_935, 617.0, 133_122, 663.0),
        b(72, 68_936, 68_985, 461.0, 133_472, 451.0),
        b(73, 68_986, 69_035, 460.0, 133_522, 450.0),
        b(74, 69_036, 69_465, 1475.0, 133_572, 1427.0),
        b(85, 70_366, 70_545, 728.0, 134_002, 698.0),
        b(87, 70_546, 70_595, 420.0, 134_182, 410.0),
        b(88, 70_596, 70_645, 422.0, 134_232, 412.0),
    ]

    /// The carrier an LTE downlink EARFCN is on. The band comes from the EARFCN itself (the downlink ranges do
    /// not overlap), so a modem that reports band -1 still gets a frequency.
    public static func lte(_ dlEarfcn: Int?) -> Carrier? {
        guard let dlEarfcn, let band = lteBands.first(where: { ($0.dlOffset...$0.dlLast).contains(dlEarfcn) }) else {
            return nil
        }
        let dl = band.dlLowMhz + 0.1 * Double(dlEarfcn - band.dlOffset)
        let ul: Double?
        if band.tdd {
            ul = dl
        } else if band.ulOffset != nil, let ulLow = band.ulLowMhz {
            // FDD: the uplink EARFCN sits the same distance into its range as the downlink one.
            ul = ulLow + 0.1 * Double(dlEarfcn - band.dlOffset)
        } else {
            ul = nil
        }
        return Carrier(band: band.band, dlMhz: round1(dl), ulMhz: ul.map(round1), tdd: band.tdd)
    }

    /// `lte(_:)` for the Int64 channel numbers the model carries.
    public static func lte(_ dlEarfcn: Int64?) -> Carrier? { lte(dlEarfcn.flatMap { Int(exactly: $0) }) }

    /// The frequency of an NR-ARFCN on the global raster, TS 38.104 table 5.4.2.1-1. The band is not derivable
    /// from the ARFCN alone (NR bands overlap; n77 contains n78), so it is not guessed here.
    public static func nrMhz(_ nrArfcn: Int?) -> Double? {
        guard let a = nrArfcn else { return nil }
        switch a {
        case 0...599_999: return round3(0.005 * Double(a))
        case 600_000...2_016_666: return round3(3000.0 + 0.015 * Double(a - 600_000))
        case 2_016_667...3_279_165: return round3(24_250.08 + 0.06 * Double(a - 2_016_667))
        default: return nil
        }
    }

    public static func nrMhz(_ nrArfcn: Int64?) -> Double? { nrMhz(nrArfcn.flatMap { Int(exactly: $0) }) }

    /// An LTE E-UTRAN cell identity split into its eNB and cell parts.
    public struct LteCellId: Hashable, Sendable {
        public var enb: Int
        public var cell: Int
    }

    /// ECI is 28 bits: a 20-bit eNB ID and an 8-bit cell ID (TS 36.413). Out of range gives nil. No NR split is
    /// offered: the gNB ID length is the operator's choice, so any NCI split would be a guess shown as a fact.
    public static func lteCellId(_ eci: Int64?) -> LteCellId? {
        guard let eci, eci >= 0, eci <= maxEci else { return nil }
        return LteCellId(enb: Int(eci >> 8), cell: Int(eci & 0xFF))
    }

    /// Distance to the eNB from the LTE timing advance: each step is 16 Ts of round trip, 78.12 m. Rough
    /// (multipath inflates it), but a bench callbox reading TA 1 confirms the phone is on the box in the room.
    public static func lteTimingAdvanceMetres(_ ta: Int?) -> Double? {
        guard let ta, ta >= 0, ta <= maxLteTa else { return nil }
        return Double(ta) * lteTaMetres
    }

    static let maxEci: Int64 = (1 << 28) - 1
    static let maxLteTa = 1282
    public static let lteTaMetres = 78.12

    /// Java's Math.round (floor of x + 0.5) to one and three decimals, so the MHz match the Kotlin exactly.
    static func round1(_ v: Double) -> Double { (v * 10 + 0.5).rounded(.down) / 10 }
    static func round3(_ v: Double) -> Double { (v * 1000 + 0.5).rounded(.down) / 1000 }
}
