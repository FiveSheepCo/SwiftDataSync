import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {
    /// The record id of a saved object, given by the URI of its object ID. An object without one gets one.
    /// Has to be called on `context`'s queue.
    func recordId(forLocalId localId: String) -> String {
        (
            CloudKitLocalEntity.entry(forLocalId: localId, in: context) ??
            CloudKitLocalEntity(id: UUID().uuidString, localId: localId, context: context)
        ).id
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
        let result = try context.performAndWaitUnchecked {
            try fetchLocalEntity(for: id).map { (localId: $0.localId, temporaryObject: temporaryObject(for: id)) }
        }
        
        return observedUpdateContext.performAndWaitUnchecked { () -> SDSSynchronizableContainer? in
            guard
                let result,
                let localObject = result.temporaryObject ?? URL(string: result.localId)
                    .flatMap(observedStore.managedObjectID(forURIRepresentation:))
                    .map(observedUpdateContext.object(with:))
            else { return nil }
            
            return container(id: { id }, object: localObject)
        }
    }
    
    /// Throws if the metadata can't be read, as inserting the object then could duplicate it.
    func retrieve(
        for id: String,
        entityName: String,
        context: NSManagedObjectContext,
        preliminaryUpdateHandler: (SDSSynchronizableContainer?) -> Void
    ) throws -> SDSSynchronizableContainer? {
        if let update = try lookUp(for: id) {
            preliminaryUpdateHandler(update)
            return update
        } else {
            let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
            preliminaryUpdateHandler(container(id: { id }, object: object))
            
            self.context.performAndWaitUnchecked {
                let new = CloudKitLocalEntity(
                    id: id,
                    localId: "",
                    context: self.context
                )
                self.temporaryObjectContainers[object] = new
            }
            
            return container(id: { id }, object: object)
        }
    }
    
    func container(for object: NSManagedObject) -> SDSSynchronizableContainer? {
        let objectId = object.objectID.isTemporaryID ? nil : object.objectID.uriRepresentation().absoluteString
        let id: () -> String = {
            let context = self.context
            return context.performAndWaitUnchecked {
                if let objectId {
                    return self.recordId(forLocalId: objectId)
                } else {
                    if let cached = self.temporaryObjectContainers[object] {
                        return cached.id
                    }
                    
                    let new = CloudKitLocalEntity(
                        id: UUID().uuidString,
                        localId: "",
                        context: context
                    )
                    self.temporaryObjectContainers[object] = new
                    return new.id
                }
            }
        }
        
        return container(id: id, object: object)
    }
}
