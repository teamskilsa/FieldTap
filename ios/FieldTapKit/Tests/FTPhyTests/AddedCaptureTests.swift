// The added decoders against both iPhone 17 captures, with the research documents' own numbers. Every expectation
// here is a line in docs/research/iphone-named-log-codes.md or iphone-unknown-log-codes.md: the record counts, the
// framing shares, the cross-code agreement, the byte totals and the clocks. If a firmware change moves a field,
// these are what fail.
//
// The captures are the git-ignored fixtures: iphone-recovered.qmdl (stationary, the contract capture) and
// capture2/capture2.qmdl (driving, the second and independent one).

import Testing
import FTModel
import FTTestSupport
@testable import FTPhy

@Suite(.serialized) struct AddedCaptureTests {
    func loaded(_ name: String) -> AddedCaptures.Loaded? {
        guard Fixtures.require(name) != nil else { return nil }
        guard let l = AddedCaptures.both.first(where: { $0.name == name }) else {
            Issue.record("\(name) did not load"); return nil
        }
        return l
    }

    /// Share as a percentage, rounded to one decimal, for comparing with the documents.
    func percent(_ hit: Int, _ total: Int) -> Double { total == 0 ? 0 : (Double(hit) / Double(total) * 1_000).rounded() / 10 }

    // MARK: 0xB126

