// The local, no-network fake-base-station / IMSI-catcher check. A byte-for-byte port of
// web/engine/src/security/report.ts (ruleset `fieldtap-security/1`). It reads an already-decoded CaptureAnalysis
// and returns a SecurityReport: per-cell verdicts, an overall verdict, and a plain-language reason plus the exact
// decoded evidence for every finding. It calls nothing, stores nothing and sends nothing — the app's "nothing
// leaves this device" promise holds. FTSecurity depends only on FTModel; there is no networking API in it.
//
// Grounding. CellGuard reads shallow QMI management packets and cross-checks Apple's cell-location database; we
// decode the actual RRC/NAS trace, so we can look for the *classic* Layer-3 catcher signatures that SnoopSnitch
// and Darshak use on Android: null/absent ciphering, an IMSI asked for in the clear, a forced 2G/3G downgrade,
// a registration accepted with no security, a reject cause that strands the UE, an implausibly strong cell, and
// a cell reached with no mobility context. Each check names the exact decoded field(s) it reads.
//
// Conservatism is the whole design. A false alarm on a real network is worse than a miss, so every rule is tuned
// to leave the real AT&T reference capture with a 'trusted' verdict, and a sophisticated catcher that mimics a
// real cell will pass.
//
// The one field the engine reads that the Swift decode does not expose the same way is
// `phySummary.intraFreqNeighbours` (a summarised 0xB179 neighbour list): the Swift PhySummary has no such field,
// so the orphan-cell check reads the equivalent decoded evidence — every PHY series whose metric names a
// "neighbour" (lte_neighbour_* and the 0xB179 lte_intra_neighbour_*) plus the PCIs named in measurement-report
// fields. The engine's PhySample carries a whole `cell`; the Swift PhySample carries `earfcn`/`pci`, from which
// the serving cell is rebuilt. Neither difference changes any golden or the real-capture verdict.

import FTModel

public enum SecurityDetector {
    /// The ruleset an iOS golden report is pinned to.
    public static let ruleset = SecurityThresholds.ruleset

    /// The whole check, over an already-decoded capture. Pure and local.
    public static func analyze(_ a: CaptureAnalysis) -> SecurityReport {
        report(events: a.flow.events, steps: a.flow.journey, connections: a.flow.connections,
               cellDetails: a.flow.cellDetails, journeyCells: a.journey.cells,
               phy: a.phy.series, phySummary: a.phy.summary)
    }

    /// The same check over the decoded pieces it reads, so a test can feed a synthetic capture without building
    /// a whole CaptureAnalysis (the engine's `analyzeSecurity(analysis)` reads exactly these fields).
    public static func report(events: [Event], steps: [Step], connections: [Connection],
                              cellDetails: [CellDetail], journeyCells: [CellSegment],
                              phy: [PhyMetric: PhySeries], phySummary: PhySummary) -> SecurityReport {
        let ctx = Context(events: events, steps: steps, connections: connections, cellDetails: cellDetails,
                          journeyCells: journeyCells, phy: phy, phySummary: phySummary)
        let findings = ctx.checkNullCipher()
            + ctx.checkNoSecurityEstablished()
            + ctx.checkImsiInClear()
            + ctx.checkRatDowngrade()
            + ctx.checkAcceptedWithoutAuth()
            + ctx.checkAbnormalReject()
            + ctx.checkImplausibleSignal()
            + ctx.checkOrphanCell()

        let grouped = ctx.groupByCell(findings)
        let verdict = worst(grouped.cells.map(\.verdict) + grouped.unattached.map { $0.severity.verdict })
        return SecurityReport(
            verdict: verdict,
            headline: headline(for: verdict, count: findings.count),
            cells: grouped.cells,
            findings: grouped.unattached,
            checksRun: allChecks,
            gaps: gaps,
            ruleset: SecurityThresholds.ruleset
        )
    }
}

// MARK: - The transparency constants

/// The candidate checks we cannot support from the current decode, kept visible in every report. Verbatim from
/// the engine so the golden JSON matches.
private let gaps: [SecurityGap] = [
    SecurityGap(
        check: "sibNeighbourList",
        reason: "SIB neighbour lists and full measurement configurations are not decoded, so \"advertised neighbour\" cannot "
            + "be read directly; the orphan-cell check falls back to measured neighbours and mobility context only."
    ),
    SecurityGap(
        check: "asSecurityAlgorithm",
        reason: "The RRC Security Mode Command is decoded by name but its chosen AS ciphering/integrity algorithm is not "
            + "exposed, so AS null-algorithm cannot be read; null-algorithm detection uses the NAS Security Mode Command."
    ),
    SecurityGap(
        check: "sibAuthenticity",
        reason: "SIB1/SI are decoded for cell identity but not cross-checked for broadcast tampering (e.g. a spoofed cell "
            + "barring or PLMN), which would need fields the current SIB decode does not surface."
    ),
]

