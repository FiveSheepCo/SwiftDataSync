import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
@testable import SwiftDataSync

@Model
final class IdentityModel {
    var link: String = ""
    var guid: String = ""
    var count: Int = 0
    var flag: Bool = false
    var rate: Double = 0
    var date: Date = Date.distantPast
    var note: String? = nil

    init(link: String, guid: String) {
        self.link = link
        self.guid = guid
    }
}

/// The synchronization data's model, loaded once: several models claiming the same classes would confuse Core Data.
/// It isn't changed after it's made.
nonisolated(unsafe) private let syncDataModel: NSManagedObjectModel = {
    let model = NSManagedObjectModel.mergedModel(from: [.module])!
    for entity in model.entities {
        entity.managedObjectClassName = "SwiftDataSync.\(entity.name!)"
    }
    return model
}()

/// Entities with an identity name their records after it, so models that several devices create for the same thing share
/// one record. Everything but CloudKit itself is checked here: naming, finding local models for downloaded records, giving
/// them the records, and saving over a record another device saved first.
@Suite
struct IdentityTests {

    /// A model container and a coordinator on the same store, like the store the synchronizer observes.
    private struct Store {
        let modelContext: ModelContext
        let coordinator: NSPersistentStoreCoordinator
        /// A context on the coordinator, like the synchronizer's observed update context.
        let context: NSManagedObjectContext

