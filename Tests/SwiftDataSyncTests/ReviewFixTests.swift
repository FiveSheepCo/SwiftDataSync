import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
@testable import SwiftDataSync

struct ValueInfo: Codable, Hashable {
    var date: Date
    var name: String
}

enum ValueKind: String, Codable {
    case first, second
}

/// Values SwiftData stores in ways records can't store directly.
@Model
final class ValueModel {
    var uuid: UUID = UUID()
    var names: [String] = []
    var info: ValueInfo = ValueInfo(date: .distantPast, name: "")
    var kind: ValueKind = ValueKind.first
    var link: URL? = nil
    var note: String? = nil
    var count: Int = 0

    init() {}
}

@Model
final class FolderModel {
    var title: String = ""
    @Relationship(deleteRule: .cascade, inverse: \NoteModel.folder) var notes: [NoteModel]? = []

    init() {}
}

@Model
final class NoteModel {
    var text: String = ""
    var folder: FolderModel?

    init() {}
}

@Model
final class RequiredModel {
    var createdAt: Date
    var title: String = ""

    init(createdAt: Date) {
        self.createdAt = createdAt
    }
}

/// A SwiftData store and a context on the same store, like the store the synchronizer observes.
private struct ValueStore {
    let modelContext: ModelContext
    let context: NSManagedObjectContext
    let model: NSManagedObjectModel

    init(for types: [any PersistentModel.Type]) throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "Values.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let modelContainer = try ModelContainer(for: Schema(types), configurations: ModelConfiguration(url: url))
        modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = false

        model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: types))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        // SwiftData tracks the history, which a coordinator has to as well to save
        _ = try coordinator.addPersistentStore(type: .sqlite, at: url, options: [NSPersistentHistoryTrackingKey: true as NSNumber])
        context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }
}

/// Values of attributes that records can't store directly are converted, both ways, rather than crashing the upload.
@Suite(.coreDataReady)
struct ValueCodingTests {

