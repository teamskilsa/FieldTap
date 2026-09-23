// The extraction side of the decoders added after the reference extractor: 0xB126 (measured antennas, rank and
// PRB allocation), 0xB12A (the control region), 0xB16C (the uplink grant), 0xB179 (the neighbour list), 0xB063
// (MAC downlink accounting) and 0x184C / 0x1D0B (front-end transmit power, and the trace the modem never wrote).
//
// Each one emits its samples here and leaves the counts its self-check needs in PhyStats; the cross-code checks
// themselves run in PhyChecksAdded once every code has been read, because they need the absolute-TTI axis.

import FTModel

extension Extraction {
    /// Times the elements of one record from its own TTIs: the last element is the record's own time and each
    /// earlier one steps back by the subframes between them (modulo the 10.24 s frame cycle). A step further back
    /// than `maxBackdateMs` is not trusted — the elements are not consecutive there, or the frame number wrapped
    /// the other way — and that element keeps the record's own time instead.
    static func elementTimes(_ ttis: [Int], recordMs: Double, maxBackdateMs: Int = 1_000) -> [Double] {
        guard let last = ttis.last else { return [] }
        return ttis.map {
            let back = (last - $0 + 10_240) % 10_240
            return recordMs - Double(back <= maxBackdateMs ? back : 0)
        }
    }

    /// Times the elements of a record that always holds the same number of consecutive subframes, the last one
    /// being "now" (0xB126's twenty sub-records and 0xB12A's twenty elements): one millisecond per subframe, from
    /// the index, so a frame number that resets cannot move a sample.
    static func consecutiveSubframeTimes(_ count: Int, recordMs: Double) -> [Double] {
        (0..<count).map { recordMs - Double((count - 1 - $0) * 10) }
    }

    // MARK: 0xB126 LL1 PDSCH demapper configuration

    mutating func demapper(_ subs: [B126.SubRecord], _ t: Double) {
        stats.b126.records += 1
        let times = Extraction.consecutiveSubframeTimes(subs.count, recordMs: t)
        for (k, s) in subs.enumerated() {
            let ts = times[k]
            let cell = servingCell(at: ts)
            let key = cell.map { Extraction.cellKey($0.earfcn, $0.pci) }
            stats.b126.subRecords += 1
            txPortsByCell[key ?? "unknown", default: [:]][s.txAntennaPorts, default: 0] += 1
            rxAntennaCounts[s.rxAntennas, default: 0] += 1
            rankCounts[s.rank, default: 0] += 1
            demapperSubs.append((ts, s.tti, s.rank, s.nPrb, s.txAntennaPorts, key))
            func put(_ m: PhyMetric, _ v: Double, perIndex: [Double?]? = nil) {
                add(m, ts, v, perIndex: perIndex, earfcn: cell?.earfcn, pci: cell?.pci, tag: s.subframe)
            }
            put(.lte_tx_antenna_ports, Double(s.txAntennaPorts))
            put(.lte_rx_antennas_used, Double(s.rxAntennas))
            put(.lte_dl_rank, Double(s.rank))
            put(.lte_dl_prb_allocation, Double(s.nPrb), perIndex: PhySample.prbWords(s.prbMask))
        }
    }

    // MARK: 0xB12A LL1 PCFICH decoding results

    mutating func pcfich(_ r: B12A.Record, _ t: Double) {
        stats.b12a.records += 1
        // The 20 elements are consecutive subframes; which of the two radio frames the header SFN names is not
        // established, so they are placed by the record's own time, a frame at worst.
        for (k, e) in r.elements.enumerated() {
            stats.b12a.elements += 1
            if e.consistent { stats.b12a.consistent += 1 }
            guard let cfi = e.cfi, e.decoded else { continue }
            stats.b12a.decoded += 1
            stats.b12a.cfi[cfi, default: 0] += 1
            add(.lte_cfi, Extraction.consecutiveSubframeTimes(r.elements.count, recordMs: t)[k], Double(cfi),
                tag: e.subframe)
        }
    }

    // MARK: 0xB16C ML1 DCI information report

    mutating func dci(_ r: B16C.Record, _ t: Double) {
        stats.b16c.records += 1
        if r.exact { stats.b16c.exact += 1 }
        let times = Extraction.elementTimes(r.elements.map(\.tti), recordMs: t)
        for (k, e) in r.elements.enumerated() {
            let ts = times[k]
            stats.b16c.elements += 1
            stats.b16c.assignments += e.dlAssignments
            if e.dlAssignments > 0 { add(.lte_dl_assignments, ts, Double(e.dlAssignments), tag: e.subframe) }
            for g in e.ulGrants {
                stats.b16c.grants += 1
                grants.append((ts, e.tti, g.startRb, g.nRb, g.modulation))
                add(.lte_ul_grant_start_rb, ts, Double(g.startRb), tag: e.subframe)
                add(.lte_ul_grant_prb, ts, Double(g.nRb), tag: e.subframe)
                if let qm = g.qm { add(.lte_ul_grant_modulation, ts, Double(qm), tag: e.subframe) }
            }
        }
    }

    // MARK: 0xB179 ML1 connected-mode intra-frequency measurements

