import SwiftUI
import FTApp
import FTModel

/// Three tabs: the captures (and, pushed on top, an open capture), the Modem logging guide, and Settings.
struct RootView: View {
    @Bindable var app: AppModel

    var body: some View {
        TabView(selection: $app.tab) {
            Tab("Captures", systemImage: "waveform.path.ecg.rectangle", value: RootTab.captures) {
                NavigationStack {
                    CapturesView(app: app)
                        .navigationDestination(item: $app.openSession) { session in
                            CaptureDetailView(session: session)
                        }
                        .reportsScreen(.captures, when: app.tab == .captures && app.openSession == nil && app.pendingImport == nil)
                }
            }
            Tab("Modem logging", systemImage: "antenna.radiowaves.left.and.right", value: RootTab.guide) {
                NavigationStack {
                    ModemLoggingGuideView(app: app)
                        .reportsScreen(.guide, when: app.tab == .guide)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                NavigationStack {
                    SettingsView(app: app)
                        .reportsScreen(.settings, when: app.tab == .settings)
                }
            }
        }
        .environment(app)
        .sheet(item: $app.pendingImport) { request in
            // A sheet does not inherit the environment set inside the view it is attached to.
            ImportSheet(url: request.url, securityScoped: request.securityScoped, app: app)
                .reportsScreen(.importSheet)
                .environment(app)
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) { app.lastError = nil }
        } message: {
            Text(app.lastError ?? "")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })
    }
}
