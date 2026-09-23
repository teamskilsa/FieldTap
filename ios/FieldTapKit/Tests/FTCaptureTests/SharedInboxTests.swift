import Foundation
import Testing
import FTModel
import FTTestSupport
@testable import FTCapture

/// The App Group hand-off the FieldTapShare extension uses: the shared-container accessor, the chunked copy the
/// extension runs on the ~400 MB file, and the app-side pickup that claims a shared sysdiagnose exactly once.
@Suite struct SharedInboxTests {
    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-share-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The container accessor names the agreed App Group, and `inboxURL` is that container's `Inbox`. (macOS
    /// hands back a Group Containers path for any identifier; an unprovisioned iOS device returns nil, which the
    /// callers already treat as "no shared inbox".)
    @Test func accessorNamesTheGroupAndInbox() {
        #expect(SharedInbox.appGroupIdentifier == "group.com.fieldtap.app")
        let group = "group.test.\(UUID().uuidString)"
        if let container = SharedInbox.containerURL(groupIdentifier: group) {
            let inbox = try? #require(SharedInbox.inboxURL(groupIdentifier: group))
            #expect(inbox?.lastPathComponent == "Inbox")
            #expect(inbox?.deletingLastPathComponent().standardizedFileURL == container.standardizedFileURL)
        } else {
            #expect(SharedInbox.inboxURL(groupIdentifier: group) == nil)
        }
    }

    /// The extension's copy is byte-for-byte and works across many small chunks (proving nothing is skipped or
    /// duplicated at the seams), and the whole file is never held at once.
    @Test func streamCopyIsExactAcrossChunks() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = Data(count: 0)
        for i in 0..<(300 * 1024) { bytes.append(UInt8(truncatingIfNeeded: i * 31 + 7)) } // ~300 KB, non-trivial
        let source = dir.appendingPathComponent("src.bin")
        try bytes.write(to: source)

        let inbox = dir.appendingPathComponent("Inbox", isDirectory: true)
        let dest = try SharedInbox.streamCopy(from: source, name: "sysdiagnose_x.tar.gz", into: inbox,
                                              chunkSize: 4096, coordinate: true)
        #expect(dest.lastPathComponent == "sysdiagnose_x.tar.gz")
        #expect(try Data(contentsOf: dest) == bytes)

        // A second copy of a different payload replaces the file cleanly (forReplacing).
        let other = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        try other.write(to: source)
        _ = try SharedInbox.streamCopy(from: source, name: "sysdiagnose_x.tar.gz", into: inbox, chunkSize: 64)
        #expect(try Data(contentsOf: dest) == other)
    }

    @Test func streamCopyMissingSourceThrows() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            try SharedInbox.streamCopy(from: dir.appendingPathComponent("nope.bin"), name: "a.tar.gz", into: dir)
        }
    }

    /// `pending` returns sysdiagnose archives newest first and ignores partial `.importing` claims.
    @Test func pendingListsArchivesNewestFirst() throws {
        let inbox = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let fm = FileManager.default
        try Data("a".utf8).write(to: inbox.appendingPathComponent("old.tar.gz"))
        try Data("b".utf8).write(to: inbox.appendingPathComponent("new.tar.gz"))
        try Data("c".utf8).write(to: inbox.appendingPathComponent("claimed.tar.gz.importing"))
        try Data("d".utf8).write(to: inbox.appendingPathComponent("notes.txt"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: 1_000)], ofItemAtPath: inbox.appendingPathComponent("old.tar.gz").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: 2_000)], ofItemAtPath: inbox.appendingPathComponent("new.tar.gz").path)

        let names = SharedInboxIngest.pending(in: inbox).map(\.lastPathComponent)
        #expect(names == ["new.tar.gz", "old.tar.gz"])
    }

    /// The core dedupe: `claimNext` moves the newest archive into the app's Documents/Inbox and removes it from
    /// the shared Inbox, so it is imported exactly once even if the app foregrounds again.
    @Test func claimNextMovesOnceAndDedupes() throws {
        let shared = Self.tempDir(), documents = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: documents) }
        let fm = FileManager.default
        let older = shared.appendingPathComponent("older.tar.gz")
        let newer = shared.appendingPathComponent("newer.tar.gz")
        try Data("older".utf8).write(to: older)
        try Data("newer".utf8).write(to: newer)
        // Fresh mtimes (both well within the stale window), older before newer, so ordering is by time.
        let base = Date()
        try fm.setAttributes([.modificationDate: base.addingTimeInterval(-100)], ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: base], ofItemAtPath: newer.path)
        let documentsInbox = documents.appendingPathComponent("Inbox", isDirectory: true)

        let first = try #require(try SharedInboxIngest.claimNext(fromShared: shared, into: documentsInbox))
        #expect(first.lastPathComponent == "newer.tar.gz")
        #expect(try Data(contentsOf: first) == Data("newer".utf8))
        #expect(!fm.fileExists(atPath: newer.path))           // moved out of the shared Inbox
        #expect(!fm.fileExists(atPath: newer.path + ".importing")) // no claim marker left behind

        // The older one is still waiting; the newer one is gone, so it cannot be taken twice.
        let second = try #require(try SharedInboxIngest.claimNext(fromShared: shared, into: documentsInbox))
        #expect(second.lastPathComponent == "older.tar.gz")
        #expect(try SharedInboxIngest.claimNext(fromShared: shared, into: documentsInbox) == nil)
    }

    /// A name already waiting in Documents/Inbox (an import in flight) is left alone, not clobbered or moved
    /// again.
    @Test func claimNextSkipsWhatIsAlreadyImporting() throws {
        let shared = Self.tempDir(), documents = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: documents) }
        let fm = FileManager.default
        let documentsInbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        try fm.createDirectory(at: documentsInbox, withIntermediateDirectories: true)
        try Data("in-flight".utf8).write(to: documentsInbox.appendingPathComponent("dup.tar.gz"))
        try Data("shared".utf8).write(to: shared.appendingPathComponent("dup.tar.gz"))

        #expect(try SharedInboxIngest.claimNext(fromShared: shared, into: documentsInbox) == nil)
        #expect(try Data(contentsOf: documentsInbox.appendingPathComponent("dup.tar.gz")) == Data("in-flight".utf8))
    }

    /// Interrupted claims (`*.importing`) and forgotten ~400 MB archives are swept, so the App Group does not
    /// fill up.
    @Test func claimNextSweepsStale() throws {
        let shared = Self.tempDir(), documents = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: documents) }
        let fm = FileManager.default
        let leftover = shared.appendingPathComponent("crash.tar.gz.importing")
        let ancient = shared.appendingPathComponent("ancient.tar.gz")
        try Data("x".utf8).write(to: leftover)
        try Data("y".utf8).write(to: ancient)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: ancient.path)

        let now = Date()
        #expect(try SharedInboxIngest.claimNext(fromShared: shared, into: documents.appendingPathComponent("Inbox"),
                                                now: now, staleAfter: 24 * 60 * 60) == nil)
        #expect(!fm.fileExists(atPath: leftover.path)) // marker swept
        #expect(!fm.fileExists(atPath: ancient.path))  // stale archive swept
    }
}

