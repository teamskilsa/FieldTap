// What each of the 48 series is: its unit and source record (as phy-golden.json lists them), the Radio page
// section and title, how far it can be trusted, and the record versions the decoders accept (the strict version
// policy, CONTRACT.md: anything else is counted in versionMisses and shown as "not decodable", never guessed).

import type { PhyConfidence, PhyMetric, PhySection } from '../types.ts';

/** Code -> the version the decoder accepts, as PhySeries.version spells it. */
export const VALIDATED_VERSIONS: Readonly<Record<string, string>> = {
  '0xB0C1': '2',
  '0xB0C2': '3',
  '0xB193': '1/0x19 v66',
  '0xB173': '50',
  '0xB139': '162',
  '0xB14E': '164',
  '0xB14D': '164',
  '0xB064': '1/0x08 v7',
  '0xB062': '1/0x06 v50',
  '0xB97F': '3.0',
  '0xB887': '3.13',
  '0xB888': '3.1',
};

/** The codes the extractor decodes, in the reference extractor's order (which fixes the series' sample order). */
export const PHY_CODES: readonly number[] = [
  0xb0c1, 0xb0c2, 0xb193, 0xb173, 0xb139, 0xb14e, 0xb14d, 0xb064, 0xb062, 0xb97f, 0xb887, 0xb888,
];

export interface PhyMetricInfo {
  title: string;
  unit: string;
  code: string;
  section: PhySection;
  confidence: PhyConfidence;
  badges?: string[];
}

const info = (
  title: string,
  unit: string,
  code: string,
  section: PhySection,
  confidence: PhyConfidence = 'high',
  badges?: string[],
): PhyMetricInfo => (badges ? { title, unit, code, section, confidence, badges } : { title, unit, code, section, confidence });

/** 0xB14D's CQI/PMI/RI bit positions are re-derived, and its samples share these series with 0xB14E's. */
const CSI_MERGED = ['medium confidence'];

