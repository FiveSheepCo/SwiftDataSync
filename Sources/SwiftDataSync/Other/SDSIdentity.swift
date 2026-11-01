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
        return entityName + "." + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The text of a value, the same for the value of a model and the one its record returns: CloudKit stores booleans as
    /// numbers and dates to the millisecond. `nil` for no value.
    static func canonicalString(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull: nil
        case let string as String: string
        case let date as Date: String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
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
        if local.parent != nil || changedKeys.contains(SDSSynchronizer.Constants.parentWorkaroundKey) {
            server.parent = local.parent
        }
        return server
    }
}

extension CloudKitLocalEntity {

    /// The record id of the object with the given URI. An object without one gets one: the name its identity gives it
    /// (`identityRecordName`), or a random one if it has no identity or another object has that record already.
    ///
    /// With `renamingToIdentity`, e.g. because an identity value changed, an object whose record has another name than
    /// its identity gives it is given that record, and its previous record id is returned to delete that record.
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
            guard
                renamingToIdentity,
                let identityRecordName,
                entry.id != identityRecordName,
                isAvailable(identityRecordName)
            else { return (entry.id, nil) }

            let previousId = entry.id
            entry.id = identityRecordName
            return (identityRecordName, previousId)
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
        guard let entry = entry(forLocalId: localId, in: context) else {
            _ = CloudKitLocalEntity(id: recordName, localId: localId, context: context)
            return (true, nil)
        }
        guard isNamedAfterIdentity, entry.id != recordName else { return (entry.id == recordName, nil) }

        let previousId = entry.id
        entry.id = recordName
        return (true, previousId)
    }

    private static func entry(forId id: String, in context: NSManagedObjectContext) -> CloudKitLocalEntity? {
        let request = fetchRequest()
        request.sortDescriptors = []
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id = %@", id)
        return try? context.fetch(request).first
    }
}
