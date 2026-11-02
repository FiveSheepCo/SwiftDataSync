import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {
    /// The record id of a saved object, given by the URI of its object ID, if it has a record. Has to be called on `context`'s queue.
    ///
    /// Looking up a record id never gives an object a record: an object that has a record name, but whose values were never
    /// queued, would look like it's synchronized, and would never be uploaded, see `backfill(onlyUntracked:)`.
    func existingRecordId(forLocalId localId: String) -> String? {
        CloudKitLocalEntity.entry(forLocalId: localId, in: context)?.id
    }
    
    /// The record name the identity values of the object give it, `nil` if its entity has no identity.
    /// Has to be called on the queue of the object's context.
    func identityRecordName(for object: NSManagedObject) -> String? {
        guard
            let entityName = object.entity.name,
            let identity = configuration?.entities[entityName]?.identity,
            !identity.isEmpty
        else { return nil }
        return SDSIdentity.recordName(entityName: entityName, values: SDSIdentity.values(of: object, keys: identity))
    }

    /// The zone of a record whose root is shared by someone else, like `SDSSynchronizableContainer.sharedZoneId`.
    /// The root is given by the URI of its object ID. A root without a record isn't shared. Has to be called on `context`'s queue.
    func sharedZoneId(forRootLocalId rootLocalId: String?) -> CKRecordZone.ID? {
        guard
            let rootLocalId,
            let rootId = existingRecordId(forLocalId: rootLocalId),
            let share = CloudKitShare.share(for: rootId, in: context),
            share.isSharedByOtherUser
        else { return nil }
        return share.recordID.zoneID
    }

    /// Has to be called on `context`'s queue.
    func existingLocalEntity(for id: String) -> CloudKitLocalEntity? {
        try? fetchLocalEntity(for: id)
    }
    
    /// Has to be called on `context`'s queue. Throws if the metadata can't be read.
    private func fetchLocalEntity(for id: String) throws -> CloudKitLocalEntity? {
        let request = CloudKitLocalEntity.fetchRequest()
        
        request.sortDescriptors = []
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id = %@", id)
        
        return try request.execute().first
    }
    
    private func container(
        id: @escaping () -> String,
        object: NSManagedObject
    ) -> SDSSynchronizableContainer? {
        guard
            let configuration,
            let entity = configuration.entities[object.entity.name ?? ""]
        else {
            return nil
        }
        
        if entity.isSharable {
            return SDSSharableContainer(
                id: id,
                object: object,
                parentKey: entity.parentKey,
                syncKeys: entity.syncedProperties,
                assetKeys: entity.assetProperties,
                synchronizer: self
            )
        } else {
            return SDSSynchronizableContainer(
                id: id,
                object: object,
                parentKey: entity.parentKey,
                syncKeys: entity.syncedProperties,
                assetKeys: entity.assetProperties,
                synchronizer: self
            )
        }
    }
    
    func find(for id: String) -> SDSSynchronizableContainer? {
        try? lookUp(for: id)
    }
    
    /// Like `find(for:)`, but throws if the metadata can't be read, so a failed read isn't taken for an object that's gone.
    func lookUp(for id: String) throws -> SDSSynchronizableContainer? {
        guard let observedUpdateContext, let observedStore else { return nil }
        
        // The local entity and temporary objects are read on `context`'s queue, the object on `observedUpdateContext`'s
        let result = try context.performAndWaitUnchecked { () -> (localId: String, temporaryObject: NSManagedObject?)? in
            if let temporaryObject = temporaryObject(for: id) {
                return ("", temporaryObject)
            }
            return try fetchLocalEntity(for: id).map { (localId: $0.localId, temporaryObject: nil) }
        }

        return try observedUpdateContext.performAndWaitUnchecked { () -> SDSSynchronizableContainer? in
            guard let result else { return nil }
            if let temporaryObject = result.temporaryObject {
                return container(id: { id }, object: temporaryObject)
            }
            guard let objectID = URL(string: result.localId).flatMap(observedStore.managedObjectID(forURIRepresentation:)) else { return nil }

            // An entity can outlive its object, e.g. when the object was deleted locally while downloading. Its values would
            // read as `nil`, and setting them would fail, so the object is taken for gone.
            let localObject: NSManagedObject
            do {
                localObject = try observedUpdateContext.existingObject(with: objectID)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSManagedObjectReferentialIntegrityError {
                return nil
            }

            return container(id: { id }, object: localObject)
        }
    }
    
    /// Throws if the metadata can't be read, as inserting the object then could duplicate it.
    /// - Parameters:
    ///   - identityRecordName: The name the record's identity values give it, if its entity has an identity.
    ///   - matchingObject: Finds a saved local object with the record's identity values, for a record that isn't known yet,
    ///     see `SDSIdentityIndex`.
    func retrieve(
        for id: String,
        entityName: String,
        identityRecordName: String? = nil,
        matchingObject: (() throws -> NSManagedObject?)? = nil,
        context: NSManagedObjectContext,
        preliminaryUpdateHandler: (SDSSynchronizableContainer?, _ movedPendingKeys: Set<String>) -> Void
    ) throws -> SDSSynchronizableContainer? {
        if let update = try lookUp(for: id) {
            preliminaryUpdateHandler(update, [])
            return update
        } else if
            let object = try matchingObject?(),
            let (match, movedKeys) = adoptObject(object, recordName: id, identityRecordName: identityRecordName)
        {
            preliminaryUpdateHandler(match, movedKeys)
            return match
        } else {
            let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
            preliminaryUpdateHandler(container(id: { id }, object: object), [])

            // The object gets its local entity once it's saved, see `temporaryObjectIds`
            self.context.performAndWaitUnchecked {
                // An entity whose object is gone (see `lookUp(for:)`) would keep the record from being found again
                self.context.metadataEntries(of: "CloudKitLocalEntity", withIds: [id]).forEach(self.context.delete)
                self.setTemporaryId(id, for: object)
            }

            return container(id: { id }, object: object)
        }
    }
    
    /// Gives a downloaded record that isn't known yet to a local object with the same identity values, e.g. one this device
    /// created for the same thing before downloading the record of another device, or one with the same values after the
    /// store was rebuilt (see `SDSContentIndex`). The record then updates it instead of inserting a duplicate.
    /// Has to be called on the queue of the observed update context.
    ///
    /// Returns the keys the object changed locally, which weren't uploaded yet: they move from its own record to this one, and
    /// win over the record's values like other local changes.
    private func adoptObject(_ object: NSManagedObject, recordName: String, identityRecordName: String?) -> (SDSSynchronizableContainer, Set<String>)? {
        let localId = object.objectID.uriRepresentation().absoluteString
        let entityName = object.entity.name ?? ""
        let isNamedAfterIdentity = recordName == identityRecordName
        let (adopted, movedKeys) = self.context.performAndWaitUnchecked {
            let (adopted, previousId) = CloudKitLocalEntity.adopt(recordName: recordName, forLocalId: localId, isNamedAfterIdentity: isNamedAfterIdentity, in: self.context)
            var movedKeys: [String] = []
            if let previousId {
                // The object's own record is a duplicate of this one. Its pending changes would be deleted with it.
                logger.log("[Download] Replacing record `\(previousId)` with `\(recordName)` of the same identity")
                movedKeys = CloudKitUpdate.find(for: previousId)?.changedKeys ?? []
                setRemoval(id: previousId, zoneId: nil)
                if !movedKeys.isEmpty {
                    setUpdate(id: recordName, zoneId: nil, entityName: entityName, changedKeys: movedKeys)
                }
            }
            return (adopted, Set(movedKeys))
        }
        guard adopted else { return nil }
        
        logger.log("[Download] Matched record `\(recordName)` to a local object of the same identity")
        guard let container = container(id: { recordName }, object: object) else { return nil }
        return (container, movedKeys)
    }
    
    /// The container of an object. Reading its `id` gives an object that has no record yet one, e.g. one that another
    /// record references, and queues its values like a backfilled object's, so it's uploaded like any other object.
    /// Has to be called on the queue of the object's context.
    func container(for object: NSManagedObject) -> SDSSynchronizableContainer? {
        let objectId = object.objectID.isTemporaryID ? nil : object.objectID.uriRepresentation().absoluteString
        let id: () -> String = {
            let context = self.context
            let existing = context.performAndWaitUnchecked {
                self.temporaryObjectIds[object] ?? objectId.flatMap(self.existingRecordId(forLocalId:))
            }
            if let existing {
                return existing
            }
            guard let objectId else {
                // An object that isn't saved yet, e.g. one a download inserted, gets its local entity once it's saved
                return context.performAndWaitUnchecked {
                    let id = UUID().uuidString
                    self.setTemporaryId(id, for: object)
                    return id
                }
            }
            
            // E.g. an object that another process saved, which a record references
            let change = object.managedObjectContext?.performAndWaitUnchecked { () -> SDSObjectChange? in
                guard let container = self.container(id: { "" }, object: object) else { return nil }
                return self.changes(of: [container], inserted: true).first
            }
            return context.performAndWaitUnchecked {
                if let change {
                    self.logger.log("Queueing `\(change.entityName, privacy: .public)` without a record, as another record references it")
                    self.storeUpdates([change], backfilled: true)
                }
                return self.existingRecordId(forLocalId: objectId) ?? self.recordIdWithoutValues(forLocalId: objectId)
            }
        }
        
        return container(id: id, object: object)
    }
    
    /// The record id of an object whose values can't be read, e.g. of an entity that isn't synchronized. Has to be called on `context`'s queue.
    private func recordIdWithoutValues(forLocalId localId: String) -> String {
        CloudKitLocalEntity.recordId(forLocalId: localId, identityRecordName: nil, renamingToIdentity: false, isReserved: { self.temporaryObject(for: $0) != nil }, in: context).id
    }
    
    /// The record id of an object if it has a record, without giving it one, see `existingRecordId(forLocalId:)`.
    /// Can be called on any queue.
    func existingRecordId(of object: NSManagedObject) -> String? {
        let objectId = object.objectID.isTemporaryID ? nil : object.objectID.uriRepresentation().absoluteString
        let context = self.context
        return context.performAndWaitUnchecked {
            self.temporaryObjectIds[object] ?? objectId.flatMap(self.existingRecordId(forLocalId:))
        }
    }
}
