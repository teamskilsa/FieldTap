import SwiftUI
import FTApp
import FTJourney
import FTModel

/// The floating glass bar at the bottom of a capture: the cursor's time since start and wall clock, a slider
/// over the whole trace, the previous and next marker, and -/+100 ms (a long press steps 1 s). A haptic tick
/// marks every marker the cursor crosses, however it moved.
struct CursorBar: View {
    @Bindable var session: CaptureSession

    var body: some View {
        let journey = session.analysis.journey
        let t = session.cursor.ms
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                roundButton("backward.end.fill", label: "Previous event", enabled: JourneyQuery.marker(before: t, in: journey) != nil) {
                    if let m = JourneyQuery.marker(before: session.cursor.ms, in: journey) { session.cursor.set(m.tMs) }
                }
                StepButton(symbol: "minus", label: "Back", session: session, sign: -1)
                VStack(spacing: 0) {
                    Text(JourneyText.clock(t))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                    Text(wallClock(t) ?? nearest(t, journey))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cursor at \(JourneyText.clock(t))")
                .accessibilityAdjustableAction { direction in
                    session.cursor.step(direction == .increment ? 100 : -100)
                }
                StepButton(symbol: "plus", label: "Forward", session: session, sign: 1)
                roundButton("forward.end.fill", label: "Next event", enabled: JourneyQuery.marker(after: t, in: journey) != nil) {
                    if let m = JourneyQuery.marker(after: session.cursor.ms, in: journey) { session.cursor.set(m.tMs) }
                }
            }
            Slider(value: Binding(get: { session.cursor.ms }, set: { session.cursor.set($0) }),
                   in: 0...max(session.durationMs, 1))
                .controlSize(.mini)
                .accessibilityLabel("Time in the trace")
                .accessibilityValue(JourneyText.clock(t))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .sensoryFeedback(.selection, trigger: JourneyQuery.markersPassed(at: t, in: journey))
        .accessibilityIdentifier("cursorBar")
    }

    private func roundButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.accent : Color.secondary.opacity(0.5))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// "15:42:21.024" in this iPhone's time zone, when the capture has network time.
    private func wallClock(_ t: Double) -> String? {
        guard let start = session.analysis.flow.startUtcMs ?? session.analysis.timeBase.startUtcMs else { return nil }
        // 24-hour, whatever the locale's clock: this is a log timestamp, not a time of day to read aloud.
        let ms = Double(start) + t
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: ms / 1_000))
        let frac = Int(ms.truncatingRemainder(dividingBy: 1_000).rounded(.down))
        return String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, frac)
    }

    /// Without network time: what the cursor is on.
    private func nearest(_ t: Double, _ journey: Journey) -> String {
        JourneyQuery.segments(at: t, in: journey).first { $0.lane == .pcell }.map(JourneyText.shortCell) ?? "no wall clock"
    }
}

/// -/+100 ms on a tap, -/+1 s on a long press.
private struct StepButton: View {
    let symbol: String
    let label: String
    @Bindable var session: CaptureSession
    let sign: Double

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .frame(width: 40, height: 40)
            .background(Circle().fill(Theme.accent.opacity(0.12)))
            .foregroundStyle(Theme.accent)
            .overlay(alignment: .bottom) {
                Text("0.1").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary).offset(y: -3)
            }
            .contentShape(Circle())
            .onTapGesture { session.cursor.step(sign * 100) }
            .onLongPressGesture(minimumDuration: 0.35) { session.cursor.step(sign * 1_000) }
            .accessibilityElement()
            .accessibilityLabel("\(label) 100 milliseconds")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { session.cursor.step(sign * 100) }
            .accessibilityAction(named: "\(label) 1 second") { session.cursor.step(sign * 1_000) }
    }
}