    @Test func valuesSurviveTheRoundTrip() throws {
        let store = try ValueStore(for: [ValueModel.self])
        let original = ValueModel()
        original.names = ["a", "b, c"]
        original.info = ValueInfo(date: Date(timeIntervalSinceReferenceDate: 815_000_000.5), name: "Info")
        original.kind = .second
        original.link = URL(string: "https://example.com/feed?a=1")
        store.modelContext.insert(original)
        try store.modelContext.save()

        let keys = ["uuid", "names", "info", "kind", "link"]
        try store.context.performAndWait {
            let object = try #require(try store.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ValueModel")).first)
            let container = SDSSynchronizableContainer(id: { "id" }, object: object, syncKeys: keys, assetKeys: [])
            let record = try container.changeDictionary(for: keys)

            #expect(Set(record.keys) == Set(keys))
            #expect(record["uuid"] as? String == (object.value(forKey: "uuid") as? UUID)?.uuidString)
            #expect(record["link"] as? String == "https://example.com/feed?a=1")
            #expect(record["names"]??.isKind(of: NSData.self) == true)
            #expect(record["info"]??.isKind(of: NSData.self) == true)

            // Downloaded into another object, the values are the same
            let copy = NSEntityDescription.insertNewObject(forEntityName: "ValueModel", into: store.context)
            let entity = object.entity
            for key in keys {
                let value: Any? = record[key] ?? nil
                copy.setValue(try SDSValueCoding.localValue(for: value, attribute: try #require(entity.attributesByName[key])), forKey: key)
            }
            try store.context.save()

            for key in keys {
                #expect((copy.value(forKey: key) as? NSObject) == (object.value(forKey: key) as? NSObject), "\(key)")
            }
        }
    }

    /// Devices with earlier versions stored `Codable` values that are valid JSON as JSON, which can still be read.
    @Test func jsonValuesCanStillBeRead() throws {
        let store = try ValueStore(for: [ValueModel.self])
        let attribute = try #require(store.model.entitiesByName["ValueModel"]?.attributesByName["kind"])
        let json = try JSONSerialization.data(withJSONObject: ["kind": "second"])
        let value = try SDSValueCoding.localValue(for: json, attribute: attribute) as? NSDictionary
        #expect(value?["kind"] as? String == "second")
    }

    @Test func unsupportedValuesAreLeftOut() throws {
        let store = try ValueStore(for: [ValueModel.self])
        try store.context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: "ValueModel", into: store.context)
            let attribute = try #require(object.entity.attributesByName["names"])
            let unregistered = try #require(attribute.copy() as? NSAttributeDescription)
            unregistered.valueTransformerName = "SDSTestTransformerThatIsNotRegistered"

            #expect(throws: SDSValueCoding.UnsupportedValueError.self) {
                try SDSValueCoding.cloudValue(for: ["a"], attribute: unregistered)
            }
            #expect(throws: SDSValueCoding.UnsupportedValueError.self) {
                try SDSValueCoding.cloudValue(for: NSObject(), attribute: nil)
            }
        }
    }

    /// Empty relationships are stored as no value. Unordered ones can't be stored, which leaves them out instead of crashing.
    @Test func relationshipsDontCrash() throws {
        let item = NSEntityDescription()
        item.name = "Item"
        let owner = NSEntityDescription()
        owner.name = "Owner"

        let items = NSRelationshipDescription()
        items.name = "items"
        items.destinationEntity = item
        items.isOrdered = true
        items.maxCount = 0
        items.isOptional = true
        let others = NSRelationshipDescription()
        others.name = "others"
        others.destinationEntity = item
        others.maxCount = 0
        others.isOptional = true
        owner.properties = [items, others]

        let model = NSManagedObjectModel()
        model.entities = [owner, item]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(type: .inMemory, at: URL(fileURLWithPath: "/dev/null"))
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        try context.performAndWait {
            let object = NSManagedObject(entity: owner, insertInto: context)
            let container = SDSSynchronizableContainer(id: { "id" }, object: object, syncKeys: ["items", "others"], assetKeys: [])
            let empty = try container.changeDictionary(for: ["items", "others"])
            #expect(empty.keys.sorted() == ["items", "others"])
            #expect(empty["items"]! == nil)
            #expect(empty["others"]! == nil)

            object.setValue(NSSet(object: NSManagedObject(entity: item, insertInto: context)), forKey: "others")
            #expect(try container.changeDictionary(for: ["others"]).isEmpty)
        }
    }

    /// Records leave out keys without a value, so a synchronized optional key that a record leaves out was cleared.
    @Test func missingKeysAreCleared() throws {
        let store = try ValueStore(for: [ValueModel.self])
        let entity = try #require(store.model.entitiesByName["ValueModel"])
        let record = CKRecord(recordType: "ValueModel", recordID: CKRecord.ID(recordName: "x", zoneID: CKRecordZone.ID(zoneName: "CoreData")))
        record["count"] = 3 as Int64
        record["link"] = "https://example.com"
        let syncedKeys = ["note", "link", "count", "uuid"]

        let cleared = SDSValueCoding.clearedValues(of: record, entity: entity, syncedKeys: syncedKeys, excludedKeys: [], catchUpKeys: [])
        // Only optional keys that the record leaves out
        #expect(Array(cleared.keys) == ["note"])
        #expect(cleared["note"]! == nil)

        // Not keys with local changes, or keys of a pending catch-up
        #expect(SDSValueCoding.clearedValues(of: record, entity: entity, syncedKeys: syncedKeys, excludedKeys: ["note"], catchUpKeys: []).isEmpty)
        #expect(SDSValueCoding.clearedValues(of: record, entity: entity, syncedKeys: syncedKeys, excludedKeys: [], catchUpKeys: ["ValueModel.note"]).isEmpty)
        #expect(SDSValueCoding.clearedValues(of: record, entity: entity, syncedKeys: syncedKeys, excludedKeys: [], catchUpKeys: ["ValueModel"]).isEmpty)
    }

    /// The files of uploaded assets are removed, but not files of other assets.
    @Test func temporaryAssetFilesAreRemoved() throws {
        let asset = try CKAsset(data: Data("asset".utf8))
        let fileURL = try #require(asset.fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let otherURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try Data("other".utf8).write(to: otherURL)

        let record = CKRecord(recordType: "ValueModel")
        record["image"] = asset
        record["other"] = CKAsset(fileURL: otherURL)
        CKAsset.removeTemporaryFiles(of: [record])

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(FileManager.default.fileExists(atPath: otherURL.path))
        try? FileManager.default.removeItem(at: otherURL)
    }
}

