import SwiftUI
import FTApp

extension View {
    /// DEBUG/Harness: once this screen shows its real content (the launch plan applied, the capture loaded), writes
    /// its screen report through DebugHooks, so sim-shot.sh and the harness never capture a half-loaded screen.
    /// `key` re-reports when what the screen shows changes (the page, the event). Compiled out of Release.
    func reportsScreen(_ route: Route, session: CaptureSession? = nil, key: AnyHashable? = nil,
                       when active: Bool = true) -> some View {
        modifier(ScreenReporting(route: route, session: session, key: key, active: active))
    }
}

struct ScreenReporting: ViewModifier {
    var route: Route
    var session: CaptureSession?
    var key: AnyHashable?
    var active: Bool
    @Environment(AppModel.self) private var app: AppModel?

    private struct Trigger: Equatable {
        var route: Route
        var key: AnyHashable?
        var active: Bool
        var settled: Bool
    }

    func body(content: Content) -> some View {
        #if DEBUG || FT_HARNESS
        content.task(id: Trigger(route: route, key: key, active: active, settled: app?.launchSettled ?? false)) {
            guard active, app?.launchSettled == true else { return }
            // Let a navigation push or sheet presentation finish before saying the screen is ready.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            DebugHooks.screenAppeared(route, session: session)
        }
        #else
        content
        #endif
    }
}
