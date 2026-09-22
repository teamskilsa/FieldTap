// Port of ios/Contract/src-v1/Spectrum.kt (android core/radio Spectrum.kt): channel numbers as frequencies, and
// cell identities as the parts an engineer reads. Computed from 3GPP tables, not a carrier database, so they are
// right for a test network on PLMN 001-01 exactly as for a commercial one. The journey (J6, J9) and the ladder
// read bands and MHz from here.

/** A downlink and, for FDD, uplink carrier frequency. TDD bands have the same frequency both ways. */
export interface Carrier {
  band: number;
  dlMhz: number;
  ulMhz: number | null;
  tdd: boolean;
}

/** One LTE band: N_Offs-DL, the last DL EARFCN, F_DL_low, and the uplink's N_Offs-UL and F_UL_low (TS 36.101 table 5.7.3-1). */
type LteBand = [band: number, dlOffset: number, dlLast: number, dlLowMhz: number, ulOffset: number | null, ulLowMhz: number | null, tdd?: boolean];

const LTE_BANDS: readonly LteBand[] = [
  [1, 0, 599, 2110.0, 18_000, 1920.0],
  [2, 600, 1_199, 1930.0, 18_600, 1850.0],
  [3, 1_200, 1_949, 1805.0, 19_200, 1710.0],
  [4, 1_950, 2_399, 2110.0, 19_950, 1710.0],
  [5, 2_400, 2_649, 869.0, 20_400, 824.0],
  [6, 2_650, 2_749, 875.0, 20_650, 830.0],
  [7, 2_750, 3_449, 2620.0, 20_750, 2500.0],
  [8, 3_450, 3_799, 925.0, 21_450, 880.0],
  [9, 3_800, 4_149, 1844.9, 21_800, 1749.9],
  [10, 4_150, 4_749, 2110.0, 22_150, 1710.0],
  [11, 4_750, 4_949, 1475.9, 22_750, 1427.9],
  [12, 5_010, 5_179, 729.0, 23_010, 699.0],
  [13, 5_180, 5_279, 746.0, 23_180, 777.0],
  [14, 5_280, 5_379, 758.0, 23_280, 788.0],
  [17, 5_730, 5_849, 734.0, 23_730, 704.0],
  [18, 5_850, 5_999, 860.0, 23_850, 815.0],
  [19, 6_000, 6_149, 875.0, 24_000, 830.0],
  [20, 6_150, 6_449, 791.0, 24_150, 832.0],
  [21, 6_450, 6_599, 1495.9, 24_450, 1447.9],
  [22, 6_600, 7_399, 3510.0, 24_600, 3410.0],
  [23, 7_500, 7_699, 2180.0, 25_500, 2000.0],
  [24, 7_700, 8_039, 1525.0, 25_700, 1626.5],
  [25, 8_040, 8_689, 1930.0, 26_040, 1850.0],
  [26, 8_690, 9_039, 859.0, 26_690, 814.0],
  [27, 9_040, 9_209, 852.0, 27_040, 807.0],
  [28, 9_210, 9_659, 758.0, 27_210, 703.0],
  [29, 9_660, 9_769, 717.0, null, null],
  [30, 9_770, 9_869, 2350.0, 27_660, 2305.0],
  [31, 9_870, 9_919, 462.5, 27_760, 452.5],
  [32, 9_920, 10_359, 1452.0, null, null],
  [33, 36_000, 36_199, 1900.0, null, null, true],
  [34, 36_200, 36_349, 2010.0, null, null, true],
  [35, 36_350, 36_949, 1850.0, null, null, true],
  [36, 36_950, 37_549, 1930.0, null, null, true],
  [37, 37_550, 37_749, 1910.0, null, null, true],
  [38, 37_750, 38_249, 2570.0, null, null, true],
  [39, 38_250, 38_649, 1880.0, null, null, true],
  [40, 38_650, 39_649, 2300.0, null, null, true],
  [41, 39_650, 41_589, 2496.0, null, null, true],
  [42, 41_590, 43_589, 3400.0, null, null, true],
  [43, 43_590, 45_589, 3600.0, null, null, true],
  [44, 45_590, 46_589, 703.0, null, null, true],
  [45, 46_590, 46_789, 1447.0, null, null, true],
  [46, 46_790, 54_539, 5150.0, null, null, true],
  [47, 54_540, 55_239, 5855.0, null, null, true],
  [48, 55_240, 56_739, 3550.0, null, null, true],
  [49, 56_740, 58_239, 3550.0, null, null, true],
  [50, 58_240, 59_089, 1432.0, null, null, true],
  [51, 59_090, 59_139, 1427.0, null, null, true],
  [52, 59_140, 60_139, 3300.0, null, null, true],
  [53, 60_140, 60_254, 2483.5, null, null, true],
  [65, 65_536, 66_435, 2110.0, 131_072, 1920.0],
  [66, 66_436, 67_335, 2110.0, 131_972, 1710.0],
  [67, 67_336, 67_535, 738.0, null, null],
  [68, 67_536, 67_835, 753.0, 132_672, 698.0],
  [69, 67_836, 68_335, 2570.0, null, null],
  [70, 68_336, 68_585, 1995.0, 132_972, 1695.0],
  [71, 68_586, 68_935, 617.0, 133_122, 663.0],
  [72, 68_936, 68_985, 461.0, 133_472, 451.0],
  [73, 68_986, 69_035, 460.0, 133_522, 450.0],
  [74, 69_036, 69_465, 1475.0, 133_572, 1427.0],
  [85, 70_366, 70_545, 728.0, 134_002, 698.0],
  [87, 70_546, 70_595, 420.0, 134_182, 410.0],
  [88, 70_596, 70_645, 422.0, 134_232, 412.0],
];

