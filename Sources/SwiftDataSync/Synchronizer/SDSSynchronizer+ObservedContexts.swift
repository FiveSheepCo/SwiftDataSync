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

/// A deletion of a synchronizable object, read while the object can still be read, when its save starts. It's stored once
/// it's saved, as it can still be discarded before, e.g. by a rollback, see `contextSaved`.
struct SDSObjectDeletion: Sendable {
    /// The URI of the object's ID.
    let localId: String
    /// See `SDSSynchronizableContainer.sharableRootLocalId`.
    let sharableRootLocalId: String?
    let isSharable: Bool
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
        guard let userInfo = userInfo(from: notification), !isForgetting else { return }
        
        // Only changes are handled here so that the update works. Deletions are stored once they're saved, see `contextWillSave`.
        // Objects that weren't saved yet are reported too. They don't have a record, and must not get a record id now,
        // as saving them gives them another one. They are uploaded with all keys once they are saved.
        let savedObjects = { (key: String) in
            (userInfo[key] as? NSSet ?? []).compactMap { $0 as? NSManagedObject }.filter { !$0.objectID.isTemporaryID }
        }
        // An object that was inserted, but has a permanent ID already, isn't saved yet either
        let updatedObjects = savedObjects(NSUpdatedObjectsKey).filter { !$0.isInserted }.compactMap(onlyIfSyncronizable)
        setUpdates(for: changes(of: updatedObjects, inserted: false, beforeSave: true))
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

