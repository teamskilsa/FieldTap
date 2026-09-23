#if DEBUG || FT_HARNESS
import Foundation

/// DEBUG/Harness launch arguments for the capture screens' screenshots, until LaunchPlan carries them:
///
///     -FTGuideStep <n>       the setup guide at step n (1-based)
///     -FTCountdown <s>       the capture countdown as if the buttons were pressed s seconds ago
///     -FTWhySheet            the guide with "Why FieldTap can't do this for you" open
enum CaptureLaunchOptions {
    static let guideStep: Int? = value("-FTGuideStep").flatMap { Int($0) }
    static let countdownSeconds: Double? = value("-FTCountdown").flatMap { Double($0) }
    static let whySheet = ProcessInfo.processInfo.arguments.contains("-FTWhySheet")
    /// An anchor id to scroll the Modem logging guide to (e.g. "oneGesture"), so a card below the fold can be
    /// screenshotted.
    static let scrollTo: String? = value("-FTScrollTo")

    private static func value(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
#endif
