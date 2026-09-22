// A port of the validated reference extractor (phy-inventory kpis.py) with the same sample selection and
// derivations, but only what the records carry: no cell tables. Records are decoded per code in time order (the
// reference's order), and every per-second bin is keyed by (whole UTC second, carrier index) at second + 0.5 s
// (CONTRACT.md, PHY parity).

import FTCore
import FTModel

public enum PhyExtractor {
    /// Every PHY series, the PHY summary FTJourney reads, the self-checks and the availability entries.
    public static func extract(records: [LogRecord], timeBase: TimeBase, secure: EncryptedCensus) -> PhyCapture {
        run(records: records, timeBase: timeBase, secure: secure, tbs: .builtIn).capture
    }

    /// The extraction with the self-check counts, against a given TBS table (tests pass the reference's).
    static func run(records: [LogRecord], timeBase: TimeBase, secure: EncryptedCensus, tbs: LteTbsLookup) -> PhyRun {
        var x = Extraction(timeBase: timeBase, tbs: tbs)
        x.decode(records)
        return x.finish(secure: secure)
    }
}

/// What one extraction found, including the counts behind the self-checks.
struct PhyRun: Sendable {
    var capture: PhyCapture
    var stats: PhyStats
}

/// The raw counts behind PhyCheck, for the tests and the Decoder health page.
struct PhyStats: Sendable {
    /// Per Rx antenna: (mean, population sd, count) of RSRQ - (RSRP - RSSI + 10log10(N_RB)) in dB.
    var rsrqResidual: [Int: (mean: Double, sd: Double, n: Int)] = [:]
    var rsrqWithinQuarterDb = 0
    var rsrqResiduals = 0
    /// EARFCN -> N_RB inferred from the same identity.
    var inferredPrb: [Int64: Int] = [:]
    var dlTbs = TbsMatches()
    var ul = UlMatches()
    var nrTbs = NrTbsMatches()
    var nr = NrCounters()
    var macSamples = 0
    var macConsistent = 0
    /// Records of a validated version too short for their own layout, per code.
    var malformed: [UInt16: Int] = [:]

    struct TbsMatches: Hashable, Sendable {
        var table64 = 0, table256 = 0, retx = 0, unexplained = 0
        var total: Int { table64 + table256 + retx + unexplained }
    }

    struct UlMatches: Hashable, Sendable {
        var unique = 0, ambiguous = 0, uciOnly = 0, noMatch = 0
        var total: Int { unique + ambiguous + uciOnly + noMatch }
    }

    struct NrTbsMatches: Hashable, Sendable {
        var matched = 0, retx = 0, unexplained = 0
    }

    /// 0xB887 sums against the 0xB888 counter deltas over the same window.
    struct NrCounters: Hashable, Sendable {
        var b887Records = 0, b887CrcFail = 0, b887PassBytes = 0
        var deltaDecodes: Int?, deltaCrcFail: Int?, deltaPassBytes: Int?
    }
}

/// One extraction pass: decoders feed samples and counters in; `finish` builds the capture.
struct Extraction {
    let timeBase: TimeBase
    let tbs: LteTbsLookup
    /// Unix ms of the time base, when the capture has network time (bins then sit on whole UTC seconds).
    let startUtcMs: Double?

    var samples: [PhyMetric: [PhySample]] = [:]
    var versionMisses: [String: Int] = [:]
    var recordsPerCode: [UInt16: Int] = [:]
    var stats = PhyStats()

    // 0xB193
    var rsrqTerms: [(earfcn: Int64, rx: Int, rsrq: Double, rsrp: Double, rssi: Double)] = []
    var scells: [SCellKey: (first: Double, last: Double, n: Int)] = [:]
    var rxByEarfcn: [Int64: [Int: Int]] = [:]
    // 0xB173 / 0xB139 bins: (second, carrier) -> (TBs, CRC fails, pass bits) / scheduled bits
    var dlBins: [BinKey: (n: Int, fail: Int, bits: Int)] = [:]
    var ulBins: [BinKey: Int] = [:]
    // 0xB062
    var rach: [RachEvent] = []
    var txAntennas: Set<Int> = []
    // 0xB887 / 0xB888
    var nrTimes: [Double] = []
    var nrPcis: Set<Int> = []
    var nrCounters: [(tMs: Double, c: B888.Counters)] = []

