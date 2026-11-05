import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// The scenarios of a second independent review of the natural keys and backfill.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct SecondIndependentReviewTests {

    /// The synchronization data couldn't be loaded, e.g. as it's corrupt, and the app resets it, the natural remedy. The reset
    /// fails rather than crashing the app.
    @Test func resetWithoutSyncDataThrows() async throws {
        let synchronizer = SDSSynchronizer(
            syncDataDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Sync"),
            viewModel: SDSSynchronizationViewModel(),
            makeCloudContainer: { _ in FakeCloudContainer(server: FakeCloudServer(), device: "A", account: .signedIn("first")) },
            monitorsNetwork: false
        )
        #expect(!synchronizer.isSyncDataLoaded)
        await #expect(throws: (any Error).self) {
            try await synchronizer.resetSyncData()
        }
    }

    /// A document, which has a parent, is edited. Saving its record conflicts, as with `.changedKeys` for a record that exists,
    /// so the edit is saved over the server's record, which keeps its parent. The upload finishes.
    @Test func childEditAfterAConflictFinishes() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "W")
            context.insert(workspace)
            let document = ScenarioDocument(title: "D")
            context.insert(document)
            document.workspace = workspace
        }
        await device.sync()
        try device.change { context in
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            document.body = "Edited"
        }
        await device.sync()

        #expect(await device.state.error == nil)
        #expect(server.record(named: documentRecordName("D"), account: "first")?["body"] as? String == "Edited")
        let pendingCount = device.synchronizer.context.performAndWait {
            (try? device.synchronizer.context.count(for: CloudKitUpdate.fetchRequest())) ?? -1
        }
        #expect(pendingCount == 0)
        device.terminate()
    }

    /// Device B renames a podcast. Device A starts renaming it too and cancels, e.g. in an edit sheet whose changes are rolled
    /// back. A's discarded edit isn't uploaded, so B's title stays on every device.
    @Test func discardedEditDoesNotOverwriteAnotherDevicesEdit() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()
        try await b.launch()
        await b.sync()
        try b.editSubscription("s1") { $0.title = "Edited on B" }
        await b.sync()

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = a.synchronizer.observedStore
        try context.performAndWait {
            let subscription = try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription")).first)
            subscription.setValue("Draft on A", forKey: "title")
            context.processPendingChanges()
            context.rollback()
        }
        await a.settle()
        await a.sync()
        await b.sync()

        #expect(b.serverSubscriptions().map(\.title) == ["Edited on B"])
        #expect(try a.subscriptions().map(\.title) == ["Edited on B"])
        #expect(try b.subscriptions().map(\.title) == ["Edited on B"])
        a.terminate()
        b.terminate()
    }

    /// Device A changes a subscription's identity, which moves it to another record, and its links to it. Uploading the links
    /// fails for now. Device B downloads in between. The subscription's previous record isn't deleted before the links
    /// reference the new one, so B doesn't delete the links with it through the delete rule.
    @Test func identityMoveDeletesThePreviousRecordAfterItsReferences() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.change { context in
            let subscription = ScenarioSubscription(feedLink: "old", title: "T")
            context.insert(subscription)
            for index in 0..<3 {
                let link = ScenarioLink(name: "l\(index)")
                context.insert(link)
                link.subscription = subscription
            }
        }
        await a.sync()
        await b.sync()
        #expect(try b.count(ScenarioLink.self) == 3)

        server.failSaving(where: { $0.recordName != subscriptionRecordName("new") }, with: CKError(.networkFailure), count: 3)
        try a.editSubscription("old") { $0.feedLink = "new" }
        await a.settle()
        await b.sync()
        #expect(try b.count(ScenarioLink.self) == 3)

        await a.sync()
        await b.sync()
        #expect(try b.count(ScenarioLink.self) == 3)
        #expect(try b.subscriptions().map(\.feedLink) == ["new"])
        #expect(b.serverSubscriptions().map(\.feedLink) == ["new"])
        a.terminate()
        b.terminate()
    }

    /// Device A saves large artwork, which goes into the record's overflow asset. Device B, which hasn't downloaded that,
    /// saves a large note, which goes into the asset too. A's artwork stays in it, rather than the asset being replaced with
    /// one of B's values only.
    @Test func overflowAssetKeepsAnotherDevicesValues() async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()
        await b.sync()

        let artwork = Data(repeating: 7, count: 300_000)
        try a.editSubscription("s1") { $0.artwork = artwork }
        await a.sync()

        // B's download fails, so it uploads without knowing A's asset
        server.failNextFetch(with: CKError(.networkFailure))
        let note = String(repeating: "n", count: 300_000)
        try b.editSubscription("s1") { $0.note = note }
        await b.settle()

        await a.sync()
        await b.sync()
        for device in [a, b] {
            #expect(try device.subscription("s1")?.artwork == artwork)
            #expect(try device.subscription("s1")?.note == note)
        }
        a.terminate()
        b.terminate()
    }

    /// Two devices create the same tag, whose name is unique, before they synchronize with each other, so each has a record of
    /// its own. Neither device folds the other's record into its tag again and again: one record is kept on both, and the
    /// other device's changes reach the tag.
    @Test func uniqueValuesOfTwoDevicesBecomeOneRecord() async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.change { $0.insert(ScenarioTag(name: "swift", color: "red")) }
        await a.sync()
        try b.change { $0.insert(ScenarioTag(name: "swift", color: "blue")) }
        // B's download fails, so it uploads its own record without knowing A's
        server.failNextFetch(with: CKError(.networkFailure))
        await b.settle()
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioTag" }.count == 2)

        for _ in 0..<3 {
            await a.sync()
            await b.sync()
        }
        let tags = server.records(account: "first").filter { $0.recordType == "ScenarioTag" }
        #expect(tags.count == 1)
        #expect(try a.count(ScenarioTag.self) == 1)
        #expect(try b.count(ScenarioTag.self) == 1)

        // A change on one device reaches the other
        try a.change { context in
            let tag = try #require(try context.fetch(FetchDescriptor<ScenarioTag>()).first)
            tag.color = "green"
        }
        await a.sync()
        await b.sync()
        let context = ModelContext(try #require(b.modelContainer))
        #expect(try context.fetch(FetchDescriptor<ScenarioTag>()).map(\.color) == ["green"])
        a.terminate()
        b.terminate()
    }

    /// The app's synchronization data is replaced with new, empty data next to its synchronized store, e.g. one a widget
    /// created in the app group before the app moved its own there. Notes, which have no identity, aren't uploaded again as
    /// new records: they're matched with their records first. Synchronizing goes on afterwards.
    @Test func newSyncDataNextToASynchronizedStoreDoesNotDuplicate() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { context in
            context.insert(ScenarioNote(text: "n1"))
            context.insert(ScenarioNote(text: "n2"))
        }
        try device.insertSubscriptions(["s1"])
        await device.settle()
        #expect(device.serverNotes() == ["n1", "n2"])
        device.terminate()

        let syncDirectory = device.directory.appending(path: "Sync")
        try FileManager.default.removeItem(at: syncDirectory)
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        try await device.launch()
        await device.sync()

        #expect(device.serverNotes() == ["n1", "n2"])
        #expect(try device.notes() == ["n1", "n2"])
        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1"])
        #expect(device.synchronizer.hasDownloadedOnce)

        try device.change { $0.insert(ScenarioNote(text: "n3")) }
        await device.settle()
        #expect(device.serverNotes() == ["n1", "n2", "n3"])
        device.terminate()
    }

    /// Documents below sharable workspaces, without an identity, which can't be below a sharable entity.
    private static let sharableConfiguration = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .sync(.without([]))),
        .init(entity: ScenarioLink.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]), isSharable: true)),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace"))
    ])

    /// A document below a sharable workspace is deleted. Its deletion is read when the save starts, when Core Data already
    /// cleared its parent. Its root is still found, which decides whether its removal goes to another user's zone.
    @Test func deletedChildStillFindsItsSharableRoot() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch(configuration: Self.sharableConfiguration)
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "W")
            context.insert(workspace)
            let document = ScenarioDocument(title: "D")
            context.insert(document)
            document.workspace = workspace
        }
        await device.sync()

        let roots = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let synchronizer = device.synchronizer!
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: nil, queue: nil) { notification in
            guard
                let context = notification.object as? NSManagedObjectContext,
                context.persistentStoreCoordinator == synchronizer.observedStore
            else { return }
            for object in context.deletedObjects where object.entity.name == "ScenarioDocument" {
                let root = synchronizer.container(for: object)?.sharableRootLocalId
                roots.withLock { $0.append(root) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try device.change { context in
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            context.delete(document)
        }

        let found = roots.withLock { $0 }
        #expect(found.count == 1)
        #expect(found.allSatisfy { $0?.contains("ScenarioWorkspace") == true })
        device.terminate()
    }
}
