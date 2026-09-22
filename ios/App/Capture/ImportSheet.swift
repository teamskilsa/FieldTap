import SwiftUI
import UIKit
import FTApp
import FTCapture
import FTJourney
import FTModel

/// Import progress and result. Shows `app.importPreview` instead of importing when a launch argument set one.
///
/// Stages with honest progress (the archive scan cannot know its total, so it shows the trace files found), then
/// a result card that confirms the capture worked, or problem cards that say why not. When the archive had no
/// modem trace, the setup steps appear right here (R1 b).
struct ImportSheet: View {
    var url: URL
    var securityScoped: Bool
    @Bindable var app: AppModel
    @State private var coordinator: ImportCoordinator?
    @State private var setupStep = 0
    @State private var openedAt = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    content
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if state.isRunning {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { coordinator?.cancel() }
                            .disabled(!state.canCancel)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { close() }.accessibilityIdentifier("importDone")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(state.isRunning)
        .task {
            guard app.importPreview == nil, coordinator == nil else { return }
            let c = ImportCoordinator(app: app)
            coordinator = c
            await c.run(url: url, securityScoped: securityScoped)
        }
    }

    private var state: ImportState { app.importPreview ?? coordinator?.state ?? .idle }

    /// The file being imported; a DEBUG preview names the loaded fixture's archive instead of its folder.
    private var archiveName: String {
        if app.importPreview != nil, let name = app.latest?.sourceName { return name }
        return url.lastPathComponent
    }

    private var title: String {
        switch state {
        case .idle, .running: "Importing"
        case .finished(let s): s.hasTrace ? "Capture ready" : "No modem trace"
        case .failed(let list):
            list.contains { $0.meansNoTrace && $0 != .notASysdiagnose && $0 != .truncatedArchive } ? "No modem trace" : "Couldn't import"
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            ImportStages(progress: ImportProgress(stage: .reading, fraction: 0), started: openedAt, archive: archiveName)
        case .running(let p):
            ImportStages(progress: p, started: coordinator?.startedAt ?? openedAt, archive: archiveName)
        case .finished(let summary):
            if summary.hasTrace {
                ImportResultCard(summary: summary) { open(summary) }
                ForEach(ProblemCopy.cards(for: summary.problems), id: \.self) { copy in
                    ProblemCard(copy: copy, showGuide: { showGuide() })
                }
            } else {
                problems(summary.problems, guide: GuideState.from(latest: summary, now: .now))
            }
        case .failed(let list):
            problems(list, guide: ProblemCopy.guideState(for: list))
        }
    }

    /// The problem cards, and when their fix is the setup, the setup steps themselves.
    @ViewBuilder private func problems(_ list: [ImportProblem], guide: GuideState?) -> some View {
        let embed = guide?.needsAttention ?? false
        let fix: (() -> Void)? = embed ? nil : { showGuide() }
        ForEach(ProblemCopy.cards(for: list), id: \.self) { copy in
            ProblemCard(copy: copy, showGuide: fix)
        }
        if let guide, embed {
            StepFlow(title: ModemLoggingGuideView.setupTitle(guide), steps: GuideContent.setup(lifetimeDays: 7), index: $setupStep) {
                close()
            }
            .onAppear { setupStep = GuideContent.setupStart(for: guide) }
            StepList(title: "Then record a problem", steps: GuideContent.capture, footnote: TimingNote.short)
        }
    }

    private func close() {
        app.pendingImport = nil
        app.importPreview = nil
    }

    private func showGuide() {
        close()
        app.tab = .guide
    }

    private func open(_ summary: CaptureSummary) {
        close()
        Task { await app.show(summary.id) }
    }
}

extension ImportState {
    var isRunning: Bool {
        if case .running = self { return true }
        return self == .idle
    }

    /// Cancel is offered while the archive is read and the trace rebuilt; saving is quick and not interrupted.
    var canCancel: Bool {
        switch self {
        case .idle: true
        case .running(let p): [.reading, .extracting, .deframing].contains(p.stage)
        default: false
        }
    }
}

/// The stages in the order an import goes through them (the importer saves before the coordinator decodes).
struct ImportStages: View {
    var progress: ImportProgress
    var started: Date
    var archive: String

    static let order: [ImportStage] = [.reading, .extracting, .deframing, .saving, .decoding]

    static func name(_ s: ImportStage) -> String {
        switch s {
        case .reading: "Reading the archive"
        case .extracting: "Finding the modem trace"
        case .deframing: "Rebuilding the modem log"
        case .saving: "Saving the trace"
        case .decoding: "Decoding calls and radio"
        case .done: "Done"
        }
    }