/// How the configuration is made from the model.
@Suite(.coreDataReady)
struct ConfigurationTests {

    /// The inverse relationship's settings are read for the inverse. In the sorted order, `FolderModel.notes` is decided
    /// first, which took `NoteModel`'s settings for `notes` and synchronized the unordered relationship instead of the parent.
    @Test func parentRelationshipIsSynchronized() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: [FolderModel.self, NoteModel.self]))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)

        let configuration = coordinator.makeConfiguration(externalConfiguration: SDSConfiguration(swiftDataEntities: [
            .init(entity: NoteModel.self, description: .sync(.with(["text", "folder"]), parentKey: "folder"))
        ]))

        #expect(configuration.entities["NoteModel"]?.syncedProperties.sorted() == ["folder", "text"])
        #expect(configuration.entities["FolderModel"]?.syncedProperties.sorted() == ["title"])
    }

    @Test func requiredValuesHaveToBeSynchronized() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: [RequiredModel.self]))
        let entity = try #require(model.entitiesByName["RequiredModel"])

        #expect(SDSInternalConfiguration.unsynchronizedRequiredAttributes(of: entity, syncedProperties: ["title"]) == ["createdAt"])
        #expect(SDSInternalConfiguration.unsynchronizedRequiredAttributes(of: entity, syncedProperties: ["createdAt"]).isEmpty)
    }
}

/// Records CloudKit rejects don't keep the other changes from being uploaded.
@Suite(.coreDataReady)
struct QuarantineTests {

    @Test func rejectedRecordsWaitUntilTheyChange() {
        var quarantine = SDSRecordQuarantine()
        let changeDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = Date(timeIntervalSinceReferenceDate: 2_000)

        #expect(!quarantine.contains("a", lastChangeDate: changeDate, now: now))
        quarantine.add("a", lastChangeDate: changeDate, now: now)
        #expect(quarantine.contains("a", lastChangeDate: changeDate, now: now))
        // A change might fix it
        #expect(!quarantine.contains("a", lastChangeDate: changeDate.addingTimeInterval(1), now: now))
        // As might time
        #expect(!quarantine.contains("a", lastChangeDate: changeDate, now: now.addingTimeInterval(SDSRecordQuarantine.duration)))
        #expect(!quarantine.contains("b", lastChangeDate: changeDate, now: now))
    }

    @Test func onlyPermanentErrorsReject() {
        func error(_ code: CKError.Code) -> Error {
            NSError(domain: CKErrorDomain, code: code.rawValue)
        }
        #expect(SDSRecordQuarantine.isPermanentRejection(error(.limitExceeded)))
        #expect(SDSRecordQuarantine.isPermanentRejection(error(.invalidArguments)))
        #expect(SDSRecordQuarantine.isPermanentRejection(error(.referenceViolation)))
        #expect(!SDSRecordQuarantine.isPermanentRejection(error(.networkFailure)))
        #expect(!SDSRecordQuarantine.isPermanentRejection(error(.batchRequestFailed)))
        #expect(!SDSRecordQuarantine.isPermanentRejection(error(.serverRecordChanged)))
        #expect(!SDSRecordQuarantine.isPermanentRejection(error(.zoneNotFound)))
    }

    @Test func missingPrivateZoneIsNoticed() {
        let privateZone = CKRecordZone.ID(zoneName: "CoreData")
        let sharedZone = CKRecordZone.ID(zoneName: "CoreData", ownerName: "_other")
        func partialFailure(_ errors: [AnyHashable: Error]) -> Error {
            NSError(domain: CKErrorDomain, code: CKError.partialFailure.rawValue, userInfo: [CKPartialErrorsByItemIDKey: errors])
        }
        let zoneNotFound = NSError(domain: CKErrorDomain, code: CKError.zoneNotFound.rawValue)
        let userDeletedZone = NSError(domain: CKErrorDomain, code: CKError.userDeletedZone.rawValue)

        #expect(SDSSynchronizer.privateZoneMissingError(in: zoneNotFound, defaultZoneID: privateZone)?.code == .zoneNotFound)
        #expect(SDSSynchronizer.privateZoneMissingError(in: partialFailure([privateZone: userDeletedZone]), defaultZoneID: privateZone)?.code == .userDeletedZone)
        #expect(SDSSynchronizer.privateZoneMissingError(in: partialFailure([CKRecord.ID(recordName: "a", zoneID: privateZone): zoneNotFound]), defaultZoneID: privateZone) != nil)
        // Zones of the shared database disappear when they're no longer shared
        #expect(SDSSynchronizer.privateZoneMissingError(in: partialFailure([sharedZone: zoneNotFound]), defaultZoneID: privateZone) == nil)
        #expect(SDSSynchronizer.privateZoneMissingError(in: NSError(domain: CKErrorDomain, code: CKError.networkFailure.rawValue), defaultZoneID: privateZone) == nil)
    }
}

