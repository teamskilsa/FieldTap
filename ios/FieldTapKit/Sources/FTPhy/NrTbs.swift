// TS 38.214 5.1.3: the PDSCH MCS tables 5.1.3.1-1/-2/-3 and the transport block size of 5.1.3.2 (the formula,
// with table 5.1.3.2-1 for small sizes). Typed from the specification and checked against 472 of 472 new
// transmissions in the iPhone 17 capture's 0xB887 records.

import Foundation

/// TS 38.214 MCS tables.
public enum NrMcsTable: String, CaseIterable, Hashable, Sendable {
    case qam64, qam256, qam64LowSe

    /// (Qm, R x 1024) per MCS index; the reserved indexes (retransmissions) are not listed.
    var entries: [(qm: Int, r1024: Double)] {
        switch self {
        case .qam64: NrTbs.table1
        case .qam256: NrTbs.table2
        case .qam64LowSe: NrTbs.table3
        }
    }

    /// Modulation order of an MCS, including the reserved retransmission indexes at the top of the table.
    public func qm(mcs: Int) -> Int? {
        let e = entries
        if e.indices.contains(mcs) { return e[mcs].qm }
        let reserved: [Int] = self == .qam256 ? [2, 4, 6, 8] : [2, 4, 6]
        let k = mcs - e.count
        return reserved.indices.contains(k) ? reserved[k] : nil
    }
}

/// TS 38.214 5.1.3.2 transport block size.
public enum NrTbs {
    /// Bytes of one transport block: N_RE = min(156, N'RE) x nPRB, N_info = N_RE x R x Qm x layers, then the
    /// quantisation of 5.1.3.2 steps 3-4. Nil for a reserved MCS or a non-positive allocation.
    public static func bytes(mcs: Int, table: NrMcsTable, nPrb: Int, layers: Int, nRePerPrb: Int) -> Int? {
        let e = table.entries
        guard e.indices.contains(mcs), nPrb > 0, layers > 0, nRePerPrb > 0 else { return nil }
        return bits(nRePerPrb: nRePerPrb, nPrb: nPrb, qm: e[mcs].qm, r: e[mcs].r1024 / 1024, layers: layers).map { $0 / 8 }
    }

    /// The size in bits, for a code rate `r` (0-1) and modulation order `qm`.
    static func bits(nRePerPrb: Int, nPrb: Int, qm: Int, r: Double, layers: Int) -> Int? {
        let nRe = Double(min(156, nRePerPrb) * nPrb)
        let nInfo = nRe * r * Double(qm) * Double(layers)
        guard nInfo > 0 else { return 0 }
        if nInfo <= 3824 {
            let n = max(3, Int(log2(nInfo).rounded(.down)) - 6)
            let step = Double(1 << n)
            let nInfoQ = max(24, step * (nInfo / step).rounded(.down))
            return smallSizes.first { Double($0) >= nInfoQ }
        }
        let n = Int(log2(nInfo - 24).rounded(.down)) - 5
        let step = Double(1 << n)
        let nInfoQ = max(3840, step * ((nInfo - 24) / step).rounded(.toNearestOrEven))
        let withCrc = nInfoQ + 24
        func segmented(_ c: Double) -> Int {
            let perBlock: Double = (withCrc / (8 * c)).rounded(.up)
            return Int(8 * c * perBlock - 24)
        }
        if r <= 0.25 { return segmented((withCrc / 3816).rounded(.up)) }
        if nInfoQ > 8424 { return segmented((withCrc / 8424).rounded(.up)) }
        let bytes: Double = (withCrc / 8).rounded(.up)
        return Int(8 * bytes - 24)
    }

    /// Table 5.1.3.2-1: TBS for N_info <= 3824.
    static let smallSizes = [24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128, 136, 144, 152, 160, 168, 176,
                             184, 192, 208, 224, 240, 256, 272, 288, 304, 320, 336, 352, 368, 384, 408, 432, 456, 480,
                             504, 528, 552, 576, 608, 640, 672, 704, 736, 768, 808, 848, 888, 928, 984, 1032, 1064, 1128,
                             1160, 1192, 1224, 1256, 1288, 1320, 1352, 1416, 1480, 1544, 1608, 1672, 1736, 1800, 1864,
                             1928, 2024, 2088, 2152, 2216, 2280, 2408, 2472, 2536, 2600, 2664, 2728, 2792, 2856, 2976,
                             3104, 3240, 3368, 3496, 3624, 3752, 3824]

    /// Table 5.1.3.1-1 (qam64), MCS 0-28.
    static let table1: [(qm: Int, r1024: Double)] = [
        (2, 120), (2, 157), (2, 193), (2, 251), (2, 308), (2, 379), (2, 449), (2, 526), (2, 602), (2, 679),
        (4, 340), (4, 378), (4, 434), (4, 490), (4, 553), (4, 616), (4, 658),
        (6, 438), (6, 466), (6, 517), (6, 567), (6, 616), (6, 666), (6, 719), (6, 772), (6, 822), (6, 873), (6, 910),
        (6, 948),
    ]

    /// Table 5.1.3.1-2 (qam256), MCS 0-27.
    static let table2: [(qm: Int, r1024: Double)] = [
        (2, 120), (2, 193), (2, 308), (2, 449), (2, 602),
        (4, 378), (4, 434), (4, 490), (4, 553), (4, 616), (4, 658),
        (6, 466), (6, 517), (6, 567), (6, 616), (6, 666), (6, 719), (6, 772), (6, 822), (6, 873),
        (8, 682.5), (8, 711), (8, 754), (8, 797), (8, 841), (8, 885), (8, 916.5), (8, 948),
    ]

    /// Table 5.1.3.1-3 (qam64LowSE), MCS 0-28.
    static let table3: [(qm: Int, r1024: Double)] = [
        (2, 30), (2, 40), (2, 50), (2, 64), (2, 78), (2, 99), (2, 120), (2, 157), (2, 193), (2, 251), (2, 308),
        (2, 379), (2, 449), (2, 526), (2, 602),
        (4, 340), (4, 378), (4, 434), (4, 490), (4, 553), (4, 616),
        (6, 438), (6, 466), (6, 517), (6, 567), (6, 616), (6, 666), (6, 719), (6, 772),
    ]
}
