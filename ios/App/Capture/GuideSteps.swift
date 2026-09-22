import SwiftUI
import FTModel

/// One step of a customer-facing guide: an SF Symbol picture, a short title, plain words, one primary button and
/// a short fix for when it doesn't go to plan (R1). No jargon: no QDSS, DIAG or ABM here.
struct GuideStep: Identifiable, Hashable {
    enum Action: Hashable {
        /// Opens Apple's Profiles and Logs page in Safari (R3), then moves on.
        case openApplePage
        /// Moves to the next step.
        case next
        /// "I pressed the buttons": starts the capture countdown (R2), then moves on.
        case startCountdown
        /// The last step.
        case finish
    }

    struct Trouble: Hashable {
        var problem: String
        var fix: String
    }

    var id: String
    var symbol: String
    var title: String
    var text: String
    var button: String
    var action: Action
    var trouble: [Trouble]
}

enum GuideContent {
    /// Apple's page for the Baseband profile (R3). The older bug-reporting address redirects here.
    static let applePage = URL(string: "https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=baseband")!

    /// Turning modem logging on: the five steps R1 lists, in the words a customer uses.
    static func setup(lifetimeDays: Int) -> [GuideStep] {
        [
            GuideStep(id: "apple", symbol: "safari", title: "Open Apple's page",
                      text: "Tap the button to open Apple's Profiles and Logs page in Safari. Sign in with your Apple Account. It's free.",
                      button: "Open Apple's page", action: .openApplePage,
                      trouble: [.init(problem: "Asked to sign in or accept terms?",
                                      fix: "That's normal. Use the Apple Account on this iPhone and accept Apple's terms. There's nothing to pay.")]),
            GuideStep(id: "download", symbol: "arrow.down.circle", title: "Download the Baseband profile",
                      text: "On Apple's page, find iOS and tap Baseband, then Download. When your iPhone asks whether to allow a configuration profile, tap Allow.",
                      button: "I downloaded it", action: .next,
                      trouble: [.init(problem: "Can't see Baseband?",
                                      fix: "Scroll down to the iOS section. Tapped Ignore by mistake? Tap Baseband again.")]),
            GuideStep(id: "install", symbol: "gearshape", title: "Install it in Settings",
                      text: "Open the Settings app. Near the top, under your name, tap Profile Downloaded, then Install. Enter your passcode and tap Install again. Do this within 8 minutes.",
                      button: "I installed it", action: .next,
                      trouble: [.init(problem: "No Profile Downloaded in Settings?",
                                      fix: "It disappears after 8 minutes. Go back one step and download it again."),
                                .init(problem: "A Stolen Device Protection message?",
                                      fix: "Try again somewhere familiar, like home or work, or turn Stolen Device Protection off for now in Settings > Face ID & Passcode.")]),
            GuideStep(id: "restart", symbol: "arrow.clockwise.circle", title: "Restart if asked",
                      text: "If your iPhone asks you to restart, do it now. If your first import says there's no modem trace, restart and take a new sysdiagnose.",
                      button: "Next", action: .next,
                      trouble: [.init(problem: "How do I restart?",
                                      fix: "Press and hold the side button and either volume button, slide to power off, then press the side button to turn it on again.")]),
            GuideStep(id: "done", symbol: "checkmark.circle", title: "Come back and tap Done",
                      text: "Modem logging is now on for \(lifetimeDays) days. After that iOS removes Apple's profile by itself, and you can install it again the same way.",
                      button: "Done", action: .finish,
                      trouble: [.init(problem: "Import says logging is off?",
                                      fix: "Open Settings > General > VPN & Device Management. If you don't see Baseband and Telephony Logging there, start again from step 1.")]),
        ]
    }

    /// Where the setup starts for a state: after a trace-less import with the profile installed, at the restart.
    static func setupStart(for state: GuideState) -> Int {
        if case .installedNoTrace = state { return 3 }
        return 0
    }

