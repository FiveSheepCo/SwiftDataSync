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

    /// Like `failedNestedSaveFromAnObserverOfTheAppKeepsTheFirstSavesEdits`, with a first save that also inserts a model of
    /// a unique value that exists, which the context's merge policy folds into the existing one, as SwiftData does for
    /// `@Attribute(.unique)`. Its DidSave doesn't list the inserted model, and still finds the save's keys.
    @Test func failedNestedSaveAfterAnUpsertKeepsTheFirstSavesEdits() async throws {
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
            NSEntityDescription.insertNewObject(forEntityName: "ScenarioTag", into: context).setValue("t", forKey: "name")
            let policy = context.mergePolicy
            context.mergePolicy = NSMergePolicy.error
            do {
                try context.save()
            } catch {
                nestedFailed.withLock { $0 = true }
                context.rollback()
            }
            context.mergePolicy = policy
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
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        appContext.withLockUnchecked { $0 = context }
        try context.performAndWait {
            let notes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioNote"))
            notes.first { ($0.value(forKey: "text") as? String) == "n1" }?.setValue("n1 edited", forKey: "text")
            NSEntityDescription.insertNewObject(forEntityName: "ScenarioTag", into: context).setValue("t", forKey: "name")
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

        // A save that only inserted, below the save whose notification this is, e.g. one whose notification's observer saves
        // again, isn't taken by it, but by its own notification later
        let inserting = remember("inserting", [])
        let fromObserver = remember("from observer", [two])
        let observers = try #require(synchronizer.takeKeysBeingSaved(by: context, savedObjects: [ObjectIdentifier(two)]))
        #expect(observers.tokens == [fromObserver])
        let inserts = try #require(synchronizer.takeKeysBeingSaved(by: context, savedObjects: []))
        #expect(inserts.tokens == [inserting])

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

    // MARK: Large values

    /// A subscription with a large note, which is in the record's overflow asset, is deleted and subscribed to again without
    /// a note before the deletion is uploaded. The new model takes the record, as a local insert, and its upload replaces the
    /// asset's values, rather than every device reading the deleted model's note from it again.
    @Test(arguments: [false, true]) func subscribingAgainDoesNotBringBackTheDeletedModelsLargeNote(freshRecordsConflict: Bool) async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = freshRecordsConflict
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.insertSubscriptions(["s1"])
        try a.editSubscription("s1") { $0.note = String(repeating: "n", count: 300_000) }
        await a.sync()
        await b.sync()
        #expect(try b.subscription("s1")?.note?.count == 300_000)

        // Offline: unsubscribe and subscribe again
        a.synchronizer.stop()
        await a.settle()
        try a.deleteSubscription("s1")
        try a.insertSubscriptions(["s1"])
        await a.settle()
        a.synchronizer.start()
        await a.settle()
        await a.sync()
        await b.sync()
        await a.sync()

        let noteA = try a.subscription("s1")?.note
        let noteB = try b.subscription("s1")?.note
        #expect(noteA == nil, "A's note: \(noteA?.count ?? 0) characters")
        #expect(noteB == nil, "B's note: \(noteB?.count ?? 0) characters")
        a.terminate()
        b.terminate()
    }

    // MARK: Held records

    /// A new device downloads many links before the subscription they reference, which was changed after them, so the links
    /// are held until it arrives. Releasing them lists the directory of held records once, rather than once for each.
    @Test func manyHeldRecordsAreReleasedQuickly() async throws {
        let count = 2000
        let server = FakeCloudServer()
        let subscription = subscriptionRecord("s1", title: "Title")
        let links = (0..<count).map { index in
            let link = CKRecord(recordType: "ScenarioLink", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: .scenario))
            link["name"] = "Link \(index)"
            link["subscription"] = CKRecord.Reference(recordID: subscription.recordID, action: .none)
            return link
        }
        server.seed(links, account: "first")
        server.seed([subscription], account: "first")
        let b = TestDevice("B", server: server)
        let start = ContinuousClock.now
        try await b.launch()
        await b.sync()
        let duration = ContinuousClock.now - start
        #expect(try b.count(ScenarioLink.self) == count)
        #expect(duration < .seconds(5), "Took \(duration)")
        b.terminate()
    }

    /// Releasing held records removes their files and their assets' files, and leaves the others.
    @Test func releasingHeldRecordsRemovesOnlyTheirFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SwiftDataSync Tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = SDSHeldRecords(directory: directory)
        let assetFile = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try Data("asset".utf8).write(to: assetFile)
        defer { try? FileManager.default.removeItem(at: assetFile) }
        let records = (0..<3).map { index in
            let record = CKRecord(recordType: "ScenarioNote", recordID: CKRecord.ID(recordName: "n\(index)", zoneID: .scenario))
            record["text"] = "n\(index)"
            record["artwork"] = CKAsset(fileURL: assetFile)
            return record
        }
        for record in records {
            try held.hold(record)
        }
        try held.storeFailedIDs([records[0].recordID])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 7)

        held.release([records[0].recordID, records[2].recordID])
        #expect(held.load().map(\.recordID.recordName) == ["n1"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
        #expect(held.loadFailedIDs() == [records[0].recordID])
    }

    // MARK: Temporary asset files

    /// Setting up a synchronizer removes the files of assets that earlier uploads left behind, but not the ones of uploads
    /// that are running, e.g. of another synchronizer of the process, which CloudKit would then reject with
    /// `assetFileNotFound`.
    @Test func setupLeavesTheAssetFilesOfRunningUploads() async throws {
        let running = try CKAsset(data: Data("running".utf8))
        let leftover = try CKAsset(data: Data("leftover".utf8))
        let runningURL = try #require(running.fileURL)
        let leftoverURL = try #require(leftover.fileURL)
        defer { try? FileManager.default.removeItem(at: runningURL) }
        let old = Date.now.addingTimeInterval(-CKAsset.leftoverTemporaryFileAge - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: leftoverURL.path)

        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch()
        #expect(FileManager.default.fileExists(atPath: runningURL.path))
        #expect(!FileManager.default.fileExists(atPath: leftoverURL.path))
        a.terminate()
    }

    // MARK: Extensions

    /// Version 1 of the app doesn't synchronize subscriptions' notes.
    private static let withoutNotes = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without(["note"]), identity: ["feedLink"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .sync(.without([]))),
        .init(entity: ScenarioLink.self, description: .sync(.without([]))),
        .init(entity: ScenarioTag.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    /// Device B's app is updated to a version that synchronizes subscriptions' notes, while its extension doesn't. The
    /// extension was set up before the app caught up on notes, and keeps running. Notes another device changes afterwards,
    /// which the extension downloads, reach B's app, as the extension keeps those records for it.
    @Test(arguments: [false, true]) func extensionSetUpBeforeTheAppCaughtUpKeepsWhatItSkipsForTheApp(relaunchingExtension: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        try a.editSubscription("s1") { $0.note = "N1" }
        await a.sync()
        // B's version 1 doesn't synchronize notes
        try await b.launch(configuration: Self.withoutNotes)
        await b.sync()
        b.terminate()

        // The update: the extension, which still doesn't synchronize notes, launches first
        var ext = try await ExtensionProcess(of: b, configuration: Self.withoutNotes)
        await ext.sync()
        // The app catches up on notes
        try await b.launch()
        await b.sync()
        #expect(try b.subscription("s1")?.note == "N1")
        b.terminate()
        if relaunchingExtension {
            ext.terminate()
            ext = try await ExtensionProcess(of: b, configuration: Self.withoutNotes)
        }

        // Another device changes the note, which the extension downloads while the app isn't running
        try a.editSubscription("s1") { $0.note = "N2" }
        await a.sync()
        await ext.sync()
        ext.terminate()

        try await b.launch()
        await b.sync()
        #expect(try b.subscription("s1")?.note == "N2")
        a.terminate()
        b.terminate()
    }
}

