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
        // Objects that weren't saved yet are reported too. They don't have a record, and must not get a record id now,
        // as saving them gives them another one. They are uploaded with all keys once they are saved.
        let savedObjects = { (key: String) in
            (userInfo[key] as? NSSet ?? []).compactMap { $0 as? NSManagedObject }.filter { !$0.objectID.isTemporaryID }
        }
        let updatedObjects = savedObjects(NSUpdatedObjectsKey).compactMap(onlyIfSyncronizable)
        let deletedObjects = savedObjects(NSDeletedObjectsKey)
            // Deletions merged from the synchronizer's own saves are reported here too, but must not be uploaded
            .filter { !wasDeletedBySynchronizer($0.objectID) }
            .compactMap(onlyIfSyncronizable)
        
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
            // Nothing cancels this task
            guard (try? await viewModel.waitForIdle(setting: .processingSaveEvent)) != nil else { return }
            
            // E.g. another process using the same synchronization data can keep the store busy, which must not crash
            let observedUpdateContext = self.observedUpdateContext!
            observedUpdateContext.performAndWait {
                do {
                    try self.saveObservedUpdateContext(observedUpdateContext)
                } catch {
                    // Nothing else changes this context while no synchronization is running, so nothing of value is discarded
                    self.logger.log("Failed to save the observed update context: \(error.localizedDescription)")
                    observedUpdateContext.rollback()
                }
            }
            
            setUpdates(for: insertedChanges)
            
            let context = self.context
            context.performAndWait {
                do {
                    try context.save()
                } catch {
                    // The pending changes stay in the context, so they are saved with its next save
                    self.logger.log("Failed to save pending changes: \(error.localizedDescription)")
                }
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