/// The expiry reminder's fire time, computed from a profile's RemovalDate. Pure, so it is tested without
/// scheduling a real notification (that lives in the app target).
@Suite struct ExpiryReminderTests {
    @Test func fireDateIsADayBeforeRemoval() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let removal = now.addingTimeInterval(7 * 86_400)
        let profile = ProfileState(identifier: "com.apple.basebandlogging", displayName: nil, installDate: now,
                                   removalDate: removal, lifetimeDays: 7, consentDays: 7, status: .active, observedAt: now)
        let fire = try? #require(profile.expiryReminderDate(now: now))
        #expect(fire == removal.addingTimeInterval(-ProfileState.expiringSoonInterval)) // exactly 24 h before
    }

    @Test func fireDateNeverInThePast() {
        let now = Date()
        // Expires in 10 minutes: the ideal (a day before) is already past, so fire ~a minute from now instead.
        let soon = ProfileState(identifier: "com.apple.basebandlogging", displayName: nil, installDate: now,
                                removalDate: now.addingTimeInterval(600), lifetimeDays: nil, consentDays: nil,
                                status: .expiringSoon, observedAt: now)
        let fire = try? #require(soon.expiryReminderDate(now: now))
        #expect(fire.map { $0 >= now.addingTimeInterval(59) && $0 <= now.addingTimeInterval(61) } == true)

        // Already expired, or no removal date: nothing to schedule.
        #expect(soon.expiryReminderDate(now: now.addingTimeInterval(3_600)) == nil)
        let noRemoval = ProfileState(identifier: "x", displayName: nil, installDate: now, removalDate: nil,
                                     lifetimeDays: nil, consentDays: nil, status: .unknown, observedAt: now)
        #expect(noRemoval.expiryReminderDate(now: now) == nil)
    }

    /// Ties the real profile stub to the reminder: its RemovalDate drives a fire time exactly a day earlier.
    @Test(.fixture("profile")) func fireDateFromTheRealStub() throws {
        guard let dir = Fixtures.require("profile") else { return }
        let stub = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .first { $0.hasSuffix(".stub") && !$0.hasPrefix("._") })
        let data = try Data(contentsOf: dir.appendingPathComponent(stub))
        let profile = try #require(ProfileStubReader.read(data, observedAt: nil))
        let removal = try #require(profile.removalDate)
        let wellBefore = removal.addingTimeInterval(-30 * 86_400)
        #expect(profile.expiryReminderDate(now: wellBefore) == removal.addingTimeInterval(-ProfileState.expiringSoonInterval))
    }
}
