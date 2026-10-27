import Foundation
import CoreData

extension SDSSynchronizer {
    /// Has to be called on `context`'s queue.
    func existingLocalEntity(for id: String) -> CloudKitLocalEntity? {
        let request = CloudKitLocalEntity.fetchRequest()
        
        request.sortDescriptors = []
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id = %@", id)
        
        return try? request.execute().first
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
        guard let observedUpdateContext, let observedStore else { return nil }
        
        // The local entity and temporary objects are read on `context`'s queue, the object on `observedUpdateContext`'s
        let result = context.performAndWaitUnchecked {
            existingLocalEntity(for: id).map { (localId: $0.localId, temporaryObject: temporaryObject(for: id)) }
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
    
    func retrieve(
        for id: String,
        entityName: String,
        context: NSManagedObjectContext,
        preliminaryUpdateHandler: (SDSSynchronizableContainer?) -> Void
    ) -> SDSSynchronizableContainer? {
        if let update = find(for: id) {
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
                    let id = (
                        CloudKitLocalEntity.entry(forLocalId: objectId, in: context) ??
                        CloudKitLocalEntity(
                            id: UUID().uuidString,
                            localId: objectId,
                            context: context
                        )
                    ).id
                    return id
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
