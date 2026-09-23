import SwiftUI
import FTCapture

/// Where the R2 countdown lives: the press time in the app's defaults (a per-viewer convenience), so it survives
/// the user leaving FieldTap to reproduce the problem.
enum CaptureCoach {
    static let pressedKey = "ft.capture.pressedAt"

    /// The countdown for a stored press time, while it is still worth showing (up to a minute after it is ready).
    static func running(_ pressedAt: Double, now: Date = .now) -> CaptureCountdown? {
        guard pressedAt > 0 else { return nil }
        let c = CaptureCountdown(pressedAt: Date(timeIntervalSince1970: pressedAt))
        return now < c.readyAt.addingTimeInterval(15 * 60) ? c : nil
    }

    /// The capture step that goes with a phase: reproduce, wait, share.
    static func step(for phase: CaptureCountdown.Phase) -> Int {
        switch phase {
        case .getReady, .doItNow: 1
        case .waiting: 2
        case .ready: 3
        }
    }
}

/// "I pressed the buttons" -> 3 s "Get ready" -> "Do it now" until 12 s -> "Now wait for the sysdiagnose
/// (up to 10 minutes)". The words under the ring are `CaptureWording.timing`, the one place the timing lives.
struct CountdownPanel: View {
    var countdown: CaptureCountdown
    @Binding var notify: Bool
    var share: () -> Void
    var stop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = countdown.phase(at: context.date)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    Ring(fraction: fraction(phase), tint: tint(phase)) {
                        Text(big(phase))
                            .font(.system(size: phase.isShort ? 34 : 22, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .frame(width: 86, height: 86)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(phase)).font(.title3.weight(.bold))
                            .accessibilityIdentifier("countdownTitle")
                        Text(detail(phase)).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if case .ready = phase {
                    Button(action: share) {
                        Label("Show me how to share it", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Text(CaptureWording.timing)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("countdownTiming")
                Toggle(isOn: notifyBinding) {
                    Text("Notify me if I leave FieldTap").font(.subheadline)
                }
                Button(role: .cancel, action: stop) {
                    Text(phase == .ready ? "Done" : "Stop the countdown").font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint(phase).opacity(0.12), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(tint(phase).opacity(0.35)))
            .animation(.snappy, value: phase)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("countdown-\(phase.token)")
        }
    }

    /// Opting in asks for permission, then schedules what is still ahead; opting out removes it.
    private var notifyBinding: Binding<Bool> {
        Binding(get: { notify }, set: { on in
            notify = on
            let c = countdown
            Task {
                if on, await ProfileReminder.requestPermission() {
                    let now = Date()
                    if c.doItNowAt > now { await ProfileReminder.scheduleDoItNow(after: c.doItNowAt.timeIntervalSince(now)) }
                    if c.readyAt > now { await ProfileReminder.scheduleSysdiagnoseReady(after: c.readyAt.timeIntervalSince(now)) }
                } else {
                    if on { notify = false }
                    ProfileReminder.cancelCapture()
                }
            }
        })
    }

    private func title(_ p: CaptureCountdown.Phase) -> String {
        switch p {
        case .getReady: "Get ready"
        case .doItNow: "Do it now"
        case .waiting: "Now wait for the sysdiagnose (up to 10 minutes)"
        case .ready: "Your sysdiagnose should be ready"
        }
    }

    private func detail(_ p: CaptureCountdown.Phase) -> String {
        switch p {
        case .getReady(let s): "Make the problem happen in \(s) seconds, and be finished within "
            + "\(Int(CaptureCountdown.doItBySeconds)) seconds of the press."
        case .doItNow: "Now: place the call, open the app, or go to the spot. Be finished before the ring empties."
        case .waiting: "You can use your iPhone meanwhile. It appears in Settings > Privacy & Security > Analytics & Improvements > Analytics Data."
        case .ready: "Share the newest sysdiagnose_… file to FieldTap."
        }
    }

    private func big(_ p: CaptureCountdown.Phase) -> String {
        switch p {
        case .getReady(let s), .doItNow(let s): "\(s)"
        case .waiting(let s): CaptureWording.minutesSeconds(Double(s))
        case .ready: "✓"
        }
    }

    private func fraction(_ p: CaptureCountdown.Phase) -> Double {
        switch p {
        case .getReady(let s): Double(s) / CaptureCountdown.getReadySeconds
        case .doItNow(let s): Double(s) / CaptureCountdown.doItSeconds
        case .waiting(let s): Double(s) / (CaptureCountdown.sysdiagnoseWaitSeconds - CaptureCountdown.doItBySeconds)
        case .ready: 1
        }
    }

    private func tint(_ p: CaptureCountdown.Phase) -> Color {
        switch p {
        case .doItNow: Theme.severity(.warning)
        default: Theme.accent
        }
    }
}

private extension CaptureCountdown.Phase {
    var isShort: Bool {
        switch self {
        case .getReady, .doItNow, .ready: true
        case .waiting: false
        }
    }
}

/// A ring that empties as time runs out, with its label inside.
struct Ring<Label: View>: View {
    var fraction: Double
    var tint: Color
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
            label
        }
        .accessibilityElement(children: .combine)
    }
}
