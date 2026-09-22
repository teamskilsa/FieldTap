import Foundation
import Testing
@testable import FTModel

/// R1: which Modem logging guide state the newest import implies, and the status line it shows.
@Suite struct GuideStateTests {
    static let now = Date(timeIntervalSince1970: 1_790_100_000)
    static let day: TimeInterval = 86_400

    static func profile(removalIn: TimeInterval?, status: ProfileStatus = .active) -> ProfileState {
        ProfileState(identifier: "com.apple.basebandlogging", displayName: "Baseband and Telephony Logging",
                     installDate: now.addingTimeInterval(-3 * day),
                     removalDate: removalIn.map { now.addingTimeInterval($0) }, lifetimeDays: 7, consentDays: 7,
                     status: status, observedAt: now)
    }

    static func summary(profile: ProfileState?, chunks: Int = 130, problems: [ImportProblem] = [],
                        loggingEnabled: Bool? = true) -> CaptureSummary {
        CaptureSummary(importedAt: now, sourceName: "sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84.tar.gz",
                       chunkCount: chunks, profile: profile, problems: problems, basebandLoggingEnabled: loggingEnabled)
    }

    @Test func nothingImportedYetIsUnknown() {
        #expect(GuideState.from(latest: nil, now: Self.now) == .unknown)
        #expect(!GuideState.unknown.needsAttention)
    }

    @Test func noProfileStubMeansLoggingIsOff() {
        let s = Self.summary(profile: nil, chunks: 0, problems: [.noBasebandTrace, .profileMissing])
        #expect(GuideState.from(latest: s, now: Self.now) == .off)
        #expect(GuideState.off.headline(now: Self.now, date: { _ in "x" }) == "Modem logging is off")
    }

    @Test func aRemovalDateInThePastIsExpired() {
        let s = Self.summary(profile: Self.profile(removalIn: -2 * Self.day))
        let state = GuideState.from(latest: s, now: Self.now)
        #expect(state == .expired(Self.now.addingTimeInterval(-2 * Self.day)))
        #expect(state.needsAttention)
        #expect(state.headline(now: Self.now, date: { _ in "Sep 28" }) == "Your logging profile expired on Sep 28")
    }

    @Test func withinOneDayIsExpiringSoon() {
        let s = Self.summary(profile: Self.profile(removalIn: 20 * 3_600))
        let state = GuideState.from(latest: s, now: Self.now)
        #expect(state == .expiringSoon(Self.now.addingTimeInterval(20 * 3_600)))
        #expect(state.needsAttention)
        #expect(state.headline(now: Self.now, date: { _ in "Sep 28" }) == "Logging is on until Sep 28 (less than 1 day left)")
    }

    @Test func activeShowsDaysLeft() {
        let s = Self.summary(profile: Self.profile(removalIn: 5 * Self.day + 600))
        let state = GuideState.from(latest: s, now: Self.now)
        #expect(state == .active(Self.now.addingTimeInterval(5 * Self.day + 600)))
        #expect(!state.needsAttention)
        #expect(state.headline(now: Self.now, date: { _ in "Sep 28" }) == "Logging is on until Sep 28 (5 days left)")
        let oneDay = GuideState.active(Self.now.addingTimeInterval(1.5 * Self.day))
        #expect(oneDay.headline(now: Self.now, date: { _ in "d" }) == "Logging is on until d (1 day left)")
    }

    @Test func profilePresentButNoTraceSaysRestart() {
        let noTrace = Self.summary(profile: Self.profile(removalIn: 4 * Self.day), chunks: 0, problems: [.profileInstalledNoTrace])
        #expect(GuideState.from(latest: noTrace, now: Self.now) == .installedNoTrace)
        let notEnabled = Self.summary(profile: Self.profile(removalIn: 4 * Self.day), chunks: 0, problems: [.loggingNotEnabled],
                                      loggingEnabled: false)
        #expect(GuideState.from(latest: notEnabled, now: Self.now) == .installedNoTrace)
        #expect(GuideState.installedNoTrace.headline(now: Self.now, date: { _ in "" })
            == "Profile installed but no modem trace — restart your iPhone and try again")
    }

    @Test func anExpiredProfileWinsOverAMissingTrace() {
        let s = Self.summary(profile: Self.profile(removalIn: -Self.day), chunks: 0, problems: [.noBasebandTrace])
        #expect(GuideState.from(latest: s, now: Self.now) == .expired(Self.now.addingTimeInterval(-Self.day)))
    }

    @Test func notASysdiagnoseSaysNothingAboutLogging() {
        let s = Self.summary(profile: nil, chunks: 0, problems: [.notASysdiagnose])
        #expect(GuideState.from(latest: s, now: Self.now) == .unknown)
    }

    @Test func tokensRoundTrip() {
        for token in ["off", "expired", "expiringSoon", "active", "installedNoTrace", "unknown"] {
            #expect(GuideState(token: token, now: Self.now)?.token == token)
        }
        #expect(GuideState(token: "bogus", now: Self.now) == nil)
        if case .expiringSoon(let d) = GuideState(token: "expiringSoon", now: Self.now) {
            #expect(d.timeIntervalSince(Self.now) < Self.day)
        } else {
            Issue.record("expiringSoon token")
        }
    }

    @Test func profileStatusAndDaysLeft() {
        let p = Self.profile(removalIn: 3 * Self.day + 60)
        #expect(p.status(at: Self.now) == .active)
        #expect(p.daysLeft(at: Self.now) == 3)
        #expect(p.status(at: Self.now.addingTimeInterval(3 * Self.day)) == .expiringSoon)
        #expect(p.status(at: Self.now.addingTimeInterval(4 * Self.day)) == .expired)
        #expect(p.daysLeft(at: Self.now.addingTimeInterval(9 * Self.day)) == 0)
        #expect(Self.profile(removalIn: nil, status: .missing).status(at: Self.now) == .missing)
    }
}

@Suite struct ImportStateTests {
    @Test func previewTokens() {
        let now = GuideStateTests.now
        let s = GuideStateTests.summary(profile: GuideStateTests.profile(removalIn: 86_400 * 3))
        #expect(ImportState.preview(token: "done", summary: s, now: now) == .finished(s))
        #expect(ImportState.preview(token: "done", summary: nil, now: now) == nil)
        #expect(ImportState.preview(token: "deframing", summary: nil, now: now)?.token == "deframing")
        #expect(ImportState.preview(token: "noBasebandTrace", summary: nil, now: now) == .failed([.noBasebandTrace]))
        #expect(ImportState.preview(token: "profileExpired", summary: s, now: now)
            == .failed([.profileExpired(s.profile!.removalDate!)]))
        #expect(ImportState.preview(token: "idle", summary: nil, now: now) == .idle)
        #expect(ImportState.preview(token: "nonsense", summary: nil, now: now) == nil)
    }

    @Test func problemsThatLeaveNoTrace() {
        #expect(ImportProblem.noBasebandTrace.meansNoTrace)
        #expect(ImportProblem.profileInstalledNoTrace.meansNoTrace)
        #expect(!ImportProblem.profileExpiresSoon(.now).meansNoTrace)
        #expect(ImportProblem.profileExpired(.now).token == "profileExpired")
    }
}