/// An extension of a test device, on its synchronization data and store, which runs while the device's app is terminated and
/// launched again.
private final class ExtensionProcess: @unchecked Sendable {
    let synchronizer: SDSSynchronizer
    let modelContainer: ModelContainer

    init(of device: TestDevice, configuration: SDSConfiguration) async throws {
        let cloud = FakeCloudContainer(server: device.server, device: "\(device.name)-extension", account: .signedIn("first"))
        synchronizer = SDSSynchronizer(
            syncDataDirectory: device.directory.appending(path: "Sync"),
            viewModel: SDSSynchronizationViewModel(),
            makeCloudContainer: { _ in cloud },
            monitorsNetwork: false,
            timing: device.timing
        )
        synchronizer.isAppExtension = true
        var created: ModelContainer?
        let storeURL = device.storeURL
        synchronizer.setup(
            containerName: "iCloud.test",
            configuration: configuration,
            modelContainer: {
                created = try? ModelContainer(
                    for: Schema([ScenarioTag.self, ScenarioLink.self, ScenarioSubscription.self, ScenarioEpisode.self, ScenarioNote.self, ScenarioWorkspace.self, ScenarioDocument.self]),
                    configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
                )
                return created
            }()
        )
        modelContainer = try #require(created)
        for _ in 0..<500 where !synchronizer.isObservingStore {
            try await Task.sleep(for: .milliseconds(10))
        }
        await settle()
    }

    func settle() async {
        var idleChecks = 0
        for _ in 0..<6000 {
            var isBusy = synchronizer.hasPendingSaveSync || synchronizer.hasPendingSyncStart || synchronizer.isSynchronizing
            if !isBusy {
                switch await synchronizer.viewModel.state {
                case .bootstrapping, .uploading, .downloading, .processingSaveEvent, .waitingForSetup, .waitingForContainerDetection: isBusy = true
                default: break
                }
            }
            idleChecks = isBusy ? 0 : idleChecks + 1
            if idleChecks >= 3 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func sync() async {
        await settle()
        await synchronizer.synchronize()
        await settle()
    }

    func terminate() {
        synchronizer.invalidate()
    }
}
