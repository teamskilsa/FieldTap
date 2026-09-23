// The synthetic goldens are the contract this port matches. For each committed engine golden
// (tests/security/golden/*.security.json, copied into TestData/golden), the Swift detector must reproduce the
// same report over the equivalent synthetic input — byte for byte, checked with GoldenCodec.jsonDiff (the same
// comparator the contract uses) and, as a second read, by decoding the golden into SecurityReport and comparing
// it for equality. Each synthetic signature is also asserted to fire the right check and no others.

import Foundation
import Testing
import FTModel
import FTSecurity
import FTTestSupport

struct SecurityGoldenTests {
    /// The golden JSON copied into the test bundle (synthetic, invented data — committed in the engine).
    static func goldenURL(_ name: String) -> URL? {
        let url = Bundle.module.resourceURL?
            .appendingPathComponent("TestData/golden/\(name).security.json")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    @Test("golden parity: the Swift report reproduces each engine golden byte for byte",
          arguments: SecurityFixtures.names)
    func goldenParity(_ name: String) throws {
        guard let url = Self.goldenURL(name) else {
            Issue.record("missing bundled golden \(name).security.json")
            return
        }
        let data = try Self.encoder.encode(SecurityFixtures.make(name).report)
        // Same rules as Contract/tools/json_equal.py: objects by key set, arrays by position, numbers within
        // 1.5e-3. Nothing is ignored — every key must match.
        JSONAssert.equal(data, url, ignoring: [])

        // A second, structural read: the golden decodes into a SecurityReport equal to the computed one.
        let golden = try JSONDecoder().decode(SecurityReport.self, from: Data(contentsOf: url))
        #expect(golden == SecurityFixtures.make(name).report, "decoded golden \(name) differs from the computed report")
    }

    /// The check each fixture is built to trip; every other check must stay silent.
    static let expected: [String: SecurityCheckId?] = [
        "clean": nil,
        "null-cipher": .nullCipher,
        "imsi-in-clear": .imsiRequestedInClear,
        "downgrade-2g": .ratDowngrade,
        "accepted-without-auth": .acceptedWithoutAuth,
        "no-security-established": .noSecurityEstablished,
        "abnormal-reject": .abnormalReject,
        "implausible-signal": .implausibleSignal,
        "orphan-cell": .orphanCell,
    ]

    @Test("each synthetic signature fires exactly its own check", arguments: SecurityFixtures.names)
    func oneSignaturePerFixture(_ name: String) throws {
        let report = SecurityFixtures.make(name).report
        let fired = Set(report.allFindings.map(\.check))
        let want = Self.expected[name]!
        if let want {
            #expect(fired == Set([want]), "\(name): expected only \(want), fired \(fired)")
        } else {
            #expect(fired.isEmpty, "clean fixture must fire nothing, fired \(fired)")
            #expect(report.verdict == .trusted)
        }
    }

    @Test("the ruleset and the checks/gaps roster match the engine")
    func rosterIsStable() {
        let report = SecurityFixtures.clean().report
        #expect(report.ruleset == "fieldtap-security/1")
        #expect(report.checksRun == [.nullCipher, .noSecurityEstablished, .imsiRequestedInClear, .ratDowngrade,
                                     .acceptedWithoutAuth, .abnormalReject, .implausibleSignal, .orphanCell])
        #expect(report.gaps.map(\.check) == ["sibNeighbourList", "asSecurityAlgorithm", "sibAuthenticity"])
    }
}
