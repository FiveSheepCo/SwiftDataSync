import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {

    /// How many objects are read at once, so large stores aren't loaded into memory at once.
    private static let backfillBatchSize = 500

    /// Queues local objects like inserts, so they're uploaded, e.g. ones that were saved before the app synchronized.
    ///
    /// Only saves made while the store is observed become changes. Objects saved before `setup`, before the app adopted
    /// SwiftDataSync, or by a process without it, would otherwise only be uploaded once they change. So would every object
    /// after switching to another iCloud account, as nothing of this device is in it yet.
    ///
    /// Their values are of unknown age, so they mustn't overwrite what's in iCloud: they're queued as backfilled (see
    /// `CloudKitUpdate.backfilledKeys`). If a record of the same name exists, e.g. because another device created the same
    /// identity, its values win completely, also over values it lacks, which another device could have cleared. Only
    /// objects whose records don't exist are uploaded with them.
    ///
    /// Objects whose records are known, but that are gone from the store, e.g. because it was lost or rebuilt, are looked for
    /// as well, see `forgetVanishedObjects`. While every record is downloaded again, objects without an identity that have no
    /// records are left for later: they might be copies of the vanished ones, which the download gives their records, see
    /// `SDSContentIndex`.
    ///
    /// Only object IDs are fetched to find the objects, which are compared with the local entities' IDs, and the objects
    /// themselves are read in batches. Throws if the stores can't be read, which mustn't be taken for no objects.
    /// - Parameter onlyUntracked: Whether only objects without a record are queued, e.g. at setup. Otherwise every object
    ///   is, e.g. after switching accounts. Objects keep their record names, so switching back doesn't duplicate them.
    func backfill(onlyUntracked: Bool) throws {
        guard let observedUpdateContext, let configuration else { return }
        let context = self.context
        // Before looking for objects that vanished, which the entities of an interrupted page save would look like
        try repairInterruptedPageSave()

        // The objects that have records, by the URI of their IDs, and the ones whose deletions weren't uploaded yet
        let (trackedLocalIds, removedIds): (Set<String>, Set<String>) = try context.performAndWait {
            // Pending changes are saved first, as the fetches only read the store
            try context.save()
            let request = NSFetchRequest<NSDictionary>(entityName: "CloudKitLocalEntity")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["localId", "id"]
            var tracked: Set<String> = []
            for row in try context.fetch(request) {
                if let localId = row["localId"] as? String { tracked.insert(localId) }
            }
            let removals = NSFetchRequest<NSDictionary>(entityName: "CloudKitRemoval")
            removals.resultType = .dictionaryResultType
            removals.propertiesToFetch = ["id"]
            return (tracked, Set(try context.fetch(removals).compactMap { $0["id"] as? String }))
        }

        let (existingLocalIds, objectIDs) = try observedUpdateContext.performAndWaitUnchecked {
            var existingLocalIds: Set<String> = []
            var objectIDs: [String: [NSManagedObjectID]] = [:]
            for entityName in configuration.entities.keys.sorted() {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: entityName)
                request.resultType = .managedObjectIDResultType
                // Subentities are synchronized as entities of their own
                request.includesSubentities = false
                request.includesPendingChanges = false
                for objectID in try observedUpdateContext.fetch(request) {
                    let localId = objectID.uriRepresentation().absoluteString
                    existingLocalIds.insert(localId)
                    objectIDs[entityName, default: []].append(objectID)
                }
            }
            return (existingLocalIds, objectIDs)
        }

        try forgetVanishedObjects(
            localIds: trackedLocalIds.subtracting(existingLocalIds),
            removedIds: removedIds,
            synchronizedEntities: Set(configuration.entities.keys)
        )
        let isRecovering = isRecoveringVanishedObjects
        
        var untracked: [String: [NSManagedObjectID]] = [:]
        var leftForRecoveryCount = 0
        for (entityName, ids) in objectIDs {
            let hasIdentity = configuration.entities[entityName]?.identity.isEmpty == false
            for objectID in ids {
                let isTracked = trackedLocalIds.contains(objectID.uriRepresentation().absoluteString)
                if isTracked && onlyUntracked { continue }
                if !isTracked && isRecovering && !hasIdentity {
                    leftForRecoveryCount += 1
                    continue
                }
                untracked[entityName, default: []].append(objectID)
            }
        }
        if leftForRecoveryCount > 0 {
            logger.log("Leaving \(leftForRecoveryCount) local objects without records until every record was downloaded again")
        }

        let count = untracked.values.reduce(0) { $0 + $1.count }
        guard count > 0 else { return }
        logger.log("Queueing \(count) local objects \(onlyUntracked ? "without records" : "for a new account or zone"), without overwriting what's in iCloud")

        for (entityName, objectIDs) in untracked.sorted(by: { $0.key < $1.key }) {
            for start in stride(from: 0, to: objectIDs.count, by: Self.backfillBatchSize) {
                let batch = Array(objectIDs[start ..< min(start + Self.backfillBatchSize, objectIDs.count)])
                let changes = try observedUpdateContext.performAndWaitUnchecked {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                    request.predicate = NSPredicate(format: "self IN %@", batch)
                    request.includesSubentities = false
                    request.returnsObjectsAsFaults = false
                    let objects = try observedUpdateContext.fetch(request)
                    let changes = self.changes(of: objects.compactMap(container(for:)), inserted: true)
                    // The objects were only read, and aren't needed anymore
                    for object in objects where !object.hasChanges {
                        observedUpdateContext.refresh(object, mergeChanges: false)
                    }
                    return changes
                }
                try context.performAndWait {
                    if onlyUntracked {
                        // Objects that got records meanwhile, e.g. because the app saved them, keep their changes as they are
                        let tracked = CloudKitLocalEntity.entries(forLocalIds: changes.map(\.localId), in: context)
                        storeUpdates(changes.filter { tracked[$0.localId] == nil }, backfilled: true)
                    } else {
                        storeUpdates(changes, backfilled: true)
                    }
                    try context.save()
                    context.refreshAllObjects()
                }
            }
        }
    }

    /// Local entities of objects that are gone, although their deletions weren't recorded, e.g. because the store was lost
    /// or replaced, or the objects were deleted by a batch delete or a process without the synchronizer.
    ///
    /// Their records mustn't be deleted: a lost store would then delete the data on every device. They're forgotten instead,
    /// and every record is downloaded again, which restores the objects. Has to be called before synchronizing.
    /// Returns how many were forgotten.
    @discardableResult
    private func forgetVanishedObjects(localIds: Set<String>, removedIds: Set<String>, synchronizedEntities: Set<String>) throws -> Int {
        // Only objects of synchronized entities are looked for, e.g. not ones of entities that aren't synchronized anymore.
        // URIs look like `x-coredata://<store>/<entity>/p<number>`.
        let vanished = localIds.filter { localId in
            guard let components = URL(string: localId)?.pathComponents, components.count >= 2 else { return false }
            return synchronizedEntities.contains(components[1])
        }
        guard !vanished.isEmpty else { return 0 }

        let context = self.context
        let forgotten: Int = try context.performAndWait {
            var forgotten = 0
            let vanished = Array(vanished)
            for start in stride(from: 0, to: vanished.count, by: Self.backfillBatchSize) {
                let batch = Array(vanished[start ..< min(start + Self.backfillBatchSize, vanished.count)])
                let entries = CloudKitLocalEntity.entries(forLocalIds: batch, in: context).values
                    // Their deletions are uploaded next, after which their entities are removed
                    .filter { !removedIds.contains($0.id) }
                // Their pending changes can't be uploaded without the objects
                context.metadataEntries(of: "CloudKitUpdate", withIds: entries.map(\.id)).forEach(context.delete)
                entries.forEach(context.delete)
                forgotten += entries.count
            }
            guard forgotten > 0 else { return 0 }

            // Written first, so objects without an identity aren't uploaded as duplicates if the app is terminated before
            // they're matched, see `backfill(onlyUntracked:)`
            updateFileState { $0.isRecoveringVanishedObjects = true }
            // Downloads only bring records that changed, so every record is downloaded again
            accessState { state in
                state.changeToken = nil
            }
            for zone in try CloudKitZone.getAll() {
                zone.changeToken = nil
            }
            try context.save()
            return forgotten
        }
        if forgotten > 0 {
            logger.error("\(forgotten) synchronized objects are gone without having been deleted, e.g. because the store was replaced. Their records stay in iCloud and are downloaded again.")
        }
        return forgotten
    }
    
    /// Repairs what a download's page save left when the app was terminated in between, see `FileState.interruptedPageSave`.
    ///
    /// Only the entities the page created for objects that weren't saved are removed, whose records are downloaded again as
    /// the change token wasn't saved, and the metadata of the records the page deleted, whose objects are gone. Taking them
    /// for objects that vanished would download everything again, and miss deletions since.
    func repairInterruptedPageSave() throws {
        guard
            let page = interruptedPageSave,
            let observedUpdateContext,
            let observedStore
        else { return }
        let context = self.context
        
        let candidates: [(id: String, localId: String)] = context.performAndWait {
            let created = CloudKitLocalEntity.entries(forLocalIds: page.createdLocalIds, in: context).values
            let deleted = context.metadataEntries(of: "CloudKitLocalEntity", withIds: page.deletedRecordNames).compactMap { $0 as? CloudKitLocalEntity }
            return (Array(created) + deleted).map { ($0.id, $0.localId) }
        }
        let goneIds: [String] = observedUpdateContext.performAndWait {
            candidates.filter { candidate in
                guard let objectID = URL(string: candidate.localId).flatMap(observedStore.managedObjectID(forURIRepresentation:)) else { return true }
                return (try? observedUpdateContext.existingObject(with: objectID)) == nil
            }.map(\.id)
        }
        
        try context.performAndWait {
            context.metadataEntries(of: "CloudKitLocalEntity", withIds: goneIds).forEach(context.delete)
            // Models that were created again since keep their changes
            let deletedIds = goneIds.filter(Set(page.deletedRecordNames).contains)
            let createdAgain = Set(CloudKitUpdate.find(ids: deletedIds, in: context).values.filter(\.isLocalInsert).map(\.id))
            for entityName in ["CloudKitUpdate", "CloudKitRemoval"] {
                context.metadataEntries(of: entityName, withIds: deletedIds.filter { !createdAgain.contains($0) }).forEach(context.delete)
            }
            try context.save()
        }
        logger.log("Repaired an interrupted save of a download, removing the records of \(goneIds.count) objects that weren't saved or were deleted")
        updateFileState { $0.interruptedPageSave = nil }
    }
    
    /// Every record was downloaded again after objects vanished, which gave the copies of the vanished objects their
    /// records. The objects without records left are queued with the next synchronization, see `backfill(onlyUntracked:)`.
    func finishRecoveringVanishedObjects() {
        updateFileState { $0.isRecoveringVanishedObjects = false }
        mutableStateNeedsBackfill()
        requestSynchronization()
    }

    /// Uploads keys of every local object of the entities, e.g. the keys that a catch-up added, which records don't have yet.
    /// Objects in zones of other users' shares are left alone. The objects are read in batches.
    /// - Parameter keysByEntity: The keys to upload by entity name, `nil` for every synchronized key.
    /// - Parameter skippingRecordNames: Records whose objects are left out, e.g. as the catch-up couldn't store them.
    /// - Parameter onlyRecordNames: The records whose objects are uploaded, rather than every object's, e.g. the ones an
    ///   earlier catch-up couldn't store.
    func uploadLocalObjects(keysByEntity: [String: [String]?], skippingRecordNames: Set<String> = [], onlyRecordNames: Set<String>? = nil) throws {
        guard let observedUpdateContext else { return }
        let context = self.context
        let localIds = { (recordNames: Set<String>) -> Set<String> in
            recordNames.isEmpty ? [] : context.performAndWait {
                Set(context.metadataEntries(of: "CloudKitLocalEntity", withIds: Array(recordNames)).compactMap { ($0 as? CloudKitLocalEntity)?.localId })
            }
        }
        let skippedLocalIds = localIds(skippingRecordNames)
        if !skippedLocalIds.isEmpty {
            logger.log("Not uploading \(skippedLocalIds.count) local objects whose records couldn't be caught up on")
        }
        let onlyLocalIds = onlyRecordNames.map(localIds)
        if onlyLocalIds?.isEmpty == true { return }

        var count = 0
        for (entityName, keys) in keysByEntity.sorted(by: { $0.key < $1.key }) {
            let objectIDs: [NSManagedObjectID] = try observedUpdateContext.performAndWait {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: entityName)
                request.resultType = .managedObjectIDResultType
                request.includesSubentities = false
                let objectIDs = try observedUpdateContext.fetch(request)
                guard let onlyLocalIds else { return objectIDs }
                return objectIDs.filter { onlyLocalIds.contains($0.uriRepresentation().absoluteString) }
            }
            for start in stride(from: 0, to: objectIDs.count, by: Self.backfillBatchSize) {
                let batch = Array(objectIDs[start ..< min(start + Self.backfillBatchSize, objectIDs.count)])
                let changes = try observedUpdateContext.performAndWaitUnchecked {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                    request.predicate = NSPredicate(format: "self IN %@", batch)
                    request.includesSubentities = false
                    request.returnsObjectsAsFaults = false
                    let objects = try observedUpdateContext.fetch(request)
                    let changes = self.changes(of: objects.compactMap(container(for:)), inserted: true).compactMap { change -> SDSObjectChange? in
                        var change = change
                        if let keys {
                            change.changedKeys = change.changedKeys.filter(keys.contains)
                        }
                        return change.changedKeys.isEmpty || skippedLocalIds.contains(change.localId) ? nil : change
                    }
                    for object in objects where !object.hasChanges {
                        observedUpdateContext.refresh(object, mergeChanges: false)
                    }
                    return changes
                }
                count += changes.count
                try context.performAndWait {
                    storeUpdates(changes, onlyPrivate: true)
                    try context.save()
                }
            }
        }
        logger.log("Uploading \(count) local objects")
    }
}
