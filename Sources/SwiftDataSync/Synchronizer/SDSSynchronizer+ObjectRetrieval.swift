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
                let localID = observedStore.managedObjectID(forURIRepresentation: URL(string: localEntity.localId)!)
            else { return nil }
            
            return container(id: { id }, object: observedUpdateContext.object(with: localID))
        }
    }
    
    func retrieve(
        for id: String,
        entityName: String,
        context: NSManagedObjectContext,
        preliminaryUpdateHandler: (SDSSynchronizableContainer?) -> Void
    ) throws -> SDSSynchronizableContainer? {
        if let update = find(for: id) {
            preliminaryUpdateHandler(update)
            return update
        } else {
            let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
            preliminaryUpdateHandler(container(id: { id }, object: object))
            try context.save()
            
            try self.context.performAndWait {
                _ = CloudKitLocalEntity(
                    id: id,
                    localId: object.objectID.uriRepresentation().absoluteString,
                    context: self.context
                )
                try self.context.save()
            }
            
            return container(id: { id }, object: object)
        }
    }
    
    func container(for object: NSManagedObject) -> SDSSynchronizableContainer? {
        let objectId = object.objectID.uriRepresentation().absoluteString
        let id: () -> String = {
            self.context.performAndWait {
                let request = CloudKitLocalEntity.fetchRequest()
                
                request.sortDescriptors = []
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "localId = %@", objectId)
                
                let id = ((try? request.execute().first) ?? CloudKitLocalEntity(id: UUID().uuidString, localId: object.objectID.uriRepresentation().absoluteString, context: self.context)).id
                try! self.context.save()
                return id
            }
        }
        
        return container(id: id, object: object)
    }
}
