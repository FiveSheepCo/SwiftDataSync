import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// A value a test's closures set, which have to be sendable.
private final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// The scenarios of a fourth review, of the whole pull request.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct FourthReviewScenarioTests {

    // MARK: Resetting

    /// A reset that keeps the local models finds the records of the ones without an identity, rather than uploading them
    /// again under new names and downloading their records as duplicates.
    @Test func resetKeepsModelsWithoutIdentityOnce() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { context in
            context.insert(ScenarioNote(text: "n1"))
            context.insert(ScenarioNote(text: "n2"))
        }
        await device.settle()
        #expect(device.serverNotes() == ["n1", "n2"])

        device.synchronizer.stop()
        try await device.synchronizer.resetSyncData()
        device.synchronizer.start()
        await device.settle()
        await device.sync()

        #expect(device.serverNotes() == ["n1", "n2"])
        #expect(try device.notes() == ["n1", "n2"])
        #expect(await device.state.error == nil)
        device.terminate()
    }

    /// Changes made before forgetting are never recorded, so they can't be uploaded, also if forgetting fails.
    @Test func changesBeforeForgettingAreNeverRecorded() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.settle()

        device.synchronizer.stop()
        let pending = Box(-1)
        let synchronizer = try #require(device.synchronizer)
        try await synchronizer.resetSyncData {
            try? device.deleteSubscription("s1")
            try? device.editSubscription("s2") { $0.title = "Changed before forgetting" }
            // Saved changes are recorded right away
            try? await Task.sleep(for: .milliseconds(200))
            let context = synchronizer.context
            pending.value = context.performAndWait {
                ["CloudKitRemoval", "CloudKitUpdate"].reduce(0) { count, entityName in
                    count + ((try? context.count(for: NSFetchRequest<NSManagedObject>(entityName: entityName))) ?? 0)
                }
            }
        }
        #expect(pending.value == 0)

        device.synchronizer.start()
        await device.settle()
        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])
        #expect(device.serverSubscriptions().last?.title == "Title of s2")
        device.terminate()
    }

    // MARK: Retrying

    /// A retry that's due sooner, e.g. as CloudKit asks to wait a moment, replaces one that's due later, e.g. after an error.
    @Test func anEarlierRetryReplacesALaterOne() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()

        // Retried after the routine interval, an hour in tests
        server.failNextFetch(with: CKError(.networkFailure))
        try device.insertSubscriptions(["s1"])
        await device.settle()
        #expect(await device.state.error != nil)

        server.failNextFetch(with: CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 0.5]))
        try device.insertSubscriptions(["s2"])
        await device.settle()
        #expect((await device.state.error as? CKError)?.retryAfterSeconds == 0.5)

        #expect(await waitUntil(timeout: 5) { device.serverSubscriptions().count == 2 })
        device.terminate()
    }

    /// "Sync Now" can't be used while synchronizing is stopped, e.g. after the user deleted the app's data in iCloud, as it
    /// wouldn't do anything.
    @Test func syncNowIsDisabledWhileStopped() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        server.deleteZone(account: "first", byUser: true)
        try device.editSubscription("s1") { $0.title = "Edited" }
        await device.settle()
        #expect((await device.state.error as? CKError)?.code == .userDeletedZone)
        #expect(await device.viewModel.forceSyncDisabled)

        device.synchronizer.start()
        await device.settle()
        #expect(await !device.viewModel.forceSyncDisabled)
        device.terminate()
    }

    // MARK: Uploading

    /// Updates that can't be uploaded anymore, e.g. as another process deleted their models, don't make an upload send the
    /// records of others twice, which CloudKit rejects.
    @Test func uploadsDontSendARecordTwice() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        device.synchronizer.stop()
        let feedLinks = (1...410).map { "s\($0)" }
        try device.insertSubscriptions(feedLinks)
        let deleted = Set(feedLinks.prefix(300))
        try device.changeInAnotherProcess { context in
            for subscription in try context.fetch(FetchDescriptor<ScenarioSubscription>()) where deleted.contains(subscription.feedLink) {
                context.delete(subscription)
            }
        }

        device.synchronizer.start()
        await device.settle()
        #expect(device.serverSubscriptions().count == 110)
        #expect(server.events(of: "A", .modifyRecords).allSatisfy { !$0.failed })
        #expect(await device.state.error == nil)
        device.terminate()
    }

    /// A removal CloudKit rejects, e.g. as the user may only read a share, is set aside like a record, rather than sent with
    /// every upload.
    @Test func rejectedRemovalsAreSetAside() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.settle()

        let attempts = OSAllocatedUnfairLock(initialState: 0)
        server.failDeleting(where: { _ in attempts.withLock { $0 += 1 }; return true }, with: CKError(.permissionFailure))
        try device.deleteSubscription("s1")
        await device.settle()
        try device.editSubscription("s2") { $0.title = "Edited" }
        await device.settle()
        #expect(device.serverSubscriptions().first { $0.feedLink == "s2" }?.title == "Edited")
        #expect(attempts.withLock { $0 } == 1)
        let error = await device.state.error as? SDSSyncError
        #expect((error?.underlyingError as? CKError)?.code == .permissionFailure)

        await device.sync()
        #expect(attempts.withLock { $0 } == 1)
        device.terminate()
    }

    /// A record referencing a model that only gets its record while the upload is prepared, e.g. one another process saved,
    /// is uploaded after that record, so the reference's target exists.
    @Test func referencedRecordsAreUploadedFirst() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { $0.insert(ScenarioDocument(title: "Document")) }
        await device.sync()

        try device.changeInAnotherProcess { $0.insert(ScenarioWorkspace(title: "From an extension")) }
        try device.change { context in
            let workspace = try #require(try context.fetch(FetchDescriptor<ScenarioWorkspace>()).first)
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            document.workspace = workspace
        }
        await device.sync()

        let workspace = try #require(server.records(account: "first").first { $0.recordType == "ScenarioWorkspace" })
        #expect(server.record(named: documentRecordName("Document"), account: "first")?.parent?.recordID == workspace.recordID)
        #expect(server.events(of: "A", .modifyRecords).allSatisfy { !$0.failed })
        #expect(await device.state.error == nil)
        device.terminate()
    }

    // MARK: Recording Changes

    /// A deletion is discarded before it's saved. The record stays.
    @Test func discardedDeletionKeepsTheRecord() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = device.synchronizer.observedStore
        try context.performAndWait {
            let subscription = try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription")).first)
            context.delete(subscription)
            context.processPendingChanges()
            context.rollback()
        }
        try device.editSubscription("s1") { $0.title = "Edited" }
        await device.sync()
        await device.sync()

        #expect(device.serverSubscriptions().map(\.title) == ["Edited"])
        #expect(try device.subscriptions().map(\.title) == ["Edited"])
        device.terminate()
    }

    /// A model changes to an identity another model has. It leaves the record named after its previous identity, which
    /// another model could take, for a record of its own.
    @Test func movingToATakenIdentityLeavesItsName() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        try device.editSubscription("s1") { $0.feedLink = "s2"; $0.title = "Moved" }
        await device.sync()

        #expect(server.record(named: subscriptionRecordName("s1"), account: "first") == nil)
        #expect(device.serverSubscriptions().map(\.feedLink) == ["s2", "s2"])
        #expect(device.serverSubscriptions().map(\.title).sorted() == ["Moved", "Title of s2"])
        device.terminate()
    }

    /// A model gives up its identity, and a new model takes it, in the same save. The record is kept for the new model.
    @Test func identityGivenUpAndTakenInOneSaveKeepsItsRecord() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        try device.change { context in
            let moved = try #require(try context.fetch(FetchDescriptor<ScenarioSubscription>()).first)
            moved.feedLink = "s3"
            context.insert(ScenarioSubscription(feedLink: "s1", title: "New", position: 1))
        }
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s3"])
        #expect(server.record(named: subscriptionRecordName("s1"), account: "first")?["title"] as? String == "New")
        #expect(server.record(named: subscriptionRecordName("s3"), account: "first")?["title"] as? String == "Title of s1")
        device.terminate()
    }

    /// Two models swap their identities in one save. Both keep records, whichever is moved first.
    @Test(arguments: 1...4) func swappedIdentitiesKeepTheirRecords(attempt: Int) async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        try device.change { context in
            let subscriptions = try context.fetch(FetchDescriptor<ScenarioSubscription>())
            for subscription in subscriptions {
                subscription.title = "Was \(subscription.feedLink)"
                subscription.feedLink = subscription.feedLink == "s1" ? "s2" : "s1"
            }
        }
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])
        #expect(device.serverSubscriptions().map(\.title) == ["Was s2", "Was s1"])
        let second = TestDevice("B", server: server)
        try await second.launch()
        #expect(try second.subscriptions().map(\.title) == ["Was s2", "Was s1"])
        device.terminate()
        second.terminate()
    }

    /// Two records reference a model that only gets its record while the upload is prepared. Both wait for its record.
    @Test func recordsReferencingTheSameNewModelWaitForIt() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { context in
            context.insert(ScenarioDocument(title: "First"))
            context.insert(ScenarioDocument(title: "Second"))
        }
        await device.sync()

        try device.changeInAnotherProcess { $0.insert(ScenarioWorkspace(title: "From an extension")) }
        try device.change { context in
            let workspace = try #require(try context.fetch(FetchDescriptor<ScenarioWorkspace>()).first)
            for document in try context.fetch(FetchDescriptor<ScenarioDocument>()) {
                document.workspace = workspace
            }
        }
        await device.sync()

        let workspace = try #require(server.records(account: "first").first { $0.recordType == "ScenarioWorkspace" })
        for title in ["First", "Second"] {
            #expect(server.record(named: documentRecordName(title), account: "first")?.parent?.recordID == workspace.recordID)
        }
        #expect(server.events(of: "A", .modifyRecords).allSatisfy { !$0.failed })
        #expect(await device.state.error == nil)
        device.terminate()
    }

    /// A model saved without the synchronizer changes its identity, to one another device has a record of already. Its other
    /// values are of unknown age, so they don't overwrite that record's.
    @Test func movedModelOfAnotherProcessDoesntOverwriteARecord() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.changeInAnotherProcess { $0.insert(ScenarioSubscription(feedLink: "s1", title: "From an extension", position: 0)) }
        server.seed([subscriptionRecord("s2", title: "From another device")], account: "first")

        try device.editSubscription("s1") { $0.feedLink = "s2" }
        await device.settle()
        await device.sync()

        #expect(device.serverSubscriptions().map(\.title) == ["From another device"])
        #expect(try device.subscriptions().map(\.title) == ["From another device"])
        device.terminate()
    }

    // MARK: Catching Up

    /// A newer version synchronizes a key that wasn't synchronized before. A record the catch-up can't download keeps the
    /// value another device uploaded, rather than getting this device's value, which might be older.
    @Test func catchUpLeavesRecordsItCouldntDownloadAlone() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        let withoutNotes = SDSConfiguration(swiftDataEntities: [
            .init(entity: ScenarioSubscription.self, description: .sync(.without(["note"]), identity: ["feedLink"])),
            .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
            .init(entity: ScenarioNote.self, description: .sync(.without([]))),
            .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
            .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
        ])
        try await device.launch(configuration: withoutNotes)
        try device.insertSubscriptions(["s1", "s2"])
        try device.editSubscription("s1") { $0.note = "Older" }
        try device.editSubscription("s2") { $0.note = "Only here" }
        await device.sync()
        // Another device, which synchronizes notes already
        server.seed([subscriptionRecord("s1", title: "Title of s1", note: "From another device")], account: "first")
        await device.sync()
        device.terminate()

        server.failDownloading(where: { $0.recordName == subscriptionRecordName("s1") }, with: CKError(.assetFileNotFound))
        try await device.launch()
        await device.sync()

        #expect(device.serverSubscriptions().first { $0.feedLink == "s1" }?.note == "From another device")
        #expect(device.serverSubscriptions().first { $0.feedLink == "s2" }?.note == "Only here")
        device.terminate()
    }
}