/// Once an app that synchronized before stores the synchronization data in an app group, its data is moved there.
/// Starting over would download every record again as new models.
@Suite(.coreDataReady)
struct SyncDataLocationTests {

    /// It isn't changed after it's made.
    nonisolated(unsafe) private static let model: NSManagedObjectModel = {
        let value = NSAttributeDescription()
        value.name = "value"
        value.type = .string
        let entity = NSEntityDescription()
        entity.name = "Row"
        entity.properties = [value]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }()

    private func storedValues(at url: URL) throws -> [String] {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Self.model)
        _ = try coordinator.addPersistentStore(type: .sqlite, at: url)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return try context.performAndWait {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Row")).compactMap { $0.value(forKey: "value") as? String }
        }
    }

    @Test func dataIsMovedOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let appURL = directory.appending(path: "App/CloudKitSync.sqlite")
        let groupURL = directory.appending(path: "Group/CloudKitSync.sqlite")
        for url in [appURL, groupURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Self.model)
        let store = try coordinator.addPersistentStore(type: .sqlite, at: appURL)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            NSEntityDescription.insertNewObject(forEntityName: "Row", into: context).setValue("mapping", forKey: "value")
            try context.save()
        }
        try coordinator.remove(store)
        try Data("[]".utf8).write(to: appURL.deletingLastPathComponent().appending(path: "CloudKitSync.keys.json"))

        SDSSynchronizer.moveSyncData(from: appURL, to: groupURL, coordinator: NSPersistentStoreCoordinator(managedObjectModel: Self.model))

        #expect(try storedValues(at: groupURL) == ["mapping"])
        #expect(FileManager.default.fileExists(atPath: groupURL.deletingLastPathComponent().appending(path: "CloudKitSync.keys.json").path))
        // The previous store is emptied, so it isn't used with outdated data if the app group is no longer used
        #expect(try storedValues(at: appURL).isEmpty)

        // Data that's in the app group already stays
        SDSSynchronizer.moveSyncData(from: appURL, to: groupURL, coordinator: NSPersistentStoreCoordinator(managedObjectModel: Self.model))
        #expect(try storedValues(at: groupURL) == ["mapping"])
    }
}

/// The view model's state decides which synchronizations start. It's shared, so these run one after another.
@Suite(.coreDataReady, .serialized)
@MainActor
struct SynchronizationStateTests {

    /// A push received while a synchronization runs might be for a change its download missed, so another one follows.
    @Test func requestWhileSyncingIsRemembered() {
        let viewModel = SDSSynchronizationViewModel.shared
        viewModel.set(state: .downloading)

        #expect(!viewModel.attemptSyncStart())
        #expect(viewModel.takeSyncRequestedWhileSyncing())
        #expect(!viewModel.takeSyncRequestedWhileSyncing())

        viewModel.set(state: .idle)
        #expect(viewModel.attemptSyncStart())
        #expect(!viewModel.takeSyncRequestedWhileSyncing())
        viewModel.set(state: .idle)
    }

    @Test func stoppedStateStays() async throws {
        let viewModel = SDSSynchronizationViewModel.shared
        viewModel.set(state: .stopped)
        #expect(!viewModel.attemptSyncStart())

        // E.g. a save is processed while stopped, and stopping stays visible
        let previousState = try await viewModel.waitForIdle(setting: .processingSaveEvent)
        viewModel.restore(previousState)
        guard case .stopped = viewModel.state else {
            Issue.record("Expected the stopped state, got \(viewModel.state)")
            return
        }

        viewModel.endStop()
        guard case .idle = viewModel.state else {
            Issue.record("Expected the idle state, got \(viewModel.state)")
            return
        }
    }
}
