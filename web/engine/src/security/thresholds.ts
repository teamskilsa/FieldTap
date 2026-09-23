// OWNER: security. The tunable constants for the fake-base-station ruleset, in one place so every threshold is
// visible and documented (security/README.md explains each). The rule of the whole module: a false positive on a
// real network is worse than a miss. Every default here was chosen to leave the real AT&T reference capture clean
// (its strongest LTE RSRP is about -81.8 dBm, its identity request is IMEISV not IMSI, its NAS/AS security runs),
// then to fire on a synthetic that carries the matching signature.

/** Bumped when a rule or a threshold changes, so an iOS port can pin the golden reports it matches. */
export const SECURITY_RULESET = 'fieldtap-security/1';

/**
 * "Implausibly strong" serving-cell thresholds, in dBm, per RAT. A real macro cell at the antenna's own doorstep
 * tops out around -60 dBm; a signal above these is closer than any legitimate deployment and is the level a
 * table-top catcher a metre away produces. They sit well above the reference capture's peak (-81.8 dBm) and above
 * CellGuard's own "too good to be true" band, so ordinary good coverage never trips them.
 */
export const STRONG_RSRP_DBM = {
  /** lte_rsrp / lte_rsrp_filtered. */
  lte: -50,
  /** nr_ss_rsrp. */
  nr: -50,
} as const;

/** A single spike is a measurement artefact; a catcher's signal is sustained. Require at least this many samples
 *  over threshold, and this share of the cell's samples, before flagging. */
export const STRONG_RSRP_MIN_SAMPLES = 5;
export const STRONG_RSRP_MIN_SHARE = 0.2;

/**
 * NAS EMM (TS 24.301) / 5GMM (TS 24.501) reject causes that force the phone off a legitimate network: the classic
 * denial/downgrade a fake BTS uses to strand a UE on 2G or on a forbidden list. Their numbers coincide across EMM
 * and 5GMM for this set.
 *   #3  Illegal UE            #6  Illegal ME
 *   #7  (E)PS services not allowed
 *   #8  (E)PS and non-(E)PS services not allowed
 *   #11 PLMN not allowed      #12 Tracking area not allowed
 *   #13 Roaming not allowed in this tracking area
 *   #14 (E)PS services not allowed in this PLMN
 *   #15 No suitable cells in tracking area
 */
export const ABNORMAL_REJECT_CAUSES = new Set([3, 6, 7, 8, 11, 12, 13, 14, 15]);

/** RAT tokens a redirect/reselection can name (from RRC RedirectedCarrierInfo). GERAN is 2G, UTRA* is 3G. */
export const DOWNGRADE_2G = ['GERAN'];
export const DOWNGRADE_3G = ['UTRA', 'UTRAN', 'UTRA-FDD', 'UTRA-TDD'];
