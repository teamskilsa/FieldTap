import FTCore
import FTJourney
import FTModel
import FTPhy
import FTSignalling

/// Turns a capture's records into everything the screens read, once per opened capture. Pure and synchronous:
/// callers run it off the main actor.
public enum Analyzer {
    public static func analyze(records: [LogRecord], summary: CaptureSummary, crcErrors: Int = 0) -> CaptureAnalysis {
        let timeBase = TimeBase.of(records)
        let flow = CallFlowReader.read(records: records, crcErrors: crcErrors)
        var s = summary
        if s.durationMs == nil { s.durationMs = flow.durationMs > 0 ? flow.durationMs : timeBase.durationMs }
        let phy = PhyExtractor.extract(records: records, timeBase: timeBase, secure: summary.secure)
        let journey = JourneyBuilder.build(flow: flow, phy: phy.summary, facts: CaptureFacts(summary: s))
        return CaptureAnalysis(summary: s, timeBase: timeBase, flow: flow, phy: phy, journey: journey)
    }

    /// The journey again, after a fixture fallback replaced the flow or the PHY summary.
    public static func rebuildJourney(_ analysis: CaptureAnalysis) -> CaptureAnalysis {
        var a = analysis
        if a.summary.durationMs == nil || a.summary.durationMs == 0 { a.summary.durationMs = a.durationMs }
        a.journey = JourneyBuilder.build(flow: a.flow, phy: a.phy.summary, facts: CaptureFacts(summary: a.summary))
        return a
    }
}