// Java's Math.round (ties toward +infinity), which Math.round matches exactly.
const round1 = (v: number) => Math.round(v * 10) / 10.0;
const round3 = (v: number) => Math.round(v * 1000) / 1000.0;

/**
 * The carrier an LTE downlink EARFCN is on. The band comes from the EARFCN itself (the downlink ranges do not
 * overlap), so a modem that reports band -1, as the OnePlus does for one of its two copies of a cell, still
 * gets a frequency.
 */
export function lteCarrier(dlEarfcn: number | null): Carrier | null {
  if (dlEarfcn === null) return null;
  const b = LTE_BANDS.find(([, first, last]) => dlEarfcn >= first && dlEarfcn <= last);
  if (!b) return null;
  const [band, dlOffset, , dlLowMhz, ulOffset, ulLowMhz, tdd = false] = b;
  const dl = dlLowMhz + 0.1 * (dlEarfcn - dlOffset);
  // FDD: the uplink EARFCN sits the same distance into its range as the downlink one.
  const ul = tdd ? dl : ulOffset !== null && ulLowMhz !== null ? ulLowMhz + 0.1 * (dlEarfcn - dlOffset) : null;
  return { band, dlMhz: round1(dl), ulMhz: ul === null ? null : round1(ul), tdd };
}

/**
 * The frequency of an NR-ARFCN on the global raster, TS 38.104 table 5.4.2.1-1. The band is not derivable from
 * the ARFCN alone (NR bands overlap, n77 contains n78), so it is not guessed.
 */
export function nrMhz(nrArfcn: number | null): number | null {
  if (nrArfcn === null) return null;
  if (nrArfcn >= 0 && nrArfcn <= 599_999) return round3(0.005 * nrArfcn);
  if (nrArfcn >= 600_000 && nrArfcn <= 2_016_666) return round3(3000.0 + 0.015 * (nrArfcn - 600_000));
  if (nrArfcn >= 2_016_667 && nrArfcn <= 3_279_165) return round3(24_250.08 + 0.06 * (nrArfcn - 2_016_667));
  return null;
}

export interface LteCellId {
  enb: number;
  cell: number;
}

const MAX_ECI = 2 ** 28 - 1;
const MAX_LTE_TA = 1282;
export const LTE_TA_METRES = 78.12;

/**
 * ECI is 28 bits: a 20-bit eNB ID and an 8-bit cell ID, fixed by TS 36.413. Out of range gives null. No NR
 * equivalent: the gNB ID is 22 to 32 bits and the split is the operator's choice, so any split would be a guess.
 */
export function lteCellId(eci: number | null): LteCellId | null {
  if (eci === null || eci < 0 || eci > MAX_ECI) return null;
  return { enb: Math.floor(eci / 256), cell: eci & 0xff };
}

/** Distance to the eNB from the LTE timing advance: 16 Ts of round trip per step, 78.12 m. Rough (multipath). */
export function lteTimingAdvanceMetres(ta: number | null): number | null {
  return ta === null || ta < 0 || ta > MAX_LTE_TA ? null : ta * LTE_TA_METRES;
}
