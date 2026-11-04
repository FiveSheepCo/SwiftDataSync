import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
@testable import SwiftDataSync

/// Workspaces identified by their titles, which documents reference.
private let configurationWithReferencedIdentity = SDSConfiguration(swiftDataEntities: [
    .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink"])),
    .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
    .init(entity: ScenarioNote.self, description: .sync(.without([]))),
    .init(entity: ScenarioWorkspace.self, description: .sync(.without([]), identity: ["title"])),
    .init(entity: ScenarioDocument.self, description: .sync(.without([])))
])

private func workspaceRecordName(_ title: String) -> String {
    SDSIdentity.recordName(entityName: "ScenarioWorkspace", values: [title])
}

/// The scenarios of a third review, of the pull request.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct ThirdReviewScenarioTests {

    // MARK: Identity Changes

    /// An identity value is changed, and the change is discarded before it's saved. The record stays where it is.
    @Test func discardedIdentityChangeKeepsTheRecord() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        // The context reports the change before it's saved
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = device.synchronizer.observedStore
        try context.performAndWait {
            let subscription = try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription")).first)
            subscription.setValue("s2", forKey: "feedLink")
            context.processPendingChanges()
            context.rollback()
        }
        try device.editSubscription("s1") { $0.title = "Edited" }
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1"])
        #expect(server.record(named: subscriptionRecordName("s1"), account: "first")?["title"] as? String == "Edited")
        device.terminate()
    }

    /// An identity value is changed and changed back before the move is uploaded. The record is kept.
    @Test func identityChangedBackKeepsTheRecord() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        device.synchronizer.stop()
        try device.editSubscription("s1") { $0.feedLink = "s2" }
        try device.editSubscription("s2") { $0.feedLink = "s1"; $0.title = "Back" }
        await device.settle()
        device.synchronizer.start()
        await device.settle()
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1"])
        #expect(server.record(named: subscriptionRecordName("s1"), account: "first")?["title"] as? String == "Back")
        device.terminate()
    }

    /// A model moves to another identity, and a new model gets its previous one before the move is uploaded. Both are uploaded.
    @Test func newModelGetsTheRecordOfAMovedIdentity() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        device.synchronizer.stop()
        try device.editSubscription("s1") { $0.feedLink = "s2" }
        try device.insertSubscriptions(["s1"], title: { _ in "New" })
        await device.settle()
        device.synchronizer.start()
        await device.settle()
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])
        #expect(server.record(named: subscriptionRecordName("s1"), account: "first")?["title"] as? String == "New")
        #expect(server.record(named: subscriptionRecordName("s2"), account: "first")?["title"] as? String == "Title of s1")
        device.terminate()
    }

    /// The identity of a model that other models reference changes. Their records reference its new record, also on
    /// devices that download them later.
    @Test func referencesFollowAnIdentityChange() async throws {
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        try await first.launch(configuration: configurationWithReferencedIdentity)
        try first.change { context in
            let workspace = ScenarioWorkspace(title: "Before")
            let document = ScenarioDocument(title: "Document")
            context.insert(workspace)
            context.insert(document)
            document.workspace = workspace
        }
        await first.sync()
        try first.change { context in
            let workspace = try #require(try context.fetch(FetchDescriptor<ScenarioWorkspace>()).first)
            workspace.title = "After"
        }
        await first.sync()

        #expect(server.record(named: workspaceRecordName("Before"), account: "first") == nil)
        let document = try #require(server.records(account: "first").first { $0.recordType == "ScenarioDocument" })
        #expect((document["workspace"] as? CKRecord.Reference)?.recordID.recordName == workspaceRecordName("After"))

        let second = TestDevice("B", server: server)
        try await second.launch(configuration: configurationWithReferencedIdentity)
        try second.change { context in
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            #expect(document.workspace?.title == "After")
        }
        first.terminate()
        second.terminate()
    }

    // MARK: Synchronizing Now

    /// The settings' "Sync Now" tries records CloudKit rejected again right away, like `forceDownload()`.
    @Test func syncNowRetriesRejectedRecords() async throws {
        let server = FakeCloudServer()
        server.isProduction = true
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.settle()
        #expect(device.serverSubscriptions().isEmpty)

        server.isProduction = false
        await device.viewModel.forceSync()
        #expect(await waitUntil(timeout: 5) { device.serverSubscriptions().count == 1 })
        device.terminate()
    }
}

