import SwiftUI
import Charts
import FTApp
import FTModel

/// The shared scaffold of every Radio chart: title and badges, the capture's visible window on x (ms since
/// the time base, labelled m:ss), the unit as the y-axis title, tap or drag to move the one time cursor, and
/// the cursor itself drawn in the chart overlay, so moving it redraws only the line and never the marks.
struct PhyChart<Content: ChartContent>: View {
    var title: String
    var unit: String
    var badges: [RadioBadge] = []
    /// Shown instead of the chart when there is nothing to draw (the catalogue's reason, usually).
    var empty: String? = nil
    var yDomain: ClosedRange<Double>? = nil
    var height: CGFloat = RadioStyle.chartHeight
    @Bindable var session: CaptureSession
    @ChartContentBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                ForEach(badges) { BadgeView(badge: $0) }
                Spacer(minLength: 0)
            }
            if let empty {
                EmptyChartNote(text: empty)
            } else if let yDomain {
                styled(Chart { content() }.chartYScale(domain: yDomain))
            } else {
                styled(Chart { content() }.chartYScale(domain: .automatic(includesZero: false)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func styled(_ chart: some View) -> some View {
        chart
            .chartXScale(domain: session.visibleWindow)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisTick().foregroundStyle(Color.secondary.opacity(0.4))
                    AxisValueLabel {
                        if let ms = value.as(Double.self) { Text(RadioFormat.clock(ms)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel()
                }
            }
            .chartYAxisLabel(position: .topLeading, alignment: .leading) { Text(unit).font(.caption2) }
            .chartLegend(.hidden)
            .chartPlotStyle { $0.clipped() }
            .chartXSelection(value: Binding<Double?>(get: { nil }, set: { if let v = $0 { session.cursor.set(v) } }))
            .chartOverlay { proxy in CursorOverlay(proxy: proxy, cursor: session.cursor) }
            .frame(height: height)
    }
}

/// The time cursor over a chart's plot area.
struct CursorOverlay: View {
    var proxy: ChartProxy
    var cursor: TimeCursor

    var body: some View {
        GeometryReader { geo in
            if let anchor = proxy.plotFrame {
                let frame = geo[anchor]
                if let x = proxy.position(forX: cursor.ms), x >= 0, x <= frame.width {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 1.5, height: frame.height)
                        .position(x: frame.minX + x, y: frame.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
