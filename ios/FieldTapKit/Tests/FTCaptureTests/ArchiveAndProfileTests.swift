import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTCapture

@Suite struct BasebandArchiveTests {
    static let name = "sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84.tar.gz"

    @Test func archiveNamesAndPaths() throws {
        let trigger = try #require(BasebandArchive.triggerDate(archiveName: Self.name))
        #expect(trigger == (try Date("2026-09-21T19:41:47Z", strategy: .iso8601)))
        #expect(BasebandArchive.zoneOffsetSeconds(archiveName: Self.name) == -4 * 3_600)
        #expect(BasebandArchive.zoneOffsetSeconds(archiveName: "sysdiagnose_2026.09.21_15-41-47+0530_x") == 5 * 3_600 + 1_800)
        #expect(BasebandArchive.triggerDate(archiveName: "capture.tar.gz") == nil)
        let chunk = "sysdiagnose_x/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss/0x0000006F.bin"
        #expect(BasebandArchive.isQdssFile(chunk))
        #expect(!BasebandArchive.isQdssFile("sysdiagnose_x/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss/._0x0000006F.bin"))
        #expect(!BasebandArchive.isQdssFile("sysdiagnose_x/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss/header.qmdl2"))
        #expect(BasebandArchive.traceDirName(chunk) == "log-bb-2026-09-21-15-42-33-844-qdss")
        #expect(BasebandArchive.isTraceMetadata("sysdiagnose_x/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss/info.txt"))
        #expect(!BasebandArchive.isTraceMetadata("sysdiagnose_x/logs/Baseband/log-bb-2026-09-21-15-42-33-844-qdss/Default.dmc"))
        #expect(BasebandArchive.isAmbtoolLog("sysdiagnose_x/logs/Baseband/ambtool_output.log"))
        #expect(BasebandArchive.isProfileStub("sysdiagnose_x/logs/MCState/Shared/profile-ab.stub"))
        #expect(!BasebandArchive.isProfileStub("sysdiagnose_x/logs/MCState/Shared/._profile-ab.stub"))
        #expect(BasebandArchive.isProfileEvents("sysdiagnose_x/logs/MCState/Shared/MCProfileEvents.plist"))
    }

    @Test func traceWindowRelativeToThePress() throws {
        let info = """
        File: 0x00000000.bin
        Starting From: 2026-09-21-15-41-45
        Size (Bytes): 10
        File: 0x00000001.bin
        Starting From: 2026-09-21-15-42-06
        Size (Bytes): 10
        File: 0x00000002.bin
        Starting From: 2026-09-21-15-42-30
        Size (Bytes): 10
        """
        let t = try #require(BasebandArchive.traceTiming(infoTxt: info, archiveName: Self.name,
                                                         traceDirName: "log-bb-2026-09-21-15-42-33-844-qdss",
                                                         keptChunks: ["0x00000001.bin", "0x00000002.bin"]))
        #expect(t.listedFiles == 3 && t.keptFiles == 2 && t.overwrittenFiles == 1)
        let w = try #require(t.windowAfterPressMs)
        #expect(w.startMs == 19_000)
        #expect(abs(w.endMs - 46_844) < 0.5)
        // Without the directory name, the window ends at the last kept file's start.
        let bare = try #require(BasebandArchive.traceTiming(infoTxt: info, archiveName: Self.name, traceDirName: nil,
                                                            keptChunks: ["0x00000001.bin", "0x00000002.bin"]))
        #expect(bare.windowAfterPressMs?.endMs == 43_000)
    }

    /// The user's info.txt: 241 files listed, the newest 130 kept, 19 to 46.8 s after the press (R2).
    @Test(.fixture("baseband-meta/info.txt")) func userTraceTiming() throws {
        guard let url = Fixtures.require("baseband-meta/info.txt") else { return }
        let info = try String(contentsOf: url, encoding: .utf8)
        let listed = BasebandArchive.traceListing(infoTxt: info, archiveName: Self.name).map(\.name)
        #expect(listed.count == 241)
        let t = try #require(BasebandArchive.traceTiming(infoTxt: info, archiveName: Self.name,
                                                         traceDirName: "log-bb-2026-09-21-15-42-33-844-qdss",
                                                         keptChunks: Set(listed.suffix(130))))
        #expect(t.overwrittenFiles == 111)
        let w = try #require(t.windowAfterPressMs)
        #expect(CaptureWording.pressWindow(w) == "covers 0:19–0:46 after you pressed the buttons")
    }
}

@Suite struct ProfileStubTests {
    static func plist(_ d: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0)
    }

    @Test func readsOnlyTheBasebandProfile() throws {
        let install = try Date("2026-09-21T19:40:06Z", strategy: .iso8601)
        let removal = install.addingTimeInterval(7 * 86_400)
        let stub: [String: Any] = [
            "PayloadIdentifier": "com.apple.basebandlogging", "PayloadDisplayName": "Baseband and Telephony Logging",
            "InstallDate": install, "RemovalDate": removal,
            "ConsentText": ["default": "The logs will expire after 7 days."],
        ]
        let p = try #require(ProfileStubReader.read(try Self.plist(stub), observedAt: install.addingTimeInterval(86_400)))
        #expect(p.consentDays == 7 && p.lifetimeDays == 7 && p.status == .active)
        #expect(p.displayName == "Baseband and Telephony Logging")
        #expect(p.daysLeft(at: install.addingTimeInterval(86_400)) == 6)
        var other = stub
        other["PayloadIdentifier"] = "com.example.vpn"
        #expect(ProfileStubReader.read(try Self.plist(other), observedAt: nil) == nil)
        #expect(ProfileStubReader.read(Data("not a plist".utf8), observedAt: nil) == nil)
    }

    /// Status relative to the archive's time, and a plain-string consent text (older copies: 21 days).
    @Test func statusIsRelativeToTheArchive() throws {
        let install = try Date("2025-05-01T10:00:00Z", strategy: .iso8601)
        let removal = install.addingTimeInterval(21 * 86_400)
        let data = try Self.plist(["PayloadIdentifier": "com.apple.basebandlogging", "InstallDate": install,
                                   "RemovalDate": removal, "ConsentText": "Logs expire after 21 days."])
        #expect(ProfileStubReader.read(data, observedAt: removal.addingTimeInterval(60))?.status == .expired)
        #expect(ProfileStubReader.read(data, observedAt: removal.addingTimeInterval(-3_600))?.status == .expiringSoon)
        let p = try #require(ProfileStubReader.read(data, observedAt: install))
        #expect(p.status == .active && p.lifetimeDays == 21)
        #expect(p.consentDays == 21)
    }

    @Test(.fixture("profile")) func profileStubFromUserArchive() throws {
        guard let dir = Fixtures.require("profile") else { return }
        let stubs = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".stub") && !$0.hasPrefix("._") }
        let url = dir.appendingPathComponent(try #require(stubs.first))
        let trigger = try Date("2026-09-21T19:41:47Z", strategy: .iso8601)
        let p = try #require(ProfileStubReader.read(try Data(contentsOf: url), observedAt: trigger))
        #expect(p.identifier == "com.apple.basebandlogging")
        #expect(p.installDate == (try Date("2026-09-21T19:40:06Z", strategy: .iso8601)))
        #expect(p.removalDate == (try Date("2026-09-28T19:40:02Z", strategy: .iso8601)))
        #expect(abs((p.lifetimeDays ?? 0) - 7.0) < 0.001)
        #expect(p.consentDays == 7)
        #expect(p.status == .active)
    }
}
