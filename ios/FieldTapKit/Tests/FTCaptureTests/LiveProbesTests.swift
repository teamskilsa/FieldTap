import Foundation
import Testing
import FTModel
@testable import FTCapture

// The live capture-status detectors' LOGIC, driven by an injected file-state stub. The real system paths do
// not exist in the simulator, so this exercises every branch the device might return — a present mod date,
// permission-denied (257), and not-found (260) — plus the graceful fallback and the watcher gate. What a
// physical iPhone on iOS 26.5.2 actually returns is device-only and must be confirmed there.

/// A `PathMetadataReading` stub that returns a fixed outcome per path.
private struct StubMetadata: PathMetadataReading {
    enum Outcome {
        case modDate(Date)
        case attributesNoDate
        case cocoa(Int)
        case posix(Int)
    }
    var outcomes: [String: Outcome]

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        switch outcomes[path] ?? .cocoa(260) {
        case .modDate(let d): return [.modificationDate: d]
        case .attributesNoDate: return [.size: 0]
        case .cocoa(let c): throw NSError(domain: NSCocoaErrorDomain, code: c)
        case .posix(let c): throw NSError(domain: NSPOSIXErrorDomain, code: c)
        }
    }
}

@Suite struct LiveProfileProbeTests {
    let plist = LiveProfileProbe.commCenterPlistPath

    @Test func liveWhenModDatePresent() {
        let installed = Date(timeIntervalSince1970: 1_790_000_000)
        let status = LiveProfileProbe.probe(metadata: StubMetadata(outcomes: [plist: .modDate(installed)]))
        #expect(status == .live(installed: installed))
        #expect(status.installDate == installed)
        // 7-day expiry from the install date.
        #expect(LiveProfileProbe.expiry(installed: installed) == installed.addingTimeInterval(7 * 86_400))
    }

    @Test func permissionDeniedIsUnavailable() {
        let cocoa = LiveProfileProbe.probe(metadata: StubMetadata(outcomes: [plist: .cocoa(257)]))
        #expect(cocoa == .unavailable(reason: .permissionDenied(code: 257)))
        let posix = LiveProfileProbe.probe(metadata: StubMetadata(outcomes: [plist: .posix(13)]))
        #expect(posix == .unavailable(reason: .permissionDenied(code: 13)))
        #expect(!cocoa.isLive)
    }

    @Test func notFoundIsUnavailable() {
        #expect(LiveProfileProbe.probe(metadata: StubMetadata(outcomes: [plist: .cocoa(260)]))
                == .unavailable(reason: .notFound(code: 260)))
        #expect(LiveProfileProbe.probe(metadata: StubMetadata(outcomes: [plist: .posix(2)]))
                == .unavailable(reason: .notFound(code: 2)))
    }

    @Test func attributesWithoutDate() {
        #expect(LiveProfileProbe.probe(metadata: StubMetadata(outcomes: [plist: .attributesNoDate]))
                == .unavailable(reason: .noModificationDate))
    }

    @Test func syntheticProfileHasSevenDayRemoval() {
        let installed = Date(timeIntervalSince1970: 1_790_000_000)
        let p = LiveProfileProbe.syntheticProfile(installed: installed, observedAt: installed.addingTimeInterval(3_600))
        #expect(p.identifier == ProfileStubReader.basebandIdentifier)
        #expect(p.removalDate == installed.addingTimeInterval(7 * 86_400))
        #expect(p.status == .active)
        // The existing reminder scheduling can read it.
        #expect(p.expiryReminderDate(now: installed) != nil)
    }
}

@Suite struct LiveGuideResolverTests {
    let now = Date(timeIntervalSince1970: 1_790_100_000)

    @Test func liveSupersedesTheUnknownPlaceholder() {
        let installed = now.addingTimeInterval(-2 * 86_400) // 2 days ago -> 5 days left
        let r = LiveGuideResolver.resolve(imported: .unknown,
                                          live: .live(installed: installed), now: now)
        #expect(r.isLive)
        if case .active(let removal) = r.state {
            #expect(removal == LiveProfileProbe.expiry(installed: installed))
        } else {
            Issue.record("expected .active, got \(r.state)")
        }
    }

