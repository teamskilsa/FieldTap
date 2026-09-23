// SEED from WP0; owned by WP4-phy. The PHY/MAC value types FTPhy produces and the Radio page, FTJourney
// and the capture summary read. Shapes follow ios/Fixtures/local/contract/phy-golden.json and phy-summary.json.

/// Every series FTPhy produces for this modem. The first 48 are the validated reference extractor's
/// (phy-inventory kpis.py) and their raw values are exactly the keys of phy-golden.json; the rest come from the
/// decoders added after it (0xB126, 0xB12A, 0xB16C, 0xB179, 0xB063 and 0x184C, see
/// docs/research/iphone-named-log-codes.md and iphone-unknown-log-codes.md).
public enum PhyMetric: String, CaseIterable, Codable, CodingKeyRepresentable, Hashable, Sendable {
    case lte_tx_antennas_mib
    case lte_dl_bandwidth_prb
    case lte_band
    case lte_rsrp
    case lte_rsrp_filtered
    case lte_rsrq_filtered
    case lte_rssi
    case lte_rx_antennas_measured
    case lte_rsrp_per_rx
    case lte_rsrq_per_rx
    case lte_rssi_per_rx
    case lte_neighbour_rsrp
    case lte_neighbour_rsrp_filtered
    case lte_neighbour_rsrq_filtered
    case lte_neighbour_rssi
    case lte_dl_mcs
    case lte_dl_prb
    case lte_dl_tbs
    case lte_dl_modulation
    case lte_dl_crc_ok
    case lte_dl_layers
    case lte_dl_bler
    case lte_dl_phy_throughput
    case lte_ul_prb
    case lte_ul_tbs
    case lte_ul_modulation
    case lte_ul_code_rate
    case lte_pusch_tx_power_required
    case lte_ul_mcs_derived
    case lte_ul_phy_throughput
    case lte_cqi_wideband_cw0
    case lte_ri
    case lte_pmi_wideband
    case lte_csf_tx_mode
    case lte_cqi_wideband_cw1
    case lte_mac_ul_grant
    case lte_power_headroom
    case lte_timing_advance_rar
    case nr_ss_rsrp
    case nr_ss_rsrq
    case nr_dl_mcs
    case nr_dl_prb
    case nr_dl_layers
    case nr_dl_tbs
    case nr_dl_modulation
    case nr_dl_crc_ok
    case nr_dl_bler
    case nr_dl_mac_throughput
    // 0xB126 v163 LL1 PDSCH demapper configuration: measured antennas, rank and allocation, per subframe.
    case lte_tx_antenna_ports
    case lte_rx_antennas_used
    case lte_dl_rank
    case lte_dl_prb_allocation
    // 0xB12A v161 LL1 PCFICH: the cell's control-region size, per subframe.
    case lte_cfi
    // 0xB16C v50 ML1 DCI information report: the uplink grant, and how many downlink assignments per subframe.
    case lte_ul_grant_start_rb
    case lte_ul_grant_prb
    case lte_ul_grant_modulation
    case lte_dl_assignments
    // 0xB179 v56 ML1 connected-mode intra-frequency measurements: the neighbour list and the handover margin.
    case lte_intra_serving_rsrp
    case lte_intra_serving_rsrq
    case lte_intra_neighbour_rsrp
    case lte_intra_neighbour_rsrq
    case lte_intra_neighbour_margin
    // 0xB063 v50 MAC DL transport block: MAC-level downlink accounting.
    case lte_mac_dl_bytes
    case lte_mac_dl_padding
    case lte_mac_dl_signalling_bytes
    case lte_mac_dl_data_bytes
    // 0x184C v17 RF FED Tx AGC: the front end's own transmit power, its limit and the amplifier state, per chain.
    case lte_tx_power_chain
    case lte_tx_power_limit
    case lte_tx_power_headroom
    case lte_tx_pa_state

