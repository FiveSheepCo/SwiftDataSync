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
