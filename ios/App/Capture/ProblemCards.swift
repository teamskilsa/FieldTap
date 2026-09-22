import SwiftUI
import FTModel

/// What an import found wrong, in plain words, each with its fix.
struct ProblemCopy: Hashable {
    var symbol: String
    var title: String
    var text: String
    /// True when the fix is in the Modem logging guide.
    var guideFix: Bool

    static func of(_ p: ImportProblem, now: Date = .now) -> ProblemCopy {
        switch p {
        case .notASysdiagnose:
            ProblemCopy(symbol: "doc.questionmark", title: "This isn't a sysdiagnose",
                        text: "Share the file whose name starts with sysdiagnose_, from Settings > Privacy & Security > Analytics & Improvements > Analytics Data.",
                        guideFix: true)
        case .truncatedArchive:
            ProblemCopy(symbol: "doc.badge.ellipsis", title: "This file was cut short",
                        text: "The copy ended before the archive did. Share it again from Analytics Data. If it keeps happening, wait a few minutes: it may still have been saving.",
                        guideFix: false)
        case .noBasebandTrace, .loggingNotEnabled, .profileMissing:
            ProblemCopy(symbol: GuideState.off.symbol, title: GuideState.off.headline(now: now, date: ModemLoggingStatus.format),
                        text: "This sysdiagnose has no modem trace: Apple's logging profile wasn't on when you pressed the buttons. Turn it on with the steps below, then take a new sysdiagnose.",
                        guideFix: true)
        case .profileExpired(let d):
            ProblemCopy(symbol: GuideState.expired(d).symbol,
                        title: GuideState.expired(d).headline(now: now, date: ModemLoggingStatus.format),
                        text: "iOS removes Apple's profile after 7 days, so the modem stopped logging. Install it again with the steps below.",
                        guideFix: true)
        case .profileExpiresSoon(let d):
            ProblemCopy(symbol: GuideState.expiringSoon(d).symbol,
                        title: "Your logging profile expires \(d.formatted(.relative(presentation: .named)))",
                        text: "Renew it before your next test: it takes about 5 minutes.", guideFix: true)
        case .profileInstalledAfterTrace:
            ProblemCopy(symbol: "clock.arrow.circlepath", title: "The profile was installed after this trace began",
                        text: "Part of the trace may be missing. Take a new sysdiagnose now that logging is on.", guideFix: true)
        case .profileInstalledNoTrace:
            ProblemCopy(symbol: GuideState.installedNoTrace.symbol,
                        title: GuideState.installedNoTrace.headline(now: now, date: ModemLoggingStatus.format),
                        text: "The profile is there, but the modem hadn't started logging. Restart your iPhone, then record the problem again.",
                        guideFix: true)
        case .unsupportedTrace(let why):
            ProblemCopy(symbol: "exclamationmark.triangle", title: "This trace can't be read", text: why, guideFix: false)
        case .lowDiskSpace(let need):
            ProblemCopy(symbol: "externaldrive.badge.exclamationmark",
                        title: "Not enough free space (need \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)))",
                        text: "FieldTap needs room to unpack the modem trace. Free up space in Settings > General > iPhone Storage, then try again.",
                        guideFix: false)
        }
    }

    /// One card per distinct message: the several problems that all mean "logging was off" become one.
    static func cards(for problems: [ImportProblem], now: Date = .now) -> [ProblemCopy] {
        var out: [ProblemCopy] = []
        let folded = problems.contains { if case .profileExpired = $0 { true } else { $0 == .profileInstalledNoTrace } }
        for p in problems {
            if folded, [.noBasebandTrace, .loggingNotEnabled, .profileMissing].contains(p) { continue }
            let c = of(p, now: now)
            if !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// The guide state the problems point to, when their fix is the setup steps.
    static func guideState(for problems: [ImportProblem]) -> GuideState? {
        for p in problems {
            if case .profileExpired(let d) = p { return .expired(d) }
        }
        if problems.contains(.profileInstalledNoTrace) { return .installedNoTrace }
        if problems.contains(where: { [.noBasebandTrace, .loggingNotEnabled, .profileMissing].contains($0) }) { return .off }
        return nil
    }
}

struct ProblemCard: View {
    var copy: ProblemCopy
    /// "Show me how", when the fix is in the guide and the guide isn't already on screen.
    var showGuide: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: copy.symbol)
                    .font(.title2)
                    .foregroundStyle(Theme.severity(.warning))
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(copy.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(copy.text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if copy.guideFix, let showGuide {
                Button(action: showGuide) {
                    Label("Show me how", systemImage: "list.number").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.severity(.warning).opacity(0.10), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.severity(.warning).opacity(0.3)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("problemCard")
    }
}
