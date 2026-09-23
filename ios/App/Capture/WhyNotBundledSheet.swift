import SwiftUI
import FTCapture
import FTModel

/// Why Apple's Baseband profile can't ship inside FieldTap, and what the app does instead (the design's
/// profile_answer, with the capture timing corrected by the ring evidence, R2), with Apple's sources. Links open
/// in Safari.
struct WhyNotBundledSheet: View {
    /// The newest import's profile, for "the copy on your iPhone" dates.
    var profile: ProfileState? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Short answer: no. FieldTap can't carry Apple's logging profile inside the app, and the app can't turn modem logging on by itself. Downloading Apple's profile about once a week is the only way Apple allows on a normal iPhone.")
                        .font(.body)
                    section("What the profile is", [
                        "It's Apple's \"Baseband and Telephony Logging\" profile (com.apple.basebandlogging), signed by Apple.",
                        "It's only an on switch: it tells the modem to record its trace. What the modem records is already on your iPhone.",
                        yourCopy,
                    ].compactMap { $0 })
                    section("Why it can't be part of the app", [
                        "iOS gives apps no way to install a profile or change that setting. You install a downloaded profile yourself, in Settings, within 8 minutes, with your passcode. Stolen Device Protection can block it away from familiar places. Apple's engineers say only Apple can make logging profiles for iOS, and that apps have no supported access to low-level cellular data.",
                        "Bundling wouldn't save a tap: even with the file inside the app, you'd still go through the same Safari, Settings and Install steps.",
                        "It's Apple's file. Apple serves it only after you sign in, under terms that don't allow sharing it, and editing it would break Apple's signature. A look-alike profile wouldn't be honoured, and it would put the app under App Review's device-management rule (5.5).",
                    ])
                    section("What FieldTap does instead", [
                        "One button opens Apple's Profiles and Logs page in Safari. Sign in with your Apple Account, tap Baseband, allow the download, then install it in Settings.",
                        "Press both volume buttons and the side button, then make the problem happen. " + CaptureWording.timing,
                        "Wait up to 10 minutes, then share the sysdiagnose from Analytics Data to FieldTap.",
                        "Each import reads the profile record in the archive, shows when it expires, can remind you a day before, and tells you plainly when there's no modem trace.",
                    ])
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sources").font(.headline)
                        Link("Apple: Install a configuration profile on your iPhone", destination: URL(string: "https://support.apple.com/en-us/102400")!)
                        Link("Apple Developer Forums: logging profiles for iOS", destination: URL(string: "https://developer.apple.com/forums/thread/726871")!)
                        Link("Apple Developer Forums: access to cellular data", destination: URL(string: "https://developer.apple.com/forums/thread/751785")!)
                        Link("App Review Guidelines 5.5: Mobile Device Management", destination: URL(string: "https://developer.apple.com/app-store/review/guidelines/#mobile-device-management")!)
                        Link("Apple: Profiles and Logs (Baseband)", destination: GuideContent.applePage)
                    }
                    .font(.subheadline)
                    Text("Everything stays on your iPhone, and identifiers are hidden by default. For company-owned, supervised iPhones, a device-management server can install Apple's profile without the Settings steps (not tested with this profile).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .fixedSize(horizontal: false, vertical: true)
            }
            .navigationTitle("Why FieldTap can't do this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var yourCopy: String? {
        guard let p = profile, let install = p.installDate, let removal = p.removalDate else {
            return "It removes itself after 7 days (older copies said 21), so FieldTap reads the real dates from each import."
        }
        let days = p.lifetimeDays.map { Int($0.rounded()) } ?? 7
        return "The copy on your iPhone was installed \(ModemLoggingStatus.format(install)) and removes itself \(ModemLoggingStatus.format(removal)): \(days) days. Older copies said 21 days, so FieldTap reads the real dates from each import."
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
