import Foundation
import CoreData

extension SDSSynchronizer {
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
                syncKeys: entity.syncedProperties
            )
        } else {
            return SDSSynchronizableContainer(
                id: id,
                object: object,
                parentKey: entity.parentKey,
                syncKeys: entity.syncedProperties
            )
        }
    }
    
    func find(for id: String) -> SDSSynchronizableContainer? {
        guard let observedUpdateContext, let observedStore else { return nil }
        
        let result = context.performAndWait {
            existingLocalEntity(for: id)
        }
        
        return observedUpdateContext.performAndWait { () -> SDSSynchronizableContainer? in
            guard
                let localEntity: CloudKitLocalEntity = result,
                let localObject = temporaryObject(for: id) ?? observedStore.managedObjectID(forURIRepresentation: URL(string: localEntity.localId)!).map(observedUpdateContext.object(with:))
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
            
            self.context.performAndWait {
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
            return context.performAndWait {
                if let objectId {
                    let request = CloudKitLocalEntity.fetchRequest()
                    
                    request.sortDescriptors = []
                    request.fetchLimit = 1
                    request.predicate = NSPredicate(format: "localId = %@", objectId)
                    
                    let id = (
                        (try? request.execute().first) ??
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
