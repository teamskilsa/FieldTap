// The cross-code self-checks of the decoders added after the reference extractor, and the summary values they
// produce. They run once every code has been read, because each one needs the absolute-TTI axis: the 10.24 s frame
// cycle aliases about twice in a 22 s capture, so a check keyed on the raw TTI would compare subframes seconds
// apart and come out flat (see PhyTtiAxis).
//
// Every threshold and every number these reproduce is in docs/research/iphone-named-log-codes.md, section
// "Runtime checks to add alongside".

import Foundation
import FTCore
import FTModel

extension Extraction {
    /// The 0xB063 walk's coverage and the 0xB111-style antenna checks are reported, not gated; everything else has
    /// a threshold. Called from `finish` before the checks are built.
    mutating func crossCheckAdded() {
        stats.axisR = axis.concentration
        stats.axisPhaseMs = axis.phaseMs
        stats.axisSamples = axis.count
        guard !axis.isEmpty else { return }

        // 0xB173's transport blocks on the absolute-TTI axis: what 0xB126, 0xB16C and 0xB063 are checked against.
        var dlByTti: [Int: [(carrier: Int, harq: Int, tbsBytes: Int, nRb: Int, layers: Int, tbCount: Int)]] = [:]
        for b in dlBlocks {
            dlByTti[axis.absoluteTti(tti: b.tti, tMs: b.tMs), default: []]
                .append((b.carrier, b.harq, b.tbsBytes, b.nRb, b.layers, b.tbCount))
        }
        var ulByTti: [Int: [(startRb: Int, nRb: Int, modulation: Int)]] = [:]
        for u in ulTransmissions {
            ulByTti[axis.absoluteTti(tti: u.tti, tMs: u.tMs), default: []].append((u.startRb, u.nRb, u.modulation))
        }

        checkDemapper(dlByTti)
        checkGrants(ulByTti)
        checkMacDl(dlByTti)
        measureClocks()
    }

    /// 0xB126: popcount(the PRB bitmap) is an N_RB 0xB173 reports for the same subframe; the rank equals 0xB173's
    /// layer count with transmit diversity excepted; the transmit antenna ports equal the serving cell's MIB.
    mutating func checkDemapper(_ dlByTti: [Int: [(carrier: Int, harq: Int, tbsBytes: Int, nRb: Int, layers: Int, tbCount: Int)]]) {
        for s in demapperSubs {
            if let blocks = dlByTti[axis.absoluteTti(tti: s.tti, tMs: s.tMs)] {
                stats.b126.prbChecked += 1
                if blocks.contains(where: { $0.nRb == s.nPrb }) { stats.b126.prbMatch += 1 }
                stats.b126.rankChecked += 1
                if blocks.contains(where: { $0.layers == s.rank }) {
                    stats.b126.rankMatch += 1
                } else if s.rank == 1 && blocks.contains(where: { $0.layers == 4 && $0.tbCount == 1 }) {
                    // 0xB173 says "4 layers, one transport block", which its own decoder documents as transmit
                    // diversity: rank 1 is the correct reading, and 0xB126 is the better field.
                    stats.b126.rankTxDiversity += 1
                }
            }
            if let cell = s.cell, let mib = mibAntennasByCell[cell] {
                stats.b126.txChecked += 1
                if mib == s.txPorts { stats.b126.txMatch += 1 }
            }
        }
    }

    /// 0xB16C: the 16-byte records precede an 0xB139 PUSCH by exactly four subframes (FDD's n+4), and where one
    /// grant meets one PUSCH report the grant's start RB, RB count and modulation are 0xB139's.
    mutating func checkGrants(_ ulByTti: [Int: [(startRb: Int, nRb: Int, modulation: Int)]]) {
        var byTti: [Int: [(startRb: Int, nRb: Int, modulation: Int)]] = [:]
        for g in grants {
            byTti[axis.absoluteTti(tti: g.tti, tMs: g.tMs), default: []].append((g.startRb, g.nRb, g.modulation))
        }
        for (tti, here) in byTti {
            stats.b16c.n4Checked += 1
            guard let sent = ulByTti[tti + 4] else { continue }
            stats.b16c.n4Match += 1
            guard here.count == 1, sent.count == 1 else { continue }
            stats.b16c.fieldChecked += 1
            if here[0].startRb == sent[0].startRb && here[0].nRb == sent[0].nRb
                && here[0].modulation == sent[0].modulation { stats.b16c.fieldMatch += 1 }
        }
    }

