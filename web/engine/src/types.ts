// The CaptureAnalysis contract between the FieldTap web engine and the Log Analyzer UI.
//
// This file is the canonical copy. The Lovable project's src/lib/analysis/types.ts must be byte-identical, and
// the UI depends on nothing else from the engine except `analyzeFile`. README.md ("Contract changes") lists every
// difference from the first UI types, so the UI can be updated in one pass.
//
// Everything here is plain data: structured-cloneable across the worker boundary and JSON-serialisable (no
// bigint, no Date, no Map). Times are ms since the capture's time base (rule D1: the first plausible modem
// timestamp) unless a name says UTC; UTC instants are ISO-8601 strings.
//
// Identifiers: the engine delivers real values, and for every string that masking would change it also delivers
// the masked form (`masked`, `summaryMasked`, ...), produced by the golden masking rules (ios/Contract/CONTRACT.md
// "Masking"). While identifiers are hidden the UI shows the masked form, and hides the hex dump, TAC and cell
// identity entirely.

/** Bumped on any breaking change to this file. */
export const CONTRACT_VERSION = 'fieldtap-web/1';

// ----------------------------------------------------------------------------------------------------- import

export type ImportStage = 'reading' | 'extracting' | 'deframing' | 'decoding' | 'radio' | 'done';

export interface ImportProgress {
  stage: ImportStage;
  /** 0..1 within the stage. */
  fraction: number;
  detail: string;
}

export type ImportProblemKind =
  /** Not a gzip or tar file, or a tar without a sysdiagnose's logs/ tree. */
  | 'notASysdiagnose'
  /** The file ends part way through (a copy cut short). */
  | 'truncatedArchive'
  /** No logs/Baseband/log-bb-*-qdss directory and no Baseband profile stub: modem logging was off. */
  | 'noBasebandTrace'
  /** logs/Baseband/ambtool_output.log says "Baseband logs are not enabled". */
  | 'loggingNotEnabled'
  /** A trace exists but the archive holds no com.apple.basebandlogging profile stub. */
  | 'profileMissing'
  /** The profile's removal date had passed when the sysdiagnose was taken (`date` = removal). */
  | 'profileExpired'
  /** Active when the sysdiagnose was taken, but iOS removed it within 1 day of it (`date` = removal). */
  | 'profileExpiresSoon'
  /** The profile was installed after the modem's trace began, so the trace predates it. */
  | 'profileInstalledAfterTrace'
  /** The profile was active but the archive has no modem trace: restart the iPhone and try again. */
  | 'profileInstalledNoTrace'
  /** A trace this engine cannot read (`detail` says why, e.g. no info.txt, an unknown record layout). */
  | 'unsupportedTrace'
  /** Trace files are missing inside the kept window (`detail` = how many); messages around them may be cut. */
  | 'traceGaps';

export interface ImportProblem {
  kind: ImportProblemKind;
  /** One plain sentence for the problem card. */
  message: string;
  /** True when the problem leaves no trace to analyse. */
  blocking: boolean;
  /** ISO UTC, for the dated kinds. */
  date?: string | undefined;
  detail?: string | undefined;
}

// ---------------------------------------------------------------------------------------------- profile/guide

/** Apple's Baseband logging profile at the moment the sysdiagnose was taken (`observedAt`). */
export type ProfileStatus = 'active' | 'expiringSoon' | 'expired' | 'missing' | 'unknown';

export interface ProfileState {
  status: ProfileStatus;
  /** 'com.apple.basebandlogging'. */
  identifier?: string | undefined;
  /** 'Baseband and Telephony Logging'. */
  displayName?: string | undefined;
  installDate?: string | undefined;
  removalDate?: string | undefined;
  /** removal - install; 7.0 for today's profile (21 for 2025 copies), so never assume it. */
  lifetimeDays?: number | undefined;
  /** The button press the status was judged at. */
  observedAt?: string | undefined;
}

