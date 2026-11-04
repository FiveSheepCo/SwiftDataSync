import Foundation
import CoreData
import CloudKit
import CryptoKit

/// Names the records of entities with an identity after the values that identify their models, so models that several
/// devices create for the same thing share one record. See `SDSConfiguration.Entity.sync`.
enum SDSIdentity {

    /// `<Entity>.<SHA-256 of the values>`, the same on every device.
    static func recordName(entityName: String, values: [Any?]) -> String {
        // Each value is prefixed with its length, so values containing a separator can't be mistaken for several values.
        // Not JSON: its escaping could change with the OS, which would name the same model differently on two devices.
        let text = values.map { value in
            canonicalString(value).map { "\($0.utf8.count):\($0)" } ?? "-"
        }.joined(separator: ",")
        let digest = SHA256.hash(data: Data(text.utf8))
        // Without `String(format:)` for each byte, as downloads name every model of an entity at once
        let hexDigits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0f)])
        }
        return entityName + "." + String(decoding: hex, as: UTF8.self)
    }

    /// The record name of a model with the identity values, `nil` if one of them has no value: models without all of their
    /// identity values aren't identified by them, but get records of their own, like models without an identity, rather
    /// than unrelated models sharing a record.
    static func identityRecordName(entityName: String, values: [Any?]) -> String? {
        guard values.allSatisfy({ canonicalString($0) != nil }) else { return nil }
        return recordName(entityName: entityName, values: values)
    }

    /// The text of a value, the same for the value of a model and the one its record returns: CloudKit stores booleans as
    /// numbers and dates to the millisecond. `nil` for no value.
    static func canonicalString(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull: nil
        case let string as String: string
        // Dates too far away for milliseconds as an integer can't be in records anyway
        case let date as Date: Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()).map(String.init) ?? String(date.timeIntervalSince1970)
        case let number as NSNumber: number.stringValue
        case let url as URL: url.absoluteString
        case let uuid as UUID: uuid.uuidString
        case let data as Data: data.base64EncodedString()
        case let value?: String(describing: value)
        }
    }

    /// The identity values of a model. Has to be called on the queue of the model's context.
    static func values(of object: NSManagedObject, keys: [String]) -> [Any?] {
        keys.map { object.value(forKey: $0) }
    }

    /// The identity values of a record, which stores keys under their renaming identifier.
    static func values(in record: CKRecord, entity: NSEntityDescription, keys: [String]) -> [Any?] {
        keys.map { key in
            record[entity.propertiesByName[key]?.renamingIdentifier ?? key]
        }
    }

    /// A saved model of the entity with the identity values, e.g. one this device created for the same thing before
    /// downloading the record of another device. Has to be called on the context's queue.
    static func matchingObject(in context: NSManagedObjectContext, entityName: String, keys: [String], values: [Any?]) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.sortDescriptors = []
        // Records of subentities have their own record type
        request.includesSubentities = false
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: zip(keys, values).map { key, value in
            switch value {
            case nil, is NSNull:
                return NSPredicate(format: "%K == nil", key)
            case let date as Date:
                // Records store dates to the millisecond
                return NSPredicate(format: "%K > %@ AND %K <= %@", key, date.addingTimeInterval(-0.0005) as NSDate, key, date.addingTimeInterval(0.0005) as NSDate)
            case let value?:
                return NSPredicate(format: "%K == %@", argumentArray: [key, value])
            }
        })
        // Models that aren't saved yet, e.g. inserted by the same download, have no record that could be replaced
        return try context.fetch(request).first { !$0.objectID.isTemporaryID }
    }

    /// The record another device saved first, with the keys of `local` that this device changed, to save them over it.
    static func merging(_ local: CKRecord, into server: CKRecord) -> CKRecord {
        let changedKeys = local.changedKeys()
        for key in changedKeys {
            server[key] = local[key]
        }
        // The parent is only set when it changed, which also sets this key, see `record(for:)`
        if changedKeys.contains(SDSSynchronizer.Constants.parentWorkaroundKey) {
            server.parent = local.parent
        }
        return server
    }
}

