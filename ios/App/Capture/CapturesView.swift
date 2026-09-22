import SwiftUI
import UniformTypeIdentifiers
import FTApp
import FTCapture
import FTJourney
import FTModel

/// The home tab: modem-logging status card, capture cards (newest first), and the empty-state guide (R1 a).
///
/// With nothing imported yet, the setup steps are right here. When the newest import says the profile has
/// expired or expires within a day, the Modem logging guide opens by itself, once for that state (R1 c, d).
struct CapturesView: View {
    @Bindable var app: AppModel
    @State private var showImporter = false
    @State private var showGuide = false
    @State private var confirmDelete: CaptureSummary?
    @AppStorage("ft.guide.setupStep") private var setupStep = 0
    /// The state (and removal date) the guide last opened itself for.
    @AppStorage("ft.guide.autoShownFor") private var autoShownFor = ""

    var body: some View {
        let now = Date()
        let state = app.guideState(now: now)
        List {
            Section {
                ModemLoggingStatus(state: state, profile: app.latest?.profile, now: now,
                                   onGuide: { app.tab = .guide }, onImport: { showImporter = true })
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if app.captures.isEmpty {
                Section {
                    FirstCaptureGuide(step: $setupStep) { app.tab = .guide }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            } else {
                Section("Captures") {
                    ForEach(app.captures) { summary in
                        Button {
                            if summary.hasTrace { Task { await app.show(summary.id) } } else { app.tab = .guide }
                        } label: {
                            CaptureCard(summary: summary, fixtureJourney: fixtureJourney(summary))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("captureCard")
                        .swipeActions(edge: .trailing) {
                            if isStored(summary) {
                                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = summary }
                            }
                        }
                    }
                }
            }
        }
        .listSectionSpacing(16)
        .navigationTitle("Captures")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import a sysdiagnose", systemImage: "plus") { showImporter = true }
                    .accessibilityIdentifier("importButton")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.gzip, .archive]) { result in
            if case .success(let url) = result { app.requestImport(url, securityScoped: true) }
        }
        .confirmationDialog("Delete this capture?", isPresented: deleteShown, titleVisibility: .visible,
                            presenting: confirmDelete) { summary in
            Button("Delete", role: .destructive) { delete(summary) }
        } message: { summary in
            Text("Frees \(ByteCountFormatter.string(fromByteCount: size(summary), countStyle: .file)). This cannot be undone.")
        }
        .sheet(isPresented: $showGuide) {
            NavigationStack {
                ModemLoggingGuideView(app: app)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showGuide = false } }
                    }
            }
            .environment(app)
        }
        .task {
            // An import killed part way leaves the sysdiagnose copy and the trace chunks behind: remove them.
            let scratch = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Import", isDirectory: true)
            let keep = app.pendingImport?.url
            _ = await Task.detached(priority: .utility) { ImportLeftovers.sweep(scratch: scratch, keep: keep) }.value
        }
        .task(id: autoOpenKey(state)) { autoOpenGuide(state) }
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }

    /// The fixture (DEBUG screenshots) is never stored, so it has nothing to delete.
    private func isStored(_ s: CaptureSummary) -> Bool { s.id != app.fixture?.summary.id }

    private func fixtureJourney(_ s: CaptureSummary) -> Journey? {
        guard let f = app.fixture, f.summary.id == s.id else { return nil }
        return f.journey
    }

    private func size(_ s: CaptureSummary) -> Int64 { (app.store as? CaptureStore)?.sizeBytes(of: s.id) ?? 0 }

    private func delete(_ s: CaptureSummary) {
        do {
            try app.store.delete(s.id)
        } catch {
            app.lastError = "Could not delete the capture: \(error.localizedDescription)"
        }
        confirmDelete = nil
        app.refresh()
    }

    private func autoOpenKey(_ state: GuideState) -> String {
        switch state {
        case .expired(let d), .expiringSoon(let d): "\(state.token)|\(Int(d.timeIntervalSince1970))"
        default: ""
        }
    }

    private func autoOpenGuide(_ state: GuideState) {
        let key = autoOpenKey(state)
        guard !key.isEmpty, key != autoShownFor, app.pendingImport == nil, app.tab == .captures else { return }
        autoShownFor = key
        showGuide = true
    }
}

/// One capture: when, how long, how many records, the journey digest over a mini strip, and a problems badge.
struct CaptureCard: View {
    var summary: CaptureSummary
    /// The fixture's journey, for DEBUG screenshots whose summary was not built by an import.
    var fixtureJourney: Journey?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text((summary.triggerUtc ?? summary.importedAt).formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.headline)
                Spacer()
                if !summary.hasTrace {
                    Label("No modem trace", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.severity(.warning))
                } else if let first = ProblemCopy.cards(for: summary.problems).first {
                    Label(first.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.severity(.warning))
                        .lineLimit(1)
                }
            }
            if summary.hasTrace {
                Text(facts).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                if let digest = digest {
                    Text(digest.text).font(.subheadline).lineLimit(2)
                    if let preview = digest.preview {
                        JourneyMiniStrip(preview: preview).frame(height: 24)
                    }
                }
            } else {
                Text(ProblemCopy.cards(for: summary.problems).first?.title ?? "No modem trace")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Tap to see how to turn modem logging on.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    /// "27.0 s trace · 92,133 records".
    private var facts: String {
        var parts: [String] = []
        if let t = CaptureWording.traceLength(ms: summary.durationMs) { parts.append(t) }
        if let d = summary.deframe { parts.append("\(d.logRecords.formatted()) records") }
        if parts.isEmpty { parts.append("\(summary.chunkCount) trace files") }
        return parts.joined(separator: " · ")
    }

    private var digest: (text: String, preview: JourneyPreview?)? {
        if let d = summary.digest { return (d, summary.preview) }
        if let j = fixtureJourney, let d = JourneyDigest.of(j) { return (d.digest, d.preview) }
        return nil
    }
}

/// First launch: the setup steps themselves, then what comes after (R1 a).
struct FirstCaptureGuide: View {
    @Binding var step: Int
    var openGuide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepFlow(title: "Here's how", steps: GuideContent.setup(lifetimeDays: 7), index: $step) {
                step = 0
                openGuide()
            }
            StepList(title: "Then record a problem", steps: GuideContent.capture, footnote: TimingNote.short)
            Button("Open the full guide", systemImage: "list.number", action: openGuide)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
    }
}
