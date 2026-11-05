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