/**
 * What the Modem logging guide should say, judged at `evaluatedAt` (when the file was analysed). Differs from
 * ProfileState.status, which is judged at the button press: a capture can be fine while its profile has since
 * expired.
 */
export type GuideStatus = 'off' | 'expired' | 'expiringSoon' | 'active' | 'installedNoTrace' | 'unknown';

export interface GuideState {
  status: GuideStatus;
  /** The profile's removal date, for expired / expiringSoon / active. */
  removalDate?: string | undefined;
  /** Whole days left before iOS removes the profile, never negative. */
  daysLeft?: number | undefined;
  /** True when the guide should open by itself: off, expired, expiringSoon or installedNoTrace. */
  needsAttention: boolean;
  evaluatedAt: string;
}

// ------------------------------------------------------------------------------------------------ trace facts

/**
 * The part of the modem's trace ring the archive kept, relative to the button press. The modem lists every file
 * it wrote in info.txt; the archive keeps only the newest (about 128 MiB), so the window is often not the
 * seconds before the press (e.g. from 20 s to 45 s after the press).
 */
export interface TraceWindow {
  /** The first kept file's info.txt 'Starting From' (whole seconds, the phone's local time), as UTC. Both times
   *  end in 'Z'; only when the press time (and so the phone's UTC offset) is unknown are they local wall times
   *  without an offset. */
  startUtc: string;
  /** The dump: the trace directory's time (ms), or the last kept file's 'Starting From' when later. */
  endUtc: string;
  /** Seconds from the press to startUtc / endUtc; null when the press time is unknown. Press time is whole
   *  seconds (the archive name), so these are good to about 1 s. */
  afterPressStartS: number | null;
  afterPressEndS: number | null;
  /** Trace files in the archive. */
  filesKept: number;
  /** Trace files info.txt lists: every file the modem wrote since the trace began. */
  filesOnPhone: number;
  /** Listed files older than the first kept one: the ring reused their space. */
  filesOverwritten: number;
  /** Listed files newer than the first kept one that the archive does not hold (dropped by the collection).
   *  filesKept + filesOverwritten + filesMissing = filesOnPhone. */
  filesMissing: number;
}

/** How many records the modem wrote encrypted (QDSS "secure" packets): counted, never decoded. */
export interface EncryptedCensus {
  records: number;
  codes: number;
  /** Records per log code ('0xB8DD' -> 100), when kept. */
  byCode?: Record<string, number> | undefined;
}

/**
 * The QDSS deframer's counters, with exactly the keys (snake_case) of the reference qdss_deframe.py stats.json,
 * so they compare with it directly. Parity compares atid32_bytes, chunks, stats, fits, fragment_kinds, packets,
 * log_records, distinct_codes and ts; the rest are diagnostics.
 */
export interface DeframeStats {
  atid32_bytes: number;
  chunks: number;
  /** 'phase' plus the parser counters (u_cont, messages, gather_flushed_unterminated, ...). */
  stats: Record<string, number>;
  fits: Record<string, number>;
  fragment_kinds: Record<string, number>;
  packets: Record<string, number>;
  log_records: number;
  distinct_codes: number;
  ts: Record<string, number>;
  incomplete_records: number;
  targets: Record<string, number>;
  /** [['0x1375', 1000], ...], most common first. */
  top_codes: [string, number][];
}

// -------------------------------------------------------------------------------------------------- call flow

/** A cell as the RRC header names it: EARFCN for LTE, NR-ARFCN for NR. An NR header logged before the SCG cell
 *  is assigned carries pci 0xFFFF or earfcn 0xFFFFFFFF (rule D4): show 'NR cell pending', never a PCI. */
export interface Cell {
  earfcn: number;
  pci: number;
  nr: boolean;
}

export interface Field {
  label: string;
  value: string;
  children: Field[];
  /** The value while identifiers are hidden; absent when masking leaves it unchanged. */
  masked?: string | undefined;
}

export type Layer = 'RRC' | 'NAS';
export type Rat = 'LTE' | 'NR';