    /// One measured frequency, already placed in time by its own TTI (see `decodeUnstamped`).
    mutating func intraFrequency(_ m: B179.Measurement, _ t: Double) {
        let serving = m.earfcn
        // The scales are 0xB193's own: compare the serving values with what 0xB193 measured for the same cell.
        if let ref = servingMeasurement(earfcn: m.earfcn, pci: m.pci, at: t, maxAge: Extraction.b179MatchMs) {
            stats.b179.rsrpChecked += 1
            let delta = m.rsrp - ref.rsrp
            b179RsrpDeltas.append(delta)
            b179RsrqDeltas.append(m.rsrq - ref.rsrq)
            if abs(delta) <= 1 { stats.b179.rsrpWithin1Db += 1 }
        }
        add(.lte_intra_serving_rsrp, t, m.rsrp, earfcn: serving, pci: m.pci, tag: CellRole.serving)
        add(.lte_intra_serving_rsrq, t, m.rsrq, earfcn: serving, pci: m.pci, tag: CellRole.serving)
        for (j, n) in m.neighbours.enumerated() {
            stats.b179.neighbours += 1
            add(.lte_intra_neighbour_rsrp, t, n.rsrp, earfcn: serving, pci: n.pci, carrier: PhySample.notServing, tag: j)
            add(.lte_intra_neighbour_rsrq, t, n.rsrq, earfcn: serving, pci: n.pci, carrier: PhySample.notServing, tag: j)
            // The margin against the serving cell on the same frequency: positive means the neighbour is stronger,
            // which is the number a handover decision turns on.
            add(.lte_intra_neighbour_margin, t, n.rsrp - m.rsrp, earfcn: serving, pci: n.pci,
                carrier: PhySample.notServing, tag: j)
        }
    }

    // MARK: 0xB063 MAC DL transport block

    mutating func macDl(_ blocks: [B063.TransportBlock], _ walk: B063.Walk, _ t: Double) {
        stats.b063.records += 1
        stats.b063.declared += walk.declared
        stats.b063.found += walk.found
        stats.b063.resynced += walk.resynced
        if walk.exact { stats.b063.exactWalks += 1 }
        let times = Extraction.elementTimes(blocks.map(\.tti), recordMs: t)
        for (k, tb) in blocks.enumerated() {
            let ts = times[k]
            macBlocks.append((ts, tb.tti, tb.carrier, tb.harq, tb.sizeBytes))
            stats.b063.macBytes += tb.sizeBytes
            stats.b063.paddingBytes += tb.paddingBytes
            stats.b063.signallingBytes += tb.signallingBytes
            stats.b063.dataBytes += tb.dataBytes
            for ce in tb.sdus where ce.control { stats.b063.controlElements[ce.lcid, default: 0] += 1 }
            func put(_ m: PhyMetric, _ v: Int) { add(m, ts, Double(v), carrier: tb.carrier, tag: tb.harq) }
            put(.lte_mac_dl_bytes, tb.sizeBytes)
            put(.lte_mac_dl_padding, tb.paddingBytes)
            if tb.signallingBytes > 0 { put(.lte_mac_dl_signalling_bytes, tb.signallingBytes) }
            if tb.dataBytes > 0 { put(.lte_mac_dl_data_bytes, tb.dataBytes) }
        }
    }

    // MARK: 0x184C RF FED Tx AGC

    mutating func txAgc(_ blocks: [D184C.Block], exact: Bool, _ t: Double) {
        stats.d184c.records += 1
        if exact { stats.d184c.exact += 1 }
        for (b, block) in blocks.enumerated() {
            stats.d184c.blocks += 1
            // The blocks of one record are consecutive subframes, the last one being the record's own time.
            let ts = t - Double(blocks.count - 1 - b)
            for s in block.subRecords {
                stats.d184c.subRecords += 1
                stats.d184c.chains[s.chain, default: 0] += 1
                guard let power = s.txPowerDbm, let limit = s.limitDbm, let headroom = s.headroomDb else { continue }
                stats.d184c.live += 1
                if headroom <= Extraction.transmitLimitedDb { stats.d184c.limited += 1 }
                add(.lte_tx_power_chain, ts, power, tag: s.chain)
                add(.lte_tx_power_limit, ts, limit, tag: s.chain)
                add(.lte_tx_power_headroom, ts, headroom, tag: s.chain)
                add(.lte_tx_pa_state, ts, Double(s.gainState), tag: s.chain)
            }
        }
    }

    /// Headroom at or below this is "transmit-limited": the chain is at the limit the front end set for it.
    static let transmitLimitedDb = 0.5

    /// How near in time an 0xB193 measurement has to be to check an 0xB179 record against it. 0xB179 places
    /// itself to about four subframes, and 0xB193 measures every 10-40 ms, so 100 ms is a fair match.
    static let b179MatchMs = 50.0

    // MARK: 0x1D0B the modem's clocks

    mutating func sampler(_ s: D1D0B.Sample, _ t: Double) {
        stats.d1d0b.records += 1
        samplerClocks.append((t, s.sleepCounts, s.tcxoTicks, s.sequence))
    }
}