    @Test func liveWithinADayIsExpiringSoon() {
        let installed = now.addingTimeInterval(-6.5 * 86_400) // 0.5 day left
        let r = LiveGuideResolver.resolve(imported: .unknown, live: .live(installed: installed), now: now)
        if case .expiringSoon = r.state { } else { Issue.record("expected .expiringSoon, got \(r.state)") }
    }

    @Test func livePastRemovalIsExpired() {
        let installed = now.addingTimeInterval(-8 * 86_400)
        let r = LiveGuideResolver.resolve(imported: .unknown, live: .live(installed: installed), now: now)
        if case .expired = r.state { } else { Issue.record("expected .expired, got \(r.state)") }
    }

    @Test func probeFailureFallsBackToImportState() {
        // Unavailable -> the import-derived state is returned untouched, not-live.
        for imported: GuideState in [.unknown, .off, .active(now.addingTimeInterval(3 * 86_400))] {
            let r = LiveGuideResolver.resolve(imported: imported,
                                              live: .unavailable(reason: .notFound(code: 260)), now: now)
            #expect(r.state == imported)
            #expect(!r.isLive)
        }
    }

    @Test func aRealImportAlwaysWinsOverLive() {
        // A non-unknown import state is stronger evidence; the live probe does not override it.
        let imported = GuideState.off
        let r = LiveGuideResolver.resolve(imported: imported,
                                          live: .live(installed: now.addingTimeInterval(-86_400)), now: now)
        #expect(r.state == .off)
        #expect(!r.isLive)
    }
}

@Suite struct SysdiagnoseWatcherProbeTests {
    let dir = SysdiagnoseWatcherProbe.sysdiagnoseDir

    @Test func existsWhenAttributesReturn() {
        let installed = Date()
        #expect(SysdiagnoseWatcherProbe.probe(metadata: StubMetadata(outcomes: [dir: .modDate(installed)])) == .exists)
    }

    @Test func permissionDeniedImpliesPresent() {
        let state = SysdiagnoseWatcherProbe.probe(metadata: StubMetadata(outcomes: [dir: .cocoa(257)]))
        #expect(state == .permissionDenied(code: 257))
        #expect(SysdiagnoseWatcherProbe.dirImpliesPresent(state))
    }

    @Test func notFoundIsAbsent() {
        let state = SysdiagnoseWatcherProbe.probe(metadata: StubMetadata(outcomes: [dir: .cocoa(260)]))
        #expect(state == .notFound(code: 260))
        #expect(!SysdiagnoseWatcherProbe.dirImpliesPresent(state))
    }

    @Test func promptGateNeedsBothSignals() {
        // Screenshot + present -> prompt.
        #expect(SysdiagnoseWatcherProbe.shouldPrompt(screenshotSeen: true, dirState: .exists))
        #expect(SysdiagnoseWatcherProbe.shouldPrompt(screenshotSeen: true, dirState: .permissionDenied(code: 257)))
        // Screenshot but the dir is absent (likely iOS 26) -> silent.
        #expect(!SysdiagnoseWatcherProbe.shouldPrompt(screenshotSeen: true, dirState: .notFound(code: 260)))
        #expect(!SysdiagnoseWatcherProbe.shouldPrompt(screenshotSeen: true, dirState: .error(code: 22)))
        // No screenshot -> silent regardless.
        #expect(!SysdiagnoseWatcherProbe.shouldPrompt(screenshotSeen: false, dirState: .exists))
    }
}

@Suite struct ProbeDiagnosticsTests {
    @Test func rendersEachProbeResult() {
        let installed = Date(timeIntervalSince1970: 1_790_000_000)
        let meta = StubMetadata(outcomes: [
            LiveProfileProbe.commCenterPlistPath: .modDate(installed),
            SysdiagnoseWatcherProbe.sysdiagnoseDir: .cocoa(257),
        ])
        let d = ProbeDiagnostics.run(metadata: meta)
        #expect(d.profileLine.hasPrefix("modification date"))
        #expect(d.sysdiagnoseLine.contains("permission-denied (257)"))
        #expect(d.profileLiveActive)
        #expect(d.sysdiagnoseWatchActive)

        let absent = ProbeDiagnostics.run(metadata: StubMetadata(outcomes: [:])) // both default to cocoa(260)
        #expect(absent.profileLine.contains("not found (error 260)"))
        #expect(absent.sysdiagnoseLine.contains("not found (260)"))
        #expect(!absent.profileLiveActive)
        #expect(!absent.sysdiagnoseWatchActive)
    }
}
