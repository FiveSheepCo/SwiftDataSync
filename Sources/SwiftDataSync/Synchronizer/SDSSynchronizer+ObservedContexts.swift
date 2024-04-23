import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {
    
    func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(contextChanged(_:)), name: .NSManagedObjectContextObjectsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextSaved(_:)), name: .NSManagedObjectContextDidSave, object: nil)
    }
    
    /// Checks whether the notification is valid and has user info.
    func userInfo(from validNotification: Notification) -> [AnyHashable : Any]? {
        guard
            let context = validNotification.object as? NSManagedObjectContext,
            context.persistentStoreCoordinator == observedStore,
            context != self.observedUpdateContext,
            let userInfo = validNotification.userInfo
        else { return nil }
        
        return userInfo
    }
    
    @objc func contextChanged(_ notification:Notification) {
        guard let userInfo = userInfo(from: notification) else { return }
        
        // Only changes and deleted objects are handled here so that the update works
        let updatedObjects = (userInfo[NSUpdatedObjectsKey] as? NSSet ?? []).compactMap(onlyIfSyncronizable)
        let deletedObjects = (userInfo[NSDeletedObjectsKey] as? NSSet ?? []).compactMap(onlyIfSyncronizable)
        
        print("changed objects!", updatedObjects.count)
        handleChangedObjects(updatedObjects)
        handleDeletedObjects(deletedObjects)
    }
    
    @objc func contextSaved(_ notification:Notification) {
        guard let userInfo = userInfo(from: notification) else { return }
        
        let insertedObjects = (userInfo[NSInsertedObjectsKey] as? NSSet ?? []).compactMap(onlyIfSyncronizable)
        
        self.saveObserved()
        
        // Inserted objects are handled from the contextSaved notification
        // Inserted objects only have a valid managed object id after being saved
        // Changes cannot be handled here as we do not get useful information about the properties that have changed
        handleChangedObjects(insertedObjects, inserted: true)
        
        self.save()
    }
    
    func handleChangedObjects(_ objects: [SDSSynchronizableContainer], inserted: Bool = false) {
        for updated in objects {
            let parentKey = updated.parentKey
            let syncKeys = updated.syncKeys
            let keysToSync: [String]
            
            let allSyncKeys = syncKeys + [parentKey].compactMap { $0 }
            if inserted {
                // Inserted objects have all keys changed automatically
                keysToSync = allSyncKeys
                logger.log("Setting Initial Keys: \(keysToSync)")
            } else {
                // Keys that should sync are keys that have changed and are marked to sync
                let changedKeys = Array(updated.object.changedValuesForCurrentEvent().keys)
                
                keysToSync  = changedKeys.filter { key -> Bool in
                    allSyncKeys.contains(key)
                }
                logger.log("Setting Update Keys: \(keysToSync)")
            }
            
            // Make sure there are keys that have changed
            guard !keysToSync.isEmpty else { continue }
            
            let id = updated.id
            let entityName = updated.object.entity.name!
            
            setUpdate(id: id, zoneId: updated.sharedZoneId, entityName: entityName, changedKeys: keysToSync)
        }
    }
    
    func handleDeletedObjects(_ objects: [SDSSynchronizableContainer]) {
        for delete in objects {
            // Delete the share if neccesary
            if delete is SDSSharableContainer {
                let id = delete.id
                self.context.perform {
                    CloudKitShare.updateShare(nil, for: id, context: self.context)
                }
            }
            
            setRemoval(id: delete.id, zoneId: delete.sharedZoneId)
        }
    }
    
    func saveObserved() {
        guard let context = self.observedUpdateContext else { return }
        
        context.performAndWait {
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    // Replace this implementation with code to handle the error appropriately.
                    // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                    let nserror = error as NSError
                    fatalError("Unresolved error saving SDSSynchronizer.context \(nserror), \(nserror.userInfo)")
                }
            }
        }
    }
}