        // Deletions are read now, as their objects can't be read anymore once they're saved, see `contextSaved`. Only the
        // ones being saved, rather than all that are made, which can still be discarded, e.g. by a rollback.
        // Pending changes are processed first, so the deletions that delete rules cascade to are included.
        context.processPendingChanges()
        var deletions: [NSManagedObjectID: SDSObjectDeletion] = [:]
        for object in context.deletedObjects where !object.objectID.isTemporaryID && !wasDeletedBySynchronizer(object.objectID) {
            guard let deleted = onlyIfSyncronizable(object: object) else { continue }
            deletions[object.objectID] = SDSObjectDeletion(
                localId: object.objectID.uriRepresentation().absoluteString,
                sharableRootLocalId: deleted.sharableRootLocalId,
                isSharable: deleted is SDSSharableContainer
            )
        }
        rememberDeletionsBeingSaved(deletions, by: context)
    }
    
    @objc func contextSaved(_ notification:Notification) {
        guard
            let userInfo = userInfo(from: notification),
            let savingContext = notification.object as? NSManagedObjectContext,
            // A child context only saves to its parent, whose save is handled. Its inserted objects don't have permanent IDs yet.
            savingContext.parent == nil
        else { return }
        let savedChanges = takeKeysBeingSaved(by: savingContext)
        // Deletions are stored once they're saved, rather than when they're made, so ones that are discarded aren't uploaded
        let configuration = self.configuration
        let deletedObjectIDs = (userInfo[NSDeletedObjectsKey] as? NSSet ?? []).compactMap { ($0 as? NSManagedObject)?.objectID }.filter { objectID in
            configuration?.entities[objectID.entity.name ?? ""] != nil && !objectID.isTemporaryID
        }
        let readDeletions = takeDeletionsBeingSaved(by: savingContext)
        // See `resetSyncData(beforeForgetting:)`
        guard !isForgetting else { return }
        let deletions = deletedObjectIDs.compactMap { objectID -> SDSObjectDeletion? in
            // Read when the save started, while only the app deleted it: a download that saves before this runs can take in
            // the deletion, which then looks like the synchronizer's, see `saveObservedUpdateContext`
            if let deletion = readDeletions[objectID] {
                return deletion
            }
            guard !wasDeletedBySynchronizer(objectID) else { return nil }
            // E.g. one a validation deleted. Its parent can't be read anymore, so it's sent to the private database.
            return SDSObjectDeletion(
                localId: objectID.uriRepresentation().absoluteString,
                sharableRootLocalId: nil,
                isSharable: configuration?.entities[objectID.entity.name ?? ""]?.isSharable == true
            )
        }
        // Before the changes, so a model saved with the identity of a deleted one gets its record, see `storeUpdates`
        storeRemovals(deletions)
        
        // Changes that were saved are stored again, so their saved values are uploaded too, see `contextWillSave`
        let updatedObjects = (userInfo[NSUpdatedObjectsKey] as? NSSet ?? []).compactMap { $0 as? NSManagedObject }
        var updatedChanges: [SDSObjectChange] = []
        for object in updatedObjects {
            guard let keys = savedChanges[object.objectID], let container = container(for: object) else { continue }
            let change = identifying(SDSObjectChange(
                localId: object.objectID.uriRepresentation().absoluteString,
                sharableRootLocalId: container.sharableRootLocalId,
                entityName: object.entity.name!,
                changedKeys: Array(keys),
                allKeys: container.syncKeys + [container.parentKey].compactMap { $0 }
            ), of: container, inserted: false)
            updatedChanges.append(change)
            if change.identityChanged {
                updatedChanges += referencingChanges(to: object)
            }
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

        // E.g. saves of models or keys that aren't synchronized don't need a synchronization
        guard !synchronizedChanges.isEmpty || !deletions.isEmpty else { return }

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
    /// - Parameter beforeSave: Whether the changes aren't saved yet, so they can still be discarded, see `contextChanged`.
    func changes(of objects: [SDSSynchronizableContainer], inserted: Bool, beforeSave: Bool = false) -> [SDSObjectChange] {
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
            ), of: updated, inserted: inserted, beforeSave: beforeSave)
        }
    }

    /// Adds what the identity of the object's entity, if it has one, needs to the change. Has to be called on the queue of the object's context.
    /// - Parameter beforeSave: Whether the change isn't saved yet. It can still be discarded, e.g. by a rollback, so the object
    ///   keeps the record of its saved identity values until it's saved, see `contextSaved`.
    private func identifying(_ change: SDSObjectChange, of container: SDSSynchronizableContainer, inserted: Bool, beforeSave: Bool = false) -> SDSObjectChange {
        guard
            let identity = configuration?.entities[change.entityName]?.identity,
            !identity.isEmpty
        else { return change }

        var change = change
        if beforeSave {
            let saved = container.object.committedValues(forKeys: identity)
            change.identityRecordName = SDSIdentity.identityRecordName(entityName: change.entityName, values: identity.map { saved[$0] })
        } else {
            change.identityRecordName = identityRecordName(for: container.object)
            change.identityChanged = !inserted && identity.contains(where: change.changedKeys.contains)
        }
        change.allKeys = container.syncKeys + [container.parentKey].compactMap { $0 }
        return change
    }

    /// Changes of the objects that reference the object through synchronized relationships, so their records reference its
    /// record again once it moved to another record: as its identity changed, or it was given the record of its identity,
    /// see `CloudKitLocalEntity.adopt`. Its previous record is deleted. Has to be called on the queue of the object's context.
    func referencingChanges(to object: NSManagedObject) -> [SDSObjectChange] {
        guard
            let context = object.managedObjectContext,
            let model = context.persistentStoreCoordinator?.managedObjectModel,
            let entities = configuration?.entities
        else { return [] }

        var keysByObject: [NSManagedObject: Set<String>] = [:]
        for (entityName, entity) in entities {
            guard let description = model.entitiesByName[entityName] else { continue }
            for key in entity.syncedProperties + [entity.parentKey].compactMap({ $0 }) {
                guard
                    let relationship = description.relationshipsByName[key],
                    let destination = relationship.destinationEntity,
                    object.entity.isKindOf(entity: destination)
                else { continue }

                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                // Subentities are fetched with their own configurations
                request.includesSubentities = false
                request.predicate = NSPredicate(format: relationship.isToMany ? "ANY %K == %@" : "%K == %@", key, object)
                // Objects that aren't saved yet are uploaded with every key once they are
                for referencing in (try? context.fetch(request)) ?? [] where referencing != object && !referencing.objectID.isTemporaryID && !referencing.isDeleted {
                    keysByObject[referencing, default: []].insert(key)
                }
            }
        }

        return keysByObject.compactMap { referencing, keys in
            guard let container = container(for: referencing) else { return nil }
            return identifying(SDSObjectChange(
                localId: referencing.objectID.uriRepresentation().absoluteString,
                sharableRootLocalId: container.sharableRootLocalId,
                entityName: referencing.entity.name!,
                changedKeys: Array(keys),
                allKeys: container.syncKeys + [container.parentKey].compactMap { $0 }
            ), of: container, inserted: false)
        }
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

    /// Stores the removals without waiting for `context`, like `setUpdates(for:)`.
    func storeRemovals(_ deletions: [SDSObjectDeletion]) {
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