/// Configurations whose identities couldn't name their records, and finding the models of identities.
@Suite(.coreDataReady)
struct ThirdReviewTests {

    private func entity(syncedProperties: [String] = [], assetProperties: [String] = [], parentKey: String? = nil, isSharable: Bool = false, identity: [String] = []) -> SDSInternalConfiguration.Entity {
        .init(syncedProperties: syncedProperties, assetProperties: assetProperties, parentKey: parentKey, isSharable: isSharable, referenceDepth: 0, identity: identity)
    }

    @Test func identitiesStayOutOfHierarchies() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: [FolderModel.self, NoteModel.self]))
        let problems = { (folder: SDSInternalConfiguration.Entity, note: SDSInternalConfiguration.Entity) in
            SDSInternalConfiguration.identityProblems(of: ["FolderModel": folder, "NoteModel": note], descriptions: model.entitiesByName)
        }

        // Shares of different users can have records of the same identity
        #expect(problems(entity(isSharable: true), entity(syncedProperties: ["text"], parentKey: "folder", identity: ["text"])).count == 1)
        #expect(problems(entity(syncedProperties: ["title"], isSharable: true, identity: ["title"]), entity()).count == 1)
        // Deleting the record of a parent deletes the records of its children
        #expect(problems(entity(syncedProperties: ["title"], identity: ["title"]), entity(parentKey: "folder")).count == 1)
        // Below a parent that isn't sharable
        #expect(problems(entity(), entity(syncedProperties: ["text"], parentKey: "folder", identity: ["text"])).isEmpty)
    }

    @Test func identityValuesHaveToBeInTheRecord() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: [FolderModel.self, NoteModel.self]))
        let problems = { (folder: SDSInternalConfiguration.Entity) in
            SDSInternalConfiguration.identityProblems(of: ["FolderModel": folder], descriptions: model.entitiesByName)
        }

        #expect(problems(entity(syncedProperties: ["title"], identity: ["title"])).isEmpty)
        #expect(problems(entity(syncedProperties: [], identity: ["title"])).count == 1)
        #expect(problems(entity(syncedProperties: ["title"], assetProperties: ["title"], identity: ["title"])).count == 1)
        #expect(problems(entity(syncedProperties: ["notes"], identity: ["notes"])).count == 1)
    }

    /// A record of an entity is never matched to a model of its subentity, whose records have their own record type.
    @Test func modelsOfSubentitiesDontMatch() throws {
        let key = NSAttributeDescription()
        key.name = "key"
        key.type = .string
        key.isOptional = true
        let base = NSEntityDescription()
        base.name = "Base"
        base.properties = [key]
        let sub = NSEntityDescription()
        sub.name = "Sub"
        base.subentities = [sub]
        let model = NSManagedObjectModel()
        model.entities = [base, sub]

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(type: .inMemory, at: URL(filePath: "/dev/null"))
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        try context.performAndWait {
            NSEntityDescription.insertNewObject(forEntityName: "Sub", into: context).setValue("a", forKey: "key")
            try context.save()

            let name = SDSIdentity.recordName(entityName: "Base", values: ["a"])
            #expect(try SDSIdentityIndex(context: context).object(entityName: "Base", keys: ["key"], recordName: name) == nil)
            #expect(try SDSIdentity.matchingObject(in: context, entityName: "Base", keys: ["key"], values: ["a"]) == nil)

            // A model of the entity itself still matches
            NSEntityDescription.insertNewObject(forEntityName: "Base", into: context).setValue("a", forKey: "key")
            try context.save()
            #expect(try SDSIdentityIndex(context: context).object(entityName: "Base", keys: ["key"], recordName: name)?.entity.name == "Base")
        }
    }
}