/** How a NAS message went over the air, from its security-protected copy. */
export interface Protection {
  headerType: number;
  /** 'integrity protected and ciphered', ... */
  headerName: string;
  sequence: number;
  mac: number;
}

export interface Event {
  index: number;
  /** 1-based position of the log record in the rebuilt log, counting every record. */
  record?: number | undefined;
  /** '0xB0C0'. */
  logCode?: string | undefined;
  sinceStartMs: number;
  /** Unix ms, when the modem had network time. */
  utcMs?: number | undefined;
  layer: Layer;
  rat: Rat;
  uplink: boolean;
  /** Logical channel for RRC ('UL-DCCH', 'BCCH-DL-SCH'); the sublayer for NAS ('EMM', '5GMM'). */
  channel: string;
  /** Matching name: ASN.1 for RRC, 3GPP for NAS. */
  key: string;
  /** Reading name: 'RRC Connection Setup'. */
  name: string;
  summary?: string | undefined;
  summaryMasked?: string | undefined;
  cell?: Cell | undefined;
  fields: Field[];
  cause?: number | undefined;
  causeName?: string | undefined;
  protection?: Protection | undefined;
  /** The type could not be read: ciphered, and no plain copy was logged. */
  ciphered: boolean;
  isFailure: boolean;
  isHandoverCommand: boolean;
  /** For NAS pulled out of an RRC message: 'carried in UL-DCCH ULInformationTransfer'. */
  carrier?: string | undefined;
  pduLength?: number | undefined;
  /** Lower-case hex of the PDU. Holds identifiers: hidden while they are masked. */
  pduHex?: string | undefined;
}

export type Outcome = 'SUCCEEDED' | 'FAILED' | 'UNANSWERED';

/** A request and what answered it; `first` and `last` index `events`. */
export interface Procedure {
  name: string;
  layer: Layer;
  detail?: string | undefined;
  detailMasked?: string | undefined;
  first: number;
  last: number;
  outcome: Outcome;
  durationMs: number;
  /** The reject's cause, when the answer was a refusal. */
  refusal?: string | undefined;
  refusalMasked?: string | undefined;
}

export type Move = 'FIRST_SEEN' | 'HANDOVER' | 'RESELECTION' | 'REDIRECT' | 'REESTABLISHMENT' | 'CELL_CHANGE';

/** The phone arrived on `to`; `event` is the first message logged there. */
export interface Step {
  move: Move;
  from?: Cell | undefined;
  to: Cell;
  event: number;
  sinceStartMs: number;
  /** The journey's reading of the move, shown as a subtitle on the ladder's Move row
   *  ('Reselection, after switch-off detach'). */
  annotation?: string | undefined;
}

export type ConnectionOutcome = 'RELEASED' | 'OPEN_AT_END' | 'LOST' | 'REJECTED' | 'NO_ANSWER';

export interface Connection {
  first: number;
  last?: number | undefined;
  establishmentCause?: string | undefined;
  releaseCause?: string | undefined;
  outcome: ConnectionOutcome;
  /** RELEASED, OPEN_AT_END or LOST. */
  established?: boolean | undefined;
  startMs: number;
  endMs?: number | undefined;
}

/** What the modem's serving-cell record (0xB0C2) said about a cell. TAC and cellIdentity locate the phone with
 *  the PLMN: hidden while identifiers are masked. */
export interface CellDetail {
  cell: Cell;
  pci: number;
  downlinkEarfcn: number;
  uplinkEarfcn: number;
  band: number;
  plmn: string;
  tac: number;
  cellIdentity?: number | undefined;
  bandwidthMhz?: number | undefined;
}

// ------------------------------------------------------------------------------------ call-flow presentation

/**
 * The ladder exactly as the Android app lays it out (CallFlowPresentation): repeated broadcast rows folded,
 * procedure banners, move rows, and the formatted strings ('0:00.500', '44.0 ms') with Java's rounding.
 */
export type FlowFilter = 'ALL' | 'RRC' | 'NAS';