    struct SCellKey: Hashable, Comparable {
        var index: Int, earfcn: Int64, pci: Int
        static func < (a: SCellKey, b: SCellKey) -> Bool { (a.index, a.earfcn, a.pci) < (b.index, b.earfcn, b.pci) }
    }

    struct BinKey: Hashable, Comparable {
        var second: Double, carrier: Int
        static func < (a: BinKey, b: BinKey) -> Bool { (a.second, a.carrier) < (b.second, b.carrier) }
    }

    init(timeBase: TimeBase, tbs: LteTbsLookup) {
        self.timeBase = timeBase
        self.tbs = tbs
        startUtcMs = timeBase.startUtcMs != nil ? Double(TimeBase.gpsEpochUtcMs) + TimeBase.modemMs(timeBase.firstRaw) : nil
    }

    // MARK: time

    /// Milliseconds since the time base, or nil for an unstamped record or one stamped before network time in a
    /// capture that has it (the reference drops neither here: none of the 12 PHY codes has such a stamp).
    func tMs(_ raw: UInt64) -> Double? {
        guard let ms = timeBase.sinceStartMs(raw) else { return nil }
        if startUtcMs != nil && TimeBase.utcMs(raw) == nil { return nil }
        return ms
    }

    /// The whole second a record falls in: UTC when the capture has network time, else since the start.
    func second(_ raw: UInt64, _ tMs: Double) -> Double {
        startUtcMs != nil ? ((Double(TimeBase.gpsEpochUtcMs) + TimeBase.modemMs(raw)) / 1000).rounded(.down)
            : (tMs / 1000).rounded(.down)
    }

    /// A bin's centre (second + 0.5 s) in ms since the time base.
    func binCentre(_ second: Double) -> Double {
        if let startUtcMs { return second * 1000 + 500 - startUtcMs }
        return second * 1000 + 500
    }

    mutating func add(_ m: PhyMetric, _ t: Double, _ value: Double?, perIndex: [Double?]? = nil, earfcn: Int64? = nil,
                      pci: Int? = nil, carrier: Int = 0, tag: Int? = nil) {
        samples[m, default: []].append(PhySample(tMs: t, value: value, perIndex: perIndex, earfcn: earfcn, pci: pci,
                                                  carrier: carrier, tag: tag))
    }

    mutating func miss(_ key: String) { versionMisses[key, default: 0] += 1 }

    // MARK: decode

    mutating func decode(_ records: [LogRecord]) {
        var byCode: [UInt16: [Int]] = [:]
        for code in PhyDispatch.codes { byCode[code] = [] }
        for (i, r) in records.enumerated() {
            recordsPerCode[r.code, default: 0] += 1
            if byCode[r.code] != nil { byCode[r.code]!.append(i) }
        }
        for code in PhyDispatch.codes {
            // The reference reads each code in time order; ties keep file order.
            let order = byCode[code]!.sorted { (records[$0].timestampRaw, $0) < (records[$1].timestampRaw, $1) }
            for i in order {
                let r = records[i]
                guard let t = tMs(r.timestampRaw) else { continue }
                decode(code, r, t)
            }
        }
    }

