import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {
    /// The record id of a saved object, given by the URI of its object ID. An object without one gets one, named after
    /// its identity if its entity has one (`identityRecordName`, see `identityRecordName(for:)`).
    /// Has to be called on `context`'s queue.
    func recordId(forLocalId localId: String, identityRecordName: String? = nil) -> String {
        CloudKitLocalEntity.recordId(
            forLocalId: localId,
            identityRecordName: identityRecordName,
            renamingToIdentity: false,
            isReserved: { self.temporaryObject(for: $0) != nil },
            in: context
        ).id
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
    /// The root is given by the URI of its object ID. Has to be called on `context`'s queue.
    func sharedZoneId(forRootLocalId rootLocalId: String?) -> CKRecordZone.ID? {
        guard
            let rootLocalId,
            let share = CloudKitShare.share(for: recordId(forLocalId: rootLocalId), in: context),
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
                assetKeys: entity.assetProperties
            )
        } else {
            return SDSSynchronizableContainer(
                id: id,
                object: object,
                parentKey: entity.parentKey,
                syncKeys: entity.syncedProperties,
                assetKeys: entity.assetProperties
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
    /// - Parameter identityValues: The record's values of the entity's identity, if it has one, to find a local object
    ///   for a record that isn't known yet.
    func retrieve(
        for id: String,
        entityName: String,
        identityValues: [Any?]? = nil,
        context: NSManagedObjectContext,
        preliminaryUpdateHandler: (SDSSynchronizableContainer?) -> Void
    ) throws -> SDSSynchronizableContainer? {
        if let update = try lookUp(for: id) {
            preliminaryUpdateHandler(update)
            return update
        } else if let identityValues, let match = try adoptObject(matching: identityValues, recordName: id, entityName: entityName, context: context) {
            preliminaryUpdateHandler(match)
            return match
        } else {
            let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
            preliminaryUpdateHandler(container(id: { id }, object: object))

            // The object gets its local entity once it's saved, see `temporaryObjectIds`
            self.context.performAndWaitUnchecked {
                // An entity whose object is gone (see `lookUp(for:)`) would keep the record from being found again
                self.context.metadataEntries(of: "CloudKitLocalEntity", withIds: [id]).forEach(self.context.delete)
                self.setTemporaryId(id, for: object)
            }

            return container(id: { id }, object: object)
        }
    }
    
    /// A local object with the identity values of a downloaded record that isn't known yet, e.g. one this device created
    /// for the same thing before downloading the record of another device. It's given the record, which then updates it
    /// instead of inserting a duplicate. Has to be called on the queue of `context`, the observed update context.
    private func adoptObject(matching values: [Any?], recordName: String, entityName: String, context: NSManagedObjectContext) throws -> SDSSynchronizableContainer? {
        guard
            let identity = configuration?.entities[entityName]?.identity,
            !identity.isEmpty,
            let object = try SDSIdentity.matchingObject(in: context, entityName: entityName, keys: identity, values: values)
        else { return nil }
        
        let localId = object.objectID.uriRepresentation().absoluteString
        let isNamedAfterIdentity = recordName == SDSIdentity.recordName(entityName: entityName, values: values)
        let adopted = self.context.performAndWaitUnchecked {
            let (adopted, previousId) = CloudKitLocalEntity.adopt(recordName: recordName, forLocalId: localId, isNamedAfterIdentity: isNamedAfterIdentity, in: self.context)
            if let previousId {
                // The object's own record is a duplicate of this one
                logger.log("[Download] Replacing record `\(previousId)` with `\(recordName)` of the same identity")
                setRemoval(id: previousId, zoneId: nil)
            }
            return adopted
        }
        guard adopted else { return nil }
        
        logger.log("[Download] Matched record `\(recordName)` to a local object of the same identity")
        return container(id: { recordName }, object: object)
    }
    
    func container(for object: NSManagedObject) -> SDSSynchronizableContainer? {
        let objectId = object.objectID.isTemporaryID ? nil : object.objectID.uriRepresentation().absoluteString
        // Read now, on the queue of the object's context, as the id is looked up on the synchronizer's
        let identityRecordName = objectId == nil ? nil : identityRecordName(for: object)
        let id: () -> String = {
            let context = self.context
            return context.performAndWaitUnchecked {
                if let objectId {
                    return self.recordId(forLocalId: objectId, identityRecordName: identityRecordName)
                } else {
                    if let cached = self.temporaryObjectIds[object] {
                        return cached
                    }

                    let id = UUID().uuidString
                    self.setTemporaryId(id, for: object)
                    return id
                }
            }
        }
        
        return container(id: id, object: object)
    }
}