export type LadderRow =
  | {
    type: 'message';
    key: string;
    /** Index into `events`; `repeats` are the folded ones. */
    event: number;
    repeats: number[];
    name: string;
    count: number;
    /** The folded rows differ in message or cell. */
    mixed: boolean;
    /** 'B2 PCI 11', 'NR cell pending'. */
    cells: string;
    cellCount: number;
    since: string;
    gap?: string | undefined;
  }
  | {
    type: 'procedure';
    key: string;
    /** Index into `procedures`. */
    procedure: number;
    name: string;
    outcome: Outcome;
    duration: string;
  }
  | {
    type: 'move';
    key: string;
    /** Index into `steps`. */
    step: number;
    move: Move;
    to: string;
    band?: string | undefined;
    downlink?: string | undefined;
  };

export interface ProcedureGroup {
  name: string;
  layer: Layer;
  n: number;
  succeeded: number;
  failed: number;
  unanswered: number;
  median?: string | undefined;
  /** Indexes into `procedures`. */
  procedures: number[];
}

export interface Ladder {
  rows: Record<FlowFilter, LadderRow[]>;
  /** 'UE' | 'eNB'/'gNB'/'RAN' | 'MME'/'AMF'/'Core'. */
  lanes: { phone: string; ran: string; core: string };
  procedureGroups: ProcedureGroup[];
}

// ---------------------------------------------------------------------------------------------------- journey

export type JourneyStateName = 'unknown' | 'connected' | 'idle' | 'radioOff';

export interface JourneyState {
  state: JourneyStateName;
  startMs: number;
  endMs: number;
  openAtEnd?: boolean | undefined;
  /** Why the segment is there ('connection 0 RELEASED'). */
  source?: string | undefined;
}

export type RegistrationState = 'registered' | 'deregistered' | 'unknown';

/** J5: the 'not registered' overlay on the state lane. */
export interface RegistrationSegment {
  state: RegistrationState;
  startMs: number;
  endMs: number;
  /** Registered only by inference: the first NAS procedure was one a registered phone runs. */
  assumed: boolean;
}

export type LaneKind = 'pcell' | 'pscell' | 'scell';

/** Where a segment came from: the decoded RRC, the PHY records, or an inference with no direct evidence. */
export type EvidenceSource = 'rrc' | 'phy' | 'inferred';

export interface JourneyCell {
  lane: LaneKind;
  /** Position within its lane (the SCell index for SCells). */
  index: number;
  cell: Cell;
  /** 'B66', or the NR candidates 'n5/n26'. */
  band: string;
  /** NR bands the ARFCN falls in ([5, 26]); empty for LTE. */
  bandCandidates?: number[] | undefined;
  dlMhz?: number | undefined;
  startMs: number;
  endMs: number;
  /** PSCell: when the NR cell completed its addition (J8). */
  addedMs?: number | undefined;
  openAtEnd?: boolean | undefined;
  /** The end was inferred (e.g. SCG release at an LTE handover command), not logged: draw it dashed. */
  endInferred: boolean;
  startReason?: string | undefined;
  endReason?: string | undefined;
  source?: EvidenceSource | undefined;
  /** The last PHY record for this cell, to cross-check an inferred end. */
  phyLastMs?: number | undefined;
}

export type MarkerKind =
  | 'handover'
  | 'reselection'
  | 'reattach'
  | 'redirect'
  | 'reestablishment'
  | 'cellChange'
  | 'scgAdd'
  | 'scgModify'
  | 'scgRelease'
  | 'attach'
  | 'detachSwitchOff'
  | 'rrcSetup'
  | 'rrcRelease'
  | 'rach'
  | 'failure'
  | 'warning';

export type Severity = 'info' | 'warning' | 'failure';

