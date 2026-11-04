import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
@testable import SwiftDataSync

/// Scenarios of the seventh review: a deletion that a download's save takes in before the synchronizer handles it, and
/// identities swapped by models with values of unknown age.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct SeventhReviewScenarioTests {

    /// The app deletes a model, and a download's save takes in the deletion before the synchronizer handles the app's save,
    /// e.g. as another observer of the save runs first. The deletion is still uploaded, rather than taken for the
    /// synchronizer's own, which made the model come back.
    @Test func deletionTakenInByADownloadIsUploaded() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        let observer = ObserverToken()
        device.beforeSetup = { synchronizer in
            // Registered before the synchronizer's, so it runs first
            let token = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { notification in
                guard
                    let saving = notification.object as? NSManagedObjectContext,
                    let updateContext = synchronizer.observedUpdateContext,
                    saving !== updateContext,
                    saving.persistentStoreCoordinator === updateContext.persistentStoreCoordinator,
                    !((notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>) ?? []).isEmpty
                else { return }
                // Like a download that takes in the deletion, and saves the update context
                updateContext.performAndWait {
                    for objectID in (notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []).map(\.objectID) {
                        updateContext.delete(updateContext.object(with: objectID))
                    }
                    try? synchronizer.saveObservedUpdateContext(updateContext)
                }
            }
            observer.token = token
        }
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        try device.deleteSubscription("s1")
        await device.sync()
        observer.token.map(NotificationCenter.default.removeObserver)

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s2"])
        device.terminate()
    }

    /// A workspace and its document change their identities in one save, so the document's change comes twice, once as
    /// it references the workspace. The record it moved away from is still deleted.
    @Test(arguments: 1...3) func movedModelsThatReferenceMovedModelsLeaveNoRecordBehind(attempt: Int) async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        let identities = SDSConfiguration(swiftDataEntities: [
            .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink"])),
            .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
            .init(entity: ScenarioNote.self, description: .sync(.without([]))),
            .init(entity: ScenarioWorkspace.self, description: .sync(.without([]), identity: ["title"])),
            // The workspace is only referenced, as entities with an identity can't be parents
            .init(entity: ScenarioDocument.self, description: .sync(.without([]), identity: ["title"]))
        ])
        try await device.launch(configuration: identities)
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "w")
            context.insert(workspace)
            for number in 1...5 {
                let document = ScenarioDocument(title: "d\(number)")
                context.insert(document)
                document.workspace = workspace
            }
        }
        await device.sync()

        try device.change { context in
            for workspace in try context.fetch(FetchDescriptor<ScenarioWorkspace>()) {
                workspace.title = "w2"
            }
            for document in try context.fetch(FetchDescriptor<ScenarioDocument>()) {
                document.title += "b"
            }
        }
        await device.sync()

        let documents = Set(server.records(account: "first").filter { $0.recordType == "ScenarioDocument" }.map(\.recordID.recordName))
        #expect(documents == Set((1...5).map { documentRecordName("d\($0)b") }))
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioWorkspace" }.count == 1)
        device.terminate()
    }

    /// The app deletes a model, and a download runs before the synchronizer stores the deletion, e.g. as another observer of
    /// the save runs first. The download leaves the record alone, rather than taking the model for gone and inserting it
    /// again, so the deletion is uploaded.
    @Test func downloadsLeaveARecordAloneWhileItsDeletionIsStored() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        let observer = ObserverToken()
        let wasRemoved = ObserverToken()
        device.beforeSetup = { synchronizer in
            let token = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { notification in
                guard
                    let saving = notification.object as? NSManagedObjectContext,
                    let updateContext = synchronizer.observedUpdateContext,
                    saving !== updateContext,
                    saving.persistentStoreCoordinator === updateContext.persistentStoreCoordinator,
                    let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>, !deleted.isEmpty
                else { return }
                // What a download that receives the record now asks
                wasRemoved.token = synchronizer.pendingLocalChange(of: subscriptionRecordName("s1")).isRemoved as NSNumber
            }
            observer.token = token
        }
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        try device.deleteSubscription("s1")
        await device.sync()
        observer.token.map(NotificationCenter.default.removeObserver)

        #expect((wasRemoved.token as? NSNumber)?.boolValue == true)
        #expect(device.serverSubscriptions().map(\.feedLink) == ["s2"])
        device.terminate()
    }

    /// The app deletes models in saves on a queue that also handles the synchronizer's saves. Its saves don't wait for the
    /// synchronizer's queue, which would wait for the app's.
    @Test func deletingDoesntWaitForTheSynchronizer() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let synchronizerContext = device.synchronizer.context
        let token = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: synchronizerContext, queue: queue) { _ in }
        let done = ObserverToken()
        queue.addOperation {
            try? device.deleteSubscription("s1")
            try? device.deleteSubscription("s2")
            done.token = true as NSNumber
        }
        for _ in 0..<500 where done.token == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        NotificationCenter.default.removeObserver(token)

        #expect(done.token != nil)
        device.terminate()
    }

    /// A model with values of unknown age and one without swap their identities. Each keeps its own keys' ages, rather
    /// than taking the other's, which kept known values from being uploaded, or uploaded unknown ones over iCloud's.
    @Test(arguments: 1...4) func swappedIdentitiesKeepTheirOwnValuesAges(attempt: Int) async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()
        device.terminate()

        // s1 is changed by a process without the synchronizer, so its values are of unknown age once it's noticed
        try device.changeInAnotherProcess { context in
            for subscription in try context.fetch(FetchDescriptor<ScenarioSubscription>()) where subscription.feedLink == "s1" {
                subscription.title = "Unknown age"
            }
        }
        try await device.launch(stopped: true)
        let synchronizer = try #require(device.synchronizer)
        let context = synchronizer.context
        // Like a backfill: s1's update has backfilled keys, s2 has none
        let s1Name = subscriptionRecordName("s1")
        let s2Name = subscriptionRecordName("s2")
        context.performAndWait {
            let update = CloudKitUpdate(id: s1Name, entityName: "ScenarioSubscription", context: context)
            update.addBackfilledKeys(["title", "position"])
            try? context.save()
        }

        try device.change { context in
            for subscription in try context.fetch(FetchDescriptor<ScenarioSubscription>()) {
                subscription.feedLink = subscription.feedLink == "s1" ? "s2" : "s1"
            }
        }
        await device.settle()

        let updates = context.performAndWait {
            CloudKitUpdate.find(ids: [s1Name, s2Name], in: context).mapValues { Set($0.backfilledKeys) }
        }
        // s2's model is at s1's name now, and the other way around
        #expect(updates[s1Name]?.isEmpty ?? true)
        #expect(updates[s2Name] == ["title", "position"])
        device.terminate()
    }
}

/// The observer a test registers, which it removes at its end.
private final class ObserverToken: @unchecked Sendable {
    var token: NSObjectProtocol?
}