/// Identity values that can't name records.
@Suite(.coreDataReady)
struct FourthReviewTests {

    /// Models without all of their identity values get records of their own, rather than sharing one.
    @Test func missingIdentityValuesNameNoRecord() {
        #expect(SDSIdentity.identityRecordName(entityName: "Model", values: ["a", nil]) == nil)
        #expect(SDSIdentity.identityRecordName(entityName: "Model", values: [NSNull()]) == nil)
        #expect(SDSIdentity.identityRecordName(entityName: "Model", values: ["a", ""]) == SDSIdentity.recordName(entityName: "Model", values: ["a", ""]))
        // Too far away for milliseconds, which mustn't crash
        _ = SDSIdentity.recordName(entityName: "Model", values: [Date(timeIntervalSince1970: .greatestFiniteMagnitude)])
    }

    /// A float's text differs from the double its record stores, so it can't be an identity value.
    @Test func identityValuesHaveToNameRecordsAlike() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: [FolderModel.self, NoteModel.self]))
        let entity = try #require(model.entitiesByName["FolderModel"]?.copy() as? NSEntityDescription)
        let rating = NSAttributeDescription()
        rating.name = "rating"
        rating.type = .float
        entity.properties.append(rating)

        let configuration = { (key: String) in
            SDSInternalConfiguration.Entity(syncedProperties: [key], assetProperties: [], parentKey: nil, isSharable: false, referenceDepth: 0, identity: [key])
        }
        #expect(SDSInternalConfiguration.identityProblems(of: ["FolderModel": configuration("rating")], descriptions: ["FolderModel": entity]).count == 1)
        #expect(SDSInternalConfiguration.identityProblems(of: ["FolderModel": configuration("title")], descriptions: ["FolderModel": entity]).isEmpty)
    }
}