/** Unique within a journey: kind plus event, or plus time for PHY-derived markers ('handover-40', 'rach-4205.0'). */
export interface Marker {
  id: string;
  kind: MarkerKind;
  tMs: number;
  event?: number | undefined;
  endEvent?: number | undefined;
  severity: Severity;
  title: string;
  detail?: string | undefined;
  /** Handover: when the phone arrived on the target. */
  arrivalMs?: number | undefined;
  from?: Cell | undefined;
  to?: Cell | undefined;
  durationMs?: number | undefined;
  /** RACH: timing advance and the distance it implies (TA x 78.12 m). */
  ta?: number | undefined;
  distanceM?: number | undefined;
  inferred?: boolean | undefined;
}

export type FindingKind =
  | 'radioOffOn'
  | 'switchedOffAtEnd'
  | 'reattach'
  | 'attach'
  | 'imsPdn'
  | 'endcAdded'
  | 'scgPhyOutlived'
  | 'handover'
  | 'carrierAggregation'
  | 'failure'
  | 'warning'
  | 'failures'
  | 'noFailures'
  | 'encryptedRecords'
  | 'traceWindow'
  | 'other';

/** One sentence of 'What happened'. `id` is unique ('handover-40'); `kind` carries the category. */
export interface Finding {
  id: string;
  kind: FindingKind;
  severity: Severity;
  text: string;
  tMs?: number | undefined;
  event?: number | undefined;
}

export type TileGroup = 'Accessibility' | 'Mobility' | 'EN-DC' | 'Retainability' | 'Integrity';

/** 'Handover 2/2, median 44.0 ms'. Ids: rrcSetup, attach, registration, serviceRequest, pdn, handover, scgAdd,
 *  abnormalReleases, lteDlPeak, nrDlPeak. */
export interface Tile {
  id: string;
  group: TileGroup;
  title: string;
  succeeded: number;
  attempts: number;
  value?: string | undefined;
  event?: number | undefined;
}

export interface Journey {
  durationMs: number;
  states: JourneyState[];
  registration: RegistrationSegment[];
  cells: JourneyCell[];
  /** Sorted stably by tMs, then kind. */
  markers: Marker[];
  /** By time, then the fixed tail: failures or noFailures, encryptedRecords, traceWindow. */
  findings: Finding[];
  tiles: Tile[];
}

// -------------------------------------------------------------------------------------------------------- PHY

/** The 48 series the validated reference extractor produces for this modem (phy-golden.json keys). */
export type PhyMetric =
  | 'lte_tx_antennas_mib'
  | 'lte_dl_bandwidth_prb'
  | 'lte_band'
  | 'lte_rsrp'
  | 'lte_rsrp_filtered'
  | 'lte_rsrq_filtered'
  | 'lte_rssi'
  | 'lte_rx_antennas_measured'
  | 'lte_rsrp_per_rx'
  | 'lte_rsrq_per_rx'
  | 'lte_rssi_per_rx'
  | 'lte_neighbour_rsrp'
  | 'lte_neighbour_rsrp_filtered'
  | 'lte_neighbour_rsrq_filtered'
  | 'lte_neighbour_rssi'
  | 'lte_dl_mcs'
  | 'lte_dl_prb'
  | 'lte_dl_tbs'
  | 'lte_dl_modulation'
  | 'lte_dl_crc_ok'
  | 'lte_dl_layers'
  | 'lte_dl_bler'
  | 'lte_dl_phy_throughput'
  | 'lte_ul_prb'
  | 'lte_ul_tbs'
  | 'lte_ul_modulation'
  | 'lte_ul_code_rate'
  | 'lte_pusch_tx_power_required'
  | 'lte_ul_mcs_derived'
  | 'lte_ul_phy_throughput'
  | 'lte_cqi_wideband_cw0'
  | 'lte_ri'
  | 'lte_pmi_wideband'
  | 'lte_csf_tx_mode'
  | 'lte_cqi_wideband_cw1'
  | 'lte_mac_ul_grant'
  | 'lte_power_headroom'
  | 'lte_timing_advance_rar'
  | 'nr_ss_rsrp'
  | 'nr_ss_rsrq'
  | 'nr_dl_mcs'
  | 'nr_dl_prb'
  | 'nr_dl_layers'
  | 'nr_dl_tbs'
  | 'nr_dl_modulation'
  | 'nr_dl_crc_ok'
  | 'nr_dl_bler'
  | 'nr_dl_mac_throughput'
  // Added with the 0xB126, 0xB12A, 0xB16C, 0xB179, 0xB063 and 0x184C decoders (see PHY_METRICS for each one's
  // record, unit and confidence).
  | 'lte_pdsch_tx_antennas'
  | 'lte_pdsch_rx_antennas'
  | 'lte_dl_rank'
  | 'lte_dl_prb_allocation'
  | 'lte_pdcch_cfi'
  | 'lte_dl_assignments'
  | 'lte_ul_grant_prb'
  | 'lte_ul_grant_start_rb'
  | 'lte_neighbour_rsrp_intra'
  | 'lte_neighbour_rsrq_intra'
  | 'lte_neighbour_margin'
  | 'lte_fed_tx_power'
  | 'lte_fed_tx_limit'
  | 'lte_pa_gain_state'
  | 'lte_mac_dl_bytes'
  | 'lte_mac_dl_padding';