/// Saved local objects of entities with an identity by the record name their identity values give them, so a download finds
/// the object for a record it doesn't know yet without a fetch for each record.
///
/// It's built for an entity once a download needs it, with a fetch of the identity values only, and kept up to date with
/// the objects the download inserts, which can be found once they're saved. Has to be used on the queue of its context.
final class SDSIdentityIndex {
    private let context: NSManagedObjectContext
    private var objectIDs: [String: [String: NSManagedObjectID]] = [:]
    /// Objects the download inserted, which only have permanent IDs once they're saved.
    private var insertedObjects: [String: [String: NSManagedObject]] = [:]

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// A saved object of the entity whose identity values give `recordName`, like `SDSIdentity.matchingObject`.
    func object(entityName: String, keys: [String], recordName: String) throws -> NSManagedObject? {
        if objectIDs[entityName] == nil {
            try build(entityName: entityName, keys: keys)
        }

        let candidate: NSManagedObject?
        if let object = insertedObjects[entityName]?[recordName] {
            candidate = object
        } else if let objectID = objectIDs[entityName]?[recordName] {
            // A deleted object's row is gone
            candidate = try? context.existingObject(with: objectID)
        } else {
            candidate = nil
        }
        // Models that aren't saved yet have no record that could be replaced. The values could have changed since.
        guard
            let candidate,
            !candidate.isDeleted,
            !candidate.objectID.isTemporaryID,
            SDSIdentity.identityRecordName(entityName: entityName, values: SDSIdentity.values(of: candidate, keys: keys)) == recordName
        else { return nil }
        return candidate
    }

    /// Adds an object the download inserted, under the name its identity values give it.
    func add(_ object: NSManagedObject, entityName: String, recordName: String) {
        if insertedObjects[entityName]?[recordName] == nil {
            insertedObjects[entityName, default: [:]][recordName] = object
        }
    }

    /// The inserted objects were saved, so they're kept by their permanent IDs from now on, rather than in memory.
    func objectsWereSaved() {
        for (entityName, objects) in insertedObjects where objectIDs[entityName] != nil {
            for (recordName, object) in objects where !object.objectID.isTemporaryID && objectIDs[entityName]?[recordName] == nil {
                objectIDs[entityName]?[recordName] = object.objectID
            }
        }
        insertedObjects = [:]
    }

    /// The inserted objects weren't saved, as the download was discarded.
    func discardInsertedObjects() {
        insertedObjects = [:]
    }

    private func build(entityName: String, keys: [String]) throws {
        let objectID = NSExpressionDescription()
        objectID.name = "objectID"
        objectID.expression = NSExpression.expressionForEvaluatedObject()
        objectID.expressionResultType = .objectIDAttributeType

        let request = NSFetchRequest<NSDictionary>(entityName: entityName)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = keys + [objectID]
        // Records of subentities have their own record type, see `SDSIdentity.matchingObject`
        request.includesSubentities = false
        // Only saved objects
        request.includesPendingChanges = false

        var index: [String: NSManagedObjectID] = [:]
        for row in try context.fetch(request) {
            guard
                let id = row["objectID"] as? NSManagedObjectID,
                let recordName = SDSIdentity.identityRecordName(entityName: entityName, values: keys.map { row[$0] })
            else { continue }
            if index[recordName] == nil {
                index[recordName] = id
            }
        }
        objectIDs[entityName] = index
    }
}

extension CloudKitLocalEntity {

    /// The record id of the object with the given URI. An object without one gets one: the name its identity gives it
    /// (`identityRecordName`), or a random one if it has no identity or another object has that record already.
    ///
    /// With `renamingToIdentity`, e.g. because an identity value changed, an object whose record has another name than
    /// its identity gives it is given that record, and its previous record id is returned to delete that record. If another
    /// object has that record, or the object lacks identity values, a record named after previous identity values is
    /// replaced with a randomly named one, as another object can take those values.
    /// `isReserved` tells about record ids of objects that get their entities later, e.g. ones a running download inserted.
    /// Has to be called on `context`'s queue.
    static func recordId(
        forLocalId localId: String,
        identityRecordName: String?,
        renamingToIdentity: Bool,
        isReserved: @escaping (String) -> Bool = { _ in false },
        in context: NSManagedObjectContext
    ) -> (id: String, previousId: String?) {
        let isAvailable = { (id: String) in !isReserved(id) && entry(forId: id, in: context) == nil }

        if let entry = entry(forLocalId: localId, in: context) {
            guard renamingToIdentity, entry.id != identityRecordName else { return (entry.id, nil) }

            let id: String
            if let identityRecordName, isAvailable(identityRecordName) {
                id = identityRecordName
            } else if UUID(uuidString: entry.id) == nil {
                // The record is named after identity values the object doesn't have anymore, which another object can take.
                // It moves to a random name, like a model whose identity is taken, or that lacks identity values.
                id = UUID().uuidString
            } else {
                return (entry.id, nil)
            }
            let previousId = entry.id
            entry.id = id
            return (id, previousId)
        }

        // Another local model with the same identity keeps its own record, as two models can't share one
        let id = identityRecordName.flatMap { isAvailable($0) ? $0 : nil } ?? UUID().uuidString
        return (CloudKitLocalEntity(id: id, localId: localId, context: context).id, nil)
    }