    /// The 48 KPIs of the reference extractor, which `contract/phy-golden.json` is the contract for.
    public static let referenceKpis: [PhyMetric] = Array(allCases.prefix(48))

    /// The series the decoders added after the reference extractor produce.
    public static let addedAfterReference: [PhyMetric] = Array(allCases.dropFirst(48))
}

/// How far a value can be trusted: read directly and validated, read from a layout with some uncertainty
/// (e.g. 0xB14D bit positions), or computed from other fields (e.g. UL MCS from the TBS table).
public enum PhyConfidence: String, Codable, Hashable, Sendable {
    case high, medium, derived
}

/// One value at one time. Per-antenna series fill `perIndex` (nil entries for an antenna not measured).
public struct PhySample: Hashable, Codable, Sendable {
    /// Milliseconds since the capture's time base (D1).
    public var tMs: Double
    public var value: Double?
    public var perIndex: [Double?]?
    public var earfcn: Int64?
    public var pci: Int?
    /// Carrier index as the record gives it: 0 = PCell, 1... = SCells. Mapped to cells through the Journey.
    public var carrier: Int
    /// Decoder-specific tag (codeword, neighbour index...).
    public var tag: Int?

    public init(tMs: Double, value: Double?, perIndex: [Double?]? = nil, earfcn: Int64? = nil, pci: Int? = nil,
                carrier: Int = 0, tag: Int? = nil) {
        self.tMs = tMs
        self.value = value
        self.perIndex = perIndex
        self.earfcn = earfcn
        self.pci = pci
        self.carrier = carrier
        self.tag = tag
    }
}

public struct PhySeries: Hashable, Codable, Sendable {
    public var metric: PhyMetric
    public var unit: String
    public var code: UInt16
    /// The record version the decoder accepted, e.g. "50" or "3.13".
    public var version: String
    public var confidence: PhyConfidence
    public var samples: [PhySample]

    public init(metric: PhyMetric, unit: String, code: UInt16, version: String, confidence: PhyConfidence,
                samples: [PhySample]) {
        self.metric = metric
        self.unit = unit
        self.code = code
        self.version = version
        self.confidence = confidence
        self.samples = samples
    }
}

/// When a carrier was active according to the PHY records. EARFCN and PCI are nil when the record carries
/// only a carrier index (the NR DL records): FTJourney attributes those to a cell.
public struct CarrierActivity: Hashable, Codable, Sendable {
    public var index: Int
    public var earfcn: Int64?
    public var pci: Int?
    public var firstMs: Double
    public var lastMs: Double
    public var records: Int
    public var source: String

    public init(index: Int, earfcn: Int64?, pci: Int?, firstMs: Double, lastMs: Double, records: Int, source: String) {
        self.index = index
        self.earfcn = earfcn
        self.pci = pci
        self.firstMs = firstMs
        self.lastMs = lastMs
        self.records = records
        self.source = source
    }
}

/// One random-access response (0xB062): the timing advance it granted and the distance that implies.
public struct RachEvent: Hashable, Codable, Sendable {
    public var tMs: Double
    public var ta: Int
    public var distanceM: Double?
    public var ulEarfcn: Int64?
    /// The preamble target power the record states, when the layout carries it.
    public var preambleTargetDbm: Double?

    public init(tMs: Double, ta: Int, distanceM: Double?, ulEarfcn: Int64?, preambleTargetDbm: Double? = nil) {
        self.tMs = tMs
        self.ta = ta
        self.distanceM = distanceM
        self.ulEarfcn = ulEarfcn
        self.preambleTargetDbm = preambleTargetDbm
    }
}