    /// 0xB063: every transport block the walk found is a 0xB173 transport block on (SFN, subframe, carrier, HARQ,
    /// size) — four independent fields at once.
    mutating func checkMacDl(_ dlByTti: [Int: [(carrier: Int, harq: Int, tbsBytes: Int, nRb: Int, layers: Int, tbCount: Int)]]) {
        for m in macBlocks {
            stats.b063.checked += 1
            let blocks = dlByTti[axis.absoluteTti(tti: m.tti, tMs: m.tMs)] ?? []
            if blocks.contains(where: { $0.carrier == m.carrier && $0.harq == m.harq && $0.tbsBytes == m.sizeBytes }) {
                stats.b063.matched += 1
            }
        }
    }

    /// 0x1D0B: the two clocks' measured rates, the sequence number, and the trace that was never written.
    mutating func measureClocks() {
        let rows = samplerClocks.sorted { $0.tMs < $1.tMs }
        guard rows.count > 1 else { return }
        var tcxo: [Double] = []
        // The sleep clock is measured over the stretches between gaps, the way the research measured it: it steps
        // by 10 or 11 counts per 10 ms record, so a per-record rate is quantised and a whole-capture slope would
        // count the gaps as trace.
        var stretchStart = 0
        var sleepCounts = 0
        var sleepMs = 0.0
        func closeStretch(_ end: Int) {
            defer { stretchStart = end + 1 }
            guard end > stretchStart else { return }
            let span = rows[end].tMs - rows[stretchStart].tMs
            let counts = Int(rows[end].sleep) - Int(rows[stretchStart].sleep)
            guard span >= 1_000, counts > 0 else { return }
            sleepCounts += counts
            sleepMs += span
        }
        for k in 1..<rows.count {
            let dt = rows[k].tMs - rows[k - 1].tMs
            let step = Int(rows[k].sequence) - Int(rows[k - 1].sequence)
            stats.d1d0b.sequenceSteps += 1
            if step == 1 { stats.d1d0b.sequenceOk += 1 }
            let counts = Int(rows[k].sleep) - Int(rows[k - 1].sleep)
            if counts > 0 {
                let missing = Double(counts) / D1D0B.sleepClockHz * 1_000 - Extraction.samplerRecordMs
                if missing > Extraction.traceGapThresholdMs {
                    stats.d1d0b.gaps += 1
                    stats.d1d0b.missingMs += missing
                    traceGaps.append(TraceGap(tMs: rows[k - 1].tMs, missingMs: missing))
                    closeStretch(k - 1)
                }
            } else {
                closeStretch(k - 1)   // the counter went backwards: a new stretch
            }
            // Rates are measured only over consecutive records (the gaps and the zero-stamped records the QDSS
            // rebuild interpolates would bias a whole-capture slope).
            guard dt > 0, dt <= 50 else { continue }
            let ticks = (Int(rows[k].tcxo) - Int(rows[k - 1].tcxo) + (1 << 24)) % (1 << 24)
            tcxo.append(Double(ticks) / (dt / 1_000))
        }
        closeStretch(rows.count - 1)
        if !tcxo.isEmpty { stats.d1d0b.tcxoHz = median(tcxo) }
        if sleepMs > 0 { stats.d1d0b.sleepHz = Double(sleepCounts) / (sleepMs / 1_000) }
    }

    /// One 0x1D0B record covers 10 ms (five 2 ms entries), so that much of a step is trace, not a gap.
    static let samplerRecordMs = 10.0
    /// A step longer than this is trace that was never written; below it the sampler was only late.
    static let traceGapThresholdMs = 500.0
}

