// The validation identities of the reference extractor, shipped as runtime self-checks ("Decoder health"), so a
// firmware update that shifts a field shows up as a failing check instead of a plausible-looking chart.

import Foundation
import FTCore
import FTModel

enum PhyChecks {
    /// A check passes while its identity holds for at least this share of what it checks.
    static let threshold = 0.95

    static func checks(_ s: PhyStats, tbsAvailable: Bool) -> [PhyCheck] {
        var out: [PhyCheck] = []
        if s.rsrqResiduals > 0 {
            let share = Double(s.rsrqWithinQuarterDb) / Double(s.rsrqResiduals)
            let perRx = s.rsrqResidual.keys.sorted().map { k in
                let r = s.rsrqResidual[k]!
                return "Rx\(k) mean \(signed(r.mean, 3)) dB, sd \(Fmt.fixed(r.sd, 3)) (\(count(r.n)))"
            }
            let prb = s.inferredPrb.keys.sorted().map { "\($0): \(s.inferredPrb[$0]!)" }.joined(separator: ", ")
            out.append(PhyCheck(id: "b193RsrqIdentity", code: 0xB193, passed: share >= threshold,
                                measured: "\(percent(share)) within 0.25 dB. " + perRx.joined(separator: "; ")
                                    + ". N_RB inferred per EARFCN: \(prb)",
                                expectation: "RSRQ = RSRP - RSSI + 10log10(N_RB) on each Rx antenna"))
        }
        if tbsAvailable, s.dlTbs.total > 0 {
            let t = s.dlTbs, checked = t.total - t.retx
            let share = checked > 0 ? Double(t.table64 + t.table256) / Double(checked) : 1
            out.append(PhyCheck(id: "b173TbsTable", code: 0xB173, passed: share >= threshold,
                                measured: "\(count(t.table64)) match the 64QAM table, \(count(t.table256)) the 256QAM table, "
                                    + "\(count(t.retx)) retransmissions (MCS 29-31), \(count(t.unexplained)) unexplained",
                                expectation: "every new C-RNTI transport block has a TS 36.213 table 7.1.7.2.1-1 size"))
        }
        if tbsAvailable, s.ul.total > 0 {
            let u = s.ul, checked = u.total - u.uciOnly
            let share = checked > 0 ? Double(u.unique + u.ambiguous) / Double(checked) : 1
            out.append(PhyCheck(id: "b139TbsModulation", code: 0xB139, passed: share >= threshold,
                                measured: "\(count(u.unique)) give one MCS, \(count(u.ambiguous)) are ambiguous, "
                                    + "\(count(u.uciOnly)) are UCI only, \(count(u.noMatch)) match no table size",
                                expectation: "TBS and modulation agree with TS 36.213 tables 7.1.7.2.1-1 and 8.6.1-1"))
        }
        if s.nrTbs.matched + s.nrTbs.unexplained > 0 {
            let n = s.nrTbs, share = Double(n.matched) / Double(n.matched + n.unexplained)
            out.append(PhyCheck(id: "b887TbsFormula", code: 0xB887, passed: share >= threshold,
                                measured: "\(count(n.matched)) of \(count(n.matched + n.unexplained)) new transmissions match, "
                                    + "\(count(n.retx)) retransmissions",
                                expectation: "TBS = TS 38.214 5.1.3.2 (qam256 MCS table, layers from the record)"))
        }
        let nr = s.nr
        if let dd = nr.deltaDecodes, let df = nr.deltaCrcFail, let db = nr.deltaPassBytes {
            let share = [ratio(nr.b887Records, dd), ratio(nr.b887CrcFail, df), ratio(nr.b887PassBytes, db)].min()!
            out.append(PhyCheck(id: "b887VsB888", code: 0xB887, passed: share >= threshold,
                                measured: "0xB887: \(count(nr.b887Records)) decodes, \(count(nr.b887CrcFail)) CRC fails, "
                                    + "\(count(nr.b887PassBytes)) pass bytes; 0xB888 counters: \(count(dd)) / \(count(df)) / \(count(db))",
                                expectation: "the per-slot records sum to the MAC counters over the same window"))
        }
        if s.macSamples > 0 {
            let share = Double(s.macConsistent) / Double(s.macSamples)
            out.append(PhyCheck(id: "b064HeaderAccounting", code: 0xB064, passed: share >= threshold,
                                measured: "\(count(s.macConsistent)) of \(count(s.macSamples)) MAC headers",
                                expectation: "subheaders and control elements use exactly the logged header length (TS 36.321 6.1.2)"))
        }
        return out
    }

    /// 1.0 when equal, else the smaller over the larger.
    static func ratio(_ a: Int, _ b: Int) -> Double {
        a == b ? 1 : (max(a, b) == 0 ? 1 : Double(min(a, b)) / Double(max(a, b)))
    }

    static func count(_ n: Int) -> String { n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }

    static func percent(_ share: Double) -> String { Fmt.fixed(share * 100, 1) + "%" }

    static func signed(_ v: Double, _ digits: Int) -> String { (v >= 0 ? "+" : "") + Fmt.fixed(v, digits) }
}

/// LTE channel bandwidth in PRB, inferred from the measurements themselves.
public enum PhyBandwidth {
    /// The LTE bandwidths (TS 36.101 table 5.6-1) in PRB.
    public static let lteBandwidthsPrb = [6, 15, 25, 50, 75, 100]

    /// The bandwidth whose 10log10(N_RB) is closest to `db` (the median of RSRQ - RSRP + RSSI).
    public static func snap(_ db: Double) -> Int {
        lteBandwidthsPrb.min { abs(10 * log10(Double($0)) - db) < abs(10 * log10(Double($1)) - db) }!
    }

    /// EARFCN -> N_RB from the per-Rx measurements of `capture` (serving and neighbour cells alike).
    public static func inferredPrb(_ capture: PhyCapture) -> [Int64: Int] {
        guard let p = capture.series[.lte_rsrp_per_rx]?.samples, let q = capture.series[.lte_rsrq_per_rx]?.samples,
              let s = capture.series[.lte_rssi_per_rx]?.samples, p.count == q.count, q.count == s.count else { return [:] }
        var terms: [Int64: [Double]] = [:]
        for i in p.indices {
            guard let e = p[i].earfcn, let pp = p[i].perIndex, let qq = q[i].perIndex, let ss = s[i].perIndex else { continue }
            for k in pp.indices where k < qq.count && k < ss.count {
                if let a = pp[k], let b = qq[k], let c = ss[k] { terms[e, default: []].append(b - a + c) }
            }
        }
        return terms.mapValues { snap(median($0)) }
    }
}
