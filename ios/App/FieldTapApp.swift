import SwiftUI
import FTApp
import FTCapture

@main
struct FieldTapApp: App {
    @State private var app = AppEnvironment.makeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .task {
                    #if DEBUG || FT_HARNESS
                    // Launch arguments and FT_FEED_PATH (App/Debug); compiled out of Release.
                    await DebugHooks.launch(app)
                    #else
                    app.refresh()
                    #endif
                    // TestFlight live profile-status probe (fails gracefully to import-based state).
                    app.refreshLiveProbe()
                    // A sysdiagnose shared to FieldTap while it was closed waits in the App Group Inbox.
                    app.ingestSharedInbox()
                    app.launchSettled = true
                }
                .onChange(of: scenePhase) { _, phase in
                    // The share happens in another process; pick up anything it left each time we come forward.
                    if phase == .active {
                        app.refreshLiveProbe()
                        app.ingestSharedInbox()
                    }
                }
                .onOpenURL { url in
                    // "Share > FieldTap" and "Open in" hand over a copy in Documents/Inbox (opening in place is off);
                    // anything outside the container needs security-scoped access.
                    app.requestImport(url, securityScoped: !AppEnvironment.isInsideContainer(url))
                }
        }
    }
}

/// Where the app keeps its files, and the model built on them.
@MainActor
enum AppEnvironment {
    static func makeModel() -> AppModel {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let store: CaptureStore
        do {
            store = try CaptureStore(root: support.appendingPathComponent("Captures", isDirectory: true))
        } catch {
            // Application Support could not be created: keep working from temporary storage this launch.
            store = try! CaptureStore(root: fm.temporaryDirectory.appendingPathComponent("Captures", isDirectory: true))
        }
        let importer = SysdiagnoseImporter(store: store, scratch: caches.appendingPathComponent("Import", isDirectory: true))
        return AppModel(store: store, importer: importer)
    }

    static func isInsideContainer(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
    }
}