private let allChecks: [SecurityCheckId] = [
    .nullCipher, .noSecurityEstablished, .imsiRequestedInClear, .ratDowngrade,
    .acceptedWithoutAuth, .abnormalReject, .implausibleSignal, .orphanCell,
]

// MARK: - The checks

private struct Context {
    let events: [Event]
    let steps: [Step]
    let connections: [Connection]
    let cellDetails: [CellDetail]
    let journeyCells: [CellSegment]
    let phy: [PhyMetric: PhySeries]
    let phySummary: PhySummary

    /// Null ciphering / integrity: a NAS Security Mode Command that chose EEA0 or EIA0.
    func checkNullCipher() -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for e in events {
            let nullCipher = fieldValue(e.fields, "Ciphering") == "EEA0"
            let nullIntegrity = fieldValue(e.fields, "Integrity") == "EIA0"
            if !nullCipher && !nullIntegrity { continue }
            var evidence: [String] = []
            if nullCipher { evidence.append("\(e.name): Ciphering = EEA0 (null ciphering)") }
            if nullIntegrity { evidence.append("\(e.name): Integrity = EIA0 (null integrity)") }
            out.append(finding(.nullCipher, .suspicious, "Null security algorithm", event: e,
                explanation: nullIntegrity
                    ? "The network turned integrity protection off (EIA0). Outside an emergency call this is a hallmark of a fake base station."
                    : "The network chose null ciphering (EEA0), so traffic would go unencrypted — a hallmark of a fake base station.",
                evidence: evidence))
        }
        return out
    }

    /// Accepted with no security established at all: an accept with no Security Mode Command (RRC or NAS) anywhere.
    func checkNoSecurityEstablished() -> [SecurityFinding] {
        guard let accept = events.first(where: isAccept) else { return [] }
        if events.contains(where: isSecurityModeCommand) { return [] }
        return [finding(.noSecurityEstablished, .suspicious, "Accepted with no security", event: accept,
            explanation: "The network accepted the phone onto the network but never ran a Security Mode Command, so ciphering and "
                + "integrity were never switched on. A legitimate network always does.",
            evidence: ["\(accept.name) was seen, but no RRC or NAS Security Mode Command was in the trace"])]
    }

    /// IMSI requested in the clear: an Identity Request for the IMSI before security is established.
    func checkImsiInClear() -> [SecurityFinding] {
        let secIndex = events.firstIndex(where: isSecurityModeCommand)
        var out: [SecurityFinding] = []
        for e in events {
            guard let requested = fieldValue(e.fields, "Identity requested"), requested.uppercased() == "IMSI" else { continue }
            if let si = secIndex, e.index > events[si].index { continue }
            out.append(finding(.imsiRequestedInClear, .suspicious, "IMSI requested in the clear", event: e,
                explanation: "The network asked for the permanent subscriber identity (IMSI) before any security was set up. A real "
                    + "network uses a temporary identity (GUTI) here; asking for the IMSI in the clear is how a catcher harvests it.",
                evidence: ["\(e.name): Identity requested = IMSI, before any Security Mode Command"]))
        }
        return out
    }

    /// RAT downgrade: a redirect/reselection to GERAN (2G) or UTRAN (3G).
    func checkRatDowngrade() -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for e in events {
            guard let to = fieldValue(e.fields, "Redirected to") else { continue }
            let up = to.uppercased()
            let is2g = SecurityThresholds.downgrade2g.contains { up.contains($0) }
            let is3g = SecurityThresholds.downgrade3g.contains { up.contains($0) }
            if !is2g && !is3g { continue }
            out.append(finding(.ratDowngrade, is2g ? .suspicious : .warning,
                is2g ? "Forced 2G downgrade" : "Forced 3G downgrade", event: e,
                explanation: is2g
                    ? "The network pushed the phone down to 2G (GERAN), which has the weakest security. Forcing a modern phone onto 2G is a classic catcher move to make interception easier."
                    : "The network redirected the phone to 3G (UTRAN). This can be a legitimate fallback, but a forced downgrade is also how a catcher escapes LTE/NR security.",
                evidence: ["\(e.name): Redirected to = \(to)"]))
        }
        return out
    }

    /// Accepted without authentication: an accept with no Authentication message and no prior security context
    /// (the initial NAS request was not integrity protected).
    func checkAcceptedWithoutAuth() -> [SecurityFinding] {
        guard let accept = events.first(where: isAccept) else { return [] }
        let hasAuth = events.contains { e in
            let n = e.name.lowercased()
            return n.contains("authentication request") || n.contains("authentication response")
        }
        if hasAuth { return [] }
        let contextProven = events.contains { e in
            isInitialNasRequest(e) && e.protection.map { $0.headerName.lowercased().contains("integrit") } == true
        }
        if contextProven { return [] }
        return [finding(.acceptedWithoutAuth, .suspicious, "Accepted without authentication", event: accept,
            explanation: "The phone was accepted onto the network without any authentication exchange and without a pre-existing "
                + "security context. A network that cannot authenticate the phone (because it does not hold the keys) is a "
                + "fake base station.",
            evidence: [
                "\(accept.name) was seen",
                "no Authentication Request/Response was in the trace",
                "the initial NAS request was not integrity protected (no prior security context)",
            ])]
    }

    /// Abnormal reject cause: a NAS reject whose EMM/5GMM cause forces the phone off a legitimate network.
    func checkAbnormalReject() -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for e in events {
            guard e.layer == .NAS, let cause = e.cause else { continue }
            if e.name.range(of: "reject", options: .caseInsensitive) == nil
                && e.key.range(of: "reject", options: .caseInsensitive) == nil { continue }
            if !SecurityThresholds.abnormalRejectCauses.contains(cause) { continue }
            let named = e.causeName.map { " (\($0))" } ?? ""
            let namedFlat = e.causeName.map { " \($0)" } ?? ""
            out.append(finding(.abnormalReject, .suspicious, "Network-stranding reject", event: e,
                explanation: "The network rejected the phone with cause #\(cause)\(named), which "
                    + "strands it or pushes it onto a forbidden list. A fake base station uses these causes to deny service and "
                    + "force the phone onto a weaker network.",
                evidence: ["\(e.name): cause #\(cause)\(namedFlat)"]))
        }
        return out
    }

    /// Implausibly strong serving cell: a serving RSRP above the per-RAT threshold, sustained over several
    /// samples. A single spike is ignored.
    func checkImplausibleSignal() -> [SecurityFinding] {
        let series: [(metric: PhyMetric, threshold: Double, nr: Bool)] = [
            (.lte_rsrp, SecurityThresholds.strongRsrpLte, false),
            (.lte_rsrp_filtered, SecurityThresholds.strongRsrpLte, false),
            (.nr_ss_rsrp, SecurityThresholds.strongRsrpNr, true),
        ]
        var flagged = Set<String>()
        var out: [SecurityFinding] = []
        for spec in series {
            guard let s = phy[spec.metric] else { continue }
            let values = s.samples.filter { $0.value != nil }
            if values.isEmpty { continue }
            let over = values.filter { ($0.value ?? 0) > spec.threshold }
            if over.count < SecurityThresholds.strongRsrpMinSamples
                || Double(over.count) / Double(values.count) < SecurityThresholds.strongRsrpMinShare { continue }
            let peak = over.compactMap(\.value).max() ?? 0
            let cell = over.compactMap { sampleCell($0, nr: spec.nr) }.first
                ?? pcellCell(at: over[0].tMs)
            let key = cell.map(cellKey) ?? spec.metric.rawValue
            if flagged.contains(key) { continue }
            flagged.insert(key)
            var f = finding(.implausibleSignal, .warning, "Implausibly strong signal", event: nil,
                explanation: "The serving cell's signal reached \(fixed1(peak)) dBm over \(over.count) samples — stronger than any "
                    + "normal macro cell delivers, which is what a small transmitter close by (a possible catcher) looks like. "
                    + "It can also just mean you were beside a real cell tower.",
                evidence: ["\(spec.metric.rawValue): \(over.count) samples above \(Int(spec.threshold)) dBm, peak \(fixed1(peak)) dBm"])
            if let cell { f.cell = cell }
            f.tMs = over[0].tMs
            out.append(f)
        }
        return out
    }

    /// Orphan cell: an LTE serving/connection cell that is not the first camped cell, reached by no handover or
    /// reselection, and in no neighbour evidence. Warning only.
    func checkOrphanCell() -> [SecurityFinding] {
        let neighbourEvidence = neighbourCellKeys()
        var legit = Set<String>()
        for s in steps where s.move == .FIRST_SEEN || s.move == .HANDOVER || s.move == .RESELECTION {
            legit.insert(cellKey(s.to))
        }
        for c in cellDetails { legit.insert(cellKey(c.cell)) }

        let ltePcells = journeyCells.filter { $0.lane == .pcell && !$0.cell.nr }
        var firstIndex: Int?
        for (i, c) in ltePcells.enumerated() {
            if firstIndex == nil || c.startMs < ltePcells[firstIndex!].startMs { firstIndex = i }
        }
        let firstServing = firstIndex.map { ltePcells[$0] }

        // Insertion-ordered candidate set (Map semantics), first writer wins on a key.
        var order: [String] = []
        var candidates: [String: (cell: Cell, startMs: Double)] = [:]
        func add(_ key: String, _ cell: Cell, _ startMs: Double) {
            if candidates[key] == nil { order.append(key); candidates[key] = (cell, startMs) }
        }
        for (i, c) in ltePcells.enumerated() {
            if firstIndex == i { continue }
            add(cellKey(c.cell), c.cell, c.startMs)
        }
        for conn in connections {
            guard events.indices.contains(conn.first), let cell = events[conn.first].cell, !cell.nr else { continue }
            if let fs = firstServing, cellKey(cell) == cellKey(fs.cell) { continue }
            add(cellKey(cell), cell, conn.startMs)
        }

        var out: [SecurityFinding] = []
        for key in order {
            guard let c = candidates[key] else { continue }
            if legit.contains(key) || neighbourEvidence.contains(key) || neighbourEvidence.contains(pciKey(c.cell)) { continue }
            var f = finding(.orphanCell, .warning, "Cell reached without mobility context", event: nil,
                explanation: "The phone connected on this cell without a normal handover or reselection into it, and it was never "
                    + "measured as a neighbour. That can happen with ordinary load-balancing, but it is also how a catcher "
                    + "inserts a cell the real network never advertised.",
                evidence: ["EARFCN \(c.cell.earfcn) PCI \(c.cell.pci): no handover/reselection step, not in any neighbour measurement"])
            f.cell = c.cell
            f.tMs = c.startMs
            out.append(f)
        }
        return out
    }

    // MARK: aggregation

    func groupByCell(_ findings: [SecurityFinding]) -> (cells: [SecurityCellVerdict], unattached: [SecurityFinding]) {
        var order: [String] = []
        var byCell: [String: [SecurityFinding]] = [:]
        var unattached: [SecurityFinding] = []
        for f in findings {
            guard let cell = f.cell else { unattached.append(f); continue }
            let key = cellKey(cell)
            if byCell[key] == nil { order.append(key) }
            byCell[key, default: []].append(f)
        }
        var cells: [SecurityCellVerdict] = []
        for key in order {
            guard let list = byCell[key], let cell = list.first?.cell else { continue }
            let sorted = stableSorted(list) { $0.severity.rank > $1.severity.rank }
            let verdict = worst(sorted.map { $0.severity.verdict })
            cells.append(SecurityCellVerdict(cell: cell, band: bandOf(cell), verdict: verdict, findings: sorted))
        }
        cells = stableSorted(cells) { $0.verdict.rank > $1.verdict.rank }
        return (cells, unattached)
    }

    // MARK: helpers on the decoded data

    private func pcellCell(at tMs: Double) -> Cell? {
        journeyCells.first { $0.lane == .pcell && tMs >= $0.startMs && tMs <= $0.endMs }?.cell
    }

    private func bandOf(_ cell: Cell) -> String? {
        journeyCells.first { $0.cell.earfcn == cell.earfcn && $0.cell.pci == cell.pci }?.band
    }

    /// The serving cell a PHY sample belongs to, rebuilt from its EARFCN/PCI (the Swift PhySample has no whole
    /// Cell as the engine's does). The RAT decides `nr`, as the engine's per-series cell does.
    private func sampleCell(_ s: PhySample, nr: Bool) -> Cell? {
        guard let earfcn = s.earfcn, let pci = s.pci else { return nil }
        return Cell(earfcn: earfcn, pci: pci, nr: nr)
    }

    /// The keys of every cell there is neighbour evidence for: measured neighbours (0xB179 and the generic
    /// neighbour series), and PCIs named in measurement-report fields. See the file header on the mapping from
    /// the engine's `phySummary.intraFreqNeighbours`.
    private func neighbourCellKeys() -> Set<String> {
        var keys = Set<String>()
        for (metric, series) in phy where metric.rawValue.contains("neighbour") {
            for x in series.samples {
                if let pci = x.pci {
                    keys.insert("pci:\(pci)")
                    if let earfcn = x.earfcn { keys.insert("\(earfcn)/\(pci)") }
                }
            }
        }
        for e in events where e.key == "measurementReport" {
            collectPciLabels(e.fields, into: &keys)
        }
        return keys
    }

    private func collectPciLabels(_ fields: [Field], into keys: inout Set<String>) {
        for f in fields {
            if let n = pciLabel(f.label) { keys.insert("pci:\(n)") }
            collectPciLabels(f.children, into: &keys)
        }
    }
}