export type PhySection = 'signal' | 'downlink' | 'uplink' | 'csi' | 'nr' | 'antennas' | 'rach';

/** high = read directly and validated; medium = a layout with some uncertainty (0xB14D bit positions);
 *  derived = computed from other fields (UL MCS from the TBS table). */
export type PhyConfidence = 'high' | 'medium' | 'derived';

export interface PhySample {
  tMs: number;
  value: number | null;
  /** Per-antenna series: one entry per Rx antenna, null where not measured. */
  perIndex?: (number | null)[] | undefined;
  /** Carrier index as the record gives it: 0 = PCell, 1.. = SCells. */
  carrier?: number | undefined;
  /** Set only when the record itself names the cell. */
  earfcn?: number | undefined;
  pci?: number | undefined;
  /** The cell the carrier index maps to through the Journey at tMs (carrier attribution). */
  cell?: Cell | undefined;
  /** 'CW1', '256QAM', 'retx', a neighbour PCI... */
  tag?: string | undefined;
  /** A bitmap the record carries, low word first: bit k of word w is item 32w + k (0xB126's PRB allocation). */
  mask?: number[] | undefined;
}

export interface PhySeries {
  metric: PhyMetric;
  title: string;
  unit: string;
  section: PhySection;
  confidence: PhyConfidence;
  /** '0xB173'. */
  code?: string | undefined;
  /** The record version the decoder accepted: '50', '3.13'. */
  version?: string | undefined;
  /** 'derived', 'medium confidence', 'before Pcmax', 'UL scheduled'. */
  badges?: string[] | undefined;
  samples: PhySample[];
}

/** When a carrier was active according to the PHY records. earfcn/pci are absent when the record carries only
 *  a carrier index (NR DL): the Journey attributes those. */
export interface CarrierActivity {
  index: number;
  earfcn?: number | undefined;
  pci?: number | undefined;
  firstMs: number;
  lastMs: number;
  records: number;
  source: string;
}

/** One random-access response (0xB062). */
export interface RachEvent {
  tMs: number;
  ta: number;
  distanceM?: number | undefined;
  ulEarfcn?: number | undefined;
  preambleTargetDbm?: number | undefined;
}

/**
 * The antenna configuration measured per serving cell from the PDSCH demapper configuration (0xB126), as opposed
 * to inferred from the MIB broadcast: `txPorts` is the cell's transmit antenna ports and `rxAntennas` the antennas
 * the phone had in use. The record does not name its cell, so the serving cell of the moment is attributed from
 * the 0xB193 serving records; `mibTxAntennas` is the broadcast's own figure for the same cell, where it was seen.
 */
export interface AntennaConfig {
  earfcn: number;
  pci: number;
  txPorts: number;
  rxAntennas: number;
  /** Subframes this configuration was measured in. */
  subframes: number;
  mibTxAntennas?: number | undefined;
  /** The MIMO rank measured on this cell: rank -> subframes. */
  rankHistogram: Record<string, number>;
  source: string;
}

