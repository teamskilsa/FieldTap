// The tunable constants for the fake-base-station ruleset, in one place so every threshold is visible. A port
// of web/engine/src/security/thresholds.ts. The rule of the whole module: a false positive on a real network is
// worse than a miss. Every default here was chosen to leave the real AT&T reference capture clean (its strongest
// LTE RSRP is about -81.8 dBm, its identity request is IMEISV not IMSI, its NAS/AS security runs), then to fire
// on a synthetic that carries the matching signature.

enum SecurityThresholds {
    /// Bumped when a rule or a threshold changes, so a golden report can be pinned to it.
    static let ruleset = "fieldtap-security/1"

    /// "Implausibly strong" serving-cell threshold, in dBm, per RAT. A real macro cell at the antenna's own
    /// doorstep tops out around -60 dBm; a signal above this is closer than any legitimate deployment.
    static let strongRsrpLte = -50.0
    static let strongRsrpNr = -50.0

    /// A single spike is a measurement artefact; a catcher's signal is sustained. Require at least this many
    /// samples over threshold, and this share of the cell's samples, before flagging.
    static let strongRsrpMinSamples = 5
    static let strongRsrpMinShare = 0.2

    /// NAS EMM (TS 24.301) / 5GMM (TS 24.501) reject causes that force the phone off a legitimate network: the
    /// classic denial/downgrade a fake BTS uses to strand a UE. #3 Illegal UE, #6 Illegal ME, #7 (E)PS services
    /// not allowed, #8 (E)PS and non-(E)PS not allowed, #11 PLMN not allowed, #12 TA not allowed, #13 Roaming
    /// not allowed in this TA, #14 (E)PS not allowed in this PLMN, #15 No suitable cells in TA.
    static let abnormalRejectCauses: Set<Int> = [3, 6, 7, 8, 11, 12, 13, 14, 15]

    /// RAT tokens a redirect/reselection can name (from RRC RedirectedCarrierInfo). GERAN is 2G, UTRA* is 3G.
    static let downgrade2g = ["GERAN"]
    static let downgrade3g = ["UTRA", "UTRAN", "UTRA-FDD", "UTRA-TDD"]
}