    /// Gives a downloaded record that isn't known yet to the object with the given URI, which has the record's identity values.
    ///
    /// An object that has a record already only gets this one if it's named after its identity values (`isNamedAfterIdentity`):
    /// its own record is then a duplicate, whose id is returned to delete it. Otherwise it keeps its record, and `nil` is returned.
    /// Has to be called on `context`'s queue.
    static func adopt(
        recordName: String,
        forLocalId localId: String,
        isNamedAfterIdentity: Bool,
        in context: NSManagedObjectContext
    ) -> (adopted: Bool, previousId: String?) {
        // An entity whose object is gone (see `SDSSynchronizer.lookUp(for:)`) would keep the record from being found again
        let stale = context.metadataEntries(of: "CloudKitLocalEntity", withIds: [recordName]).filter { ($0 as? CloudKitLocalEntity)?.localId != localId }
        guard let entry = entry(forLocalId: localId, in: context) else {
            stale.forEach(context.delete)
            _ = CloudKitLocalEntity(id: recordName, localId: localId, context: context)
            return (true, nil)
        }
        guard isNamedAfterIdentity, entry.id != recordName else { return (entry.id == recordName, nil) }

        stale.forEach(context.delete)
        let previousId = entry.id
        entry.id = recordName
        return (true, previousId)
    }

}

/// Local objects of entities without an identity that have no records, by their synchronized values, so a download can give
/// them the records they're copies of, rather than inserting the records as duplicates.
///
/// Used after objects vanished from the store, e.g. because it was rebuilt and its objects got new URIs, see
/// `SDSSynchronizer.backfill(onlyUntracked:)`: the same data then looks like new objects, which would be uploaded again as
/// new records, while every record is downloaded again. Objects whose values differ from every record's stay new objects.
/// Has to be used on the queue of its context.
final class SDSContentIndex {
    private weak var synchronizer: SDSSynchronizer?
    private let context: NSManagedObjectContext
    /// The URIs of the objects that have records.
    private let trackedLocalIds: Set<String>
    private var objectIDs: [String: [String: [NSManagedObjectID]]] = [:]

    init(synchronizer: SDSSynchronizer, context: NSManagedObjectContext, trackedLocalIds: Set<String>) {
        self.synchronizer = synchronizer
        self.context = context
        self.trackedLocalIds = trackedLocalIds
    }

    /// An object without a record whose synchronized attributes have the record's values, which isn't matched again.
    /// - Parameter overflowValues: The values of the record's overflow asset, see `SDSOverflow`.
    func object(matching record: CKRecord, overflowValues: [String: Any], entity: NSEntityDescription, keys: [String]) -> NSManagedObject? {
        guard let entityName = entity.name else { return nil }
        let attributeKeys = keys.filter { entity.attributesByName[$0] != nil }.sorted()
        if objectIDs[entityName] == nil {
            build(entity: entity, keys: attributeKeys)
        }
        let recordKey = { (key: String) in entity.propertiesByName[key]?.renamingIdentifier ?? key }
        let content = Self.content(attributeKeys.map { key -> Any? in
            let rawKey = recordKey(key)
            let value = record[rawKey] ?? overflowValues[rawKey]
            if let asset = value as? CKAsset {
                return asset.fileURL.flatMap { try? Data(contentsOf: $0) }
            }
            return value
        })
        guard var candidates = objectIDs[entityName]?[content], !candidates.isEmpty else { return nil }
        let objectID = candidates.removeFirst()
        objectIDs[entityName]?[content] = candidates
        return try? context.existingObject(with: objectID)
    }

    private static func content(_ values: [Any?]) -> String {
        values.map { SDSIdentity.canonicalString($0).map { "\($0.utf8.count):\($0)" } ?? "-" }.joined(separator: ",")
    }

    private func build(entity: NSEntityDescription, keys: [String]) {
        guard let entityName = entity.name, let synchronizer else { return }
        var index: [String: [NSManagedObjectID]] = [:]
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.includesSubentities = false
        request.fetchBatchSize = 200
        let objects = (try? context.fetch(request)) ?? []
        for object in objects where !trackedLocalIds.contains(object.objectID.uriRepresentation().absoluteString) {
            guard let container = synchronizer.container(for: object) else { continue }
            let assetKeys = Set(container.assetKeys)
            // The values as records store them, e.g. strings for URLs, without writing assets
            let values = (try? container.changeDictionary(for: keys.filter { !assetKeys.contains($0) })) ?? [:]
            let content = Self.content(keys.map { key -> Any? in
                if assetKeys.contains(key) {
                    return object.value(forKey: key)
                }
                return values[entity.propertiesByName[key]?.renamingIdentifier ?? key] ?? nil
            })
            index[content, default: []].append(object.objectID)
            if !object.hasChanges {
                context.refresh(object, mergeChanges: false)
            }
        }
        objectIDs[entityName] = index
    }
}
