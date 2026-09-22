// DEBUG/Harness only (WP7). The per-route values of a screen report: what the screen is showing, as counts,
// ids and flags taken from the same model the view draws from, so sim-verify.sh can gate on them instead of
// on PNG sizes. Never a decoded field value.

#if DEBUG || FT_HARNESS
import Foundation
import FTApp
import FTJourney
import FTModel
import FTPhy
import FTPresentation

@MainActor
enum ScreenValues {
    static func of(_ route: Route, session: CaptureSession?, app: AppModel?, now: Date = .now) -> [String: ScreenValue] {
        switch route {
        case .captures: captures(app)
        case .guide: guide(app, now: now)
        case .settings: settings(app)
        case .importSheet: ["importState": .string(app?.importPreview?.token ?? "none"),
                            "pending": .bool(app?.pendingImport != nil)]
        case .overview: session.map { overview($0) } ?? [:]
        case .callflow: session.map { callflow($0) } ?? [:]
        case .message: session.map { message($0) } ?? [:]
        case .radio: session.map { radio($0) } ?? [:]
        }
    }

    private static func n(_ v: Int) -> ScreenValue { .number(Double(v)) }

    private static func captures(_ app: AppModel?) -> [String: ScreenValue] {
        guard let app else { return [:] }
        var v: [String: ScreenValue] = [
            "cardCount": n(app.captures.count),
            "fixtureLoaded": .bool(app.fixture != nil),
            "guideStatus": .string(app.guideState().token),
        ]
        if let latest = app.latest {
            v["latestProblems"] = .strings(latest.problems.map(\.token))
            v["latestHasTrace"] = .bool(latest.hasTrace)
            v["latestHasDigest"] = .bool(latest.digest != nil)
        }
        return v
    }

    /// The guide's state (R1) and the days left the status line quotes.
    private static func guide(_ app: AppModel?, now: Date) -> [String: ScreenValue] {
        guard let app else { return [:] }
        let state = app.guideState(now: now)
        var v: [String: ScreenValue] = [
            "status": .string(state.token),
            "needsAttention": .bool(state.needsAttention),
            "overridden": .bool(app.guideOverride != nil),
        ]
        switch state {
        case .active(let d), .expiringSoon(let d):
            v["daysLeft"] = n(max(0, Int((d.timeIntervalSince(now) / 86_400).rounded(.down))))
        case .expired:
            v["daysLeft"] = n(0)
        default:
            break
        }
        if let profile = app.latest?.profile { v["profileStatus"] = .string(profile.status(at: now).rawValue) }
        return v
    }

    private static func settings(_ app: AppModel?) -> [String: ScreenValue] {
        guard let app else { return [:] }
        return ["revealIdentifiers": .bool(app.revealIdentifiers), "captureCount": n(app.captures.count)]
    }

    private static func overview(_ s: CaptureSession) -> [String: ScreenValue] {
        let j = s.analysis.journey
        let at = JourneyQuery.segments(at: s.cursor.ms, in: j)
        var v: [String: ScreenValue] = [
            "findingIds": .strings(j.findings.map(\.id)),
            "findingCount": n(j.findings.count),
            "markerCount": n(j.markers.count),
            "tileCount": n(j.tiles.count),
            "eventCount": n(s.analysis.flow.events.count),
            "procedureCount": n(s.analysis.flow.procedures.count),
            "scellsAtCursor": n(at.count { $0.lane == .scell }),
            "pscellAtCursor": .bool(at.contains { $0.lane == .pscell }),
        ]
        if let pcell = at.first(where: { $0.lane == .pcell }) { v["pcellBandAtCursor"] = .string(pcell.band ?? "NR") }
        return v
    }

    private static func callflow(_ s: CaptureSession) -> [String: ScreenValue] {
        let rows = CallFlowPresentation.rows(s.analysis.flow, s.filter)
        return [
            "filter": .string(s.filter.rawValue),
            "rowCount": n(rows.count),
            "firstRowIds": .strings(rows.prefix(5).map(\.id)),
            "eventCount": n(s.analysis.flow.events.count),
        ]
    }

