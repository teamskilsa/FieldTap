import Foundation
import FTModel
import FTPresentation
import FTCapture

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
    /// The live profile probe's last result (TestFlight builds; a public-API metadata read of the CommCenter
    /// logging plist). `.unavailable` on the simulator and on any device where the path is not readable, so
    /// the guide falls back to the import-derived state. Refreshed at launch and on foreground.
    public private(set) var liveProfile: ProfileProbeStatus = .unavailable(reason: .notFound(code: 0))
    /// DEBUG/Harness: -FTLiveProbe, a stub live-probe result so the "logging is on" screenshot can be taken
    /// without the real system path (which the simulator lacks). Never set in a normal build.
    public var liveProbeOverride: ProfileProbeStatus?
    /// DEBUG/Harness: -FTCaptureNoticed, force the SysdiagnoseWatcher's "we noticed a capture" banner.
    public var noticedCaptureDemo = false

    public init(store: any CaptureStoring, importer: any CaptureImporting) {
        self.store = store
        self.importer = importer
    }

    /// The newest import: the evidence the Modem logging guide works from.
    public var latest: CaptureSummary? { captures.first }

    /// Re-runs the live profile probe (or applies the debug override). Cheap: one FileManager metadata call.
    public func refreshLiveProbe(metadata: any PathMetadataReading = RealPathMetadata()) {
        liveProfile = liveProbeOverride ?? LiveProfileProbe.probe(metadata: metadata)
    }

    /// The Modem logging guide's state at `now` (R1). A launch override wins; otherwise the import-derived
    /// state, with the live device probe folded in only when there is no usable import (the `.unknown`
    /// placeholder), per `LiveGuideResolver`.
    public func guideState(now: Date = .now) -> GuideState { resolveGuide(now: now).state }

    /// The resolved guide state plus whether it came from the live device probe (for the "detected on this
    /// iPhone" note on the status card).
    public func resolveGuide(now: Date = .now) -> LiveGuideResolver.Resolved {
        if let override = guideOverride { return .init(state: override, isLive: false) }
        return LiveGuideResolver.resolve(imported: GuideState.from(latest: latest, now: now),
                                         live: liveProfile, now: now)
    }

    /// The profile the expiry reminder is scheduled from: a real import stub (its removal date is exact) when
    /// present, otherwise the live device probe synthesised into a `ProfileState`.
    public var reminderProfile: ProfileState? {
        if let p = latest?.profile, p.removalDate != nil { return p }
        if case .live(let installed) = liveProfile { return LiveProfileProbe.syntheticProfile(installed: installed) }
        return latest?.profile
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

    /// Picks up a sysdiagnose the FieldTapShare extension dropped in the App Group Inbox and starts the normal
    /// import for it, so the customer does not have to open Files and pick the file again. Safe to call on launch
    /// and on every foreground: a no-op when the App Group is empty or an import is already open, and one capture
    /// is never imported twice (`SharedInboxIngest.claimNext` moves it out of the shared Inbox as it claims it).
    public func ingestSharedInbox() {
        guard pendingImport == nil, importPreview == nil else { return }
        guard let shared = SharedInbox.inboxURL() else { return }
        do {
            if let moved = try SharedInboxIngest.claimNext(fromShared: shared, into: ImportLeftovers.inboxURL) {
                // Landed in the app's own Documents/Inbox, so the importer deletes it when the import finishes.
                requestImport(moved, securityScoped: false)
            }
        } catch {
            lastError = "Could not open the shared sysdiagnose: \(error.localizedDescription)"
        }
    }

    /// DEBUG/Harness: loads a fixture folder as a capture (FixtureLoader) and lists it first.
    public func loadFixture(dir: URL) async throws {
        let analysis = try await Task.detached(priority: .userInitiated) { try FixtureLoader.load(dir: dir) }.value
        fixture = analysis
        refresh()
    }

    /// Lists a synthetic, already-analysed capture as the fixture (e.g. the built-in Security demo). Plain logic
    /// only the DEBUG/Harness launch hooks call; dead-stripped from a Release app that never references it.
    public func loadSynthetic(_ analysis: CaptureAnalysis) {
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
        if let token = plan.securityDemo {
            loadSynthetic(SecurityDemo.analysis(token))
        } else if let dir = plan.fixtureDir {
            do {
                try await loadFixture(dir: dir)
            } catch {
                lastError = "Could not load the fixture: \(error.localizedDescription)"
            }
        } else {
            refresh()
        }
        guideOverride = plan.guideState.flatMap { GuideState(token: $0, now: now) }
        switch plan.liveProbe {
        case "live": liveProbeOverride = .live(installed: now.addingTimeInterval(-2 * 86_400))
        case "unavailable": liveProbeOverride = .unavailable(reason: .notFound(code: 260))
        default: break
        }
        refreshLiveProbe()
        noticedCaptureDemo = plan.captureNoticed
        if let token = plan.importState {
            importPreview = ImportState.preview(token: token, summary: latest, now: now)
        }

        let route = plan.route ?? (plan.securityDemo != nil ? .security : (plan.needsCapture ? .overview : .captures))
        tab = route.tab
        if plan.needsCapture, let id = latest?.id, let session = await show(id) {
            if let page = route.page { session.page = page }
            if let filter = plan.filter { session.filter = filter }
            if let section = plan.radioSection { session.radioSection = section }
            if let entry = plan.radioEntry { session.radioEntry = entry }
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
