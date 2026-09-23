/// Everything the capture screens read, built once per opened capture by `Analyzer` (FTApp).
public struct CaptureAnalysis: Sendable {
    public var summary: CaptureSummary
    public var timeBase: TimeBase
    public var flow: Flow
    public var phy: PhyCapture
    public var journey: Journey
    /// Local fake-base-station / IMSI-catcher check over the decoded call flow (FTSecurity). Optional and
    /// back-compatible: an analysis built before this field, or one whose detector has not run yet, has none.
    public var security: SecurityReport?

    public init(summary: CaptureSummary, timeBase: TimeBase, flow: Flow, phy: PhyCapture, journey: Journey,
                security: SecurityReport? = nil) {
        self.summary = summary
        self.timeBase = timeBase
        self.flow = flow
        self.phy = phy
        self.journey = journey
        self.security = security
    }

    /// The length the time cursor and every chart share: the call flow's duration, else the time base's.
    public var durationMs: Double {
        flow.durationMs > 0 ? flow.durationMs : timeBase.durationMs
    }
}