// MARK: - Free helpers

/// One finding. `id` is `check-eventIndex` when a message raised it, else the check name; an event fills in its
/// index, time and cell (the engine's `finding()`).
private func finding(_ check: SecurityCheckId, _ severity: SecuritySeverity, _ title: String, event: Event?,
                     explanation: String, evidence: [String]) -> SecurityFinding {
    var f = SecurityFinding(id: event.map { "\(check.rawValue)-\($0.index)" } ?? check.rawValue,
                            check: check, severity: severity, title: title, explanation: explanation, evidence: evidence)
    if let event {
        f.event = event.index
        f.tMs = event.sinceStartMs
        if let cell = event.cell { f.cell = cell }
    }
    return f
}

/// The first matching field's value, searched depth-first through the field tree.
private func fieldValue(_ fields: [Field], _ label: String) -> String? {
    for f in fields {
        if f.label == label { return f.value }
        if let child = fieldValue(f.children, label) { return child }
    }
    return nil
}

private let acceptNames: Set<String> = ["attach accept", "tracking area update accept", "registration accept", "service accept"]
private let initialRequestNames: Set<String> = [
    "attach request", "tracking area update request", "registration request", "service request", "extended service request",
]

private func isAccept(_ e: Event) -> Bool { acceptNames.contains(e.name.lowercased()) }
private func isInitialNasRequest(_ e: Event) -> Bool { initialRequestNames.contains(e.name.lowercased()) }
private func isSecurityModeCommand(_ e: Event) -> Bool { e.key == "securityModeCommand" || e.name.lowercased() == "security mode command" }

