import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// The scenarios of an independent review of the natural keys and backfill.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct IndependentReviewTests {

    /// Device B renames a podcast while a download brings another device's new title and position of it. B's title wins,
    /// as it's uploaded next, and the downloaded position is stored, rather than being discarded with the title. CloudKit
    /// rejects B's upload, so no later download brings the record again until it's uploaded.
    @Test func editDuringADownloadKeepsTheRecordsOtherValues() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()
        try await b.launch()
        await b.sync()
        #expect(try b.subscription("s1")?.title == "Title of s1")

        try a.editSubscription("s1") { subscription in
            subscription.title = "A's title"
            subscription.position = 7
        }
        await a.settle()
        await a.sync()

        server.beforePageTokenUpdate = { [server, b] name, _ in
            guard name == "B" else { return }
            server.beforePageTokenUpdate = nil
            try? b.editSubscription("s1") { $0.title = "B's title" }
        }
        server.failSaving(where: { $0.recordName == subscriptionRecordName("s1") }, with: CKError(.invalidArguments), count: 1)
        await b.sync()
        await b.settle()

        #expect(try b.subscription("s1")?.position == 7)
        #expect(try b.subscription("s1")?.title == "B's title")
        #expect(b.serverSubscriptions().map(\.title) == ["A's title"])

        // The rejected record is uploaded again once the user asks for it
        await b.synchronizer.forceDownloadSync()
        await b.settle()
        #expect(b.serverSubscriptions().map(\.title) == ["B's title"])
        #expect(b.serverSubscriptions().map(\.position) == [7])
        a.terminate()
        b.terminate()
    }

    /// Text that reads the same names the same record, whether its characters are composed or decomposed, e.g. typed on one
    /// device and read from a file name on another.
    @Test func identityIgnoresTheUnicodeNormalization() {
        let composed = "Caf\u{E9}"
        let decomposed = "Cafe\u{301}"
        #expect(composed.utf8.count != decomposed.utf8.count)
        #expect(SDSIdentity.recordName(entityName: "Feed", values: [composed]) == SDSIdentity.recordName(entityName: "Feed", values: [decomposed]))
        // Other text still names other records
        #expect(SDSIdentity.recordName(entityName: "Feed", values: [composed]) != SDSIdentity.recordName(entityName: "Feed", values: ["Cafe"]))
    }

    /// Rejected records whose time is up don't make uploads fetch more updates, and are forgotten.
    @Test func quarantineOnlyCountsRecordsThatAreLeftOut() {
        var quarantine = SDSRecordQuarantine()
        let changeDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        let later = now.addingTimeInterval(SDSRecordQuarantine.duration)

        quarantine.add("a", lastChangeDate: changeDate, error: CKError(.invalidArguments), now: now)
        #expect(quarantine.count(now: now) == 1)
        #expect(quarantine.latestError(now: now) != nil)
        #expect(quarantine.count(now: later) == 0)
        #expect(quarantine.latestError(now: later) == nil)

        // Adding another one forgets the first, whose time is up
        quarantine.add("b", lastChangeDate: changeDate, now: later)
        #expect(quarantine.count(now: now) == 1)
        #expect(!quarantine.contains("a", lastChangeDate: changeDate, now: now))
        #expect(quarantine.contains("b", lastChangeDate: changeDate, now: later))
    }

    /// An upload that's rejected as a whole, e.g. a backfill of a field the production schema lacks, adds all its records at
    /// once, and still forgets the ones whose time is up.
    @Test func quarantineAddsAWholeUploadAtOnce() {
        var quarantine = SDSRecordQuarantine()
        let changeDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        let later = now.addingTimeInterval(SDSRecordQuarantine.duration)

        quarantine.add("old", lastChangeDate: changeDate, now: now)
        let rejections = Dictionary(uniqueKeysWithValues: (0..<10_000).map {
            ("r\($0)", SDSRecordQuarantine.Rejection(lastChangeDate: changeDate, error: CKError(.invalidArguments)))
        })
        quarantine.add(rejections, now: later)

        #expect(quarantine.count(now: later) == 10_000)
        #expect(!quarantine.contains("old", lastChangeDate: changeDate, now: later))
        #expect(quarantine.contains("r9999", lastChangeDate: changeDate, now: later))
        #expect(quarantine.latestError(now: later) != nil)
    }
}
