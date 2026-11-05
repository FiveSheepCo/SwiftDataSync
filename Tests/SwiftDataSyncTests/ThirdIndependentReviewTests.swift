import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// The scenarios of a third independent review of the natural keys and backfill.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct ThirdIndependentReviewTests {

    /// An app observes saves after the synchronizer was set up, and stamps the subscriptions being saved. The stamp is saved
    /// with the edit, so it's uploaded too, rather than reverted by the next download.
    @Test func valueAnObserverSetsWhileSavingIsUploaded() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        let observedStore = device.synchronizer.observedStore
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: nil, queue: nil) { notification in
            guard let context = notification.object as? NSManagedObjectContext, context.persistentStoreCoordinator == observedStore else { return }
            for object in context.updatedObjects where object.entity.name == "ScenarioSubscription" {
                object.setValue("Stamped", forKey: "note")
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try device.editSubscription("s1") { $0.title = "Edited" }
        NotificationCenter.default.removeObserver(observer)
        await device.sync()
        await device.sync()

        #expect(try device.subscription("s1")?.note == "Stamped")
        #expect(device.serverSubscriptions().first?.note == "Stamped")
        #expect(device.serverSubscriptions().first?.title == "Edited")
        device.terminate()
    }
}