    mutating func decode(_ code: UInt16, _ r: LogRecord, _ t: Double) {
        func handle<V>(_ d: Decoded<V>, _ body: (inout Extraction, V) -> Void) {
            switch d {
            case .value(let v): body(&self, v)
            case .versionMiss(let key): miss(key)
            case .malformed: stats.malformed[code, default: 0] += 1
            }
        }
        switch code {
        case 0xB0C1: handle(B0C1.decode(r.body)) { $0.mib($1, t) }
        case 0xB0C2: handle(B0C2.decode(r.body)) { $0.add(.lte_band, t, Double($1.band), earfcn: $1.dlEarfcn, pci: $1.pci) }
        case 0xB193: handle(B193.decode(r.body)) { x, cells in for c in cells { x.measurement(c, t) } }
        case 0xB173: handle(B173.decode(r.body)) { x, recs in for rec in recs { x.pdsch(rec, r.timestampRaw, t) } }
        case 0xB139: handle(B139.decode(r.body)) { x, txs in for tx in txs { x.pusch(tx, r.timestampRaw, t) } }
        case 0xB14E: handle(B14E.decode(r.body)) { $0.puschCsf($1, t) }
        case 0xB14D: handle(B14D.decode(r.body)) { $0.pucchCsf($1, t) }
        case 0xB064: handle(B064.decode(r.body)) { x, ss in for s in ss { x.macUl(s, t) } }
        case 0xB062: handle(B062.decode(r.body)) { x, atts in for a in atts { x.rachAttempt(a, t) } }
        case 0xB97F: handle(B97F.decode(r.body)) { x, carriers in for c in carriers { x.nrMeasurement(c, t) } }
        case 0xB887: handle(B887.decode(r.body)) { x, slots in for s in slots { x.nrSlot(s, t) } }
        case 0xB888: handle(B888.decode(r.body)) { $0.nrCounters.append((t, $1)) }
        default: break
        }
    }

    mutating func mib(_ m: B0C1.Mib, _ t: Double) {
        add(.lte_tx_antennas_mib, t, Double(m.txAntennas), earfcn: m.earfcn, pci: m.pci)
        add(.lte_dl_bandwidth_prb, t, Double(m.dlBandwidthPrb), earfcn: m.earfcn, pci: m.pci)
        txAntennas.insert(m.txAntennas)
    }

    mutating func measurement(_ c: B193.CellMeasurement, _ t: Double) {
        let carrier = c.serving ? c.carrier : PhySample.notServing
        let tag = c.serving ? CellRole.serving : CellRole.neighbour
        func put(_ m: PhyMetric, _ v: Double) { add(m, t, v, earfcn: c.earfcn, pci: c.pci, carrier: carrier, tag: tag) }
        if c.serving {
            put(.lte_rsrp, c.rsrp)
            put(.lte_rsrp_filtered, c.rsrpFiltered)
            put(.lte_rsrq_filtered, c.rsrqFiltered)
            put(.lte_rssi, c.rssi)
        } else {
            put(.lte_neighbour_rsrp, c.rsrp)
            put(.lte_neighbour_rsrp_filtered, c.rsrpFiltered)
            put(.lte_neighbour_rsrq_filtered, c.rsrqFiltered)
            put(.lte_neighbour_rssi, c.rssi)
        }
        put(.lte_rx_antennas_measured, Double(c.rxCount))
        func perRx(_ v: [Double]) -> [Double?] { (0..<4).map { c.measured($0) ? v[$0] : nil } }
        add(.lte_rsrp_per_rx, t, nil, perIndex: perRx(c.rsrpRx), earfcn: c.earfcn, pci: c.pci, carrier: carrier, tag: tag)
        add(.lte_rsrq_per_rx, t, nil, perIndex: perRx(c.rsrqRx), earfcn: c.earfcn, pci: c.pci, carrier: carrier, tag: tag)
        add(.lte_rssi_per_rx, t, nil, perIndex: perRx(c.rssiRx), earfcn: c.earfcn, pci: c.pci, carrier: carrier, tag: tag)
        for k in 0..<4 where c.measured(k) {
            rsrqTerms.append((c.earfcn, k, c.rsrqRx[k], c.rsrpRx[k], c.rssiRx[k]))
        }
        if c.serving && c.carrier >= 1 {
            let key = SCellKey(index: c.carrier, earfcn: c.earfcn, pci: c.pci)
            let s = scells[key] ?? (t, t, 0)
            scells[key] = (min(s.first, t), max(s.last, t), s.n + 1)
        }
        if c.serving && c.carrier == 0 { rxByEarfcn[c.earfcn, default: [:]][c.rxCount, default: 0] += 1 }
    }

