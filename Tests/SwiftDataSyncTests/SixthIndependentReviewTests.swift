import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// The scenarios of the sixth independent review of the natural keys and backfill.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct SixthIndependentReviewTests {

    // MARK: Upgrading from main

    /// Device B inserted a subscription with the previous version of the library (`main`), which wasn't uploaded yet when the
    /// app was updated, e.g. as it was offline. That version stored a pending insert like an edit, with every key and without
    /// the insert marker. After the update, the subscription is still uploaded, also if the first download fails.
    @Test(arguments: [false, true], [false, true])
    func insertPendingFromThePreviousVersionIsUploaded(asPreviousVersionStoredIt: Bool, downloadFails: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try b.insertSubscriptions(["s1"])
        await b.sync()
        #expect(a.serverSubscriptions().map(\.feedLink) == ["s1"])

        // Offline: the insert stays pending
        b.synchronizer.stop()
        await b.settle()
        try b.insertSubscriptions(["s2"])
        await b.settle()
        // What the previous version stored for it: the keys, without markers
        let context = b.synchronizer.context
        let pending: [String] = try context.performAndWait {
            let updates = try context.fetch(CloudKitUpdate.fetchRequest())
            for update in updates where asPreviousVersionStoredIt {
                update.rawChangedKeys = (update.changedKeys + update.backfilledKeys).joined(separator: ",")
            }
            try context.save()
            return updates.map(\.rawChangedKeys)
        }
        #expect(pending.count == 1)
        b.terminate()

        if downloadFails {
            server.failNextFetch(with: CKError(.networkFailure))
        }
        try await b.launch()
        await b.sync()
        await b.sync()
        #expect(b.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])
        let left = context.performAndWait { ((try? context.fetch(CloudKitUpdate.fetchRequest())) ?? []).map(\.rawChangedKeys) }
        #expect(left.isEmpty, "Pending: \(left)")
        a.terminate()
        b.terminate()
    }

    /// Like `insertPendingFromThePreviousVersionIsUploaded`, for a model without an identity, inserted while the synchronizer
    /// was stopped.
    @Test(arguments: [true, false]) func pendingInsertOfAnEarlierVersionIsUploaded(stripMarker: Bool) async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { $0.insert(ScenarioNote(text: "synced")) }
        await device.sync()
        #expect(device.serverNotes() == ["synced"])
        device.synchronizer.stop()
        await device.settle()
        try device.change { $0.insert(ScenarioNote(text: "offline")) }
        await device.settle()

        // Like the update the previous version stored: the keys only, without `+`
        let context = device.synchronizer.context
        let raw: [String] = context.performAndWait {
            let updates = (try? context.fetch(CloudKitUpdate.fetchRequest())) ?? []
            for update in updates where stripMarker {
                update.rawChangedKeys = update.rawChangedKeys.components(separatedBy: ",").filter { $0 != CloudKitUpdate.insertMarker }.joined(separator: ",")
            }
            try? context.save()
            return updates.map(\.rawChangedKeys)
        }
        #expect(raw.count == 1)

        device.synchronizer.start()
        await device.settle()
        await device.sync()
        await device.sync()

        #expect(device.serverNotes() == ["offline", "synced"])
        device.terminate()
    }
}
