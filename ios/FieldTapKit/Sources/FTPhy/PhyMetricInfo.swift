// What each series is: its unit and source record (as phy-golden.json lists them for the first 48), the record
// version the decoder accepts, how far it can be trusted, and the short name the Radio page shows.

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

    /// The 0xB126 PRB allocation bitmap, carried in `perIndex` as 32-bit words, low word first (a bitmap does not
    /// fit a Double exactly above 53 bits, and an LTE cell has up to 100 PRB).
    public static func prbWords(_ mask: UInt64) -> [Double?] {
        [Double(mask & 0xFFFF_FFFF), Double((mask >> 32) & 0xFFFF_FFFF)]
    }

    /// That bitmap back, or nil for a sample that carries no allocation.
    public var prbMask: UInt64? {
        guard let p = perIndex, p.count >= 2, let low = p[0], let high = p[1] else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }
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
        case .lte_tx_antenna_ports: ("Cell Tx antenna ports (measured)", "count", 0xB126, .high)
        case .lte_rx_antennas_used: ("Rx antennas in use", "count", 0xB126, .medium)
        case .lte_dl_rank: ("DL rank per subframe", "layers", 0xB126, .high)
        case .lte_dl_prb_allocation: ("PRB allocation", "PRB (bitmap)", 0xB126, .high)
        case .lte_cfi: ("Control region (CFI)", "symbols", 0xB12A, .high)
        case .lte_ul_grant_start_rb: ("UL grant start RB", "PRB index", 0xB16C, .high)
        case .lte_ul_grant_prb: ("UL granted PRB", "PRB", 0xB16C, .high)
        case .lte_ul_grant_modulation: ("UL granted modulation", "Qm", 0xB16C, .high)
        case .lte_dl_assignments: ("DL assignments per subframe", "count", 0xB16C, .high)
        case .lte_intra_serving_rsrp: ("Serving RSRP (intra-freq)", "dBm", 0xB179, .high)
        case .lte_intra_serving_rsrq: ("Serving RSRQ (intra-freq)", "dB", 0xB179, .high)
        case .lte_intra_neighbour_rsrp: ("Neighbour RSRP (intra-freq)", "dBm", 0xB179, .high)
        case .lte_intra_neighbour_rsrq: ("Neighbour RSRQ (intra-freq)", "dB", 0xB179, .high)
        case .lte_intra_neighbour_margin: ("Neighbour margin", "dB", 0xB179, .derived)
        case .lte_mac_dl_bytes: ("MAC DL transport block", "bytes", 0xB063, .high)
        case .lte_mac_dl_padding: ("MAC DL padding", "bytes", 0xB063, .medium)
        case .lte_mac_dl_signalling_bytes: ("MAC DL signalling", "bytes", 0xB063, .high)
        case .lte_mac_dl_data_bytes: ("MAC DL user data", "bytes", 0xB063, .high)
        case .lte_tx_power_chain: ("Front-end Tx power per chain", "dBm", 0x184C, .medium)
        case .lte_tx_power_limit: ("Front-end Tx limit per chain", "dBm", 0x184C, .medium)
        case .lte_tx_power_headroom: ("Front-end Tx headroom", "dB", 0x184C, .derived)
        case .lte_tx_pa_state: ("Amplifier gain state", "state", 0x184C, .medium)
        }
        return PhyMetricInfo(title: title, unit: unit, code: code, version: PhyDispatch.version(of: code), confidence: confidence)
    }

    /// An empty series with this metric's metadata.
    var emptySeries: PhySeries {
        let i = info
        return PhySeries(metric: self, unit: i.unit, code: i.code, version: i.version, confidence: i.confidence, samples: [])
    }
}
