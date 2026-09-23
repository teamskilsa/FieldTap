// The journey layer on top of the parity call flow (rules J1-J12, ios/Contract/CONTRACT.md): lanes, markers,
// findings and KPI tiles from Flow, PhySummary and the capture facts only, so Android can implement the same
// rules against journey-expected.json.

import FTCore
import FTModel
import FTPhy

public enum JourneyBuilder {
    /// A pure function of the parity call flow, the PHY summary and the capture facts.
    public static func build(flow: Flow, phy: PhySummary, facts: CaptureFacts) -> Journey {
        let ctx = JourneyContext(flow: flow, phy: phy)
        let pcells = JourneyLanes.pcells(ctx)
        let endc = JourneyEnDc.build(ctx, pcells: pcells)
        let cells = pcells + endc.pscells + JourneyLanes.scells(ctx)
        var journey = Journey(durationMs: ctx.endMs, states: JourneyLanes.states(ctx),
                              registration: JourneyLanes.registration(ctx), cells: cells,
                              markers: JourneyMarkers.build(ctx, endc: endc.markers), findings: [], tiles: [])
        var f = facts
        if f.encrypted.records == 0 { f.encrypted = phy.encrypted }
        if f.traceWindowMs <= 0 { f.traceWindowMs = ctx.endMs }
        journey.findings = Findings.of(flow: flow, journey: journey, facts: f, phy: phy)
        journey.tiles = KpiTiles.of(flow: flow, journey: journey, phy: phy)
        return journey
    }
}