    mutating func pdsch(_ r: B173.Record, _ raw: UInt64, _ t: Double) {
        for (j, tb) in r.blocks.enumerated() {
            guard tb.rntiType == 0, tb.qm != 0 else { continue }   // C-RNTI traffic only
            let layers = (r.transportBlocks == 2 && r.layers == 4) || (r.transportBlocks == 2 && r.layers == 3 && j == 1) ? 2 : 1
            let bits = tb.tbsBytes * 8
            if tbs.isAvailable {
                if tb.mcs >= 29 { stats.dlTbs.retx += 1 }
                else if bits == tbs.dl(mcs: tb.mcs, nPrb: tb.nRb, layers: layers, table256: false) { stats.dlTbs.table64 += 1 }
                else if bits == tbs.dl(mcs: tb.mcs, nPrb: tb.nRb, layers: layers, table256: true) { stats.dlTbs.table256 += 1 }
                else { stats.dlTbs.unexplained += 1 }
            }
            func put(_ m: PhyMetric, _ v: Int) { add(m, t, Double(v), carrier: r.carrier, tag: j) }
            put(.lte_dl_mcs, tb.mcs)
            put(.lte_dl_prb, tb.nRb)
            put(.lte_dl_tbs, tb.tbsBytes)
            put(.lte_dl_modulation, tb.qm)
            put(.lte_dl_crc_ok, tb.crcOk ? 1 : 0)
            let key = BinKey(second: second(raw, t), carrier: r.carrier)
            let b = dlBins[key] ?? (0, 0, 0)
            dlBins[key] = (b.n + 1, b.fail + (tb.crcOk ? 0 : 1), b.bits + (tb.crcOk ? bits : 0))
        }
        if let first = r.blocks.first, first.rntiType == 0 {
            // tag = number of transport blocks: 4 layers with 1 TB is transmit diversity.
            add(.lte_dl_layers, t, Double(r.layers), carrier: r.carrier, tag: r.transportBlocks)
        }
    }

    mutating func pusch(_ tx: B139.Transmission, _ raw: UInt64, _ t: Double) {
        guard tx.nRb > 0 else { return }
        var mcs: [Int] = []
        if tbs.isAvailable {
            if tx.tbsBytes == 0 {
                stats.ul.uciOnly += 1
            } else {
                let found = tbs.ulMcs(bits: tx.tbsBytes * 8, nPrb: tx.nRb, qm: tx.qm)
                mcs = found.mcs
                if mcs.count == 1 { stats.ul.unique += 1 } else if found.matchesTable { stats.ul.ambiguous += 1 } else { stats.ul.noMatch += 1 }
            }
        }
        func put(_ m: PhyMetric, _ v: Double?) { add(m, t, v, pci: tx.pci, carrier: tx.carrier) }
        put(.lte_ul_prb, Double(tx.nRb))
        put(.lte_ul_tbs, Double(tx.tbsBytes))
        put(.lte_ul_modulation, tx.qm.map(Double.init))
        put(.lte_ul_code_rate, tx.codeRate)
        if mcs.count == 1 { put(.lte_ul_mcs_derived, Double(mcs[0])) }
        put(.lte_pusch_tx_power_required, tx.requiredPowerDbm)
        ulBins[BinKey(second: second(raw, t), carrier: tx.carrier), default: 0] += tx.tbsBytes * 8
    }

    mutating func puschCsf(_ c: B14E.Report, _ t: Double) {
        func put(_ m: PhyMetric, _ v: Int) { add(m, t, Double(v), carrier: c.carrier, tag: CsfSource.pusch) }
        put(.lte_cqi_wideband_cw0, c.cqiCw0)
        if c.ri > 1 { put(.lte_cqi_wideband_cw1, c.cqiCw1) }
        put(.lte_ri, c.ri)
        put(.lte_pmi_wideband, c.widebandPmi)
        put(.lte_csf_tx_mode, c.txMode)
    }

