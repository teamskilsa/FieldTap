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
    // The decoders added after the reference extractor, each with the counts behind its own self-check.
    var b126 = B126Counters()
    var b12a = B12ACounters()
    var b16c = B16CCounters()
    var b179 = B179Counters()
    var b063 = B063Counters()
    var d184c = D184CCounters()
    var d1d0b = D1D0BCounters()
    /// The capture's frame phase from 0xB173, which the 0xB126 / 0xB063 / 0xB16C checks are keyed on.
    var axisR = 0.0
    var axisPhaseMs = 0.0
    var axisSamples = 0

    /// 0xB126 against 0xB173's own PRB counts and layers, and against the 0xB0C1 MIB.
    struct B126Counters: Hashable, Sendable {
        var records = 0, subRecords = 0
        var prbChecked = 0, prbMatch = 0
        var rankChecked = 0, rankMatch = 0, rankTxDiversity = 0
        var txChecked = 0, txMatch = 0
    }

    /// 0xB12A: the CFI is 4 x {1, 2, 3}, and 0 exactly when the decode flag is 0.
    struct B12ACounters: Hashable, Sendable {
        var records = 0, elements = 0, consistent = 0, decoded = 0
        var cfi: [Int: Int] = [:]
    }

    /// 0xB16C: the element chain closes, the 16-byte records precede an 0xB139 PUSCH by four subframes, and their
    /// fields equal 0xB139's.
    struct B16CCounters: Hashable, Sendable {
        var records = 0, exact = 0, elements = 0, grants = 0, assignments = 0
        var n4Checked = 0, n4Match = 0
        var fieldChecked = 0, fieldMatch = 0
    }

    /// 0xB179: the length identity, and the serving RSRP against 0xB193's.
    struct B179Counters: Hashable, Sendable {
        var records = 0, lengthExact = 0, neighbours = 0, placed = 0
        var rsrpChecked = 0, rsrpWithin1Db = 0
        var rsrpMeanDb = 0.0, rsrpSdDb = 0.0, rsrqMeanDb = 0.0
        var axisR = 0.0
    }

    /// 0xB063: every transport block against 0xB173, and the walk's coverage (reported, not gated).
    struct B063Counters: Hashable, Sendable {
        var records = 0, declared = 0, found = 0, exactWalks = 0, resynced = 0
        var checked = 0, matched = 0
        var macBytes = 0, paddingBytes = 0, signallingBytes = 0, dataBytes = 0
        var controlElements: [Int: Int] = [:]
    }

    /// 0x184C: the block walk closes on the body's last byte, and how many chains were live or at their limit.
    struct D184CCounters: Hashable, Sendable {
        var records = 0, exact = 0, blocks = 0, subRecords = 0, live = 0, limited = 0
        var chains: [Int: Int] = [:]
    }

    /// 0x1D0B: the two clocks' measured rates, the sequence number, and the trace the modem never wrote.
    struct D1D0BCounters: Hashable, Sendable {
        var records = 0, sequenceSteps = 0, sequenceOk = 0
        var tcxoHz: Double?
        var sleepHz: Double?
        var gaps = 0
        var missingMs = 0.0
    }

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

    // The absolute-TTI axis (PhyTtiAxis), fed by 0xB173: without it a cross-code check keyed on the raw TTI
    // matches subframes seconds apart, because the 10.24 s frame cycle aliases twice in a 22 s capture.
    var axis = PhyTtiAxis()
    /// 0xB193's PCell measurements in time order, for attributing the later codes to a cell.
    var pcellMeasurements: [(tMs: Double, earfcn: Int64, pci: Int, rsrp: Double, rsrq: Double)] = []
    /// "EARFCN/PCI" -> the antenna count that cell's MIB announced (0xB0C1).
    var mibAntennasByCell: [String: Int] = [:]
    /// 0xB173's transport blocks and 0xB139's transmissions, keyed later by absolute TTI.
    var dlBlocks: [(tMs: Double, tti: Int, carrier: Int, harq: Int, tbsBytes: Int, nRb: Int, layers: Int, tbCount: Int)] = []
    var ulTransmissions: [(tMs: Double, tti: Int, startRb: Int, nRb: Int, modulation: Int)] = []
    /// 0xB126's sub-records, 0xB16C's uplink grants and 0xB063's transport blocks, for the cross-checks.
    var demapperSubs: [(tMs: Double, tti: Int, rank: Int, nPrb: Int, txPorts: Int, cell: String?)] = []
    var grants: [(tMs: Double, tti: Int, startRb: Int, nRb: Int, modulation: Int)] = []
    var macBlocks: [(tMs: Double, tti: Int, carrier: Int, harq: Int, sizeBytes: Int)] = []
    /// 0x1D0B's clock samples, in time order.
    var samplerClocks: [(tMs: Double, sleep: UInt32, tcxo: UInt32, sequence: UInt32)] = []
    /// The measured antenna configuration (0xB126), for the summary.
    var txPortsByCell: [String: [Int: Int]] = [:]
    var rxAntennaCounts: [Int: Int] = [:]
    var rankCounts: [Int: Int] = [:]
    /// Every serving cell 0xB193 measured, in time order per cell, for the 0xB179 comparison.
    var servingRsrpByCell: [String: [(tMs: Double, rsrp: Double, rsrq: Double)]] = [:]
    /// 0xB179's serving values minus 0xB193's for the same cell.
    var b179RsrpDeltas: [Double] = []
    var b179RsrqDeltas: [Double] = []
    /// 0x1D0B: the trace the modem never wrote, in order of time.
    var traceGaps: [TraceGap] = []

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
            if PhyDispatch.unstampedCodes.contains(code) {
                decodeUnstamped(code, records, byCode[code]!)
                continue
            }
            // The reference reads each code in time order; ties keep file order.
            let order = byCode[code]!.sorted { (records[$0].timestampRaw, $0) < (records[$1].timestampRaw, $1) }
            for i in order {
                let r = records[i]
                guard let t = tMs(r.timestampRaw) else { continue }
                decode(code, r, t)
            }
        }
    }

    /// A code whose records carry no DIAG timestamp (0xB179): each record is placed by its own in-record TTI. The
    /// cycle it belongs to comes from the nearest stamped record in file order, and the phase from the records of
    /// this code themselves, so the placement does not depend on the QDSS rebuild interpolating anything.
    mutating func decodeUnstamped(_ code: UInt16, _ records: [LogRecord], _ indexes: [Int]) {
        guard !indexes.isEmpty else { return }
        let anchors = fileOrderAnchors(records, indexes)
        // Pass one: the decoded records with their anchors, and this code's own frame phase.
        var pending: [(anchor: Double, value: B179.Measurement)] = []
        var axis = PhyTtiAxis()
        for i in indexes {
            guard let anchor = anchors[i] else { continue }
            switch B179.decode(records[i].body) {
            case .value(let m):
                stats.b179.records += 1
                if m.lengthExact { stats.b179.lengthExact += 1 }
                axis.add(tMs: anchor, tti: m.tti)
                pending.append((anchor, m))
            case .versionMiss(let key): miss(key)
            case .malformed: stats.malformed[code, default: 0] += 1
            }
        }
        stats.b179.axisR = axis.concentration
        // Pass two: place each record on its own TTI and emit its samples, in time order.
        let placed = pending.map { (tMs: axis.timeMs(tti: $0.value.tti, near: $0.anchor), value: $0.value) }
            .sorted { $0.tMs < $1.tMs }
        stats.b179.placed = placed.count
        for p in placed { intraFrequency(p.value, p.tMs) }
    }

    /// For each index in `indexes`, the time of the nearest stamped record in file order (the record before it,
    /// else the one after). Records arrive in the thousands per second, so that is within a millisecond or two of
    /// when the unstamped record was written.
    func fileOrderAnchors(_ records: [LogRecord], _ indexes: [Int]) -> [Int: Double] {
        let wanted = Set(indexes)
        var out: [Int: Double] = [:]
        var previous: Double?
        var open: [Int] = []
        for (i, r) in records.enumerated() {
            if wanted.contains(i) {
                if let previous { out[i] = previous } else { open.append(i) }
                continue
            }
            guard let t = tMs(r.timestampRaw) else { continue }
            previous = t
            for j in open { out[j] = t }
            open.removeAll()
        }
        return out
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
        case 0xB126: handle(B126.decode(r.body)) { $0.demapper($1, t) }
        case 0xB12A: handle(B12A.decode(r.body)) { $0.pcfich($1, t) }
        case 0xB16C: handle(B16C.decode(r.body)) { $0.dci($1, t) }
        case 0xB063: handle(B063.decode(r.body)) { $0.macDl($1.blocks, $1.walk, t) }
        case 0x184C: handle(D184C.decode(r.body)) { $0.txAgc($1.blocks, exact: $1.exact, t) }
        case 0x1D0B: handle(D1D0B.decode(r.body)) { $0.sampler($1, t) }
        default: break
        }
    }

    mutating func mib(_ m: B0C1.Mib, _ t: Double) {
        add(.lte_tx_antennas_mib, t, Double(m.txAntennas), earfcn: m.earfcn, pci: m.pci)
        add(.lte_dl_bandwidth_prb, t, Double(m.dlBandwidthPrb), earfcn: m.earfcn, pci: m.pci)
        txAntennas.insert(m.txAntennas)
        mibAntennasByCell[Extraction.cellKey(m.earfcn, m.pci)] = m.txAntennas
    }

    /// "EARFCN/PCI", the key the measured-antenna summary and the MIB comparison share.
    static func cellKey(_ earfcn: Int64, _ pci: Int) -> String { "\(earfcn)/\(pci)" }

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
        if c.serving {
            servingRsrpByCell[Extraction.cellKey(c.earfcn, c.pci), default: []].append((t, c.rsrp, c.rsrq))
        }
        if c.serving && c.carrier == 0 {
            rxByEarfcn[c.earfcn, default: [:]][c.rxCount, default: 0] += 1
            pcellMeasurements.append((t, c.earfcn, c.pci, c.rsrp, c.rsrq))
        }
    }

    /// What 0xB193 measured for one serving cell nearest to `t`, for checking another code's own measurement.
    func servingMeasurement(earfcn: Int64, pci: Int, at t: Double,
                            maxAge: Double) -> (rsrp: Double, rsrq: Double, ageMs: Double)? {
        guard let list = servingRsrpByCell[Extraction.cellKey(earfcn, pci)], !list.isEmpty else { return nil }
        var lo = 0, hi = list.count - 1, best = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if list[mid].tMs <= t { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let candidates = [best, best + 1].filter { $0 >= 0 && $0 < list.count }
        guard let k = candidates.min(by: { abs(list[$0].tMs - t) < abs(list[$1].tMs - t) }) else { return nil }
        let age = abs(list[k].tMs - t)
        guard age <= maxAge else { return nil }
        return (list[k].rsrp, list[k].rsrq, age)
    }

    /// The PCell 0xB193 measured at `t`, within `maxAge`: what the records after it are attributed to.
    func servingCell(at t: Double, maxAge: Double = 500) -> (earfcn: Int64, pci: Int)? {
        guard !pcellMeasurements.isEmpty else { return nil }
        var lo = 0, hi = pcellMeasurements.count - 1, best = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if pcellMeasurements[mid].tMs <= t { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        // The nearest measurement either side of t, whichever is closer.
        let candidates = [best, best + 1].filter { $0 >= 0 && $0 < pcellMeasurements.count }
        guard let k = candidates.min(by: { abs(pcellMeasurements[$0].tMs - t) < abs(pcellMeasurements[$1].tMs - t) }),
              abs(pcellMeasurements[k].tMs - t) <= maxAge else { return nil }
        return (pcellMeasurements[k].earfcn, pcellMeasurements[k].pci)
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
        // The frame phase and the per-subframe facts the later decoders are checked against. The 0xB173 SFN word
        // is 12 bits wide; the codes it is compared with carry the 10-bit 3GPP SFN.
        let tti = (r.sfn & 1_023) * 10 + r.subframe
        axis.add(tMs: t, tti: tti)
        for tb in r.blocks where tb.qm != 0 {
            dlBlocks.append((t, tti, r.carrier, tb.harq, tb.tbsBytes, tb.nRb, r.layers, r.transportBlocks))
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
        ulTransmissions.append((t, tx.tti % 10_240, tx.startRb, tx.nRb, tx.modulation))
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

    /// The N'RE per PRB values the TBS check tries (12 subcarriers x 10-13 symbols, less DMRS/overhead), up to
    /// the 156 that TS 38.214 5.1.3.2 caps N_RE at. The first capture never used the cap; the second one, on a
    /// wide carrier, has 84 transport blocks that only 156 explains, and with it every one of its 828 new
    /// transmissions matches.
    static let nrRePerPrb = [120, 126, 132, 138, 144, 150, 156]

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
