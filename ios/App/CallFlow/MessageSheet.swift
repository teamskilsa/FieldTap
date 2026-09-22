import SwiftUI
import UIKit
import FTApp
import FTModel
import FTPresentation

/// One message, opened: direction, layer and channel; when; the cell; every decoded field; its security; and its
/// bytes. Everything comes from MessageSheetModel, so identifiers are masked here, in Copy and in Share unless the
/// user reveals them for the session, and the bytes stay hidden while they are masked (an Identity response
/// carries the IMEISV there and nowhere else).
struct MessageSheet: View {
    var event: Event
    @Bindable var session: CaptureSession
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(\.dismiss) private var dismiss
    /// Previous and Next move within the sheet; nil shows `event`.
    @State private var shown: Int?
    @State private var confirmReveal = false
    @State private var copied = false
    @State private var detent: PresentationDetent = .medium

    /// Which sheet sections come first: on a half-height sheet the decoded fields matter most.
    private static let order = ["Decoded", "Cell", "Security", "When"]

    var body: some View {
        let flow = session.analysis.flow
        let current = shown.flatMap { flow.events.indices.contains($0) ? flow.events[$0] : nil } ?? event
        let model = MessageSheetModel(event: current, flow: flow, reveal: session.reveal)
        let order = ladderOrder(flow)
        let position = order.firstIndex(of: current.index)
        let sections = model.sections.sorted {
            (Self.order.firstIndex(of: $0.title) ?? 99) < (Self.order.firstIndex(of: $1.title) ?? 99)
        }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading(model, current)
                    ForEach(sections, id: \.title) { section in
                        SheetSection(title: section.title) {
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                                KeyValueRow(line: line, emphasised: line.label == "Cause")
                            }
                            if let note = section.note {
                                Text(note).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
                            }
                        }
                    }
                    bytes(model)
                    Text(model.source).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button { go(order, position.map { $0 - 1 }) } label: {
                            Label("Previous", systemImage: "chevron.up").frame(maxWidth: .infinity)
                        }
                        .disabled(position.map { $0 == 0 } ?? true)
                        Button { go(order, position.map { $0 + 1 }) } label: {
                            Label("Next", systemImage: "chevron.down").frame(maxWidth: .infinity)
                        }
                        .disabled(position.map { $0 + 1 >= order.count } ?? true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .navigationTitle(position.map { "Message \($0 + 1) of \(order.count)" } ?? "Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = model.copyText
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("messageCopy")
                    ShareLink(item: model.copyText, subject: Text(model.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("messageShare")
                }
            }
            .sensoryFeedback(.success, trigger: copied) { _, new in new }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
            .confirmationDialog("Show identifiers for this session?", isPresented: $confirmReveal, titleVisibility: .visible) {
                Button("Show identifiers", role: .destructive) {
                    session.reveal = true
                    app?.revealIdentifiers = true
                }
            } message: {
                Text("The phone number, IMSI, IMEI and IP addresses in this capture will be visible, and Copy and "
                     + "Share will include them. They are hidden again when FieldTap restarts.")
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .accessibilityIdentifier("messageSheet")
        .task { openLargeForDebug() }
    }

    /// DEBUG/Harness: `-FTSheetDetent large` opens the sheet full height, for screenshots of every section.
    private func openLargeForDebug() {
        #if DEBUG || FT_HARNESS
        if UserDefaults.standard.string(forKey: "FTSheetDetent") == "large" { detent = .large }
        #endif
    }

    private func heading(_ model: MessageSheetModel, _ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(model.tags.enumerated()), id: \.offset) { i, tag in
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(i == 0 ? CallFlowStyle.layer(event.layer) : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().strokeBorder(i == 0 ? CallFlowStyle.layer(event.layer).opacity(0.6)
                                                                  : Color(uiColor: .separator)))
                }
            }
            Text(model.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(model.isFailure ? CallFlowStyle.failure : .primary)
                .accessibilityAddTraits(.isHeader)
            if let summary = model.summary {
                Text(summary).font(.subheadline).foregroundStyle(model.isFailure ? CallFlowStyle.failure : .secondary)
            }
            if let carried = model.carriedIn {
                Text(carried).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func bytes(_ model: MessageSheetModel) -> some View {
        SheetSection(title: model.bytesTitle) {
            if let dump = model.hexDump {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(dump)
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize()
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground)))
                .padding(.top, 6)
                .accessibilityLabel("Hex dump")
            }
            if let note = model.bytesNote {
                Label {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: model.bytesVisible ? "doc" : "eye.slash").foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                .accessibilityIdentifier("bytesNote")
            }
            Group {
                if session.reveal {
                    Button("Hide identifiers") {
                        session.reveal = false
                        app?.revealIdentifiers = false
                    }
                } else {
                    Button("Show identifiers…") { confirmReveal = true }
                        .accessibilityIdentifier("showIdentifiers")
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.top, 6)
        }
    }

    /// The messages in ladder order under the page's filter, the way Previous and Next step (folded ones too).
    private func ladderOrder(_ flow: Flow) -> [Int] {
        CallFlowPresentation.rows(flow, session.filter).flatMap(\.events).map(\.index)
    }

    private func go(_ order: [Int], _ position: Int?) {
        guard let position, order.indices.contains(position) else { return }
        let index = order[position]
        shown = index
        session.cursor.set(session.analysis.flow.events[index].sinceStartMs)
    }
}

/// A titled block of the sheet, as the Android sheet draws one: small caps title, a rule, then the rows.
private struct SheetSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            Divider()
            content
        }
    }
}

/// Label on the left (42%), value on the right, nested fields indented: dense enough that a half-height sheet
/// shows a whole NAS message.
private struct KeyValueRow: View {
    var line: MessageSheetModel.Line
    var emphasised: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(line.depth) * 14)
                .containerRelativeFrame(.horizontal, alignment: .leading) { w, _ in w * 0.42 }
            Text(line.value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(emphasised ? CallFlowStyle.failure : line.value.contains(Redaction.masked) ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
