import Foundation
import CoreData
import CloudKit

/// A change of a saved synchronizable object. It's read on the queue of the object's context, so it can be handled anywhere.
/// Its record id and zone are looked up later, on the synchronizer's queue, see `setUpdates(for:)`.
struct SDSObjectChange: Sendable {
    /// The URI of the object's ID.
    let localId: String
    /// See `SDSSynchronizableContainer.sharableRootLocalId`.
    let sharableRootLocalId: String?
    let entityName: String
    var changedKeys: [String]
    /// The record name the object's identity gives it, if its entity has one. See `SDSConfiguration.Entity.sync`.
    var identityRecordName: String? = nil
    /// Whether an identity value changed, so the object is moved to the record of its new identity.
    var identityChanged = false
    /// Every synchronized key, uploaded when the object is moved to another record, or doesn't have one yet.
    var allKeys: [String] = []
}

extension SDSSynchronizer {
    
    func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(contextChanged(_:)), name: .NSManagedObjectContextObjectsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextWillSave(_:)), name: .NSManagedObjectContextWillSave, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contextSaved(_:)), name: .NSManagedObjectContextDidSave, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged(_:)), name: .CKAccountChanged, object: nil)
    }

    /// The account is checked again with the next synchronization, which starts over if it's another one, see `checkLoggedIntoIcloud()`.
    /// A running synchronization ends at its next step, as it could otherwise upload to or download from another account
    /// with the data of the previous one, see `checkNotStopped()`. Also while stopped, so `start()` checks the account.
    @objc func accountChanged(_ notification: Notification) {
        noteAccountChange()
        Task {
            await viewModel.set(loggedIntoiCloud: false)
            startSync()
        }
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
        
        setUpdates(for: changes(of: updatedObjects, inserted: false))
        handleDeletedObjects(deletedObjects)
    }
    
    /// Changes are stored when they are made, but uploads read the values from the store, so ones that were uploaded
    /// before they were saved are stored again once they are, see `contextSaved`.
    /// The keys are read from what is being saved, so changes that were discarded, e.g. by a rollback, aren't stored again.
    @objc func contextWillSave(_ notification: Notification) {
        guard
            let context = notification.object as? NSManagedObjectContext,
            context.persistentStoreCoordinator == observedStore,
            context != observedUpdateContext,
            // A child context only saves to its parent, whose save is handled
            context.parent == nil
        else { return }
        
        var keys: [NSManagedObjectID: Set<String>] = [:]
        for object in context.updatedObjects where !object.objectID.isTemporaryID {
            guard let container = container(for: object) else { continue }
            let synchronizedKeys = Set(container.syncKeys + [container.parentKey].compactMap { $0 })
            let savedKeys = synchronizedKeys.intersection(object.changedValues().keys)
            if !savedKeys.isEmpty {
                keys[object.objectID] = savedKeys
            }
        }
        rememberKeysBeingSaved(keys, by: context)
    }
    
    @objc func contextSaved(_ notification:Notification) {
        guard
            let userInfo = userInfo(from: notification),
            let savingContext = notification.object as? NSManagedObjectContext,
            // A child context only saves to its parent, whose save is handled. Its inserted objects don't have permanent IDs yet.
            savingContext.parent == nil
        else { return }
        
        // Changes that were saved are stored again, so their saved values are uploaded too, see `contextWillSave`
        let updatedObjects = (userInfo[NSUpdatedObjectsKey] as? NSSet ?? []).compactMap { $0 as? NSManagedObject }
        let savedChanges = takeKeysBeingSaved(by: savingContext)
        let updatedChanges = updatedObjects.compactMap { object -> SDSObjectChange? in
            guard let keys = savedChanges[object.objectID], let container = container(for: object) else { return nil }
            return identifying(SDSObjectChange(
                localId: object.objectID.uriRepresentation().absoluteString,
                sharableRootLocalId: container.sharableRootLocalId,
                entityName: object.entity.name!,
                changedKeys: Array(keys),
                allKeys: container.syncKeys + [container.parentKey].compactMap { $0 }
            ), of: container, inserted: false)
        }

        let insertedObjects = (userInfo[NSInsertedObjectsKey] as? NSSet ?? []).compactMap(onlyIfSyncronizable)

        // Inserted objects are handled from the contextSaved notification
        // Inserted objects only have a valid managed object id after being saved
        // Changes cannot be handled here as we do not get useful information about the properties that have changed
        // The objects belong to the context that was saved, so they are read now, while on its queue
        // They are stored right away, like other changes, and together with the saved changes of updated objects.
        // Otherwise a running upload could upload a record that references an inserted object before the object,
        // and another device that downloads in between couldn't store the record.
        let synchronizedChanges = updatedChanges + changes(of: insertedObjects, inserted: true)
        setUpdates(for: synchronizedChanges)

        // Deletions were stored when they were made, see `contextChanged`. Only the IDs of deleted objects are read.
        let configuration = self.configuration
        let hasDeletions = (userInfo[NSDeletedObjectsKey] as? NSSet ?? []).contains { object in
            guard let objectID = (object as? NSManagedObject)?.objectID else { return false }
            return configuration?.entities[objectID.entity.name ?? ""] != nil && !wasDeletedBySynchronizer(objectID)
        }
        // E.g. saves of models or keys that aren't synchronized don't need a synchronization
        guard !synchronizedChanges.isEmpty || hasDeletions else { return }

        // The changes are saved right away, rather than when no synchronization runs, so they aren't lost if the app
        // is terminated while one does. Blocks run on the context's queue in order, so this saves them.
        let context = self.context
        context.perform {
            do {
                try context.save()
            } catch {
                // The pending changes stay in the context, so they are saved with its next save
                self.logger.log("Failed to save pending changes: \(error.localizedDescription)")
            }
        }

        synchronizeAfterSave()
    }

    /// Synchronizes shortly after a save, or once the running synchronization is done.
    /// Saves meanwhile are synchronized by the same synchronization.
    private func synchronizeAfterSave() {
        startTask(at: \.saveSync) {
            // Nothing cancels this task.
            // While stopped, the changes are only saved, and the state keeps showing that synchronizing is stopped.
            let isStopped = self.isStopped
            // The state shows that a synchronization follows right away, e.g. to apps that wait for it before being suspended.
            var previousState: SDSSynchronizationViewModel.StateSnapshot?
            if !isStopped {
                guard let state = try? await self.viewModel.waitForIdle(setting: .processingSaveEvent) else {
                    self.finishTask(at: \.saveSync)
                    return
                }
                previousState = state
            }
            try? await Task.sleep(for: self.timing.saveSynchronizationDelay)

            // A running download keeps the objects it inserted unsaved in the observed update context, which mustn't be
            // saved without their records, so this waits for it to end, also while synchronizing is stopped
            try? await self.beginExclusiveActivity()

            // E.g. another process using the same synchronization data can keep the store busy, which must not crash
            if let observedUpdateContext = self.observedUpdateContext {
                observedUpdateContext.performAndWait {
                    do {
                        try self.saveObservedUpdateContext(observedUpdateContext)
                    } catch {
                        // Nothing else changes this context while no synchronization is running, so nothing of value is discarded
                        self.logger.log("Failed to save the observed update context: \(error.localizedDescription)")
                        observedUpdateContext.rollback()
                    }
                }
            }

            let context = self.context
            context.performAndWait {
                do {
                    try context.save()
                } catch {
                    // The pending changes stay in the context, so they are saved with its next save
                    self.logger.log("Failed to save pending changes: \(error.localizedDescription)")
                }
            }

            // Saves from now on schedule another synchronization, as the one started now might not include them
            self.finishTask(at: \.saveSync)

            if let previousState {
                // E.g. an error's retry delay isn't forgotten, which a synchronization started now has to respect
                await self.viewModel.restore(previousState)
            }
            // `start()` and `stop()` only change the state they find, which this task could have replaced meanwhile
            await self.updateStoppedState()
            self.endActivity()

            self.startSync()
        }
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

            // Callers only pass saved objects. Others don't have a record yet, see `contextChanged`.
            guard !updated.object.objectID.isTemporaryID else { return nil }

            let entityName = updated.object.entity.name!

            return identifying(SDSObjectChange(
                localId: updated.object.objectID.uriRepresentation().absoluteString,
                sharableRootLocalId: updated.sharableRootLocalId,
                entityName: entityName,
                changedKeys: keysToSync,
                allKeys: allSyncKeys
            ), of: updated, inserted: inserted)
        }
    }

    /// Adds what the identity of the object's entity, if it has one, needs to the change. Has to be called on the queue of the object's context.
    private func identifying(_ change: SDSObjectChange, of container: SDSSynchronizableContainer, inserted: Bool) -> SDSObjectChange {
        guard
            let identity = configuration?.entities[change.entityName]?.identity,
            !identity.isEmpty
        else { return change }
        
        var change = change
        change.identityRecordName = identityRecordName(for: container.object)
        change.identityChanged = !inserted && identity.contains(where: change.changedKeys.contains)
        change.allKeys = container.syncKeys + [container.parentKey].compactMap { $0 }
        return change
    }

    /// Stores the changes at once, so an upload never selects some of them without the others.
    ///
    /// They're stored without waiting for `context`, as notifications are often handled on the main thread, which must never wait for it.
    /// Blocks run on its queue in order, so anything that reads the changes on its queue afterwards finds them.
    func setUpdates(for changes: [SDSObjectChange]) {
        guard !changes.isEmpty else { return }

        let context = self.context
        context.perform {
            self.storeUpdates(changes)
        }
    }

    /// Stores the removals without waiting for `context`, like `setUpdates(for:)`. Has to be called on the queue of the objects' context.
    func handleDeletedObjects(_ objects: [SDSSynchronizableContainer]) {
        // Callers only pass saved objects, see `contextChanged`
        let deletions = objects.filter { !$0.object.objectID.isTemporaryID }.map { delete in
            (
                localId: delete.object.objectID.uriRepresentation().absoluteString,
                sharableRootLocalId: delete.sharableRootLocalId,
                isSharable: delete is SDSSharableContainer
            )
        }
        guard !deletions.isEmpty else { return }

        let context = self.context
        context.perform {
            for deletion in deletions {
                // An object without a record was never uploaded, so there's nothing to delete
                guard let id = self.existingRecordId(forLocalId: deletion.localId) else { continue }
                // Read before the share is deleted, which would send the removal to the private database
                let zoneId = self.sharedZoneId(forRootLocalId: deletion.sharableRootLocalId)

                // Delete the share if neccesary
                if deletion.isSharable {
                    CloudKitShare.updateShare(nil, for: id, context: context)
                }

                self.setRemoval(id: id, zoneId: zoneId)
            }
        }
    }
}
