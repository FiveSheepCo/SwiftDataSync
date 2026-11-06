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

    // MARK: Saves

    /// An observer of the app that runs before the synchronizer's saves the context again from the first save's DidSave, and
    /// that nested save fails (here a unique constraint conflict), so it posts no DidSave. The first save's DidSave still
    /// stores the first save's keys, rather than the failed save's, which are on top of them.
    @Test func failedNestedSaveFromAnObserverOfTheAppKeepsTheFirstSavesEdits() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let appContext = OSAllocatedUnfairLock<NSManagedObjectContext?>(uncheckedState: nil)
        let savesAgain = OSAllocatedUnfairLock(initialState: false)
        let nestedFailed = OSAllocatedUnfairLock(initialState: false)
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { notification in
            guard
                let context = notification.object as? NSManagedObjectContext,
                appContext.withLockUnchecked({ $0 === context }),
                savesAgain.withLock({ isSaving in defer { isSaving = false }; return isSaving })
            else { return }
            let notes = try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioNote"))
            notes?.first { ($0.value(forKey: "text") as? String) == "n2" }?.setValue("n2 never saved", forKey: "text")
            let tag = NSEntityDescription.insertNewObject(forEntityName: "ScenarioTag", into: context)
            tag.setValue("t", forKey: "name")
            do {
                try context.save()
            } catch {
                nestedFailed.withLock { $0 = true }
                context.rollback()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await a.launch()
        try a.change { context in
            for index in 1...2 { context.insert(ScenarioNote(text: "n\(index)")) }
            context.insert(ScenarioTag(name: "t"))
        }
        await a.sync()

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = try #require(a.synchronizer.observedStore)
        appContext.withLockUnchecked { $0 = context }
        try context.performAndWait {
            let notes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioNote"))
            notes.first { ($0.value(forKey: "text") as? String) == "n1" }?.setValue("n1 edited", forKey: "text")
            savesAgain.withLock { $0 = true }
            try context.save()
        }
        await a.sync()
        await a.sync()

        #expect(nestedFailed.withLock { $0 })
        #expect(a.serverNotes() == ["n1 edited", "n2"])
        a.terminate()
    }

    /// A save fails, and the app saves other changes right after, before the failed save's keys are dropped. The second
    /// save's edit is uploaded, and the failed one's isn't.
    @Test func saveRightAfterAFailedOneKeepsItsEdits() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.change { context in
            for index in 1...2 { context.insert(ScenarioNote(text: "n\(index)")) }
            context.insert(ScenarioTag(name: "t"))
        }
        await a.sync()

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = try #require(a.synchronizer.observedStore)
        let failed: Bool = try context.performAndWait {
            let notes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioNote"))
            notes.first { ($0.value(forKey: "text") as? String) == "n1" }?.setValue("n1 never saved", forKey: "text")
            NSEntityDescription.insertNewObject(forEntityName: "ScenarioTag", into: context).setValue("t", forKey: "name")
            var failed = false
            do { try context.save() } catch { failed = true }
            context.rollback()
            notes.first { ($0.value(forKey: "text") as? String) == "n2" }?.setValue("n2 edited", forKey: "text")
            try context.save()
            return failed
        }
        await a.sync()
        await a.sync()

        #expect(failed)
        #expect(a.serverNotes() == ["n1", "n2 edited"])
        a.terminate()
    }

    /// The saves a DidSave is matched with, by the objects they started with. Several that match are taken together, and
    /// none that matches takes the newest, as before.
    @Test func savesAreMatchedByTheirObjects() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.change { $0.insert(ScenarioNote(text: "n")) }
        let synchronizer = try #require(a.synchronizer)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = try #require(synchronizer.observedStore)
        let (one, two, three) = (NSObject(), NSObject(), NSObject())
        let objectID = try #require(context.performAndWait {
            try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioNote")).first?.objectID
        })
        func remember(_ key: String, _ objects: [NSObject]) -> Int {
            synchronizer.rememberKeysBeingSaved([objectID: [key]], previousReferences: [:], objects: Set(objects.map(ObjectIdentifier.init)), by: context)
        }

        // The outer save's DidSave, below a failed save of other objects
        let outer = remember("outer", [one, two])
        _ = remember("failed", [three])
        let first = try #require(synchronizer.takeKeysBeingSaved(by: context, savedObjects: Set([one, two].map(ObjectIdentifier.init))))
        #expect(first.tokens == [outer])
        #expect(first.save.keys[objectID] == ["outer"])

        // A failed save of objects that are saved too is taken with the save
        _ = remember("failed of the same", [one])
        let next = remember("next", [one, two])
        let both = try #require(synchronizer.takeKeysBeingSaved(by: context, savedObjects: Set([one, two].map(ObjectIdentifier.init))))
        #expect(both.save.token == next)
        #expect(both.tokens.count == 2)
        #expect(both.save.keys[objectID] == ["failed of the same", "next"])

        // Without a match, the newest, which leaves the failed save of other objects from the start
        let newest = remember("unmatched", [one])
        let fallback = try #require(synchronizer.takeKeysBeingSaved(by: context, savedObjects: []))
        #expect(fallback.tokens == [newest])
        let left = try #require(synchronizer.takeKeysBeingSaved(by: context, savedObjects: [ObjectIdentifier(three)]))
        #expect(left.save.keys[objectID] == ["failed"])
        #expect(synchronizer.takeKeysBeingSaved(by: context, savedObjects: []) == nil ? true : false)
        a.terminate()
    }

    // MARK: Removals held back for records that are replaced

    /// A model whose identity changes twice before its new record is uploaded, as iCloud is full. The second move deletes the
    /// update of the first move's record, which held back the original record's removal: the new record's update holds it
    /// back instead, so device B keeps the model meanwhile.
    @Test func modelMovingTwiceKeepsItsOriginalRecordUntilTheNewOneIsUploaded() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.insertSubscriptions(["s1", "s2"])
        await a.sync()
        await b.sync()

        let isFailing = OSAllocatedUnfairLock(initialState: true)
        server.failSaving(where: { _ in isFailing.withLock { $0 } }, with: CKError(.quotaExceeded))
        try a.editSubscription("s1") { $0.feedLink = "s1x" }
        try a.editSubscription("s1x") { $0.feedLink = "s1y" }
        await a.sync()
        await a.sync()
        await b.sync()
        #expect(server.records(account: "first").contains { $0.recordID.recordName == subscriptionRecordName("s1") })
        #expect(try b.subscriptions().map(\.feedLink) == ["s1", "s2"])

        isFailing.withLock { $0 = false }
        a.synchronizer.resumeUploads()
        await a.sync()
        await a.sync()
        await b.sync()
        #expect(a.serverSubscriptions().map(\.feedLink) == ["s1y", "s2"])
        #expect(try b.subscriptions().map(\.feedLink) == ["s1y", "s2"])
        a.terminate()
        b.terminate()
    }

    /// A document moves to another workspace and changes its identity, in one save or two, while iCloud is full or CloudKit
    /// rejects its new record, and its previous workspace is deleted. The document's previous record still has that workspace
    /// as its parent, so the workspace's removal waits for the new record, rather than CloudKit deleting the document's
    /// previous record with it, and device B the document.
    @Test(arguments: [false, true], [true, false]) func moveWithIdentityChangeKeepsThePreviousParent(rejected: Bool, inOneSave: Bool) async throws {
        let server = FakeCloudServer()
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.change { context in
            let w1 = ScenarioWorkspace(title: "W1")
            let w2 = ScenarioWorkspace(title: "W2")
            context.insert(w1)
            context.insert(w2)
            let document = ScenarioDocument(title: "d1")
            context.insert(document)
            document.workspace = w1
        }
        await a.sync()
        await b.sync()
        #expect(try b.count(ScenarioDocument.self) == 1)

        let isFailing = OSAllocatedUnfairLock(initialState: true)
        if rejected {
            server.failSaving(where: { $0.recordName == documentRecordName("d2") && isFailing.withLock { $0 } }, with: CKError(.serverRejectedRequest))
        } else {
            server.failSaving(where: { _ in isFailing.withLock { $0 } }, with: CKError(.quotaExceeded))
        }
        try a.change { context in
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            let w2 = try #require(try context.fetch(FetchDescriptor<ScenarioWorkspace>(predicate: #Predicate { $0.title == "W2" })).first)
            document.workspace = w2
            if inOneSave { document.title = "d2" }
        }
        if !inOneSave {
            try a.change { context in
                let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
                document.title = "d2"
            }
        }
        try a.change { context in
            for workspace in try context.fetch(FetchDescriptor<ScenarioWorkspace>(predicate: #Predicate { $0.title == "W1" })) {
                context.delete(workspace)
            }
        }
        await a.sync()
        await a.sync()
        await b.sync()
        #expect(server.record(named: documentRecordName("d1"), account: "first") != nil, "The previous record is gone before the new one was uploaded")
        #expect(try b.count(ScenarioDocument.self) == 1)

        isFailing.withLock { $0 = false }
        a.synchronizer.resetQuarantine()
        a.synchronizer.resumeUploads()
        await a.sync()
        await a.sync()
        await b.sync()
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioDocument" }.map(\.recordID.recordName) == [documentRecordName("d2")])
        #expect(try b.count(ScenarioDocument.self) == 1)
        a.terminate()
        b.terminate()
    }
}