    /// The message sheet: which event, and that identifiers and bytes stay hidden while masked.
    private static func message(_ s: CaptureSession) -> [String: ScreenValue] {
        let flow = s.analysis.flow
        guard let index = s.selectedEvent, flow.events.indices.contains(index) else { return ["event": n(-1)] }
        let e = flow.events[index]
        let model = MessageSheetModel(event: e, flow: flow, reveal: s.reveal)
        let lines = model.sections.flatMap(\.lines)
        return [
            "event": n(index),
            "key": .string(e.key),
            "layer": .string(e.layer.rawValue),
            "rat": .string(e.rat),
            "uplink": .bool(e.uplink),
            "masked": .bool(!s.reveal),
            "bytesVisible": .bool(model.bytesVisible),
            "pduPresent": .bool(!e.pdu.isEmpty),
            "sectionCount": n(model.sections.count),
            "lineCount": n(lines.count),
            "maskedLineCount": n(lines.count { $0.value.contains(Redaction.masked) }),
        ]
    }

    /// The Radio section: the metrics its charts plot (after the Radio page's decimation to the visible
    /// window), plus the section's own counts.
    private static func radio(_ s: CaptureSession) -> [String: ScreenValue] {
        let section = s.radioSection ?? "signal"
        let phy = s.analysis.phy
        let metrics = RadioSections.metrics[section] ?? []
        let series = metrics.map { phy.series[$0] }
        var v: [String: ScreenValue] = [
            "section": .string(section),
            "metrics": .strings(metrics.map(\.rawValue)),
            "sampleCounts": .numbers(series.map { Double($0?.samples.count ?? 0) }),
            "pointCounts": .numbers(series.map { s0 in
                Double(s0.map { PhyQuery.decimate($0.samples, window: s.visibleWindow).count } ?? 0)
            }),
            "chartCount": n(series.count { !($0?.samples.isEmpty ?? true) }),
            "versionMisses": n(phy.versionMisses.values.reduce(0, +)),
        ]
        switch section {
        case "carriers":
            let at = JourneyQuery.segments(at: s.cursor.ms, in: s.analysis.journey)
            v["carriersAtCursor"] = n(at.count)
            v["scellActivity"] = n(phy.summary.scellActivity.count)
        case "rach":
            v["rachCount"] = n(phy.summary.rach.count)
        case "antennas":
            v["txAntennasMib"] = .numbers(phy.summary.txAntennasMib.map(Double.init))
            v["rxAntennaEarfcns"] = n(phy.summary.rxAntennasByEarfcn.count)
        case "unavailable":
            v["availabilityCount"] = n(phy.availability.count)
            v["catalogCount"] = n(PhyCatalog.entries.count)
        default:
            break
        }
        return v
    }
}

/// Which PHY series each Radio section plots, as the design's dashboard lists them (design.json
/// phy_dashboard_design). The Radio page (WP4) draws them; the harness only counts them.
enum RadioSections {
    static let metrics: [String: [PhyMetric]] = [
        "signal": [.lte_rsrp_per_rx, .lte_rsrp_filtered, .lte_rsrq_filtered, .lte_rssi, .lte_neighbour_rsrp],
        "dl": [.lte_dl_mcs, .lte_dl_modulation, .lte_dl_prb, .lte_dl_tbs, .lte_dl_layers, .lte_dl_bler,
               .lte_dl_phy_throughput],
        "ul": [.lte_ul_prb, .lte_ul_tbs, .lte_ul_modulation, .lte_ul_code_rate, .lte_ul_mcs_derived,
               .lte_pusch_tx_power_required, .lte_power_headroom, .lte_mac_ul_grant, .lte_ul_phy_throughput],
        "csi": [.lte_cqi_wideband_cw0, .lte_cqi_wideband_cw1, .lte_ri, .lte_pmi_wideband, .lte_csf_tx_mode],
        "nr": [.nr_ss_rsrp, .nr_ss_rsrq, .nr_dl_mcs, .nr_dl_prb, .nr_dl_layers, .nr_dl_tbs, .nr_dl_bler,
               .nr_dl_mac_throughput],
        "antennas": [.lte_tx_antennas_mib, .lte_rx_antennas_measured, .lte_rsrp_per_rx, .lte_dl_layers, .nr_dl_layers],
        "carriers": [.lte_band, .lte_dl_bandwidth_prb],
        "rach": [.lte_timing_advance_rar],
        "unavailable": [],
    ]
}
#endif