    /// Recording a problem (R2): press first, reproduce 20-40 s later, wait, share.
    static let capture: [GuideStep] = [
        GuideStep(id: "press", symbol: "hand.tap", title: "Press the buttons first",
                  text: "Press both volume buttons and the side button together, briefly, until you feel a short buzz. Do this before the problem: in early tests your iPhone kept only about 27 seconds of modem trace, all after the press.",
                  button: "I pressed the buttons", action: .startCountdown,
                  trouble: [.init(problem: "No buzz?",
                                  fix: "Press all three at the same moment and let go right away. Holding them down starts Emergency SOS, so don't hold them.")]),
        GuideStep(id: "reproduce", symbol: "phone.arrow.up.right", title: "Then make the problem happen",
                  text: "About 20 to 40 seconds after the buzz, do the thing that goes wrong: place the call, open the app, or go to the spot where it fails.",
                  button: "Next", action: .next,
                  trouble: [.init(problem: "Missed the moment?",
                                  fix: "Start again: press the buttons, wait 20 seconds, then try it. The countdown in FieldTap can time it for you.")]),
        GuideStep(id: "wait", symbol: "hourglass", title: "Wait for the sysdiagnose",
                  text: "Your iPhone takes up to 10 minutes to finish it. You can use your phone meanwhile.",
                  button: "Next", action: .next,
                  trouble: [.init(problem: "Can't find it yet?",
                                  fix: "Give it the full 10 minutes. It appears only when it's complete.")]),
        GuideStep(id: "share", symbol: "square.and.arrow.up", title: "Share it to FieldTap",
                  text: "Open Settings > Privacy & Security > Analytics & Improvements > Analytics Data. Tap the newest sysdiagnose_… file, tap Share, then FieldTap.",
                  button: "Done", action: .finish,
                  trouble: [.init(problem: "Import says logging is off?",
                                  fix: "Modem logging wasn't on when you pressed the buttons. Turn it on with the steps above, then record again.")]),
    ]
}

/// "Step 2 of 5", a progress bar, and the current step's card with its one primary button.
struct StepFlow: View {
    var title: String
    var steps: [GuideStep]
    @Binding var index: Int
    var onFinish: () -> Void = {}
    var onStartCountdown: () -> Void = {}
    @Environment(\.openURL) private var openURL

    var body: some View {
        let i = min(max(0, index), steps.count - 1)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text("Step \(i + 1) of \(steps.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("guideStepCounter")
            }
            .padding(.horizontal, 6)
            ProgressView(value: Double(i + 1), total: Double(steps.count))
                .tint(Theme.accent)
                .padding(.horizontal, 6)
                .accessibilityHidden(true)
            StepCard(step: steps[i], canGoBack: i > 0, back: { index = i - 1 }) {
                switch steps[i].action {
                case .openApplePage:
                    openURL(GuideContent.applePage)
                    index = i + 1
                case .next:
                    index = min(i + 1, steps.count - 1)
                case .startCountdown:
                    onStartCountdown()
                    index = min(i + 1, steps.count - 1)
                case .finish:
                    onFinish()
                }
            }
            .id(steps[i].id)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .animation(.snappy, value: index)
    }
}

/// One step: the picture, the words, the primary button, and "Having trouble?".
struct StepCard: View {
    var step: GuideStep
    var canGoBack: Bool
    var back: () -> Void
    var primary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: step.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 56)
                    .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title).font(.title3.weight(.semibold))
                    Text(step.text).font(.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: primary) {
                Label(step.button, systemImage: step.action == .openApplePage ? "safari" : "arrow.right")
                    .labelStyle(TrailingIconLabelStyle(showIcon: step.action != .finish))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("guidePrimary-\(step.id)")
            VStack(alignment: .leading, spacing: 6) {
                Label("Having trouble?", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(step.trouble, id: \.self) { t in
                    Text("\(Text(t.problem).fontWeight(.semibold)) \(t.fix)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if canGoBack {
                Button("Back", systemImage: "chevron.left", action: back)
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }
}

/// Title first, then the icon.
struct TrailingIconLabelStyle: LabelStyle {
    var showIcon = true

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            if showIcon { configuration.icon }
        }
    }
}

/// The steps as one short numbered list, for the flow that is not the main one on the screen.
struct StepList: View {
    var title: String
    var steps: [GuideStep]
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text(step.title).font(.subheadline)
                }
            }
            if let footnote {
                Text(footnote).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }
}