/**
 * One intra-frequency neighbour cell measured by 0xB179, over the whole capture. The handover margin is the
 * neighbour's RSRP less the serving cell's in the *same record*, so a positive margin means the neighbour was the
 * stronger cell at that instant: that is the answer to "why did it not hand over".
 */
export interface NeighbourCell {
  earfcn: number;
  pci: number;
  measurements: number;
  rsrpBestDbm: number;
  rsrpMedianDbm: number;
  rsrqMedianDb: number;
  /** The best (largest) and the median margin against the serving cell, in dB. */
  marginBestDb: number;
  marginMedianDb: number;
  firstMs: number;
  lastMs: number;
  /** True when this PCI is measured by no other record in the capture (0xB193 never reports it). */
  onlySource: boolean;
}

/** One LCID's share of the downlink MAC bytes 0xB063 accounts for (TS 36.321 table 6.2.1-1). */
export interface MacDlChannel {
  lcid: number;
  /** 'signalling' (LCID 1-2), 'data' (3-10), 'control' (a MAC control element), 'broadcast' (LCID 0), or 'other'
   *  for an LCID that is not a 3GPP downlink channel (the walk's own uncertainty; never counted as user data). */
  kind: 'signalling' | 'data' | 'control' | 'broadcast' | 'other';
  name: string;
  bytes: number;
  sdus: number;
}

/**
 * MAC-level downlink accounting from 0xB063. It is never the total: the walk over the PDCP tails reaches only
 * `coverageShare` of the transport blocks the records declare, so `bytes` is a floor and 0xB173 remains the
 * throughput source.
 */
export interface MacDlAccounting {
  records: number;
  declaredBlocks: number;
  walkedBlocks: number;
  /** walkedBlocks / declaredBlocks: the explicit coverage figure this view must be read with. */
  coverageShare: number;
  /** Records whose walk ended exactly on the last byte of the body. */
  exactWalks: number;
  bytes: number;
  paddingBytes: number;
  paddingShare: number;
  channels: MacDlChannel[];
  /** Timing-advance commands seen (LCID 29). Their 6-bit value is not in the record. */
  timingAdvanceCommands: number;
}

/** One transmit chain of the front end (0x184C), over the whole capture. */
export interface TxChain {
  /** The record's own chain tag, as hex ('0x10'). */
  chain: string;
  samples: number;
  /** Samples where the chain was transmitting (not the -70.0 dBm off sentinel). */
  liveSamples: number;
  maxPowerDbm: number;
  medianPowerDbm: number;
  /** The chain's own binding power limit in dBm, where it was logged. */
  limitDbm?: number | undefined;
  /** Live samples within 0.5 dB of the limit. */
  atLimitSamples: number;
  /** Distinct PA gain states seen. */
  gainStates: number[];
}

/** Whether the phone was transmit-limited, and on which chain, from the front-end Tx AGC records (0x184C). */
export interface FrontEndUplink {
  records: number;
  /** Records whose block walk consumed the body exactly. */
  framedRecords: number;
  liveSamples: number;
  atLimitSamples: number;
  /** atLimitSamples / liveSamples: the share of transmitting samples sitting at the chain's limit. */
  atLimitShare: number;
  chains: TxChain[];
  /** The chain with the most live samples ('0x10'), i.e. the one that was transmitting. */
  liveChain?: string | undefined;
  source: string;
}

/** PDCCH load from the PCFICH results (0xB12A): how many OFDM symbols the cell spent on control. */
export interface PdcchLoad {
  subframes: number;
  /** CFI value -> subframes ({'1': 19012, '2': 2823, '3': 9605}). */
  cfi: Record<string, number>;
  /** Subframes at CFI 3, as a share of the decoded ones: a cell sitting at CFI 3 is congested. */
  cfi3Share: number;
  /** Elements whose PCFICH was not decoded, so they carry no CFI. */
  notDecoded: number;
}