        init() throws {
            let url = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                .appending(path: "Identity.store")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let modelContainer = try ModelContainer(for: IdentityModel.self, configurations: ModelConfiguration(url: url))
            modelContext = ModelContext(modelContainer)
            modelContext.autosaveEnabled = false

            let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: [IdentityModel.self]))
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: url)
            context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
        }

        var entity: NSEntityDescription {
            coordinator.managedObjectModel.entitiesByName["IdentityModel"]!
        }
    }

    /// The synchronization data, in memory.
    private func makeSyncDataContext() throws -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "CloudKitSync", managedObjectModel: syncDataModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: (any Error)?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container.newBackgroundContext()
    }

    private let zoneID = CKRecordZone.ID(zoneName: "CoreData")

    // MARK: Naming

    @Test func recordNameIsTheSameForTheSameValues() {
        let name = SDSIdentity.recordName(entityName: "Subscription", values: ["https://example.com/feed", 5])
        #expect(name == SDSIdentity.recordName(entityName: "Subscription", values: ["https://example.com/feed", 5]))
        #expect(name.hasPrefix("Subscription."))
        #expect(name.count == "Subscription.".count + 64)
        #expect(name.allSatisfy { $0.isASCII })

        let long = SDSIdentity.recordName(entityName: "EpisodeState", values: [String(repeating: "x", count: 2000)])
        #expect(long.count < 255)
    }

    @Test func recordNameKeepsValuesApart() {
        let name = { (entityName: String, values: [Any?]) in SDSIdentity.recordName(entityName: entityName, values: values) }
        #expect(name("A", ["a,b"]) != name("A", ["a", "b"]))
        #expect(name("A", ["1:a"]) != name("A", ["1", "a"]))
        #expect(name("A", [nil]) != name("A", [""]))
        #expect(name("A", ["-"]) != name("A", [nil]))
        #expect(name("A", ["a", "b"]) != name("A", ["b", "a"]))
        #expect(name("A", ["a"]) != name("B", ["a"]))
    }

    /// A device names a model after its own values, another device matches the record's values: CloudKit returns
    /// booleans as numbers and dates to the millisecond.
    @Test func modelAndItsRecordGiveTheSameName() throws {
        let store = try Store()
        let date = Date(timeIntervalSinceReferenceDate: 815_000_000.123_456_7)
        let model = IdentityModel(link: "https://example.com/feed", guid: "guid-ü")
        model.count = 3
        model.flag = true
        model.rate = 1.25
        model.date = date
        store.modelContext.insert(model)
        try store.modelContext.save()

        let keys = ["link", "guid", "count", "flag", "rate", "date"]
        let localName = try store.context.performAndWait {
            let object = try #require(try store.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "IdentityModel")).first)
            return SDSIdentity.recordName(entityName: "IdentityModel", values: SDSIdentity.values(of: object, keys: keys))
        }

        let record = CKRecord(recordType: "IdentityModel", recordID: CKRecord.ID(recordName: localName, zoneID: zoneID))
        record["link"] = "https://example.com/feed"
        record["guid"] = "guid-ü"
        record["count"] = 3 as Int64
        record["flag"] = 1 as Int64
        record["rate"] = 1.25
        record["date"] = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
        let recordName = SDSIdentity.recordName(entityName: "IdentityModel", values: SDSIdentity.values(in: record, entity: store.entity, keys: keys))

        #expect(localName == recordName)
    }

    // MARK: Downloading

    @Test func downloadedRecordFindsTheSavedModelWithItsIdentity() throws {
        let store = try Store()
        let date = Date(timeIntervalSinceReferenceDate: 815_000_000.123_456_7)
        let saved = IdentityModel(link: "https://example.com/feed", guid: "1")
        saved.date = date
        store.modelContext.insert(saved)
        store.modelContext.insert(IdentityModel(link: "https://example.com/feed", guid: "2"))
        try store.modelContext.save()

        func match(_ link: String, _ guid: String, _ date: Date? = nil) throws -> NSManagedObject? {
            let record = CKRecord(recordType: "IdentityModel", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
            record["link"] = link
            record["guid"] = guid
            record["date"] = date
            let keys = date == nil ? ["link", "guid"] : ["link", "guid", "date"]
            let values = SDSIdentity.values(in: record, entity: store.entity, keys: keys)
            return try store.context.performAndWait {
                try SDSIdentity.matchingObject(in: store.context, entityName: "IdentityModel", keys: keys, values: values)
            }
        }

        let found = try #require(try match("https://example.com/feed", "1"))
        #expect(store.context.performAndWait { found.value(forKey: "guid") as? String } == "1")
        #expect(try match("https://example.com/feed", "3") == nil)
        #expect(try match("https://example.com/other", "1") == nil)
        // The record's date only has milliseconds
        #expect(try match("https://example.com/feed", "1", Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)) != nil)
        #expect(try match("https://example.com/feed", "1", date.addingTimeInterval(0.01)) == nil)
    }

    /// A model that isn't saved has no record to give a downloaded one, e.g. one the same download inserted.
    @Test func downloadedRecordDoesNotFindUnsavedModels() throws {
        let store = try Store()
        let found = try store.context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: "IdentityModel", into: store.context)
            object.setValue("https://example.com/feed", forKey: "link")
            object.setValue("1", forKey: "guid")
            return try SDSIdentity.matchingObject(in: store.context, entityName: "IdentityModel", keys: ["link", "guid"], values: ["https://example.com/feed", "1"])
        }
        #expect(found == nil)
    }

    @Test func downloadedRecordIsGivenToTheMatchingModel() throws {
        let context = try makeSyncDataContext()
        let name = SDSIdentity.recordName(entityName: "IdentityModel", values: ["https://example.com/feed", "1"])

        try context.performAndWait {
            // A model without a record gets it
            let first = CloudKitLocalEntity.adopt(recordName: name, forLocalId: "x-coredata://store/IdentityModel/p1", isNamedAfterIdentity: true, in: context)
            #expect(first.adopted && first.previousId == nil)
            #expect(CloudKitLocalEntity.entry(forLocalId: "x-coredata://store/IdentityModel/p1", in: context)?.id == name)

            // A model with a random record gets the one named after its identity, its own is deleted as a duplicate
            _ = CloudKitLocalEntity(id: "random", localId: "x-coredata://store/IdentityModel/p2", context: context)
            let second = CloudKitLocalEntity.adopt(recordName: name + "2", forLocalId: "x-coredata://store/IdentityModel/p2", isNamedAfterIdentity: true, in: context)
            #expect(second.adopted && second.previousId == "random")

            // A record that isn't named after its identity, e.g. uploaded before the identity was configured, doesn't replace one
            _ = CloudKitLocalEntity(id: "own", localId: "x-coredata://store/IdentityModel/p3", context: context)
            let third = CloudKitLocalEntity.adopt(recordName: "legacy", forLocalId: "x-coredata://store/IdentityModel/p3", isNamedAfterIdentity: false, in: context)
            #expect(!third.adopted && third.previousId == nil)
            #expect(CloudKitLocalEntity.entry(forLocalId: "x-coredata://store/IdentityModel/p3", in: context)?.id == "own")
            try context.save()
        }
    }

    // MARK: Uploading

    @Test func newModelIsNamedAfterItsIdentity() throws {
        let context = try makeSyncDataContext()
        let name = SDSIdentity.recordName(entityName: "IdentityModel", values: ["https://example.com/feed", "1"])

        context.performAndWait {
            let first = CloudKitLocalEntity.recordId(forLocalId: "x-coredata://store/IdentityModel/p1", identityRecordName: name, renamingToIdentity: false, in: context)
            #expect(first.id == name && first.previousId == nil)
            #expect(CloudKitLocalEntity.recordId(forLocalId: "x-coredata://store/IdentityModel/p1", identityRecordName: name, renamingToIdentity: false, in: context).id == name)

            // A second local model with the same identity can't share the record
            let second = CloudKitLocalEntity.recordId(forLocalId: "x-coredata://store/IdentityModel/p2", identityRecordName: name, renamingToIdentity: false, in: context)
            #expect(second.id != name && second.previousId == nil)

            // Without an identity, records are named randomly as before
            let other = CloudKitLocalEntity.recordId(forLocalId: "x-coredata://store/IdentityModel/p3", identityRecordName: nil, renamingToIdentity: false, in: context)
            #expect(UUID(uuidString: other.id) != nil)
        }
    }

    @Test func changedIdentityMovesTheModelToAnotherRecord() throws {
        let context = try makeSyncDataContext()
        let oldName = SDSIdentity.recordName(entityName: "IdentityModel", values: ["https://example.com/old", "1"])
        let newName = SDSIdentity.recordName(entityName: "IdentityModel", values: ["https://example.com/new", "1"])
        let localId = "x-coredata://store/IdentityModel/p1"

        context.performAndWait {
            _ = CloudKitLocalEntity.recordId(forLocalId: localId, identityRecordName: oldName, renamingToIdentity: false, in: context)

            // Other changes keep the record
            let unchanged = CloudKitLocalEntity.recordId(forLocalId: localId, identityRecordName: newName, renamingToIdentity: false, in: context)
            #expect(unchanged.id == oldName && unchanged.previousId == nil)

            let moved = CloudKitLocalEntity.recordId(forLocalId: localId, identityRecordName: newName, renamingToIdentity: true, in: context)
            #expect(moved.id == newName && moved.previousId == oldName)
            #expect(CloudKitLocalEntity.entry(forLocalId: localId, in: context)?.id == newName)

            // Another model has the record of the new identity already, so this one keeps its record
            _ = CloudKitLocalEntity(id: oldName, localId: "x-coredata://store/IdentityModel/p2", context: context)
            let blocked = CloudKitLocalEntity.recordId(forLocalId: localId, identityRecordName: oldName, renamingToIdentity: true, in: context)
            #expect(blocked.id == newName && blocked.previousId == nil)
        }
    }

    /// When another device saved the same identity first, this device's changed keys are saved over its record.
    @Test func conflictSavesTheChangedKeysOverTheOtherDevicesRecord() {
        let recordID = CKRecord.ID(recordName: SDSIdentity.recordName(entityName: "IdentityModel", values: ["a", "1"]), zoneID: zoneID)
        let server = CKRecord(recordType: "IdentityModel", recordID: recordID)
        server["link"] = "a"
        server["count"] = 1 as Int64
        server["note"] = "From the other device"

        let local = CKRecord(recordType: "IdentityModel", recordID: recordID)
        local["count"] = 7 as Int64
        local["rate"] = 2.5

        let merged = SDSIdentity.merging(local, into: server)
        #expect(merged === server)
        #expect(merged.recordID == recordID)
        #expect(merged["count"] as? Int64 == 7)
        #expect(merged["rate"] as? Double == 2.5)
        #expect(merged["note"] as? String == "From the other device")
        #expect(merged["link"] as? String == "a")
    }

    @Test func conflictKeepsAClearedParent() {
        let recordID = CKRecord.ID(recordName: "IdentityModel.x", zoneID: zoneID)
        let server = CKRecord(recordType: "IdentityModel", recordID: recordID)
        server.setParent(CKRecord.ID(recordName: "Parent.y", zoneID: zoneID))

        let local = CKRecord(recordType: "IdentityModel", recordID: recordID)
        local.setParent(nil as CKRecord.ID?)
        local[SDSSynchronizer.Constants.parentWorkaroundKey] = nil
        #expect(SDSIdentity.merging(local, into: server).parent == nil)

        let unchangedParent = CKRecord(recordType: "IdentityModel", recordID: recordID)
        unchangedParent.setParent(CKRecord.ID(recordName: "Parent.y", zoneID: zoneID))
        #expect(SDSIdentity.merging(CKRecord(recordType: "IdentityModel", recordID: recordID), into: unchangedParent).parent != nil)
    }

    // MARK: Configuration

    @Test func configurationKeepsTheIdentity() throws {
        let store = try Store()
        let withIdentity = store.coordinator.makeConfiguration(externalConfiguration: SDSConfiguration(swiftDataEntities: [
            .init(entity: IdentityModel.self, description: .sync(.without(["note"]), identity: ["link", "guid"]))
        ]))
        #expect(withIdentity.entities["IdentityModel"]?.identity == ["link", "guid"])
        #expect(withIdentity.entities["IdentityModel"]?.syncedProperties.contains("note") == false)

        let raw = store.coordinator.makeConfiguration(externalConfiguration: SDSConfiguration(rawEntities: [
            "IdentityModel": .sync(.all, identity: ["link"])
        ]))
        #expect(raw.entities["IdentityModel"]?.identity == ["link"])

        let withoutIdentity = store.coordinator.makeConfiguration(externalConfiguration: SDSConfiguration(swiftDataEntities: []))
        #expect(withoutIdentity.entities["IdentityModel"]?.identity == [])
    }
}
