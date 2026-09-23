import SwiftUI
import FTApp
import FTModel
import FTSecurity

/// The fake-base-station / IMSI-catcher check: a calm verdict banner (most captures are clean), the per-cell
/// findings with their plain-language reason and the exact decoded evidence, the honest "what this can and can't
/// catch" note, the checks that ran, and the gaps the current decode cannot cover. It reads the report the
/// Analyzer attached (`analysis.security`), recomputing it locally if an older analysis has none. Nothing here
/// touches the network — the whole check ran on this device.
struct SecurityPage: View {
    @Bindable var session: CaptureSession
    @State private var selectedFinding: String?

    private var report: SecurityReport {
        session.analysis.security ?? SecurityDetector.analyze(session.analysis)
    }

    var body: some View {
        let report = report
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VerdictBanner(report: report)

                if !report.allFindings.isEmpty {
                    section("What was found", id: "findings") {
                        VStack(spacing: 12) {
                            ForEach(report.cells) { cell in
                                CellFindingsCard(cellVerdict: cell, selected: $selectedFinding, session: session)
                            }
                            if !report.findings.isEmpty {
                                UnattachedFindingsCard(findings: report.findings, selected: $selectedFinding, session: session)
                            }
                        }
                    }
                }

                section("What this can and can't catch", id: "limits") {
                    LimitsCard()
                }

                section("Checks that ran", id: "checks") {
                    ChecksRanCard(report: report)
                }

                if !report.gaps.isEmpty {
                    section("Not yet supported", id: "gaps") {
                        GapsCard(gaps: report.gaps)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, CapturePageLayout.scrollBottomInset, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .journeyStripCollapses(with: session)
    }

    private func section<Content: View>(_ title: String, id: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .id(id)
    }
}

// MARK: - Verdict banner

private struct VerdictBanner: View {
    let report: SecurityReport

    var body: some View {
        let style = SecurityStyle.verdict(report.verdict)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: style.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(style.color)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(style.word)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(style.color)
                Text(report.headline)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(style.color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(style.color.opacity(0.25)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verdict: \(style.word). \(report.headline)")
    }
}

// MARK: - Findings

private struct CellFindingsCard: View {
    let cellVerdict: SecurityCellVerdict
    @Binding var selected: String?
    @Bindable var session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let band = cellVerdict.band {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.bandColor(band)).frame(width: 10, height: 10)
                    Text(band).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Text(SecurityStyle.cellLabel(cellVerdict.cell))
                    .font(.subheadline.weight(cellVerdict.band == nil ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(cellVerdict.band == nil ? .primary : .secondary)
                Spacer(minLength: 0)
                VerdictChip(verdict: cellVerdict.verdict)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            ForEach(Array(cellVerdict.findings.enumerated()), id: \.element.id) { i, f in
                if i > 0 { Divider().padding(.leading, 52) }
                FindingRow(finding: f, selected: selected == f.id, session: session) {
                    toggle(f)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func toggle(_ f: SecurityFinding) {
        withAnimation(.snappy(duration: 0.2)) { selected = selected == f.id ? nil : f.id }
        if let t = f.tMs { session.cursor.set(t) }
    }
}

private struct UnattachedFindingsCard: View {
    let findings: [SecurityFinding]
    @Binding var selected: String?
    @Bindable var session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Not tied to one cell")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            ForEach(Array(findings.enumerated()), id: \.element.id) { i, f in
                if i > 0 { Divider().padding(.leading, 52) }
                FindingRow(finding: f, selected: selected == f.id, session: session) {
                    withAnimation(.snappy(duration: 0.2)) { selected = selected == f.id ? nil : f.id }
                    if let t = f.tMs { session.cursor.set(t) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

private struct FindingRow: View {
    let finding: SecurityFinding
    let selected: Bool
    @Bindable var session: CaptureSession
    let onTap: () -> Void

    var body: some View {
        let color = SecurityStyle.severity(finding.severity)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: SecurityStyle.symbol(finding.check))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 6) {
                Text(finding.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.explanation).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
                if let t = finding.tMs {
                    Text(SecurityStyle.clock(t)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if selected, finding.event != nil || finding.tMs != nil {
                    Button {
                        showInCallFlow(session, event: finding.event, tMs: finding.tMs)
                    } label: {
                        Label("Show in call flow", systemImage: "arrow.left.arrow.right.square")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? Theme.accent.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show in call flow") {
            showInCallFlow(session, event: finding.event, tMs: finding.tMs)
        }
    }
}

private struct VerdictChip: View {
    let verdict: SecurityVerdict

    var body: some View {
        let style = SecurityStyle.verdict(verdict)
        Text(style.word.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(style.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(style.color.opacity(0.14)))
    }
}

// MARK: - Explanatory cards

private struct LimitsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("checkmark.circle", "A clean result means no Layer-3 anomaly was found in this capture — not that no fake base station was present.")
            row("questionmark.circle", "A sophisticated catcher that mimics a real cell can pass every check here. This is evidence to weigh, not proof.")
            row("iphone.gen3", "The whole check ran on this device. Nothing about your capture or your cells was sent anywhere.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct ChecksRanCard: View {
    let report: SecurityReport

    /// A check fired if any finding cites it.
    private var fired: Set<SecurityCheckId> { Set(report.allFindings.map(\.check)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChipFlow(spacing: 8) {
                ForEach(report.checksRun, id: \.self) { check in
                    let hit = fired.contains(check)
                    HStack(spacing: 5) {
                        Image(systemName: hit ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(hit ? Theme.severity(.warning) : Theme.accent)
                        Text(SecurityStyle.checkName(check)).font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color(.tertiarySystemGroupedBackground)))
                }
            }
            Text("Ruleset \(report.ruleset). All eight checks ran; a tick means nothing was found for it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

private struct GapsCard: View {
    let gaps: [SecurityGap]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(gaps.enumerated()), id: \.element.id) { i, gap in
                if i > 0 { Divider().padding(.leading, 14) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(SecurityStyle.gapName(gap.check)).font(.subheadline.weight(.semibold))
                    Text(gap.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

// MARK: - Chip flow (wraps onto as many lines as needed)

private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
