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
}
