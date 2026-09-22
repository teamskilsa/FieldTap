/// Everything the capture screens read, built once per opened capture by `Analyzer` (FTApp).
public struct CaptureAnalysis: Sendable {
    public var summary: CaptureSummary
    public var timeBase: TimeBase
    public var flow: Flow
    public var phy: PhyCapture
    public var journey: Journey

    public init(summary: CaptureSummary, timeBase: TimeBase, flow: Flow, phy: PhyCapture, journey: Journey) {
        self.summary = summary
        self.timeBase = timeBase
        self.flow = flow
        self.phy = phy
        self.journey = journey
    }

    /// The length the time cursor and every chart share: the call flow's duration, else the time base's.
    public var durationMs: Double {
        flow.durationMs > 0 ? flow.durationMs : timeBase.durationMs
    }
}
