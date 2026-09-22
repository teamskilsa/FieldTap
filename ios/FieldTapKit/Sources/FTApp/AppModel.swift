import Foundation
import FTModel
import FTPresentation

/// A file the user asked to import: from the share sheet or "Open in" (copied into Documents/Inbox, not
/// security scoped) or from the Files importer (security scoped).
public struct ImportRequest: Identifiable, Hashable, Sendable {
    public var url: URL
    public var securityScoped: Bool
    public var id: URL { url }

    public init(url: URL, securityScoped: Bool) {
        self.url = url
        self.securityScoped = securityScoped
    }
}

/// App-wide state: the stored captures, the identifier setting, and what is open.
@Observable @MainActor
public final class AppModel {
    public let store: any CaptureStoring
    public let importer: any CaptureImporting
    /// Newest first.
    public private(set) var captures: [CaptureSummary] = []
    /// Masked by default. Never persisted: every launch starts masked again.
    public var revealIdentifiers = false
    /// Set by onOpenURL or the Files importer; the root view presents the import sheet for it.
    public var pendingImport: ImportRequest?
    public var tab: RootTab = .captures
    /// The capture pushed on the Captures tab.
    public var openSession: CaptureSession?
    /// The last thing that went wrong, for an alert.
    public var lastError: String?
    /// DEBUG/Harness: a capture loaded from -FTFixture. Listed first and opened like a stored one; never saved.
    public private(set) var fixture: CaptureAnalysis?
    /// DEBUG/Harness: -FTGuideState, so every R1 guide state can be shown without an archive.
    public var guideOverride: GuideState?
    /// DEBUG/Harness: -FTImportState, an import sheet state shown instead of running an import.
    public var importPreview: ImportState?
    /// True once the launch hooks have finished, so a screen report names the screen the launch asked for.
    public var launchSettled = false

    public init(store: any CaptureStoring, importer: any CaptureImporting) {
        self.store = store
        self.importer = importer
    }

    /// The newest import: the evidence the Modem logging guide works from.
    public var latest: CaptureSummary? { captures.first }

    /// The Modem logging guide's state at `now` (R1), from the newest import unless overridden.
    public func guideState(now: Date = .now) -> GuideState {
        guideOverride ?? GuideState.from(latest: latest, now: now)
    }

    /// Reloads the list from the store (and the fixture, when one is loaded).
    public func refresh() {
        do {
            let stored = try store.list().sorted { $0.importedAt > $1.importedAt }
            captures = (fixture.map { [$0.summary] } ?? []) + stored.filter { $0.id != fixture?.summary.id }
        } catch {
            captures = fixture.map { [$0.summary] } ?? []
            lastError = "Could not read the saved captures: \(error.localizedDescription)"
        }
    }

    /// The capture's analysis, built off the main actor.
    public func open(_ id: UUID) async throws -> CaptureSession {
        if let f = fixture, f.summary.id == id { return CaptureSession(analysis: f, reveal: revealIdentifiers) }
        guard let summary = captures.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        let store = self.store
        let analysis = try await Task.detached(priority: .userInitiated) {
            Analyzer.analyze(records: try store.records(for: id), summary: summary)
        }.value
        return CaptureSession(analysis: analysis, reveal: revealIdentifiers)
    }

    /// Opens a capture and pushes its detail screen; errors go to `lastError`.
    @discardableResult
    public func show(_ id: UUID) async -> CaptureSession? {
        do {
            let session = try await open(id)
            tab = .captures
            openSession = session
            return session
        } catch {
            lastError = "Could not open the capture: \(error.localizedDescription)"
            return nil
        }
    }

    public func requestImport(_ url: URL, securityScoped: Bool) {
        pendingImport = ImportRequest(url: url, securityScoped: securityScoped)
    }

    /// DEBUG/Harness: loads a fixture folder as a capture (FixtureLoader) and lists it first.
    public func loadFixture(dir: URL) async throws {
        let analysis = try await Task.detached(priority: .userInitiated) { try FixtureLoader.load(dir: dir) }.value
        fixture = analysis
        refresh()
    }

    /// Deletes every stored capture (Settings). The fixture, if any, is only forgotten.
    public func deleteAll() throws {
        for summary in try store.list() { try store.delete(summary.id) }
        if openSession != nil { openSession = nil }
        fixture = nil
        refresh()
    }

    /// Bytes under the store's root, for Settings.
    public func storageBytes() -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: store.rootURL, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Applies a launch plan (DEBUG/Harness): loads the fixture, sets the overrides, opens a capture and routes.
    public func apply(_ plan: LaunchPlan, now: Date = .now) async {
        if let dir = plan.fixtureDir {
            do {
                try await loadFixture(dir: dir)
            } catch {
                lastError = "Could not load the fixture: \(error.localizedDescription)"
            }
        } else {
            refresh()
        }
        guideOverride = plan.guideState.flatMap { GuideState(token: $0, now: now) }
        if let token = plan.importState {
            importPreview = ImportState.preview(token: token, summary: latest, now: now)
        }

        let route = plan.route ?? (plan.needsCapture ? .overview : .captures)
        tab = route.tab
        if plan.needsCapture, let id = latest?.id, let session = await show(id) {
            if let page = route.page { session.page = page }
            if let filter = plan.filter { session.filter = filter }
            if let section = plan.radioSection { session.radioSection = section }
            if let ms = plan.cursorMs { session.cursor.set(ms) }
            if let event = plan.event {
                if route == .message { session.select(event: event) } else if plan.cursorMs == nil,
                   session.analysis.flow.events.indices.contains(event) {
                    session.cursor.set(session.analysis.flow.events[event].sinceStartMs)
                }
            } else if route == .message, !session.analysis.flow.events.isEmpty {
                session.select(event: 0)
            }
        }
        if route == .importSheet {
            if importPreview == nil { importPreview = latest.map { .finished($0) } ?? .idle }
            requestImport(plan.fixtureDir ?? URL(fileURLWithPath: NSTemporaryDirectory()), securityScoped: false)
        }
    }
}
