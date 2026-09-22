// SEED from WP0; owned by WP4-phy. The PHY/MAC value types FTPhy produces and the Radio page, FTJourney
// and the capture summary read. Shapes follow ios/Fixtures/local/contract/phy-golden.json and phy-summary.json.

/// The 48 series the validated reference extractor (phy-inventory kpis.py) produces for this modem. Raw values
/// are exactly the keys of phy-golden.json.
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

/// What FTJourney needs from the PHY layer; decodes contract/phy-summary.json as is.
public struct PhySummary: Hashable, Codable, Sendable {
    public var scellActivity: [CarrierActivity]
    public var nrDlActivity: CarrierActivity?
    public var rach: [RachEvent]
    public var txAntennasMib: [Int]
    /// EARFCN -> number of Rx antennas measured -> records.
    public var rxAntennasByEarfcn: [String: [String: Int]]
    public var encrypted: EncryptedCensus

    public init(scellActivity: [CarrierActivity], nrDlActivity: CarrierActivity?, rach: [RachEvent],
                txAntennasMib: [Int], rxAntennasByEarfcn: [String: [String: Int]], encrypted: EncryptedCensus) {
        self.scellActivity = scellActivity
        self.nrDlActivity = nrDlActivity
        self.rach = rach
        self.txAntennasMib = txAntennasMib
        self.rxAntennasByEarfcn = rxAntennasByEarfcn
        self.encrypted = encrypted
    }

    public static let empty = PhySummary(scellActivity: [], nrDlActivity: nil, rach: [], txAntennasMib: [],
                                         rxAntennasByEarfcn: [:], encrypted: .empty)

    /// True when no PHY decoder contributed anything (the seed, or a capture without PHY records).
    public var isEmpty: Bool {
        scellActivity.isEmpty && nrDlActivity == nil && rach.isEmpty && txAntennasMib.isEmpty && rxAntennasByEarfcn.isEmpty
    }
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