/** In PhyMetric order: the order PhyCapture.series follows. */
export const PHY_METRICS: Readonly<Record<PhyMetric, PhyMetricInfo>> = {
  lte_tx_antennas_mib: info('eNB Tx antennas (MIB)', 'count', '0xB0C1', 'antennas'),
  lte_dl_bandwidth_prb: info('DL bandwidth (MIB)', 'PRB', '0xB0C1', 'antennas'),
  lte_band: info('Band', 'band', '0xB0C2', 'signal'),
  lte_rsrp: info('RSRP', 'dBm', '0xB193', 'signal'),
  lte_rsrp_filtered: info('RSRP (filtered)', 'dBm', '0xB193', 'signal'),
  lte_rsrq_filtered: info('RSRQ (filtered)', 'dB', '0xB193', 'signal'),
  lte_rssi: info('RSSI', 'dBm', '0xB193', 'signal'),
  lte_rx_antennas_measured: info('Rx antennas measured', 'count', '0xB193', 'antennas'),
  lte_rsrp_per_rx: info('RSRP per Rx antenna', 'dBm', '0xB193', 'signal'),
  lte_rsrq_per_rx: info('RSRQ per Rx antenna', 'dB', '0xB193', 'signal'),
  lte_rssi_per_rx: info('RSSI per Rx antenna', 'dBm', '0xB193', 'signal'),
  lte_neighbour_rsrp: info('Neighbour RSRP', 'dBm', '0xB193', 'signal'),
  lte_neighbour_rsrp_filtered: info('Neighbour RSRP (filtered)', 'dBm', '0xB193', 'signal'),
  lte_neighbour_rsrq_filtered: info('Neighbour RSRQ (filtered)', 'dB', '0xB193', 'signal'),
  lte_neighbour_rssi: info('Neighbour RSSI', 'dBm', '0xB193', 'signal'),
  lte_dl_mcs: info('DL MCS', 'index', '0xB173', 'downlink'),
  lte_dl_prb: info('DL PRB', 'PRB', '0xB173', 'downlink'),
  lte_dl_tbs: info('DL TBS', 'bytes', '0xB173', 'downlink'),
  lte_dl_modulation: info('DL modulation', 'Qm', '0xB173', 'downlink'),
  lte_dl_crc_ok: info('DL CRC pass', 'bool', '0xB173', 'downlink'),
  lte_dl_layers: info('DL layers', 'layers', '0xB173', 'downlink'),
  lte_dl_bler: info('DL BLER per 1 s', '%', '0xB173', 'downlink'),
  lte_dl_phy_throughput: info('DL PHY throughput per 1 s', 'Mbit/s', '0xB173', 'downlink'),
  lte_ul_prb: info('UL PRB', 'PRB', '0xB139', 'uplink'),
  lte_ul_tbs: info('UL TBS', 'bytes', '0xB139', 'uplink'),
  lte_ul_modulation: info('UL modulation', 'Qm', '0xB139', 'uplink'),
  lte_ul_code_rate: info('UL code rate', 'ratio', '0xB139', 'uplink'),
  lte_pusch_tx_power_required: info('PUSCH power required', 'dBm', '0xB139', 'uplink', 'medium', ['before Pcmax', 'medium confidence']),
  lte_ul_mcs_derived: info('UL MCS', 'index', '0xB139', 'uplink', 'derived', ['derived']),
  // Scheduled PUSCH TBS per second, retransmissions included: what the network granted, not goodput.
  lte_ul_phy_throughput: info('UL scheduled per 1 s', 'Mbit/s', '0xB139', 'uplink', 'high', ['UL scheduled']),
  lte_cqi_wideband_cw0: info('Wideband CQI CW0', 'CQI', '0xB14E', 'csi', 'medium', CSI_MERGED),
  lte_ri: info('Rank indicator', 'rank', '0xB14E', 'csi', 'medium', CSI_MERGED),
  lte_pmi_wideband: info('Wideband PMI', 'index', '0xB14E', 'csi', 'medium', CSI_MERGED),
  lte_csf_tx_mode: info('Transmission mode (CSF)', 'TM', '0xB14E', 'csi'),
  lte_cqi_wideband_cw1: info('Wideband CQI CW1', 'CQI', '0xB14E', 'csi'),
  lte_mac_ul_grant: info('UL grant', 'bytes', '0xB064', 'uplink'),
  lte_power_headroom: info('Power headroom', 'dB', '0xB064', 'uplink'),
  lte_timing_advance_rar: info('Timing advance (RAR)', 'TA (16 Ts units)', '0xB062', 'rach'),
  nr_ss_rsrp: info('NR SS-RSRP', 'dBm', '0xB97F', 'nr'),
  nr_ss_rsrq: info('NR SS-RSRQ', 'dB', '0xB97F', 'nr'),
  nr_dl_mcs: info('NR DL MCS', 'index (qam256 table)', '0xB887', 'nr'),
  nr_dl_prb: info('NR DL PRB', 'PRB', '0xB887', 'nr'),
  nr_dl_layers: info('NR DL layers', 'layers', '0xB887', 'nr'),
  nr_dl_tbs: info('NR DL TBS', 'bytes', '0xB887', 'nr'),
  nr_dl_modulation: info('NR DL modulation', 'Qm', '0xB887', 'nr'),
  nr_dl_crc_ok: info('NR DL CRC pass', 'bool', '0xB887', 'nr'),
  nr_dl_bler: info('NR DL BLER', '%', '0xB888', 'nr'),
  nr_dl_mac_throughput: info('NR MAC DL throughput', 'Mbit/s', '0xB888', 'nr', 'high', ['MAC']),
};

export const PHY_METRIC_ORDER = Object.keys(PHY_METRICS) as PhyMetric[];

/** PhySample.tag values the extractor writes. */
export const TAG = {
  neighbour: 'neighbour',
  serving: 'serving',
  /** 0xB14E, PUSCH CSF (aperiodic). */
  puschCsf: 'PUSCH CSF',
  /** 0xB14D, PUCCH CSF (periodic): medium-confidence bit positions. */
  pucchCsf: 'PUCCH CSF',
  /** 4 layers with one transport block: transmit diversity, one layer of data. */
  txDiversity: 'TxD',
  /** 3 layers: seen in 2 records of the first capture, while RI never exceeded 2. */
  unverified: 'unverified',
} as const;