    @Test(.fixture(AddedCaptures.stationary), .fixture(AddedCaptures.driving))
    func b126MeasuresAntennasRankAndAllocation() throws {
        for l in [loaded(AddedCaptures.stationary), loaded(AddedCaptures.driving)].compactMap({ $0 }) {
            let b = l.stats.b126
            let driving = l.name == AddedCaptures.driving
            // "62 records, 1,240 sub-records" and "118 records, 2,360 sub-records", 20 per record throughout.
            #expect(b.records == (driving ? 62 : 118), "\(l.name) records \(b.records)")
            #expect(b.subRecords == b.records * 20)
            #expect(b.subRecords == (driving ? 1_240 : 2_360))
            // popcount(bitmap) is an N_RB 0xB173 reports for the same subframe: the document's 99.5% / 99.7%.
            #expect(percent(b.prbMatch, b.prbChecked) >= 99.5, "\(l.name) PRB \(b.prbMatch)/\(b.prbChecked)")
            // Rank equals 0xB173's layers with transmit diversity excepted: 99.9% / 100.0%.
            #expect(percent(b.rankMatch + b.rankTxDiversity, b.rankChecked) >= 99.9,
                    "\(l.name) rank \(b.rankMatch)+\(b.rankTxDiversity)/\(b.rankChecked)")
            #expect(b.rankTxDiversity == (driving ? 33 : 73), "\(l.name) transmit diversity \(b.rankTxDiversity)")
            // Transmit antenna ports equal the MIB's count for every cell whose MIB was captured. The document's
            // own counts, exactly: "all 2,360 of 2,360 sub-records in the stationary capture, across three cells,
            // read 4" and "1,059 of 1,080 sub-records on the driving capture's PCI-235 cell read 4, against 21".
            #expect(b.txChecked == (driving ? 1_080 : 2_360), "\(l.name) Tx checked \(b.txChecked)")
            #expect(b.txMatch == (driving ? 1_059 : 2_360), "\(l.name) Tx ports \(b.txMatch)/\(b.txChecked)")
            #expect(percent(b.txMatch, b.txChecked) >= 98.0)
            #expect(l.samples(.lte_dl_rank).count == b.subRecords)
            #expect(l.samples(.lte_dl_prb_allocation).count == b.subRecords)
            // The bitmap survives the trip through PhySample as two 32-bit words.
            let allocation = l.samples(.lte_dl_prb_allocation).first { ($0.value ?? 0) > 0 }
            let mask = try #require(allocation?.prbMask)
            #expect(mask.nonzeroBitCount == Int(allocation?.value ?? 0))
            #expect(mask >> 50 == 0, "byte +14 only ever holds bits 48 and 49: 50 PRB on a 50-PRB cell")
            // The measured summary names its source and the cells it measured.
            let antennas = try #require(l.capture.summary.antennas)
            #expect(antennas.subRecords == b.subRecords)
            #expect(antennas.source.contains("0xB126 v163"))
            #expect(antennas.txPortsByCell.count == (driving ? 2 : 3), "\(l.name) cells \(antennas.txPortsByCell.keys.sorted())")
            #expect(!antennas.txPortsByCell.keys.contains("unknown"), "every sub-record is attributed to a serving cell")
            for check in ["b126PrbBitmap", "b126Rank", "b126TxAntennaPorts"] {
                #expect(l.check(check)?.passed == true, "\(l.name) \(check): \(l.check(check)?.measured ?? "missing")")
            }
        }
    }

    /// The stationary capture's cells all broadcast four antenna ports, and the driving capture's PCI-80 cell —
    /// the one whose MIB is not in the capture — is the only one that reads two.
    @Test(.fixture(AddedCaptures.driving))
    func b126FollowsTheServingCellNotTheScheduling() throws {
        guard let l = loaded(AddedCaptures.driving) else { return }
        let antennas = try #require(l.capture.summary.antennas)
        // "EARFCN 650 / PCI 235 gives 4 in 1,059 sub-records against 21, and EARFCN 5110 / PCI 80 gives 2 in 140
        // against 20" — the field follows the serving cell, which is why it is an antenna count and not the
        // transmission mode.
        #expect(antennas.txPortsByCell["650/235"] == ["4": 1_059, "2": 21])
        #expect(antennas.txPortsByCell["5110/80"] == ["2": 140, "4": 20])
        #expect(antennas.txPorts(earfcn: 650, pci: 235) == 4)
        #expect(antennas.txPorts(earfcn: 5_110, pci: 80) == 2)
        let ports = Set(l.samples(.lte_tx_antenna_ports).compactMap(\.value))
        #expect(ports == [2, 4], "\(ports)")
    }

    // MARK: 0xB12A

    @Test(.fixture(AddedCaptures.stationary), .fixture(AddedCaptures.driving))
    func b12aGivesTheControlRegionSize() throws {
        for l in [loaded(AddedCaptures.stationary), loaded(AddedCaptures.driving)].compactMap({ $0 }) {
            let b = l.stats.b12a
            let driving = l.name == AddedCaptures.driving
            #expect(b.records == (driving ? 1_607 : 1_334), "\(l.name) records \(b.records)")
            #expect(b.elements == b.records * 20)
            #expect(b.elements == (driving ? 32_140 : 26_680))
            // "only 0x04, 0x08, 0x0C and 0x00 across all 32,140 and 26,680 elements", and 0 exactly when the
            // decode flag is 0: 100%, no exceptions.
            #expect(b.consistent == b.elements, "\(l.name) consistent \(b.consistent) of \(b.elements)")
            #expect(Set(b.cfi.keys) == [1, 2, 3], "\(b.cfi)")
            // The document's own splits.
            if driving {
                #expect(b.cfi == [1: 19_012, 2: 2_823, 3: 9_605], "\(b.cfi)")
            } else {
                #expect(b.cfi == [1: 19_699, 2: 3_364, 3: 1_734], "\(b.cfi)")
            }
            // CFI 3 for 30% of subframes while driving against 6% while stationary: the load contrast.
            let share = percent(b.cfi[3] ?? 0, b.decoded)
            #expect(driving ? share > 25 : share < 10, "\(l.name) CFI 3 share \(share)%")
            #expect(l.check("b12aCfi")?.passed == true)
            #expect(l.samples(.lte_cfi).count == b.decoded)
        }
    }

    // MARK: 0xB16C

    @Test(.fixture(AddedCaptures.stationary), .fixture(AddedCaptures.driving))
    func b16cGivesTheUplinkGrant() throws {
        for l in [loaded(AddedCaptures.stationary), loaded(AddedCaptures.driving)].compactMap({ $0 }) {
            let b = l.stats.b16c
            let driving = l.name == AddedCaptures.driving
            #expect(b.records == (driving ? 177 : 318), "\(l.name) records \(b.records)")
            // "The chain consumes 495 of 495 bodies exactly."
            #expect(b.exact == b.records, "\(l.name) exact \(b.exact) of \(b.records)")
            #expect(b.grants == (driving ? 2_816 : 4_763), "\(l.name) grants \(b.grants)")
            // The 16-byte records precede an 0xB139 PUSCH by exactly four subframes: 97.7% / 99.6% in the
            // document, which is the 0.90 threshold's reason.
            #expect(percent(b.n4Match, b.n4Checked) >= 97.5, "\(l.name) n+4 \(b.n4Match)/\(b.n4Checked)")
            // And the grant's own fields equal 0xB139's: 99.96% / 99.98%.
            #expect(percent(b.fieldMatch, b.fieldChecked) >= 99.9, "\(l.name) fields \(b.fieldMatch)/\(b.fieldChecked)")
            #expect(l.check("b16cUlGrantTiming")?.passed == true)
            #expect(l.check("b16cUlGrantFields")?.passed == true)
            #expect(l.samples(.lte_ul_grant_prb).count == b.grants)
            #expect(l.samples(.lte_ul_grant_start_rb).count == b.grants)
            // Nothing is claimed from the 8-byte downlink assignments: they are counted and no field is read.
            #expect(b.assignments > 0)
            #expect(l.samples(.lte_dl_assignments).compactMap(\.value).allSatisfy { $0 >= 1 })
        }
    }

    // MARK: 0xB179

    @Test(.fixture(AddedCaptures.stationary), .fixture(AddedCaptures.driving))
    func b179GivesTheNeighbourListAndItsOwnTime() throws {
        for l in [loaded(AddedCaptures.stationary), loaded(AddedCaptures.driving)].compactMap({ $0 }) {
            let b = l.stats.b179
            let driving = l.name == AddedCaptures.driving
            #expect(b.records == (driving ? 385 : 373), "\(l.name) records \(b.records)")
            // "len == 28 + 12 x count in 380 of 385 (98.7%) and 369 of 373 (98.9%)".
            #expect(b.lengthExact == (driving ? 380 : 369), "\(l.name) length \(b.lengthExact)")
            // Every record is placed, although none of them carries a DIAG timestamp.
            #expect(b.placed == b.records)
            #expect(b.axisR > 0.9999, "\(l.name) own-timing R \(b.axisR)")
            // The scales are 0xB193's: the mean offset is within a fraction of a decibel on both captures, and the
            // spread is what degrades while driving (1.2 dB against 2.8 dB), which the check reports.
            #expect(abs(b.rsrpMeanDb) <= 0.3, "\(l.name) RSRP mean \(b.rsrpMeanDb)")
            #expect(abs(b.rsrqMeanDb) <= 0.5, "\(l.name) RSRQ mean \(b.rsrqMeanDb)")
            #expect(b.rsrpSdDb < (driving ? 3.0 : 1.5), "\(l.name) RSRP sd \(b.rsrpSdDb)")
            #expect(l.check("b179Length")?.passed == true)
            #expect(l.check("b179OwnTiming")?.passed == true)
            #expect(l.check("b179ServingRsrp")?.passed == true)
            // The neighbours: 501 measurements while driving on PCIs nothing else in the capture reports.
            #expect(b.neighbours == (driving ? 501 : 272), "\(l.name) neighbours \(b.neighbours)")
            #expect(l.samples(.lte_intra_neighbour_rsrp).count == b.neighbours)
            #expect(l.samples(.lte_intra_neighbour_margin).count == b.neighbours)
            // The margin is the neighbour minus the serving cell, and both come from the same record.
            let margins = l.samples(.lte_intra_neighbour_margin).compactMap(\.value)
            // A neighbour is usually weaker than the serving cell; the few that are stronger are the handover
            // candidates, and none is more than a few dB ahead in either capture.
            #expect(margins.allSatisfy { $0 > -100 && $0 < 20 }, "\(margins.min() ?? 0) ... \(margins.max() ?? 0)")
            #expect((margins.max() ?? 0) > 0, "some neighbour was stronger at some point")
            if driving {
                let pcis = Set(l.samples(.lte_intra_neighbour_rsrp).compactMap(\.pci))
                #expect(pcis.isSuperset(of: [295, 388, 298, 449, 263, 362]), "\(pcis.sorted())")
                let measuredElsewhere = Set(l.samples(.lte_neighbour_rsrp).compactMap(\.pci))
                #expect(!pcis.subtracting(measuredElsewhere).isEmpty,
                        "most of these cells are measured by nothing else in the capture")
            }
            // Its samples are in time order although the records arrive unstamped.
            let times = l.samples(.lte_intra_serving_rsrp).map(\.tMs)
            #expect(times == times.sorted())
        }
    }

    // MARK: 0xB063

    @Test(.fixture(AddedCaptures.stationary), .fixture(AddedCaptures.driving))
    func b063AccountsForTheMacDownlink() throws {
        for l in [loaded(AddedCaptures.stationary), loaded(AddedCaptures.driving)].compactMap({ $0 }) {
            let b = l.stats.b063
            let driving = l.name == AddedCaptures.driving
            #expect(b.records == (driving ? 143 : 129), "\(l.name) records \(b.records)")
            // "978 of 1,230" and "2,521 of 3,085" declared transport blocks, i.e. 80% / 82% coverage.
            #expect(b.declared == (driving ? 1_230 : 3_085), "\(l.name) declared \(b.declared)")
            #expect(b.found == (driving ? 978 : 2_521), "\(l.name) found \(b.found)")
            #expect(percent(b.found, b.declared) >= 79.0)
            // "the walk lands on the last byte in 93 (65%)" / "72 (56%)".
            #expect(b.exactWalks == (driving ? 93 : 72), "\(l.name) exact walks \(b.exactWalks)")
            // Every transport block is a 0xB173 one on (SFN, subframe, carrier, HARQ, size): 99.0% / 99.9%.
            #expect(percent(b.matched, b.checked) >= 98.5, "\(l.name) matched \(b.matched)/\(b.checked)")
            // The byte totals and the padding share, exactly as the document states them.
            #expect(b.macBytes == (driving ? 655_956 : 2_235_835), "\(l.name) MAC bytes \(b.macBytes)")
            #expect(b.paddingBytes == (driving ? 18_880 : 41_730), "\(l.name) padding \(b.paddingBytes)")
            let padding = percent(b.paddingBytes, b.macBytes)
            #expect(abs(padding - (driving ? 2.9 : 1.9)) <= 0.1, "\(l.name) padding share \(padding)%")
            // The timing-advance command appears, and carries no value: twice driving, four times stationary.
            #expect(b.controlElements[29] == (driving ? 2 : 4), "\(l.name) TA commands \(b.controlElements)")
            #expect(b.controlElements[27] == (driving ? 31 : 18), "activation/deactivation \(b.controlElements)")
            #expect(b.controlElements[28] == 1, "one contention resolution identity \(b.controlElements)")
            let mac = try #require(l.capture.summary.macDl)
            #expect(mac.macBytes == b.macBytes && mac.foundBlocks == b.found && mac.declaredBlocks == b.declared)
            #expect(mac.coverage >= 0.79 && mac.coverage <= 0.83, "\(mac.coverage)")
            #expect(mac.dataBytes > mac.signallingBytes * 100, "this is user-data traffic, not signalling")
            #expect(l.check("b063VsB173")?.passed == true)
            // The coverage check is reported, not gated, and says so.
            let coverage = try #require(l.check("b063WalkCoverage"))
            #expect(coverage.passed && coverage.expectation.contains("reported and not gated"))
            #expect(l.samples(.lte_mac_dl_bytes).count == b.found)
        }
    }

    // MARK: 0x184C and 0x1D0B

    @Test(.fixture(AddedCaptures.stationary), .fixture(AddedCaptures.driving))
    func d184cGivesFrontEndTransmitPowerPerChain() throws {
        for l in [loaded(AddedCaptures.stationary), loaded(AddedCaptures.driving)].compactMap({ $0 }) {
            let b = l.stats.d184c
            let driving = l.name == AddedCaptures.driving
            #expect(b.records == (driving ? 2_393 : 4_465), "\(l.name) records \(b.records)")
            // "the walk consumes the body exactly on 2,391 of 2,393 records (99.92%) and 4,464 of 4,465 (99.98%)".
            #expect(b.exact == (driving ? 2_391 : 4_464), "\(l.name) exact \(b.exact)")
            #expect(percent(b.exact, b.records) >= 99.9)
            #expect(b.live > 0 && b.live < b.subRecords, "some chains are off (the -70.0 dBm sentinel)")
            #expect(l.check("d184cFraming")?.passed == true)
            #expect(l.samples(.lte_tx_power_chain).count == b.live)
            #expect(l.samples(.lte_tx_power_headroom).count == b.live)
            // The power's range, and the limit's, are the document's: -70 ... +25 dBm and 17.7 ... 25.0 dBm.
            let power = l.samples(.lte_tx_power_chain).compactMap(\.value)
            #expect((power.min() ?? 0) > -70.0 && (power.max() ?? 0) <= 25.0, "\(power.min() ?? 0) ... \(power.max() ?? 0)")
            // The limit's validated range, with the records that leave the field at zero dropped as unset.
            let limits = l.samples(.lte_tx_power_limit).compactMap(\.value)
            #expect((limits.min() ?? 0) >= 17.0 && (limits.max() ?? 0) <= 25.0, "\(limits.min() ?? 0) ... \(limits.max() ?? 0)")
            // Transmit-limited: the phone sits at its chain's limit a large part of the time in both captures,
            // which is the answer this code exists to give.
            let limited = percent(b.limited, b.live)
            #expect(limited > 30 && limited < 70, "\(l.name) at the limit \(limited)% of live sub-records")
            // Several chains, the tags the record writes.
            #expect(b.chains.keys.sorted() == [0, 1, 2, 16, 17, 18, 32, 33, 34], "\(b.chains.keys.sorted())")
        }
    }

    @Test(.fixture(AddedCaptures.stationary), .fixture(AddedCaptures.driving))
    func d1d0bMeasuresTheMissingTraceInSeconds() throws {
        for l in [loaded(AddedCaptures.stationary), loaded(AddedCaptures.driving)].compactMap({ $0 }) {
            let b = l.stats.d1d0b
            let driving = l.name == AddedCaptures.driving
            #expect(b.records == (driving ? 1_914 : 2_238), "\(l.name) records \(b.records)")
            // "median per-record rate 19,200,006 counts/s - the 19.2 MHz TCXO, to seven figures".
            let tcxo = try #require(b.tcxoHz)
            #expect(abs(tcxo - 19_200_000) < 20_000, "\(l.name) TCXO \(tcxo)")
            // "1,902 of 1,907 consecutive deltas are exactly +1" driving; every one of them stationary.
            #expect(b.sequenceOk == (driving ? 1_902 : 2_237), "\(l.name) sequence \(b.sequenceOk)/\(b.sequenceSteps)")
            #expect(l.check("d1d0bClocks")?.passed == true, "\(l.check("d1d0bClocks")?.measured ?? "missing")")
            // The gaps: the driving capture's detach loses 2.2 s, 1.1 s, 1.0 s and 0.6 s of trace, which is what
            // the app now says instead of "messages around the gaps may be incomplete".
            let gaps = l.capture.summary.traceGaps ?? []
            #expect(gaps.count == b.gaps && b.gaps == (driving ? 4 : 2), "\(l.name) gaps \(gaps)")
            #expect(gaps.map(\.tMs) == gaps.map(\.tMs).sorted())
            let seconds = gaps.map { ($0.missingMs / 100).rounded() / 10 }.sorted(by: >)
            if driving {
                #expect(seconds == [2.2, 1.1, 1.0, 0.6], "\(seconds)")
                // Two of them are inside the detach and re-attach window.
                #expect(gaps.filter { $0.tMs > 10_000 && $0.tMs < 13_000 }.count >= 3, "\(gaps.map(\.tMs))")
            } else {
                #expect(seconds == [2.5, 1.2], "\(seconds)")
            }
            let total = l.capture.summary.missingTraceMs / 1_000
            #expect(abs(total - (driving ? 4.89 : 3.71)) < 0.05, "\(l.name) missing \(total) s")
        }
    }

    // MARK: the whole run

    @Test(.fixture(AddedCaptures.stationary), .fixture(AddedCaptures.driving))
    func everyAddedDecoderIsCleanOnBothCaptures() throws {
        for l in [loaded(AddedCaptures.stationary), loaded(AddedCaptures.driving)].compactMap({ $0 }) {
            // No record of a validated version was too short for its own layout, and no version was skipped.
            #expect(l.stats.malformed.isEmpty, "\(l.name) malformed \(l.stats.malformed)")
            #expect(l.capture.versionMisses.isEmpty, "\(l.name) version misses \(l.capture.versionMisses)")
            // The absolute-TTI axis the cross-checks are keyed on holds.
            #expect(l.stats.axisR > 0.99, "\(l.name) axis R \(l.stats.axisR)")
            #expect(l.stats.axisSamples > 1_000)
            // Every added check ran and passed.
            let added = ["b126PrbBitmap", "b126Rank", "b126TxAntennaPorts", "b12aCfi", "b16cUlGrantTiming",
                         "b16cUlGrantFields", "b179Length", "b179OwnTiming", "b179ServingRsrp", "b063VsB173",
                         "b063WalkCoverage", "d184cFraming", "d1d0bClocks"]
            #expect(Set(l.capture.checks.map(\.id)).isSuperset(of: Set(added)), "\(l.name) \(l.capture.checks.map(\.id))")
            for c in l.capture.checks { #expect(c.passed, "\(l.name) \(c.id): \(c.measured)") }
            // Every added series has samples on both captures, and none of them is empty.
            for m in PhyMetric.addedAfterReference {
                #expect(!l.samples(m).isEmpty, "\(l.name) \(m.rawValue) is empty")
                #expect(l.samples(m).map(\.tMs) == l.samples(m).map(\.tMs).sorted(), "\(l.name) \(m.rawValue) out of order")
            }
            // And the codes the research rejected are still not decoded: no series names them.
            let rejected: Set<UInt16> = [0xB883, 0xB884, 0xB885, 0xB8A7, 0xB111, 0xB8C9, 0xB114, 0xB122, 0xB146, 0xB16B]
            #expect(Set(PhyMetric.allCases.map(\.info.code)).isDisjoint(with: rejected))
        }
    }
}