/// 0xB126 v163: the antenna configuration the modem *measured*, per subframe, rather than the one the MIB
/// broadcasts. Transmit antenna ports are high confidence (they equal the MIB's count for every cell whose MIB
/// was captured), receive antennas medium (they agree with 0xB193's Rx map in 88-93%).
public struct MeasuredAntennas: Hashable, Codable, Sendable {
    /// "EARFCN/PCI" of the serving cell -> transmit antenna ports -> sub-records.
    public var txPortsByCell: [String: [String: Int]]
    /// Receive antennas in use -> sub-records.
    public var rxAntennas: [String: Int]
    /// Rank (spatial layers of the PDSCH) -> sub-records.
    public var rank: [String: Int]
    public var subRecords: Int
    public var source: String

    public init(txPortsByCell: [String: [String: Int]], rxAntennas: [String: Int], rank: [String: Int],
                subRecords: Int, source: String) {
        self.txPortsByCell = txPortsByCell
        self.rxAntennas = rxAntennas
        self.rank = rank
        self.subRecords = subRecords
        self.source = source
    }

    /// The transmit antenna ports of one cell, when the sub-records agree on one value.
    public func txPorts(earfcn: Int64, pci: Int) -> Int? {
        let counts = txPortsByCell["\(earfcn)/\(pci)"] ?? [:]
        return counts.max { $0.value < $1.value }.flatMap { Int($0.key) }
    }
}

/// 0xB063 v50: MAC-level downlink accounting. The transport-block header is validated against 0xB173, but the
/// walk over the PDCP tail reaches only about 80% of the declared transport blocks, so every total here carries
/// its coverage and 0xB173 stays the throughput source.
public struct MacDlAccounting: Hashable, Codable, Sendable {
    public var records: Int
    /// Transport blocks the records declare, and how many the walk reached.
    public var declaredBlocks: Int
    public var foundBlocks: Int
    /// Records whose walk ended exactly on the last byte of the body.
    public var exactWalks: Int
    public var macBytes: Int
    public var paddingBytes: Int
    /// SDU bytes on LCID 0-2 (signalling: CCCH and the two default DCCHs) and on LCID 3 and up (user data).
    public var signallingBytes: Int
    public var dataBytes: Int
    /// LCID -> MAC control elements seen (TS 36.321 table 6.2.1-1).
    public var controlElements: [String: Int]
    public var source: String

    public init(records: Int, declaredBlocks: Int, foundBlocks: Int, exactWalks: Int, macBytes: Int,
                paddingBytes: Int, signallingBytes: Int, dataBytes: Int, controlElements: [String: Int],
                source: String) {
        self.records = records
        self.declaredBlocks = declaredBlocks
        self.foundBlocks = foundBlocks
        self.exactWalks = exactWalks
        self.macBytes = macBytes
        self.paddingBytes = paddingBytes
        self.signallingBytes = signallingBytes
        self.dataBytes = dataBytes
        self.controlElements = controlElements
        self.source = source
    }

    /// The share of declared transport blocks the walk reached; every byte total is short by the rest.
    public var coverage: Double { declaredBlocks > 0 ? Double(foundBlocks) / Double(declaredBlocks) : 0 }
    public var paddingShare: Double { macBytes > 0 ? Double(paddingBytes) / Double(macBytes) : 0 }
}

/// A stretch of trace that was never written, measured by the modem's own 1024 Hz clock in 0x1D0B: the record
/// after the gap says exactly how much wall time passed.
public struct TraceGap: Hashable, Codable, Sendable {
    /// Where the gap starts, in ms since the time base.
    public var tMs: Double
    public var missingMs: Double

    public init(tMs: Double, missingMs: Double) {
        self.tMs = tMs
        self.missingMs = missingMs
    }
}

