import SwiftUI
import FTCapture
import FTModel

/// How each guide state looks: an SF Symbol, a colour and a short chip, next to R1's status line.
extension GuideState {
    var symbol: String {
        switch self {
        case .off: "antenna.radiowaves.left.and.right.slash"
        case .expired: "clock.badge.xmark"
        case .expiringSoon: "clock.badge.exclamationmark"
        case .active: "checkmark.seal.fill"
        case .installedNoTrace: "arrow.clockwise.circle"
        case .unknown: "antenna.radiowaves.left.and.right"
        }
    }

    var tint: Color {
        switch self {
        case .active: Theme.accent
        case .unknown: .secondary
        case .off, .expired, .expiringSoon, .installedNoTrace: Theme.severity(.warning)
        }
    }

    var chip: String {
        switch self {
        case .off: "Off"
        case .expired: "Expired"
        case .expiringSoon: "Expires soon"
        case .active: "On"
        case .installedNoTrace: "Restart needed"
        case .unknown: "Not set up yet"
        }
    }

    /// R1's status line; for a first launch, what to do instead of "not known".
    func title(now: Date) -> String {
        if case .unknown = self { return "Turn on modem logging" }
        return headline(now: now, date: ModemLoggingStatus.format)
    }

    /// True for the states where the setup steps are the main thing to show.
    var needsSetup: Bool {
        switch self {
        case .active: false
        default: true
        }
    }
}

/// The Modem logging status card on the Captures tab and at the top of the guide.
struct ModemLoggingStatus: View {
    var state: GuideState
    var profile: ProfileState?
    var now: Date
    /// True when `state` came from the live on-device probe (TestFlight) rather than an import, so the card
    /// says the estimate was detected on this iPhone.
    var isLive: Bool = false
    /// Buttons under the card (the Captures tab has "Guide" and "Import"); none in the guide.
    var onGuide: (() -> Void)?
    var onImport: (() -> Void)?
    @Environment(\.openURL) private var openURL

    nonisolated static func format(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
                Text("Modem logging").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(state.chip)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(state.tint)
                    .background(state.tint.opacity(0.14), in: .capsule)
                    .accessibilityIdentifier("guideStateChip")
            }
            Text(state.title(now: now))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("guideHeadline")
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if isLive {
                Label("Detected on this iPhone. The date is an estimate (install + \(lifetime) days); import a sysdiagnose to confirm.",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("liveProbeNote")
            }
            if case .active = state, onGuide == nil {
                Button {
                    openURL(GuideContent.applePage)
                } label: {
                    Label("Renew any time on Apple's page in Safari", systemImage: "safari")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            if onGuide != nil || onImport != nil {
                HStack(spacing: 10) {
                    if let onGuide {
                        Button(action: onGuide) {
                            Label(state.needsSetup ? "Show me how" : "Guide", systemImage: "list.number")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("statusGuide")
                    }
                    if let onImport {
                        Button(action: onImport) {
                            Label("Import", systemImage: "square.and.arrow.down").lineLimit(1).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("statusImport")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// The dates from the newest import's profile stub, or what to do next.
    private var detail: String? {
        switch state {
        case .unknown:
            return "FieldTap reads the modem trace from a sysdiagnose. Apple's free logging profile turns it on; it takes about 5 minutes."
        case .off:
            return "Your last sysdiagnose had no modem trace. Apple's logging profile turns it on; it takes about 5 minutes."
        case .installedNoTrace:
            return "Apple's profile is installed, but your last sysdiagnose had no modem trace yet."
        case .expired:
            return "iOS removes Apple's profile after \(lifetime) days. Install it again to keep logging."
        case .active, .expiringSoon:
            var parts: [String] = []
            if let install = profile?.installDate { parts.append("Apple profile installed \(Self.format(install))") }
            parts.append("lasts \(lifetime) days")
            return parts.joined(separator: ", ").capitalizedFirst + "."
        }
    }

    private var lifetime: Int {
        if let days = profile?.lifetimeDays { return max(1, Int(days.rounded())) }
        return profile?.consentDays ?? 7
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