/** The uplink loop: what the PDCCH granted (0xB16C) against what the PUSCH reports say was sent (0xB139). */
export interface UplinkGrants {
  grants: number;
  /** Downlink assignments in the same records: counted, contents not decoded. */
  assignments: number;
  /** Grants matched one-to-one to a PUSCH report four subframes later. */
  matched: number;
  prbGranted: number;
  prbSent: number;
  source: string;
}

/** What the modem's own clocks say about the holes in the trace (0x1D0B). */
export interface TraceClock {
  records: number;
  /** Steps in the 1024 Hz counter wider than a record period: trace that was never written. */
  gaps: { tMs: number; missingMs: number }[];
  missingMs: number;
  /** Consecutive sequence numbers that stepped by exactly 1. */
  sequenceSteps: number;
  sequenceStepsExpected: number;
}

export interface PhySummary {
  scellActivity: CarrierActivity[];
  nrDlActivity?: CarrierActivity | undefined;
  rach: RachEvent[];
  /** eNB Tx antennas from the MIB (0xB0C1). */
  txAntennasMib: number[];
  /** EARFCN -> Rx antennas measured -> records ({'66786': {'4': 700, '2': 90}}). */
  rxAntennasByEarfcn: Record<string, Record<string, number>>;
  /** Measured per serving cell from 0xB126, which is what the Antennas section should show. */
  measuredAntennas?: AntennaConfig[] | undefined;
  intraFreqNeighbours?: NeighbourCell[] | undefined;
  macDl?: MacDlAccounting | undefined;
  uplinkFrontEnd?: FrontEndUplink | undefined;
  pdcchLoad?: PdcchLoad | undefined;
  uplinkGrants?: UplinkGrants | undefined;
  traceClock?: TraceClock | undefined;
}

/** A runtime self-check of a decoder against a physical or 3GPP identity ('Decoder health'). */
export interface PhyCheck {
  id: string;
  code: string;
  passed: boolean;
  measured: string;
  expectation: string;
}

export type AvailabilityStatus =
  | 'available'
  | 'notDecodedYet'
  | 'notFoundInPlainLogs'
  | 'encryptedByModem'
  | 'notOnIPhone';

export interface Availability {
  id: string;
  title: string;
  status: AvailabilityStatus;
  reason: string;
  /** The log codes involved ('0xB8DD'). */
  codes?: string[] | undefined;
}

// ----------------------------------------------------------------------------------------------- the analysis

export interface CaptureAnalysis {
  contract: typeof CONTRACT_VERSION;
  fileName: string;
  /** When the buttons were pressed (the archive's name), ISO UTC. */
  triggerTime?: string | undefined;
  /** Null when the archive holds no trace directory with an info.txt. */
  traceWindow: TraceWindow | null;
  profile: ProfileState;
  guide: GuideState;
  /** Ordered: blocking problems first. */
  problems: ImportProblem[];

  /** Plain log records rebuilt from the trace, and their distinct codes. */
  records: number;
  codes: number;
  /** = encrypted.records. */
  encryptedRecords: number;
  encrypted: EncryptedCensus;
  deframe?: DeframeStats | undefined;
  crcErrors: number;
  /** D1 time base: first to last plausible modem timestamp. */
  durationMs: number;
  /** UTC of the time base (tMs 0), when the modem had network time. */
  startUtc?: string | undefined;

  events: Event[];
  procedures: Procedure[];
  steps: Step[];
  connections: Connection[];
  cellDetails: CellDetail[];
  ladder: Ladder;

  journey: Journey;

  phy: PhySeries[];
  phySummary: PhySummary;
  phyChecks: PhyCheck[];
  /** '0xB173 v48' -> records skipped because the version is not one the decoder validated. */
  versionMisses: Record<string, number>;
  availability: Availability[];

  /** Wall-clock ms spent per stage, for the import sheet and performance notes. */
  timings: Partial<Record<ImportStage, number>>;
}