/// What FTJourney needs from the PHY layer; decodes contract/phy-summary.json as is. The fields added after the
/// contract are optional so an older summary still decodes.
public struct PhySummary: Hashable, Codable, Sendable {
    public var scellActivity: [CarrierActivity]
    public var nrDlActivity: CarrierActivity?
    public var rach: [RachEvent]
    public var txAntennasMib: [Int]
    /// EARFCN -> number of Rx antennas measured -> records.
    public var rxAntennasByEarfcn: [String: [String: Int]]
    public var encrypted: EncryptedCensus
    /// 0xB126: the measured antenna configuration, nil when the capture has no 0xB126 record.
    public var antennas: MeasuredAntennas?
    /// 0xB063: MAC downlink accounting with its coverage, nil when the capture has no 0xB063 record.
    public var macDl: MacDlAccounting?
    /// 0x1D0B: the trace the modem never wrote, in order of time; nil when the capture has no 0x1D0B record.
    public var traceGaps: [TraceGap]?

    public init(scellActivity: [CarrierActivity], nrDlActivity: CarrierActivity?, rach: [RachEvent],
                txAntennasMib: [Int], rxAntennasByEarfcn: [String: [String: Int]], encrypted: EncryptedCensus,
                antennas: MeasuredAntennas? = nil, macDl: MacDlAccounting? = nil, traceGaps: [TraceGap]? = nil) {
        self.scellActivity = scellActivity
        self.nrDlActivity = nrDlActivity
        self.rach = rach
        self.txAntennasMib = txAntennasMib
        self.rxAntennasByEarfcn = rxAntennasByEarfcn
        self.encrypted = encrypted
        self.antennas = antennas
        self.macDl = macDl
        self.traceGaps = traceGaps
    }

    public static let empty = PhySummary(scellActivity: [], nrDlActivity: nil, rach: [], txAntennasMib: [],
                                         rxAntennasByEarfcn: [:], encrypted: .empty)

    /// True when no PHY decoder contributed anything (the seed, or a capture without PHY records).
    public var isEmpty: Bool {
        scellActivity.isEmpty && nrDlActivity == nil && rach.isEmpty && txAntennasMib.isEmpty
            && rxAntennasByEarfcn.isEmpty && antennas == nil && macDl == nil && (traceGaps ?? []).isEmpty
    }

    /// Total trace the modem never wrote, and the gaps that carry it (0x1D0B).
    public var missingTraceMs: Double { (traceGaps ?? []).reduce(0) { $0 + $1.missingMs } }
}

/// A runtime self-check of a decoder against a physical or 3GPP identity ("Decoder health").
public struct PhyCheck: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var code: UInt16
    public var passed: Bool
    public var measured: String
    public var expectation: String

    public init(id: String, code: UInt16, passed: Bool, measured: String, expectation: String) {
        self.id = id
        self.code = code
        self.passed = passed
        self.measured = measured
        self.expectation = expectation
    }
}

public enum AvailabilityStatus: String, Codable, Hashable, Sendable {
    case available, notDecodedYet, notFoundInPlainLogs, encryptedByModem, notOnIPhone
    /// Decodable, and deliberately not decoded: the GNSS position records (see `CapturePrivacy`).
    case excludedForPrivacy
}

/// One entry of the "not available on this iPhone" catalogue, so an empty chart is never a mystery.
public struct Availability: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var status: AvailabilityStatus
    public var codes: [UInt16]
    public var reason: String

    public init(id: String, title: String, status: AvailabilityStatus, codes: [UInt16], reason: String) {
        self.id = id
        self.title = title
        self.status = status
        self.codes = codes
        self.reason = reason
    }
}

public struct PhyCapture: Hashable, Codable, Sendable {
    public var series: [PhyMetric: PhySeries]
    public var summary: PhySummary
    public var checks: [PhyCheck]
    /// "0xB173 v48" -> records skipped because the version is not one the decoder validated.
    public var versionMisses: [String: Int]
    public var availability: [Availability]

    public init(series: [PhyMetric: PhySeries], summary: PhySummary, checks: [PhyCheck],
                versionMisses: [String: Int], availability: [Availability]) {
        self.series = series
        self.summary = summary
        self.checks = checks
        self.versionMisses = versionMisses
        self.availability = availability
    }

    public static let empty = PhyCapture(series: [:], summary: .empty, checks: [], versionMisses: [:], availability: [])
}