/// The PCI a "PCI 388" measurement field names (1-3 digits), else nil.
private func pciLabel(_ label: String) -> Int? {
    guard let r = label.range(of: "^PCI [0-9]{1,3}$", options: .regularExpression) else { return nil }
    return Int(label[r].dropFirst(4))
}

private func cellKey(_ c: Cell) -> String { "\(c.earfcn)/\(c.pci)\(c.nr ? "/nr" : "")" }
private func pciKey(_ c: Cell) -> String { "pci:\(c.pci)" }

private func worst(_ verdicts: [SecurityVerdict]) -> SecurityVerdict {
    verdicts.reduce(SecurityVerdict.trusted) { $1.rank > $0.rank ? $1 : $0 }
}

private func headline(for verdict: SecurityVerdict, count n: Int) -> String {
    switch verdict {
    case .trusted:
        "No fake-base-station signatures found. The network authenticated and encrypted as expected."
    case .warning:
        "\(n) thing\(n == 1 ? "" : "s") worth a look — most have an ordinary explanation. Read the reasons before drawing a conclusion."
    case .suspicious:
        "This capture carries Layer-3 signatures associated with fake base stations. Review each finding — this is evidence to check, not proof."
    }
}

/// `%.1f` the way Java's `String.format` / JS `toFixed(1)` do (a whole -38 becomes "-38.0").
private func fixed1(_ v: Double) -> String { String(format: "%.1f", v) }

/// A stable sort (Swift's `sort` is not guaranteed stable; V8's, which the engine uses, is), by decorating each
/// element with its original position and breaking ties on it.
private func stableSorted<T>(_ items: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
    items.enumerated()
        .sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }
        .map(\.element)
}