extension PhyChecks {
    /// The self-checks of the added decoders, in the order the Radio page lists them.
    static func added(_ s: PhyStats) -> [PhyCheck] {
        var out: [PhyCheck] = []
        let b126 = s.b126
        if b126.prbChecked > 0 {
            let share = Double(b126.prbMatch) / Double(b126.prbChecked)
            out.append(PhyCheck(id: "b126PrbBitmap", code: 0xB126, passed: share >= threshold,
                                measured: "\(count(b126.prbMatch)) of \(count(b126.prbChecked)) sub-records "
                                    + "(\(percent(share))); \(count(b126.subRecords)) sub-records in "
                                    + "\(count(b126.records)) records",
                                expectation: "popcount(the PRB allocation bitmap) is an N_RB 0xB173 reports for the same subframe"))
        }
        if b126.rankChecked > 0 {
            let agree = b126.rankMatch + b126.rankTxDiversity
            let share = Double(agree) / Double(b126.rankChecked)
            out.append(PhyCheck(id: "b126Rank", code: 0xB126, passed: share >= threshold,
                                measured: "\(count(b126.rankMatch)) equal 0xB173's layers, \(count(b126.rankTxDiversity)) "
                                    + "are transmit diversity (0xB173: 4 layers, 1 transport block), "
                                    + "\(count(b126.rankChecked - agree)) disagree (\(percent(share)))",
                                expectation: "the rank equals 0xB173's layer count, transmit diversity excepted"))
        }
        if b126.txChecked > 0 {
            let share = Double(b126.txMatch) / Double(b126.txChecked)
            out.append(PhyCheck(id: "b126TxAntennaPorts", code: 0xB126, passed: share >= threshold,
                                measured: "\(count(b126.txMatch)) of \(count(b126.txChecked)) sub-records whose serving "
                                    + "cell broadcast a MIB (\(percent(share)))",
                                expectation: "the transmit antenna ports equal the 0xB0C1 MIB's antenna count for the serving cell"))
        }
        let b12a = s.b12a
        if b12a.elements > 0 {
            let share = Double(b12a.consistent) / Double(b12a.elements)
            let split = b12a.cfi.keys.sorted().map { "CFI \($0): \(count(b12a.cfi[$0] ?? 0))" }.joined(separator: ", ")
            out.append(PhyCheck(id: "b12aCfi", code: 0xB12A, passed: share >= 0.99,
                                measured: "\(count(b12a.consistent)) of \(count(b12a.elements)) elements (\(percent(share))); "
                                    + (split.isEmpty ? "no decoded element" : split),
                                expectation: "the CFI byte is 4 x {1, 2, 3}, and 0 exactly when the decode flag is 0"))
        }
        let b16c = s.b16c
        if b16c.n4Checked > 0 {
            let share = Double(b16c.n4Match) / Double(b16c.n4Checked)
            out.append(PhyCheck(id: "b16cUlGrantTiming", code: 0xB16C, passed: share >= 0.90,
                                measured: "\(count(b16c.n4Match)) of \(count(b16c.n4Checked)) subframes with an uplink "
                                    + "grant (\(percent(share))); \(count(b16c.grants)) grants, "
                                    + "\(count(b16c.assignments)) downlink assignments",
                                expectation: "a 16-byte record precedes an 0xB139 PUSCH report by exactly 4 subframes (FDD n+4)"))
        }
        if b16c.fieldChecked > 0 {
            let share = Double(b16c.fieldMatch) / Double(b16c.fieldChecked)
            out.append(PhyCheck(id: "b16cUlGrantFields", code: 0xB16C, passed: share >= threshold,
                                measured: "\(count(b16c.fieldMatch)) of \(count(b16c.fieldChecked)) one-to-one matches "
                                    + "(\(percent(share)))",
                                expectation: "the grant's start RB, RB count and modulation equal 0xB139's for the PUSCH it schedules"))
        }
        let b179 = s.b179
        if b179.records > 0 {
            let share = Double(b179.lengthExact) / Double(b179.records)
            out.append(PhyCheck(id: "b179Length", code: 0xB179, passed: share >= threshold,
                                measured: "\(count(b179.lengthExact)) of \(count(b179.records)) records (\(percent(share))); "
                                    + "\(count(b179.neighbours)) neighbour measurements",
                                expectation: "the body is 28 + 12 x the neighbour count the record declares"))
            out.append(PhyCheck(id: "b179OwnTiming", code: 0xB179, passed: b179.axisR >= 0.99,
                                measured: "circular R = \(Fmt.fixed(b179.axisR, 5)) over \(count(b179.placed)) records",
                                expectation: "these records carry no timestamp: their own TTI places them, so it must fit the records around them"))
        }
        if b179.rsrpChecked > 0 {
            let share = Double(b179.rsrpWithin1Db) / Double(b179.rsrpChecked)
            // The pass criterion is the scale, not the spread: the share within 1 dB is 93% on the stationary
            // capture but falls while driving, where the two records are a few subframes apart and RSRP is moving.
            // A layout or scale change moves the mean, which is what this gates on; the share is reported.
            out.append(PhyCheck(id: "b179ServingRsrp", code: 0xB179, passed: abs(b179.rsrpMeanDb) <= 1.0,
                                measured: "mean \(signed(b179.rsrpMeanDb, 2)) dB, sd \(Fmt.fixed(b179.rsrpSdDb, 2)) dB, "
                                    + "\(percent(share)) within 1 dB over \(count(b179.rsrpChecked)) matched records; "
                                    + "RSRQ mean \(signed(b179.rsrqMeanDb, 2)) dB",
                                expectation: "the serving RSRP and RSRQ are on 0xB193's scales (mean within 1 dB of it)"))
        }
        let b063 = s.b063
        if b063.checked > 0 {
            let share = Double(b063.matched) / Double(b063.checked)
            out.append(PhyCheck(id: "b063VsB173", code: 0xB063, passed: share >= threshold,
                                measured: "\(count(b063.matched)) of \(count(b063.checked)) transport blocks "
                                    + "(\(percent(share))); \(count(b063.macBytes)) MAC bytes, "
                                    + "\(percent(b063.macBytes > 0 ? Double(b063.paddingBytes) / Double(b063.macBytes) : 0)) padding",
                                expectation: "every transport block matches a 0xB173 one on (SFN, subframe, carrier, HARQ, size)"))
        }
        if b063.declared > 0 {
            let coverage = Double(b063.found) / Double(b063.declared)
            out.append(PhyCheck(id: "b063WalkCoverage", code: 0xB063, passed: true,
                                measured: "\(count(b063.found)) of \(count(b063.declared)) declared transport blocks "
                                    + "(\(percent(coverage))); the walk ended on the body's last byte in "
                                    + "\(count(b063.exactWalks)) of \(count(b063.records)) records, "
                                    + "\(count(b063.resynced)) resynchronisations",
                                expectation: "coverage, reported and not gated: the PDCP tail rule reached 80% / 82% on the "
                                    + "reference captures, and a fall means the tail changed"))
        }
        let agc = s.d184c
        if agc.records > 0 {
            let share = Double(agc.exact) / Double(agc.records)
            let chains = agc.chains.keys.sorted().map { Fmt.hex(UInt16($0), width: 2) }.joined(separator: ", ")
            out.append(PhyCheck(id: "d184cFraming", code: 0x184C, passed: share >= threshold,
                                measured: "\(count(agc.exact)) of \(count(agc.records)) records (\(percent(share))); "
                                    + "\(count(agc.subRecords)) sub-records on chains \(chains), \(count(agc.live)) live",
                                expectation: "the block walk (16-byte header plus 120-byte sub-records) ends on the body's last byte"))
        }
        let clocks = s.d1d0b
        if let tcxo = clocks.tcxoHz, clocks.sequenceSteps > 0 {
            let sequence = Double(clocks.sequenceOk) / Double(clocks.sequenceSteps)
            // Only the TCXO rate and the sequence number are gated. The sleep-clock rate is measured against the
            // capture's own timestamps, and where the QDSS rebuild had to interpolate those it is the timestamps
            // that drift, not the clock — which is exactly why the missing seconds are counted on this clock and
            // not on the trace's. So it is reported, not gated.
            let rateOk = abs(tcxo - D1D0B.tcxoHz) / D1D0B.tcxoHz <= 0.01
            let sleep = clocks.sleepHz.map { Fmt.fixed($0, 1) } ?? "not measured"
            out.append(PhyCheck(id: "d1d0bClocks", code: 0x1D0B, passed: rateOk && sequence >= threshold,
                                measured: "\(Fmt.fixed(tcxo, 0)) ticks/s against a nominal 19,200,000; the sleep clock "
                                    + "\(sleep) counts/s against 1,024 on this capture's own time axis (reported, not "
                                    + "gated); the sequence number steps by 1 in \(percent(sequence)); "
                                    + "\(count(clocks.gaps)) trace gaps totalling "
                                    + "\(Fmt.fixed(clocks.missingMs / 1_000, 2)) s",
                                expectation: "the 19.2 MHz TCXO runs at its nominal rate and the sequence number does not skip"))
        }
        return out
    }
}
