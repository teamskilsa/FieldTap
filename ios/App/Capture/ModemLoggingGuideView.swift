import SwiftUI
import FTApp
import FTCapture
import FTModel

/// The step-by-step, customer-facing Modem logging guide (R1): the status from the newest import, then one card
/// per step with "Step N of M", one primary button and a short fix. While logging is off, expired, expiring or
/// missing its trace, the setup steps come first; once it is on, recording a problem does (R2, with the
/// countdown). The state comes from the newest import, because an App Store app cannot look at installed profiles.
struct ModemLoggingGuideView: View {
    @Bindable var app: AppModel
    @State private var captureStep = 0
    @State private var showWhy = false
    @AppStorage("ft.guide.setupStep") private var setupStep = 0
    /// Which state the saved setup step belongs to, so a new state starts at its own first step.
    @AppStorage("ft.guide.setupFor") private var setupFor = ""
    /// Set when the user taps Done on the last setup step: until the next import we can't confirm it worked.
    @AppStorage("ft.guide.doneFor") private var doneFor = ""
    @AppStorage(CaptureCoach.pressedKey) private var pressedAt: Double = 0
    @AppStorage("ft.capture.notify") private var notify = false
    @AppStorage("ft.reminder.expiry") private var remindExpiry = false

    var body: some View {
        let now = Date()
        let state = app.guideState(now: now)
        let profile = app.latest?.profile
        let doneKey = Self.key(state, app.latest)
        let showSetup = state.needsSetup && doneFor != doneKey
        ScrollView {
            VStack(spacing: 16) {
                if let countdown = CaptureCoach.running(pressedAt) {
                    CountdownPanel(countdown: countdown, notify: $notify, share: { captureStep = 3 }) {
                        pressedAt = 0
                        captureStep = 0
                        ProfileReminder.cancelCapture()
                    }
                }
                ModemLoggingStatus(state: state, profile: profile, now: now)
                if showSetup {
                    StepFlow(title: Self.setupTitle(state), steps: setupSteps(profile), index: $setupStep) {
                        doneFor = doneKey
                        setupStep = 0
                    }
                    StepList(title: "Then record a problem", steps: GuideContent.capture, footnote: TimingNote.short)
                } else {
                    if state.needsSetup {
                        Label("You've set it up. Your next import will confirm modem logging is on.",
                              systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    StepFlow(title: "Record a problem", steps: GuideContent.capture, index: $captureStep,
                             onFinish: { captureStep = 0 }, onStartCountdown: startCountdown)
                    TimingNote(latest: app.latest)
                    StepList(title: "Renew or set up again", steps: setupSteps(profile),
                             footnote: "Apple's page opens in Safari from step 1.")
                }
                if Self.canRemind(state), let profile {
                    ReminderToggle(isOn: $remindExpiry, profile: profile)
                }
                WhyCard { showWhy = true }
                PrivacyNote()
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Modem logging")
        .sheet(isPresented: $showWhy) {
            WhyNotBundledSheet(profile: profile)
        }
        .onAppear { applyState(state) }
        .onChange(of: state.token) { applyState(app.guideState()) }
    }

    private func setupSteps(_ profile: ProfileState?) -> [GuideStep] {
        GuideContent.setup(lifetimeDays: profile?.consentDays ?? profile?.lifetimeDays.map { Int($0.rounded()) } ?? 7)
    }

    /// A new state starts at its own first step; the same state keeps where the user was (they leave for Safari
    /// and Settings in the middle).
    private func applyState(_ state: GuideState) {
        if setupFor != state.token {
            setupFor = state.token
            setupStep = GuideContent.setupStart(for: state)
        }
        #if DEBUG || FT_HARNESS
        if let step = CaptureLaunchOptions.guideStep { setupStep = step - 1 }
        if CaptureLaunchOptions.whySheet { showWhy = true }
        if let seconds = CaptureLaunchOptions.countdownSeconds {
            pressedAt = Date().addingTimeInterval(-seconds).timeIntervalSince1970
        }
        #endif
        if let c = CaptureCoach.running(pressedAt) { captureStep = CaptureCoach.step(for: c.phase(at: .now)) }
    }

    private func startCountdown() {
        let c = CaptureCountdown(pressedAt: .now)
        pressedAt = c.pressedAt.timeIntervalSince1970
        if notify {
            Task {
                await ProfileReminder.scheduleDoItNow(after: CaptureCountdown.getReadySeconds)
                await ProfileReminder.scheduleSysdiagnoseReady(after: CaptureCountdown.sysdiagnoseWaitSeconds)
            }
        }
    }

    static func setupTitle(_ state: GuideState) -> String {
        switch state {
        case .expired, .expiringSoon: "Renew modem logging"
        case .installedNoTrace: "Finish turning it on"
        default: "Turn on modem logging"
        }
    }

    static func key(_ state: GuideState, _ latest: CaptureSummary?) -> String {
        state.token + "|" + (latest?.id.uuidString ?? "none")
    }

    static func canRemind(_ state: GuideState) -> Bool {
        switch state {
        case .active, .expiringSoon: true
        default: false
        }
    }
}

/// Why press first, and what the newest capture covered (R2). The advice is `CaptureWording.timing`, the one
/// place the timing is written down; the numbers come from two captures, and it says so.
struct TimingNote: View {
    var latest: CaptureSummary?

    static let short = CaptureWording.timing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Why press first?", systemImage: "timer").font(.headline)
            Text(CaptureWording.timing)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let w = latest?.traceWindowAfterPressMs {
                let overwritten = CaptureWording.overwritten(latest?.overwrittenFiles, listed: latest?.listedFiles)
                Text("Your last capture \(CaptureWording.pressWindow(w))" + (overwritten.map { "; \($0)" } ?? "") + ".")
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("lastTraceWindow")
            }
            Text("Your iPhone writes the modem log out about 19 seconds after the press and keeps only the last "
                 + "20 to 30 seconds of it. These timings come from two captures and may change.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }
}

/// "Remind me a day before it expires": asks for notification permission only when turned on.
struct ReminderToggle: View {
    @Binding var isOn: Bool
    var profile: ProfileState

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in
            isOn = on
            Task {
                if on, await ProfileReminder.requestPermission() {
                    await ProfileReminder.scheduleExpiry(profile)
                } else {
                    if on { isOn = false }
                    ProfileReminder.cancelExpiry()
                }
            }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remind me a day before it expires")
                if let removal = profile.removalDate {
                    Text("Apple's profile ends \(ModemLoggingStatus.format(removal)).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("remindExpiry")
    }
}

/// One line on why the profile can't come with the app, and the full answer behind "Learn why".
struct WhyCard: View {
    var learnWhy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Why FieldTap can't do this for you", systemImage: "lock.shield").font(.headline)
            Text("Only Apple can switch modem logging on. iOS lets you install Apple's profile yourself in Settings, and it expires after 7 days.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Button("Learn why", action: learnWhy)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityIdentifier("learnWhy")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }
}

struct PrivacyNote: View {
    var body: some View {
        Label {
            Text("Apple's profile says a sysdiagnose can include message contents, identifiers and location. FieldTap keeps only the modem trace, on this iPhone, and hides identifiers unless you choose to show them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.raised").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
