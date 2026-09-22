// TS 36.213 transport block sizes: table 7.1.7.2.1-1 (I_TBS x N_PRB), the PDSCH MCS tables 7.1.7.1-1 and -1A
// and the PUSCH MCS table 8.6.1-1. The 34 x 110 TBS table is generated source (LteTbsTable.swift, written by
// Tests/FTPhyTests/TestData/tools/gen_lte_tbs.py from the 3GPP document itself); the short MCS tables are here.

/// TS 36.213 table 7.1.7.2.1-1.
public enum LteTbs {
    /// Transport block size in bits for one layer, or nil outside the table (or when this build carries no table).
    public static func bits(iTbs: Int, nPrb: Int) -> Int? { LteTbsLookup.builtIn.bits(iTbs: iTbs, nPrb: nPrb) }

    /// True when this build carries the TS 36.213 table. Without it the TBS self-checks and the derived UL MCS
    /// cannot run, and the Radio page says so.
    public static var isAvailable: Bool { LteTbsLookup.builtIn.isAvailable }

    /// Table 7.1.7.1-1: PDSCH MCS 0-28 -> I_TBS (64QAM table).
    static let dlMcsToITbs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 10, 11, 12, 13, 14, 15, 15, 16, 17, 18, 19, 20, 21, 22,
                              23, 24, 25, 26]
    /// Table 7.1.7.1-1A: PDSCH MCS 0-27 -> I_TBS (256QAM table).
    static let dlMcs256ToITbs = [0, 2, 4, 6, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 27, 28,
                                 29, 30, 31, 32, 33]
    /// Table 8.6.1-1: PUSCH MCS 0-28 -> I_TBS.
    static let ulMcsToITbs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22,
                              23, 24, 25, 26]

    /// Table 8.6.1-1's modulation order per PUSCH MCS (no 64QAM restriction): QPSK 0-10, 16QAM 11-20, 64QAM 21-28.
    static func ulQm(mcs: Int) -> Int? {
        switch mcs {
        case 0...10: 2
        case 11...20: 4
        case 21...28: 6
        default: nil
        }
    }
}

/// A TBS table to look sizes up in: the generated one, or one a test supplies (the reference extractor's copy).
struct LteTbsLookup: Sendable {
    /// rows[I_TBS][N_PRB - 1] in bits.
    let rows: [[Int32]]

    static let builtIn = LteTbsLookup(rows: LteTbsTable.rows)

    var isAvailable: Bool { !rows.isEmpty }

    func bits(iTbs: Int, nPrb: Int) -> Int? {
        guard rows.indices.contains(iTbs), nPrb >= 1, nPrb <= rows[iTbs].count else { return nil }
        return Int(rows[iTbs][nPrb - 1])
    }

    /// PDSCH TBS for an MCS: `layers` > 1 reads the 2 x N_PRB column (TS 36.213 7.1.7.2.2, N_PRB <= 55); larger
    /// allocations need the layer translation table, which 10 MHz cells never reach.
    func dl(mcs: Int, nPrb: Int, layers: Int, table256: Bool) -> Int? {
        let table = table256 ? LteTbs.dlMcs256ToITbs : LteTbs.dlMcsToITbs
        guard table.indices.contains(mcs) else { return nil }
        return bits(iTbs: table[mcs], nPrb: nPrb * layers)
    }

    /// Every I_TBS whose size at `nPrb` is `bits`.
    func iTbs(matching bits: Int, nPrb: Int) -> [Int] {
        rows.indices.filter { self.bits(iTbs: $0, nPrb: nPrb) == bits }
    }

    /// The PUSCH MCS a (TBS, nRB, Qm) triple implies, by inverting table 8.6.1-1: the MCSs whose I_TBS gives the
    /// size and whose modulation matches. Empty when nothing fits, several when it is ambiguous.
    func ulMcs(bits: Int, nPrb: Int, qm: Int?) -> (matchesTable: Bool, mcs: [Int]) {
        let candidates = iTbs(matching: bits, nPrb: nPrb)
        let mcs = (0...28).filter { m in candidates.contains(LteTbs.ulMcsToITbs[m]) && LteTbs.ulQm(mcs: m) == qm }
        return (!candidates.isEmpty, mcs)
    }
}