    var body: some View {
        let current = Self.order.firstIndex(of: progress.stage) ?? Self.order.count
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(archive).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    Text(CaptureWording.minutesSeconds(ctx.date.timeIntervalSince(started)))
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(Self.order.enumerated()), id: \.element) { i, stage in
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if i < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        } else if i == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.name(stage)).font(.body.weight(i == current ? .semibold : .regular))
                            .foregroundStyle(i > current ? .secondary : .primary)
                        if i == current {
                            if progress.fraction >= 0 {
                                ProgressView(value: min(1, progress.fraction)).tint(Theme.accent)
                            }
                            if !progress.detail.isEmpty {
                                Text(progress.detail).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("Keep FieldTap open. The sysdiagnose stays where it is; FieldTap keeps only the modem trace.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("importStages")
    }
}

/// What the import produced, confirming it worked: trace length and records, the window after the press, the
/// encrypted census and the profile's dates.
struct ImportResultCard: View {
    var summary: CaptureSummary
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Modem trace found", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            row("waveform.path.ecg", traceLine)
            if let w = summary.traceWindowAfterPressMs {
                let overwritten = CaptureWording.overwritten(summary.overwrittenFiles, listed: summary.listedFiles)
                row("timer", "It " + CaptureWording.pressWindow(w) + (overwritten.map { "; \($0)" } ?? "")
                    + ". Timing is based on early tests.")
            }
            if summary.secure.records > 0 {
                row("lock", "\(summary.secure.records.formatted()) records encrypted by the modem (\(summary.secure.codes) codes), not readable")
            }
            if let p = summary.profile, let install = p.installDate, let removal = p.removalDate {
                row("person.badge.shield.checkmark",
                    "Apple profile: installed \(ModemLoggingStatus.format(install)), expires \(ModemLoggingStatus.format(removal))")
            }
            if let digest = summary.digest {
                row("point.topleft.down.to.point.bottomright.curvepath", digest)
            }
            Button(action: open) {
                Label("Open capture", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle()).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("openCapture")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("importResult")
    }

    private var traceLine: String {
        var parts = ["Modem trace"]
        if let ms = summary.durationMs, ms > 0 { parts.append(String(format: "%.1f s", ms / 1_000)) }
        if let d = summary.deframe {
            parts.append("\(d.logRecords.formatted()) records, \(d.distinctCodes) codes")
        }
        return parts.count == 1 ? "Modem trace saved" : parts[0] + " " + parts.dropFirst().joined(separator: ", ")
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Runs one import: importer, then Analyzer, then the summary's digest and preview, then the store.
@Observable @MainActor
final class ImportCoordinator {
    var state: ImportState = .idle
    private(set) var startedAt = Date()
    let app: AppModel
    private var job: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    func run(url: URL, securityScoped: Bool) async {
        startedAt = Date()
        state = .running(ImportProgress(stage: .reading, fraction: 0))
        let job = Task { await perform(url: url, securityScoped: securityScoped) }
        self.job = job
        await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
    }

    func cancel() { job?.cancel() }

    private func perform(url: URL, securityScoped: Bool) async {
        // A 400 MB import takes seconds; keep going if the user switches apps, and stop cleanly if iOS says no.
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Import sysdiagnose") { [weak self] in
            MainActor.assumeIsolated { self?.cancel() }
        }
        defer { UIApplication.shared.endBackgroundTask(background) }
        do {
            let imported = try await app.importer.importArchive(at: url, securityScoped: securityScoped) { [weak self] p in
                Task { @MainActor in self?.advance(p) }
            }
            var summary = imported.summary
            if summary.hasTrace {
                advance(ImportProgress(stage: .decoding, fraction: -1, detail: "\(imported.records.count.formatted()) records"))
                let records = imported.records, base = summary
                let analysis = await Task.detached(priority: .userInitiated) {
                    Analyzer.analyze(records: records, summary: base)
                }.value
                summary.durationMs = analysis.summary.durationMs
                if let d = JourneyDigest.of(analysis.journey) {
                    summary.digest = d.digest
                    summary.preview = d.preview
                }
                try? app.store.update(summary)
            }
            app.refresh()
            if UserDefaults.standard.bool(forKey: "ft.reminder.expiry"), let p = summary.profile {
                await ProfileReminder.scheduleExpiry(p)
            }
            state = .finished(summary)
        } catch is CancellationError {
            app.refresh()
            app.pendingImport = nil
        } catch let failure as ImportFailure {
            state = .failed(failure.problems)
        } catch {
            state = .failed([.unsupportedTrace(error.localizedDescription)])
        }
    }

    /// Progress arrives from the importer's thread; stages only move forward.
    private func advance(_ p: ImportProgress) {
        guard case .running(let now) = state, p.stage != .done else { return }
        let order = ImportStages.order
        if let a = order.firstIndex(of: now.stage), let b = order.firstIndex(of: p.stage), b < a { return }
        state = .running(p)
    }
}
