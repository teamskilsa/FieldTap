// DEBUG/Harness only (WP7). The launch hooks the harness drives: FT_FEED_PATH (the real sysdiagnose, read in
// place from the host), -FTScanOnly, -FTDumpAnalysis, the launch plan, and the per-screen reports that
// sim-shot.sh and sim-verify.sh wait on and check. See ios/scripts/HARNESS.md. Compiled out of Release.

#if DEBUG || FT_HARNESS
import Foundation
import FTApp
import FTModel

enum DebugHooks {
    /// The model the launch hooks were given, so a screen report can say what the captures list and the guide
    /// show. Weak: the app owns it.
    @MainActor private static weak var model: AppModel?

    /// Called once at launch, before `launchSettled`.
    ///
    /// With FT_FEED_PATH set (`SIMCTL_CHILD_FT_FEED_PATH=... xcrun simctl launch ...`), first either scans the
    /// archive (-FTScanOnly: scan.json) or imports it through the app's importer and writes import.json and
    /// analysis.json. Then applies the launch arguments (LaunchPlan). -FTDumpAnalysis also writes
    /// analysis-fixture.json for a -FTFixture capture, so the checker can run without an importer.
    @MainActor static func launch(_ app: AppModel) async {
        model = app
        let info = ProcessInfo.processInfo
        let plan = LaunchPlan.parse(info)
        if let path = info.environment["FT_FEED_PATH"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if info.arguments.contains("-FTScanOnly") {
                await HarnessFeed.scan(url)
            } else {
                await HarnessFeed.importAndAnalyze(url, app: app)
            }
        }
        await app.apply(plan)
        if info.arguments.contains("-FTDumpAnalysis"), let fixture = app.fixture, let dir = plan.fixtureDir {
            await HarnessFeed.dumpFixture(fixture, dir: dir)
        }
        if !plan.problems.isEmpty { print("FieldTap launch plan ignored: \(plan.problems.joined(separator: ", "))") }
    }

    /// Called when a screen shows its real content; writes Documents/ft-debug/screen-<route>[-<qualifier>].json
    /// with the common keys and the route's values (ScreenValues).
    @MainActor static func screenAppeared(_ route: Route, session: CaptureSession?) {
        let qualifier: String? = switch route {
        case .message: session?.selectedEvent.map(String.init)
        case .radio: session?.radioSection
        default: nil
        }
        var report = ScreenReport(route: route, session: session, qualifier: qualifier)
        // The first group of the UUID: enough to tell captures apart, and a random UUID's last group can be
        // twelve decimal digits, which the privacy gate would rightly flag.
        report.captureId = session.map { String($0.id.uuidString.prefix(8)) }
        report.cursorMs = DebugFiles.r3(report.cursorMs)
        report.values = ScreenValues.of(route, session: session, app: model)
        DebugFiles.write(report)
    }
}
#endif
