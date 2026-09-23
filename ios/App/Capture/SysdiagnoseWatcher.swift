import SwiftUI
import UIKit
import FTCapture

// The sysdiagnose-creation watcher (CellGuard's SysdiagTask analogue), TestFlight only.
//
// Signal (a) — the sysdiagnose gesture (both volume buttons + side button) takes a screenshot, so
// `UIApplication.userDidTakeScreenshotNotification` is a proxy that the user may have just triggered a capture.
// Signal (b) — a metadata-only probe of the sysdiagnose directory. A permission-denied error is treated as
// "the path exists" (a capture may be in progress); not-found means absent. Contents are NEVER read.
//
// Gated so it degrades to nothing: if the directory probe returns not-found (likely on iOS 26's tightened
// sandbox), `onScreenshot()` never prompts. The pure decision lives in `SysdiagnoseWatcherProbe` (FTCapture)
// and is unit-tested; this type only wires it to UIKit and the local notification.

/// Encapsulates the watcher: which notification to observe, running the directory probe on a screenshot, and
/// posting the "we noticed a capture" local notification. Held as view `@State`; the view observes the
/// notification and calls `onScreenshot()`.
struct SysdiagnoseWatcher {
    var metadata: any PathMetadataReading = RealPathMetadata()

    /// The screenshot notification that stands in for the sysdiagnose gesture.
    static let screenshotSignal = UIApplication.userDidTakeScreenshotNotification

    /// The last directory state seen (for debugging / the diagnostics readout parity).
    private(set) var lastDirState: DirProbeState = .notFound(code: 0)

    /// Runs the directory probe and decides whether to show the "we noticed a capture" prompt.
    mutating func onScreenshot() -> Bool {
        lastDirState = SysdiagnoseWatcherProbe.probe(metadata: metadata)
        return SysdiagnoseWatcherProbe.shouldPrompt(screenshotSeen: true, dirState: lastDirState)
    }

    /// Best-effort local notification (only if notifications are already authorised).
    func notifyNoticedCapture() async { await ProfileReminder.notifyNoticedCapture() }
}

/// The home-screen banner shown when the watcher spots a likely sysdiagnose: guides the user to Analytics
/// Data and to share the result into FieldTap.
struct NoticedCaptureBanner: View {
    var onImport: () -> Void
    var onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.accent)
                Text("We noticed a capture").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            Text("If you just took a sysdiagnose, import it when it's ready: Settings > Privacy & Security > Analytics & Improvements > Analytics Data, then Share into FieldTap.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Import a sysdiagnose", systemImage: "square.and.arrow.down", action: onImport)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.10), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noticedCaptureBanner")
    }
}
