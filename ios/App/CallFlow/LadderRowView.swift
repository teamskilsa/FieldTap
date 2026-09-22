import SwiftUI
import FTModel
import FTPresentation

/// One line of the ladder: a message between lanes, a cell move banner, or a procedure banner. Rows abut, so the
/// lane lines each row draws behind itself run unbroken down the screen.
struct LadderRowView: View {
    var row: LadderRow
    /// The gap to the message before, for message rows.
    var gapMs: Double?
    var highlighted: Bool
    /// The journey's annotation for a move ("Reselection, after switch-off detach"), when there is one.
    var annotation: String?

    var body: some View {
        switch row {
        case .move(let step): MoveLine(step: step, annotation: annotation)
        case .procedureStart(let p, _): ProcedureLine(procedure: p)
        case .message(let e, let repeats):
            MessageLine(event: e, repeats: repeats, mixed: row.mixed, gapMs: gapMs, highlighted: highlighted)
        }
    }
}

/// The three lane lines (phone, RAN, core) behind a row's lane area.
struct LaneLines: View {
    var body: some View {
        Canvas { ctx, size in
            for x in [CallFlowStyle.laneInset, size.width / 2, size.width - CallFlowStyle.laneInset] {
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(CallFlowStyle.lane), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The page's ground, and the highlight over it: text is set on it so the lane lines stop short of the letters.
private struct Ground: View {
    var highlighted: Bool

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if highlighted { Theme.accent.opacity(0.16) }
        }
    }
}

/// One message: the name above an arrow between lanes, and the line that matters below it. RRC runs UE to RAN,
/// NAS UE to core. Colour says the layer; failure red, and a dashed grey arrow says it could not be read.
private struct MessageLine: View {
    var event: Event
    var repeats: [Event]
    var mixed: Bool
    var gapMs: Double?
    var highlighted: Bool
    @Environment(\.callFlowReveal) private var reveal

    private var color: Color {
        event.isFailure ? CallFlowStyle.failure : event.ciphered ? .secondary : CallFlowStyle.layer(event.layer)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(CallFlowPresentation.sinceStart(event.sinceStartMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let gapMs, gapMs >= 0.05 {
                    Text("+" + CallFlowPresentation.duration(gapMs))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.leading, 12)
            .padding(.top, 6)
            .frame(width: CallFlowStyle.gutter, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(mixed ? "System information" : display(event.name))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(event.isFailure ? CallFlowStyle.failure : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !repeats.isEmpty {
                        Text("×\(repeats.count + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if event.isFailure {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(CallFlowStyle.failure)
                            .accessibilityLabel("Failure")
                    }
                    if event.protection != nil {
                        Image(systemName: "checkmark.shield").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Security protected")
                    }
                    if event.ciphered {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Ciphered")
                    }
                    // No summary line: the cell rides on the name line, so the row is one line shorter.
                    if detail == nil {
                        Spacer(minLength: 4)
                        cellChip
                    }
                }
                .padding(.horizontal, 4)
                .background(Ground(highlighted: highlighted))
                .padding(.leading, 10)
                .padding(.trailing, detail == nil ? 4 : 0)

                Arrow(event: event, color: color).frame(height: 12)

                if let detail {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(event.isFailure ? CallFlowStyle.failure : .secondary)
                            .lineLimit(2)
                            .padding(.horizontal, 4)
                            .background(Ground(highlighted: highlighted))
                        Spacer(minLength: 0)
                        cellChip
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LaneLines())
        }
        .padding(.trailing, CallFlowStyle.endPadding)
        .background(Ground(highlighted: highlighted))
        .accessibilityElement(children: .combine)
    }

    /// "B66 PCI 80" or "NR cell pending"; nothing for a run across cells, whose summary line names them.
    @ViewBuilder private var cellChip: some View {
        if let cell = event.cell, CallFlowPresentation.cellCount(event, repeats: repeats) <= 1 {
            Text(CallFlowPresentation.shortCell(cell))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(cell.isPendingNr ? AnyShapeStyle(CallFlowStyle.unanswered) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
        }
    }

    /// The summary, or the cells of a folded run that crossed cells: "B3 PCI 3, B7 PCI 2 +14".
    private var detail: String? {
        if CallFlowPresentation.cellCount(event, repeats: repeats) > 1 {
            return CallFlowPresentation.cellsOf(event, repeats: repeats)
        }
        return event.summary.map(display)
    }

    private func display(_ s: String) -> String { reveal ? s : Redaction.scrub(s) }
}

/// The arrow between lanes, pointing the way the message went.
private struct Arrow: View {
    var event: Event
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let y = size.height / 2
            let phone = CallFlowStyle.laneInset, ran = size.width / 2, core = size.width - CallFlowStyle.laneInset
            let (from, to): (CGFloat, CGFloat) = switch (event.layer, event.uplink) {
            case (.RRC, true): (phone, ran)
            case (.RRC, false): (ran, phone)
            case (.NAS, true): (phone, core)
            case (.NAS, false): (core, phone)
            }
            let head: CGFloat = 7
            let sign: CGFloat = to > from ? 1 : -1
            ctx.fill(Path(ellipseIn: CGRect(x: from - 3, y: y - 3, width: 6, height: 6)), with: .color(color))
            var line = Path()
            line.move(to: CGPoint(x: from, y: y))
            line.addLine(to: CGPoint(x: to - sign * head * 0.6, y: y))
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 2, dash: event.ciphered ? [6, 4] : []))
            var tip = Path()
            tip.move(to: CGPoint(x: to, y: y))
            tip.addLine(to: CGPoint(x: to - sign * head, y: y - head * 0.55))
            tip.addLine(to: CGPoint(x: to - sign * head, y: y + head * 0.55))
            tip.closeSubpath()
            ctx.fill(tip, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// The phone arrived on another cell: a band across the lanes, before the first message logged there, in the
/// colour the destination band has on the journey strip.
private struct MoveLine: View {
    var step: Step
    var annotation: String?

    var body: some View {
        let color = CallFlowStyle.moveColor(step.to)
        HStack(spacing: 0) {
            Spacer().frame(width: CallFlowStyle.gutter)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.left.arrow.right").font(.footnote.weight(.semibold)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    // Non-breaking spaces inside each cell, so a wrap falls between cells, never inside "PCI 235".
                    Text(CallFlowStyle.moveName(step.move) + " · "
                         + (step.from.map { nb(CallFlowPresentation.shortCell($0)) + " → " } ?? "")
                         + nb(CallFlowPresentation.shortCell(step.to)))
                        .font(.footnote.weight(.semibold))
                    if let sub = subtitle {
                        Text(sub).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .systemBackground)))
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.14)).padding(-0.5))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.6), lineWidth: 1))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(LaneLines())
        }
        .padding(.trailing, CallFlowStyle.endPadding)
        .accessibilityElement(children: .combine)
    }

    /// "739.0 MHz · Reselection, after switch-off detach".
    private var subtitle: String? {
        let parts = [CallFlowPresentation.downlinkMhz(step.to), annotation].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func nb(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }
}

