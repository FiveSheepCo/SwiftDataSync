import Foundation
import CoreData
import CloudKit

/// A change of a synchronizable object. It's read on the queue of the object's context, so it can be handled anywhere.
struct SDSObjectChange: Sendable {
    let id: String
    let zoneId: CKRecordZone.ID?
    let entityName: String
    let changedKeys: [String]
}

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
        
        handleChangedObjects(updatedObjects)
        handleDeletedObjects(deletedObjects)
    }
    
    @objc func contextSaved(_ notification:Notification) {
        guard let userInfo = userInfo(from: notification) else { return }
        
        let insertedObjects = (userInfo[NSInsertedObjectsKey] as? NSSet ?? []).compactMap(onlyIfSyncronizable)
        
        // Inserted objects are handled from the contextSaved notification
        // Inserted objects only have a valid managed object id after being saved
        // Changes cannot be handled here as we do not get useful information about the properties that have changed
        // The objects belong to the context that was saved, so they are read now, while on its queue
        let insertedChanges = changes(of: insertedObjects, inserted: true)
        
        Task {
            await viewModel.waitForIdle(setting: .processingSaveEvent)
            
            let observedUpdateContext = self.observedUpdateContext!
            try! observedUpdateContext.performAndWait {
                try observedUpdateContext.save()
            }
            
            setUpdates(for: insertedChanges)
            
            let context = self.context
            try! context.performAndWait {
                try context.save()
            }
            
            await viewModel.set(state: .idle)
            
            self.startSync()
        }
    }
    
    func handleChangedObjects(_ objects: [SDSSynchronizableContainer]) {
        setUpdates(for: changes(of: objects, inserted: false))
    }
    
    /// Has to be called on the queue of the objects' context.
    func changes(of objects: [SDSSynchronizableContainer], inserted: Bool) -> [SDSObjectChange] {
        objects.compactMap { updated in
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
                
                keysToSync = changedKeys.filter { key -> Bool in
                    allSyncKeys.contains(key)
                }
                logger.log("Setting Update Keys: \(keysToSync)")
            }
            
            // Make sure there are keys that have changed
            guard !keysToSync.isEmpty else { return nil }
            
            let entityName = updated.object.entity.name!
            
            return SDSObjectChange(id: updated.id, zoneId: updated.sharedZoneId, entityName: entityName, changedKeys: keysToSync)
        }
    }
    
    func setUpdates(for changes: [SDSObjectChange]) {
        for change in changes {
            setUpdate(id: change.id, zoneId: change.zoneId, entityName: change.entityName, changedKeys: change.changedKeys)
        }
    }
    
    func handleDeletedObjects(_ objects: [SDSSynchronizableContainer]) {
        for delete in objects {
            // Delete the share if neccesary
            let id = delete.id
            if delete is SDSSharableContainer {
                let context = self.context
                context.perform {
                    CloudKitShare.updateShare(nil, for: id, context: context)
                }
            }
            
            setRemoval(id: id, zoneId: delete.sharedZoneId)
        }
    }
}
