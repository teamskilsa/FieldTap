// What each of the 48 series is: its unit and source record (as phy-golden.json lists them), the record version
// the decoder accepts, how far it can be trusted, and the short name the Radio page shows.

import FTModel

public struct PhyMetricInfo: Hashable, Sendable {
    public var title: String
    public var unit: String
    public var code: UInt16
    public var version: String
    public var confidence: PhyConfidence
}

/// The source tag of a CSI sample (`PhySample.tag`): which CSF record carried it.
public enum CsfSource {
    /// 0xB14E, PUSCH CSF (aperiodic).
    public static let pusch = 0xB14E
    /// 0xB14D, PUCCH CSF (periodic); medium-confidence bit positions.
    public static let pucch = 0xB14D
}

/// `PhySample.tag` of the cell-level measurement series (0xB193 and 0xB97F): serving cell or neighbour.
public enum CellRole {
    public static let neighbour = 0
    public static let serving = 1
}

extension PhySample {
    /// `carrier` of a neighbour measurement, which is on no serving carrier.
    public static let notServing = -1
}

extension PhyMetric {
    public var info: PhyMetricInfo {
        let (title, unit, code, confidence): (String, String, UInt16, PhyConfidence) = switch self {
        case .lte_tx_antennas_mib: ("eNB Tx antennas (MIB)", "count", 0xB0C1, .high)
        case .lte_dl_bandwidth_prb: ("DL bandwidth (MIB)", "PRB", 0xB0C1, .high)
        case .lte_band: ("Band", "band", 0xB0C2, .high)
        case .lte_rsrp: ("RSRP", "dBm", 0xB193, .high)
        case .lte_rsrp_filtered: ("RSRP (filtered)", "dBm", 0xB193, .high)
        case .lte_rsrq_filtered: ("RSRQ (filtered)", "dB", 0xB193, .high)
        case .lte_rssi: ("RSSI", "dBm", 0xB193, .high)
        case .lte_rx_antennas_measured: ("Rx antennas measured", "count", 0xB193, .high)
        case .lte_rsrp_per_rx: ("RSRP per Rx", "dBm", 0xB193, .high)
        case .lte_rsrq_per_rx: ("RSRQ per Rx", "dB", 0xB193, .high)
        case .lte_rssi_per_rx: ("RSSI per Rx", "dBm", 0xB193, .high)
        case .lte_neighbour_rsrp: ("Neighbour RSRP", "dBm", 0xB193, .high)
        case .lte_neighbour_rsrp_filtered: ("Neighbour RSRP (filtered)", "dBm", 0xB193, .high)
        case .lte_neighbour_rsrq_filtered: ("Neighbour RSRQ (filtered)", "dB", 0xB193, .high)
        case .lte_neighbour_rssi: ("Neighbour RSSI", "dBm", 0xB193, .high)
        case .lte_dl_mcs: ("DL MCS", "index", 0xB173, .high)
        case .lte_dl_prb: ("DL PRB", "PRB", 0xB173, .high)
        case .lte_dl_tbs: ("DL TBS", "bytes", 0xB173, .high)
        case .lte_dl_modulation: ("DL modulation", "Qm", 0xB173, .high)
        case .lte_dl_crc_ok: ("DL CRC pass", "bool", 0xB173, .high)
        case .lte_dl_layers: ("DL layers", "layers", 0xB173, .high)
        case .lte_dl_bler: ("DL BLER", "%", 0xB173, .high)
        case .lte_dl_phy_throughput: ("DL PHY throughput", "Mbit/s", 0xB173, .high)
        case .lte_ul_prb: ("UL PRB", "PRB", 0xB139, .high)
        case .lte_ul_tbs: ("UL TBS", "bytes", 0xB139, .high)
        case .lte_ul_modulation: ("UL modulation", "Qm", 0xB139, .high)
        case .lte_ul_code_rate: ("UL code rate", "ratio", 0xB139, .high)
        case .lte_pusch_tx_power_required: ("PUSCH power required", "dBm", 0xB139, .medium)
        case .lte_ul_mcs_derived: ("UL MCS", "index", 0xB139, .derived)
        case .lte_ul_phy_throughput: ("UL scheduled", "Mbit/s", 0xB139, .high)
        case .lte_cqi_wideband_cw0: ("Wideband CQI CW0", "CQI", 0xB14E, .medium)
        case .lte_ri: ("Rank indicator", "rank", 0xB14E, .medium)
        case .lte_pmi_wideband: ("Wideband PMI", "index", 0xB14E, .medium)
        case .lte_csf_tx_mode: ("Transmission mode (CSF)", "TM", 0xB14E, .high)
        case .lte_cqi_wideband_cw1: ("Wideband CQI CW1", "CQI", 0xB14E, .high)
        case .lte_mac_ul_grant: ("UL grant", "bytes", 0xB064, .high)
        case .lte_power_headroom: ("Power headroom", "dB", 0xB064, .high)
        case .lte_timing_advance_rar: ("Timing advance (RAR)", "TA (16 Ts units)", 0xB062, .high)
        case .nr_ss_rsrp: ("NR SS-RSRP", "dBm", 0xB97F, .high)
        case .nr_ss_rsrq: ("NR SS-RSRQ", "dB", 0xB97F, .high)
        case .nr_dl_mcs: ("NR DL MCS", "index (qam256 table)", 0xB887, .high)
        case .nr_dl_prb: ("NR DL PRB", "PRB", 0xB887, .high)
        case .nr_dl_layers: ("NR DL layers", "layers", 0xB887, .high)
        case .nr_dl_tbs: ("NR DL TBS", "bytes", 0xB887, .high)
        case .nr_dl_modulation: ("NR DL modulation", "Qm", 0xB887, .high)
        case .nr_dl_crc_ok: ("NR DL CRC pass", "bool", 0xB887, .high)
        case .nr_dl_bler: ("NR DL BLER", "%", 0xB888, .high)
        case .nr_dl_mac_throughput: ("NR MAC DL throughput", "Mbit/s", 0xB888, .high)
        }
        return PhyMetricInfo(title: title, unit: unit, code: code, version: PhyDispatch.version(of: code), confidence: confidence)
    }

    /// An empty series with this metric's metadata.
    var emptySeries: PhySeries {
        let i = info
        return PhySeries(metric: self, unit: i.unit, code: i.code, version: i.version, confidence: i.confidence, samples: [])
    }
}