/// A procedure begins: its name, a symbol and a dot for how it ended, and how long it took.
private struct ProcedureLine: View {
    var procedure: Procedure

    var body: some View {
        let look = CallFlowStyle.outcome(procedure.outcome)
        HStack(spacing: 0) {
            Spacer().frame(width: CallFlowStyle.gutter)
            HStack(spacing: 5) {
                Image(systemName: look.symbol).font(.caption2).foregroundStyle(look.color)
                Text(procedure.name.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(CallFlowStyle.layer(procedure.layer))
                    .lineLimit(1)
                if let result {
                    Text("· " + result).font(.caption2.monospacedDigit()).foregroundStyle(look.color).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
            .background(Color(uiColor: .systemBackground))
            .padding(.leading, 10)
            .padding(.top, 10)
            .padding(.bottom, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LaneLines())
        }
        .padding(.trailing, CallFlowStyle.endPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(procedure.name), \(look.word)" + (result.map { ", \($0)" } ?? ""))
    }

    /// "335 ms", "no answer", or nothing for a procedure that closed the moment it opened (a switch-off detach).
    private var result: String? {
        if procedure.outcome == .UNANSWERED { return "no answer" }
        return procedure.durationMs >= 0.05 ? CallFlowPresentation.duration(procedure.durationMs) : nil
    }
}

extension EnvironmentValues {
    /// Whether identifiers are shown on the call-flow screens (CaptureSession.reveal).
    @Entry var callFlowReveal = false
}
