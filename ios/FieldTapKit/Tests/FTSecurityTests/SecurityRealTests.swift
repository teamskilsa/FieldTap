// The real iPhone capture MUST come back clean: a legitimate network must never be flagged. This loads
// ios/Fixtures/local (git-ignored, capture-derived) through the same FixtureLoader the app and harness use,
// which runs the records through the Analyzer — the security report is what the Security screen shows. It skips
// when the fixture is absent (a machine without the capture) and, under FT_REQUIRE_FIXTURES=1, records a failure
// instead, so a skipped run never passes for a real one.

import Foundation
import Testing
import FTApp
import FTModel
import FTSecurity
import FTTestSupport

struct SecurityRealTests {
    @Test(.fixture("iphone-recovered.qmdl"))
    func realCaptureIsTrusted() throws {
        guard let dir = Fixtures.root, Fixtures.require("iphone-recovered.qmdl") != nil else { return }
        let analysis = try FixtureLoader.load(dir: dir)

        // The Analyzer fills `security` after the journey stage; it is what the Security screen renders.
        let report = try #require(analysis.security, "the analyzer must attach a security report")
        let fired = report.allFindings
        #expect(report.verdict == .trusted,
                "expected a clean capture, got \(report.verdict) with [\(fired.map { "\($0.check): \($0.evidence.joined(separator: "; "))" }.joined(separator: " | "))]")
        #expect(fired.isEmpty, "no findings on a legitimate network, got \(fired.count)")
        #expect(!report.headline.isEmpty)
        #expect(report.ruleset == "fieldtap-security/1")

        // Recomputing directly from the analysis gives the same verdict (the report is a pure function of it).
        #expect(SecurityDetector.analyze(analysis).verdict == .trusted)
    }
}
