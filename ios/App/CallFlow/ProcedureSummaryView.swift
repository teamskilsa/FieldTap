import SwiftUI
import FTModel
import FTPresentation

/// Procedures by kind (android/app/.../ui/signalling/Signalling.kt, Procedures): "Attach: 3 succeeded, 40 failed, 74
/// no answer, median 282 ms" reads the same for a one-minute test and an overnight run. A kind with one attempt
/// jumps straight to it; a kind with several opens to its first five attempts, each a jump. Built from plain
/// stacks, not a List, so the Overview page can embed it in its own scroll view.
struct ProcedureSummaryView: View {
    var flow: Flow
    var onJump: (Int) -> Void
    @State private var opened: String?
    @State private var showAll: Set<String> = []
    /// Masked unless the call-flow page says the session revealed identifiers; embedded elsewhere it stays masked.
    @Environment(\.callFlowReveal) private var reveal

    /// Attempts listed under an opened kind before "Show all": a phone retrying all night makes hundreds.
    static let instancesListed = 5

    var body: some View {
        let groups = CallFlowPresentation.procedureGroups(flow)
        VStack(alignment: .leading, spacing: 0) {
            Text(headline(groups))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(Array(groups.enumerated()), id: \.element.name) { i, group in
                if i > 0 { Divider() }
                groupRow(group)
                if opened == group.name, group.items.count > 1 {
                    instances(group)
                }
            }
        }
        .accessibilityIdentifier("procedureSummary")
    }

    /// "34 procedures, all answered", or what went wrong: "2 failed, 1 with no answer, of 12 procedures".
    private func headline(_ groups: [CallFlowPresentation.ProcedureGroup]) -> String {
        let failed = groups.reduce(0) { $0 + $1.failed }
        let unanswered = groups.reduce(0) { $0 + $1.unanswered }
        let n = flow.procedures.count
        if n == 0 { return "No procedures in this capture." }
        if failed == 0, unanswered == 0 { return "\(n) procedure\(n == 1 ? "" : "s"), all answered." }
        let parts = [failed > 0 ? "\(failed) failed" : nil, unanswered > 0 ? "\(unanswered) with no answer" : nil]
        return parts.compactMap { $0 }.joined(separator: ", ") + " of \(n) procedures."
    }

    private func groupRow(_ group: CallFlowPresentation.ProcedureGroup) -> some View {
        let single = group.items.count == 1
        let look = CallFlowStyle.outcome(group.worst)
        return Button {
            if single {
                onJump(group.items[0].first)
            } else {
                withAnimation(.snappy) { opened = opened == group.name ? nil : group.name }
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: look.symbol).font(.title3).foregroundStyle(look.color)
                    .accessibilityLabel(look.word)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(CallFlowStyle.layer(group.layer)).frame(width: 6, height: 6)
                        Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                    if single {
                        let only = group.items[0]
                        if let detail = only.detail.map(display) {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let refusal = only.refusal.map(display) {
                            Text(refusal).font(.caption).foregroundStyle(CallFlowStyle.failure).lineLimit(2)
                        }
                    } else {
                        HStack(spacing: 10) {
                            if group.succeeded > 0 { count("\(group.succeeded) succeeded", CallFlowStyle.success) }
                            if group.failed > 0 { count("\(group.failed) failed", CallFlowStyle.failure) }
                            if group.unanswered > 0 { count("\(group.unanswered) no answer", CallFlowStyle.unanswered) }
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    let time = shownTime(group)
                    Text(time.map { single ? CallFlowPresentation.duration($0) : "median " + CallFlowPresentation.duration($0) } ?? "—")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(time == nil ? .secondary : single && group.failed > 0 ? CallFlowStyle.failure : .primary)
                    if !single {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(opened == group.name ? 180 : 0))
                    }
                }
            }
            .frame(minHeight: 48)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("procedureGroup-\(group.name)")
        .accessibilityHint(single ? "Shows it in the call flow" : opened == group.name ? "Hides the attempts" : "Lists the attempts")
    }

    /// One attempt shows its own time, answered or refused; several show the median of the successes. A switch-off
    /// detach closes the moment it is sent, and "0.0 ms" would be a time nobody measured.
    private func shownTime(_ group: CallFlowPresentation.ProcedureGroup) -> Double? {
        let time: Double?
        if group.items.count == 1 {
            let only = group.items[0]
            time = only.outcome == .UNANSWERED ? nil : only.durationMs
        } else {
            time = group.medianMs
        }
        return time.flatMap { $0 >= 0.05 ? $0 : nil }
    }

    @ViewBuilder private func instances(_ group: CallFlowPresentation.ProcedureGroup) -> some View {
        let all = showAll.contains(group.name)
        let listed = all ? group.items : Array(group.items.prefix(Self.instancesListed))
        ForEach(Array(listed.enumerated()), id: \.offset) { _, p in
            instanceRow(p)
        }
        if group.items.count > listed.count {
            Button("Show all \(group.items.count)") { withAnimation(.snappy) { _ = showAll.insert(group.name) } }
                .font(.footnote.weight(.semibold))
                .padding(.leading, 30)
                .padding(.vertical, 8)
                .accessibilityIdentifier("procedureShowAll-\(group.name)")
        }
    }

    private func instanceRow(_ p: Procedure) -> some View {
        let look = CallFlowStyle.outcome(p.outcome)
        let atMs = flow.events.indices.contains(p.first) ? flow.events[p.first].sinceStartMs : 0
        return Button { onJump(p.first) } label: {
            HStack(spacing: 8) {
                Image(systemName: look.symbol).font(.footnote).foregroundStyle(look.color)
                    .accessibilityLabel(look.word)
                Text(CallFlowPresentation.sinceStart(atMs)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Text((p.refusal ?? p.detail).map(display) ?? "")
                    .font(.caption)
                    .foregroundStyle(p.refusal != nil ? CallFlowStyle.failure : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(p.outcome == .UNANSWERED ? "—" : CallFlowPresentation.duration(p.durationMs))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(look.color)
            }
            .padding(.leading, 30)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows it in the call flow")
    }

    private func display(_ s: String) -> String { reveal ? s : Redaction.scrub(s) }

    private func count(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.monospacedDigit()).foregroundStyle(color)
    }
}
