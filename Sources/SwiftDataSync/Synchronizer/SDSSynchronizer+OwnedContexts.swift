import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {

    /// - Parameter backfilled: Whether the values are of unknown age, see `CloudKitUpdate.backfilledKeys`.
    func setUpdate(id: String, zoneId: CKRecordZone.ID?, entityName: String, changedKeys: [String], backfilled: Bool = false) {
        let context = self.context

        context.performAndWait {
            let update = CloudKitUpdate.retrieve(for: id, entityName: entityName, context: context)
            if backfilled {
                update.addBackfilledKeys(changedKeys)
            } else {
                update.addChangedKeys(changedKeys)
            }
            if let zoneId = zoneId {
                update.sharedZone = CloudKitZone.getZone(with: zoneId, context: context)
            }
        }
    }

    func setRemoval(id: String, zoneId: CKRecordZone.ID?) {
        let context = self.context

        countRemoval()
        context.performAndWait {
            CloudKitUpdate.find(for: id)?.delete()
            let removal = CloudKitRemoval.retrieve(for: id, context: context)

            if let zoneId = zoneId {
                removal.sharedZone = CloudKitZone.getZone(with: zoneId, context: context)
            }
        }
    }

    /// Stores the changes like `setUpdates(for:)` does, with a few fetches for each batch of them rather than several for
    /// each change, e.g. for tens of thousands of objects that are backfilled. Has to be called on `context`'s queue.
    /// - Parameters:
    ///   - backfilled: Whether the values are of unknown age, see `CloudKitUpdate.backfilledKeys`.
    ///   - onlyPrivate: Whether changes of objects in zones of other users' shares are left out.
    func storeUpdates(_ changes: [SDSObjectChange], backfilled: Bool = false, onlyPrivate: Bool = false) {
        let context = self.context
        let batchSize = 500
        for start in stride(from: 0, to: changes.count, by: batchSize) {
            let batch = Array(changes[start ..< min(start + batchSize, changes.count)])

            // The objects' records, and which of the names their identities give them are taken
            let localIds = batch.map(\.localId)
            var entries = CloudKitLocalEntity.entries(forLocalIds: localIds, in: context)
            // An object without a record, e.g. one that was changed before synchronizing started, is uploaded with every key
            let hadRecord = Set(entries.keys)
            let identityNames = Array(Set(batch.compactMap(\.identityRecordName)))
            var takenIds = CloudKitLocalEntity.existingIds(identityNames, in: context)
            // Names whose models were deleted, which wasn't uploaded yet, see below
            var removedIds = Set(context.metadataEntries(of: "CloudKitRemoval", withIds: identityNames).compactMap { $0.value(forKey: "id") as? String })
            // Names that models moved away from in this batch, and the ones of them that other models took, which are kept
            var vacatedIds: Set<String> = []
            var reclaimedIds: Set<String> = []

            var zonesByRoot: [String: CKRecordZone.ID?] = [:]
            let zone = { (rootLocalId: String?) -> CKRecordZone.ID? in
                guard let rootLocalId else { return nil }
                if let zone = zonesByRoot[rootLocalId] { return zone }
                // Like `sharedZoneId(forRootLocalId:)`, with the entities of this batch. A root without a record isn't shared.
                let zone = (entries[rootLocalId]?.id ?? self.existingRecordId(forLocalId: rootLocalId))
                    .flatMap { CloudKitShare.share(for: $0, in: context) }
                    .flatMap { $0.isSharedByOtherUser ? $0.recordID.zoneID : nil }
                zonesByRoot[rootLocalId] = zone
                return zone
            }

            var stored: [(change: SDSObjectChange, id: String, previousId: String?, zoneId: CKRecordZone.ID?)] = []
            for change in batch {
                // Before the object gets a record, which would keep backfill from uploading it, see `backfill(onlyUntracked:)`
                let zoneId = zone(change.sharableRootLocalId)
                if onlyPrivate && zoneId != nil {
                    continue
                }

                let id: String
                var previousId: String?
                if change.identityChanged {
                    // Rare, so it's done like for a single change
                    (id, previousId) = CloudKitLocalEntity.recordId(
                        forLocalId: change.localId,
                        identityRecordName: change.identityRecordName,
                        renamingToIdentity: change.identityChanged,
                        isReserved: { self.temporaryObject(for: $0) != nil },
                        in: context
                    )
                    entries[change.localId] = CloudKitLocalEntity.entry(forLocalId: change.localId, in: context)
                    if let previousId {
                        // E.g. another model of this save takes the identity this one gave up
                        takenIds.remove(previousId)
                        vacatedIds.insert(previousId)
                        // E.g. two models swap their identities
                        if vacatedIds.contains(id) {
                            logger.log("Giving `\(id)` to a model that moved to the identity another model of the same save moved away from")
                            reclaimedIds.insert(id)
                        }
                    }
                    if previousId != nil && removedIds.contains(id) {
                        // E.g. the identity changed back before its move was uploaded. The record is kept, rather than deleted,
                        // as its removal would win over the upload.
                        logger.log("Keeping `\(id)`, as the model moved back to it")
                        context.metadataEntries(of: "CloudKitRemoval", withIds: [id]).forEach(context.delete)
                        removedIds.remove(id)
                    }
                } else if let entry = entries[change.localId] {
                    id = entry.id
                } else if
                    let name = change.identityRecordName,
                    removedIds.contains(name),
                    let entry = CloudKitLocalEntity.entry(forId: name, in: context)
                {
                    // The model of the identity was deleted, and is created again before that was uploaded, e.g. when the user
                    // unsubscribes and subscribes again. It keeps the record, rather than the record being deleted and the
                    // model uploaded under another name, as a model with the same identity keeps its own record.
                    logger.log("Giving `\(name)` to the model created again with its identity")
                    context.metadataEntries(of: "CloudKitRemoval", withIds: [name]).forEach(context.delete)
                    removedIds.remove(name)
                    entry.localId = change.localId
                    entries[change.localId] = entry
                    id = name
                } else {
                    // Another local model with the same identity keeps its own record, as two models can't share one
                    let identityName = change.identityRecordName.flatMap { name in
                        !takenIds.contains(name) && self.temporaryObject(for: name) == nil ? name : nil
                    }
                    id = identityName ?? UUID().uuidString
                    entries[change.localId] = CloudKitLocalEntity(id: id, localId: change.localId, context: context)
                    if vacatedIds.contains(id) {
                        logger.log("Giving `\(id)` to a model with the identity another model of the same save moved away from")
                        reclaimedIds.insert(id)
                    }
                    if removedIds.contains(id) {
                        // The record of a model that moved to another identity, which wasn't deleted yet. It's kept for
                        // this model, as its removal would win over the upload.
                        logger.log("Giving `\(id)` to a model with the identity another model moved away from")
                        context.metadataEntries(of: "CloudKitRemoval", withIds: [id]).forEach(context.delete)
                        removedIds.remove(id)
                    }
                }
                takenIds.insert(id)

                stored.append((change, id, previousId, zoneId))
            }

            var updates = CloudKitUpdate.find(ids: stored.map(\.id), in: context)
            for (change, id, previousId, zoneId) in stored {
                let keys: [String]
                // Keys whose values are of unknown age
                var unchangedKeys: [String] = []
                if let previousId {
                    // An identity value changed: the record of the old values is deleted, unless another model took it, and
                    // the object uploaded as a new record
                    logger.log("Moving `\(previousId)` to `\(id)`, as its identity changed")
                    // Values of unknown age stay so, e.g. of an object saved before synchronizing started, and mustn't
                    // overwrite a record of the new identity
                    let previouslyBackfilled = Set(CloudKitUpdate.find(ids: [previousId], in: context)[previousId]?.backfilledKeys ?? [])
                    if !reclaimedIds.contains(previousId) {
                        setRemoval(id: previousId, zoneId: zoneId)
                    }
                    keys = change.allKeys.filter { !previouslyBackfilled.contains($0) || change.changedKeys.contains($0) }
                    unchangedKeys = change.allKeys.filter { !keys.contains($0) }
                } else if !hadRecord.contains(change.localId) && !change.allKeys.isEmpty {
                    // An object that was saved before synchronizing started, or by a process without the synchronizer, and
                    // changed now: its other values are backfilled, see `backfill(onlyUntracked:)`
                    keys = change.changedKeys
                    unchangedKeys = change.allKeys.filter { !change.changedKeys.contains($0) }
                } else {
                    keys = change.changedKeys
                }

                // Not one a removal of this batch deleted, which is gone from the context if it wasn't saved yet
                let update = updates[id].flatMap { $0.isDeleted || $0.managedObjectContext == nil ? nil : $0 } ?? CloudKitUpdate(id: id, entityName: change.entityName, context: context)
                updates[id] = update
                if backfilled {
                    update.addBackfilledKeys(keys)
                } else {
                    update.addChangedKeys(keys)
                    update.addBackfilledKeys(unchangedKeys)
                }
                // The record was named here, and isn't known to exist, see `CloudKitUpdate.isLocalInsert`
                if backfilled || previousId != nil || !hadRecord.contains(change.localId) {
                    update.markAsLocalInsert()
                }
                if let zoneId {
                    update.sharedZone = CloudKitZone.getZone(with: zoneId, context: context)
                }
            }
        }
    }
}
