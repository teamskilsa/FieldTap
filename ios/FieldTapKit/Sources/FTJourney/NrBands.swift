// NR operating bands by downlink NR-ARFCN, from 3GPP TS 38.104 table 5.2-1 (band edges) converted with the
// global raster of table 5.4.2.1-1. Facts from the specification, not from any decoder's tables.

import FTCore

public enum NrBands {
    /// One band's downlink NR-ARFCN range, inclusive.
    struct Band: Sendable {
        var band: Int
        var first: Int64
        var last: Int64
    }

    /// Every FR1 band with a downlink (n1-n105; the SUL-only bands n80-n84, n86, n89, n95, n97-n99 have none)
    /// and the FR2 bands n257-n262.
    static let bands: [Band] = [
        Band(band: 1, first: 422_000, last: 434_000),      // 2110-2170 MHz
        Band(band: 2, first: 386_000, last: 398_000),      // 1930-1990
        Band(band: 3, first: 361_000, last: 376_000),      // 1805-1880
        Band(band: 5, first: 173_800, last: 178_800),      // 869-894
        Band(band: 7, first: 524_000, last: 538_000),      // 2620-2690
        Band(band: 8, first: 185_000, last: 192_000),      // 925-960
        Band(band: 12, first: 145_800, last: 149_200),     // 729-746
        Band(band: 13, first: 149_200, last: 151_200),     // 746-756
        Band(band: 14, first: 151_600, last: 153_600),     // 758-768
        Band(band: 18, first: 172_000, last: 175_000),     // 860-875
        Band(band: 20, first: 158_200, last: 164_200),     // 791-821
        Band(band: 24, first: 305_000, last: 311_800),     // 1525-1559
        Band(band: 25, first: 386_000, last: 399_000),     // 1930-1995
        Band(band: 26, first: 171_800, last: 178_800),     // 859-894
        Band(band: 28, first: 151_600, last: 160_600),     // 758-803
        Band(band: 29, first: 143_400, last: 145_600),     // 717-728
        Band(band: 30, first: 470_000, last: 472_000),     // 2350-2360
        Band(band: 31, first: 92_500, last: 93_500),       // 462.5-467.5
        Band(band: 34, first: 402_000, last: 405_000),     // 2010-2025
        Band(band: 38, first: 514_000, last: 524_000),     // 2570-2620
        Band(band: 39, first: 376_000, last: 384_000),     // 1880-1920
        Band(band: 40, first: 460_000, last: 480_000),     // 2300-2400
        Band(band: 41, first: 499_200, last: 537_999),     // 2496-2690
        Band(band: 46, first: 743_334, last: 795_000),     // 5150-5925
        Band(band: 47, first: 790_334, last: 795_000),     // 5855-5925
        Band(band: 48, first: 636_667, last: 646_666),     // 3550-3700
        Band(band: 50, first: 286_400, last: 303_400),     // 1432-1517
        Band(band: 51, first: 285_400, last: 286_400),     // 1427-1432
        Band(band: 53, first: 496_700, last: 499_000),     // 2483.5-2495
        Band(band: 54, first: 334_000, last: 335_000),     // 1670-1675
        Band(band: 65, first: 422_000, last: 440_000),     // 2110-2200
        Band(band: 66, first: 422_000, last: 440_000),     // 2110-2200
        Band(band: 67, first: 147_600, last: 151_600),     // 738-758
        Band(band: 70, first: 399_000, last: 404_000),     // 1995-2020
        Band(band: 71, first: 123_400, last: 130_400),     // 617-652
        Band(band: 72, first: 92_200, last: 93_200),       // 461-466
        Band(band: 74, first: 295_000, last: 303_600),     // 1475-1518
        Band(band: 75, first: 286_400, last: 303_400),     // 1432-1517
        Band(band: 76, first: 285_400, last: 286_400),     // 1427-1432
        Band(band: 77, first: 620_000, last: 680_000),     // 3300-4200
        Band(band: 78, first: 620_000, last: 653_333),     // 3300-3800
        Band(band: 79, first: 693_334, last: 733_333),     // 4400-5000
        Band(band: 85, first: 145_600, last: 149_200),     // 728-746
        Band(band: 90, first: 499_200, last: 538_000),     // 2496-2690
        Band(band: 91, first: 285_400, last: 286_400),     // 1427-1432
        Band(band: 92, first: 286_400, last: 303_400),     // 1432-1517
        Band(band: 93, first: 285_400, last: 286_400),     // 1427-1432
        Band(band: 94, first: 286_400, last: 303_400),     // 1432-1517
        Band(band: 96, first: 795_000, last: 875_000),     // 5925-7125
        Band(band: 100, first: 183_880, last: 185_000),    // 919.4-925
        Band(band: 101, first: 380_000, last: 382_000),    // 1900-1910
        Band(band: 102, first: 795_000, last: 828_333),    // 5925-6425
        Band(band: 104, first: 828_334, last: 875_000),    // 6425-7125
        Band(band: 105, first: 122_400, last: 130_400),    // 612-652
        Band(band: 257, first: 2_054_166, last: 2_104_165), // 26.5-29.5 GHz
        Band(band: 258, first: 2_016_667, last: 2_070_832), // 24.25-27.5
        Band(band: 259, first: 2_270_833, last: 2_337_499), // 39.5-43.5
        Band(band: 260, first: 2_229_166, last: 2_279_165), // 37-40
        Band(band: 261, first: 2_070_833, last: 2_084_999), // 27.5-28.35
        Band(band: 262, first: 2_399_166, last: 2_415_832), // 47.2-48.2
    ]

    /// The bands used in Canada (MCC 302), the United States (310-316) and Mexico (334). A band outside this set
    /// is not offered for those networks: 873.85 MHz is n5, n18 and n26 on paper, but n18 is a Japanese band.
    static let northAmerica: Set<Int> = [2, 5, 7, 12, 13, 14, 25, 26, 29, 30, 38, 41, 46, 48, 53, 66, 70, 71, 77, 85,
                                         90, 96, 102, 104, 105, 258, 260, 261, 262]

    /// NR bands whose DL range holds `arfcn` (TS 38.104), narrowed by region for MCC 302, 310-316 and 334. Test
    /// PLMNs (001, 999) and every other MCC are not narrowed, and overlapping bands are all listed: 647328
    /// (3709.92 MHz) gives [77, 78], 501390 gives [41, 90], 174770 on MCC 310 gives [5, 26].
    public static func candidates(arfcn: Int64, mcc: Int?) -> [Int] {
        let all = bands.filter { arfcn >= $0.first && arfcn <= $0.last }.map(\.band)
        guard let mcc, isNorthAmerican(mcc) else { return all }
        let narrowed = all.filter { northAmerica.contains($0) }
        return narrowed.isEmpty ? all : narrowed
    }

    public static func dlMhz(arfcn: Int64) -> Double? { Spectrum.nrMhz(arfcn) }

    static func isNorthAmerican(_ mcc: Int) -> Bool { mcc == 302 || (310...316).contains(mcc) || mcc == 334 }
}