    mutating func pucchCsf(_ c: B14D.Report, _ t: Double) {
        func put(_ m: PhyMetric, _ v: Int) { add(m, t, Double(v), carrier: c.carrier, tag: CsfSource.pucch) }
        if let ri = c.ri { put(.lte_ri, ri) }
        if let cqi = c.cqiCw0, let pmi = c.widebandPmi {
            put(.lte_cqi_wideband_cw0, cqi)
            put(.lte_pmi_wideband, pmi)
        }
    }

    mutating func macUl(_ s: B064.Sample, _ t: Double) {
        stats.macSamples += 1
        if s.headerConsistent { stats.macConsistent += 1 }
        for ce in s.controlElements where ce.lcid == 26 && !ce.payload.isEmpty {
            add(.lte_power_headroom, t, Double(Int(ce.payload[0] & 63) - 23), carrier: s.carrier)
        }
        add(.lte_mac_ul_grant, t, Double(s.grantBytes), carrier: s.carrier, tag: s.harq)
    }

    mutating func rachAttempt(_ a: B062.Attempt, _ t: Double) {
        guard let ta = a.taRar else { return }
        add(.lte_timing_advance_rar, t, Double(ta))
        rach.append(RachEvent(tMs: t, ta: ta, distanceM: Spectrum.lteTimingAdvanceMetres(ta), ulEarfcn: a.ulEarfcn,
                              preambleTargetDbm: Double(a.preambleTargetDbm)))
    }

    mutating func nrMeasurement(_ carrier: B97F.Carrier, _ t: Double) {
        let cc = carrier.ccId == 255 ? PhySample.notServing : carrier.ccId
        for cell in carrier.cells {
            let tag = carrier.servingPci == cell.pci ? CellRole.serving : CellRole.neighbour
            if let v = cell.rsrp { add(.nr_ss_rsrp, t, v, earfcn: carrier.arfcn, pci: cell.pci, carrier: cc, tag: tag) }
            if let v = cell.rsrq { add(.nr_ss_rsrq, t, v, earfcn: carrier.arfcn, pci: cell.pci, carrier: cc, tag: tag) }
        }
    }

    /// The N'RE per PRB values the TBS check tries (12 subcarriers x 10-13 symbols, less DMRS/overhead).
    static let nrRePerPrb = [120, 126, 132, 138, 144, 150]

    mutating func nrSlot(_ s: B887.Slot, _ t: Double) {
        if s.mcs < 28 {
            let e = NrMcsTable.qam256.entries[s.mcs]
            let ok = Self.nrRePerPrb.contains {
                NrTbs.bits(nRePerPrb: $0, nPrb: s.nRb, qm: e.qm, r: e.r1024 / 1024, layers: s.layers) == s.tbsBytes * 8
            }
            if ok { stats.nrTbs.matched += 1 } else { stats.nrTbs.unexplained += 1 }
        } else {
            stats.nrTbs.retx += 1
        }
        func put(_ m: PhyMetric, _ v: Int) { add(m, t, Double(v), pci: s.pci, tag: s.harq) }
        put(.nr_dl_mcs, s.mcs)
        put(.nr_dl_prb, s.nRb)
        put(.nr_dl_layers, s.layers)
        put(.nr_dl_tbs, s.tbsBytes)
        if let qm = NrMcsTable.qam256.qm(mcs: s.mcs) { put(.nr_dl_modulation, qm) }
        put(.nr_dl_crc_ok, s.crcOk ? 1 : 0)
        stats.nr.b887Records += 1
        if !s.crcOk { stats.nr.b887CrcFail += 1 } else { stats.nr.b887PassBytes += s.tbsBytes }
        nrTimes.append(t)
        nrPcis.insert(s.pci)
    }
}
