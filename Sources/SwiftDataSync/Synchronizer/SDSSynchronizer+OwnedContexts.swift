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

        // The names models move away from, as their identities changed, which other models of these changes can take, e.g.
        // when two swap their identities, in whichever order they come. Only names that identities give: a model whose
        // identity changed always leaves one, see `CloudKitLocalEntity.recordId`. Identities can't be sharable, so none is
        // left out by `onlyPrivate`.
        var vacating: Set<String> = []
        // The keys of moving models whose values are of unknown age, read before another model takes their records, which
        // gets updates of its own there, see below
        var backfilledKeysOfMoving: [String: Set<String>] = [:]
        // What the updates of the records moving models move away from hold back, which their new records' updates hold back
        // instead, as the records in iCloud still reference them until those are uploaded, see `CloudKitUpdate.previousReferences`.
        // Read before the updates are deleted with the records' removals, or as other models take the records.
        var heldBackByMoving: [String: [String]] = [:]
        let moving = changes.filter(\.identityChanged)
        if !moving.isEmpty {
            let current = CloudKitLocalEntity.entries(forLocalIds: moving.map(\.localId), in: context)
            let pending = CloudKitUpdate.find(ids: current.values.map(\.id), in: context)
            for change in moving {
                guard let id = current[change.localId]?.id else { continue }
                backfilledKeysOfMoving[change.localId] = Set(pending[id]?.backfilledKeys ?? [])
                heldBackByMoving[change.localId] = pending[id]?.previousReferences ?? []
                guard id != change.identityRecordName, UUID(uuidString: id) == nil else { continue }
                vacating.insert(id)
            }
        }
        let vacatedByMoving = vacating

        // The records that changed relationships referenced before, read before models move to other records here, so the
        // records they move away from are found, see `CloudKitUpdate.previousReferences`
        let previousReferenceLocalIds = Array(Set(changes.flatMap(\.previousReferenceLocalIds)))
        let previousReferenceIds = previousReferenceLocalIds.isEmpty ? [:] : CloudKitLocalEntity.entries(forLocalIds: previousReferenceLocalIds, in: context).mapValues(\.id)

        // The names models moved away from, which are deleted once every batch is stored, unless another model of these
        // changes took them, also one of another batch
        var vacatedIds: [(id: String, zoneId: CKRecordZone.ID?)] = []
        // The names models were given in these changes, rather than had already. A model's change can come twice, e.g.
        // as it references another one whose identity changed, once before its own move.
        var assignedIds: Set<String> = []

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
                // Whether the model had the record already, rather than being given it here
                var hadId = false
                if change.identityChanged {
                    if
                        let name = change.identityRecordName,
                        removedIds.contains(name),
                        let stale = CloudKitLocalEntity.entry(forId: name, in: context),
                        stale.localId != change.localId
                    {
                        // The model of the identity was deleted, which wasn't uploaded yet. This one takes its record, like
                        // a model created again with it (see below), rather than moving to a random name.
                        logger.log("Giving `\(name)` to a model that moved to the identity of a deleted one")
                        context.delete(stale)
                        context.metadataEntries(of: "CloudKitRemoval", withIds: [name]).forEach(context.delete)
                        removedIds.remove(name)
                    }
                    // Rare, so it's done like for a single change
                    (id, previousId) = CloudKitLocalEntity.recordId(
                        forLocalId: change.localId,
                        identityRecordName: change.identityRecordName,
                        renamingToIdentity: change.identityChanged,
                        isReserved: { self.temporaryObject(for: $0) != nil },
                        vacating: vacating,
                        in: context
                    )
                    // Kept its record, e.g. as the name its identity gives it is taken
                    hadId = previousId == nil && entries[change.localId] != nil
                    entries[change.localId] = CloudKitLocalEntity.entry(forLocalId: change.localId, in: context)
                    if previousId != nil && removedIds.contains(id) {
                        // E.g. the identity changed back before its move was uploaded. The record is kept, rather than deleted,
                        // as its removal would win over the upload.
                        logger.log("Keeping `\(id)`, as the model moved back to it")
                        context.metadataEntries(of: "CloudKitRemoval", withIds: [id]).forEach(context.delete)
                        removedIds.remove(id)
                    }
                } else if let entry = entries[change.localId] {
                    id = entry.id
                    hadId = true
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
                    // Another local model with the same identity keeps its own record, as two models can't share one, unless it
                    // moves away from it
                    let identityName = change.identityRecordName.flatMap { name in
                        (vacating.contains(name) || !takenIds.contains(name)) && self.temporaryObject(for: name) == nil ? name : nil
                    }
                    id = identityName ?? UUID().uuidString
                    entries[change.localId] = CloudKitLocalEntity(id: id, localId: change.localId, context: context)
                    if removedIds.contains(id) {
                        // The record of a model that moved to another identity, which wasn't deleted yet. It's kept for
                        // this model, as its removal would win over the upload.
                        logger.log("Giving `\(id)` to a model with the identity another model moved away from")
                        context.metadataEntries(of: "CloudKitRemoval", withIds: [id]).forEach(context.delete)
                        removedIds.remove(id)
                    }
                }
                takenIds.insert(id)
                if !hadId {
                    vacating.remove(id)
                    assignedIds.insert(id)
                }

                stored.append((change, id, previousId, zoneId))
            }

            var updates = CloudKitUpdate.find(ids: stored.map(\.id), in: context)
            for (change, id, previousId, zoneId) in stored {
                let keys: [String]
                // Keys whose values are of unknown age
                var unchangedKeys: [String] = []
                if let previousId {
                    // An identity value changed: the record of the old values is deleted, unless another model takes it (see
                    // below), and the object uploaded as a new record
                    logger.log("Moving `\(previousId)` to `\(id)`, as its identity changed")
                    // Values of unknown age stay so, e.g. of an object saved before synchronizing started, and mustn't
                    // overwrite a record of the new identity
                    let previouslyBackfilled = backfilledKeysOfMoving[change.localId] ?? []
                    vacatedIds.append((previousId, zoneId))
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
                var existing = updates[id].flatMap { $0.isDeleted || $0.managedObjectContext == nil ? nil : $0 }
                if let other = existing, vacatedByMoving.contains(id), previousId != nil || !hadRecord.contains(change.localId) {
                    // The update of the model that moved away from the record, whose changes go to its new record. This one
                    // gets an update of its own, rather than taking the other's keys and their ages.
                    context.delete(other)
                    existing = nil
                }
                let update = existing ?? CloudKitUpdate(id: id, entityName: change.entityName, context: context)
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
                // The records that the model's record in iCloud references, whose removals wait for this update, see
                // `CloudKitUpdate.previousReferences`: what its relationships referenced before they changed, and records that
                // were replaced. A model that moves away from its record also holds back that record's removal, rather than it
                // being deleted while the new record waits, e.g. as iCloud is full, which would delete the model on other devices
                // meanwhile, and what that record's update held back, e.g. the record of a move before, or a previous parent.
                var references = change.previousReferenceLocalIds.compactMap { previousReferenceIds[$0] } + change.previousReferenceRecordIds
                if let previousId {
                    references += [previousId] + (heldBackByMoving[change.localId] ?? [])
                }
                update.addPreviousReferences(references.filter { $0 != id })
                if let zoneId {
                    update.sharedZone = CloudKitZone.getZone(with: zoneId, context: context)
                }
            }
        }

        // E.g. two models swap their identities, or one takes the identity another gave up: the record stays for it
        for (id, zoneId) in vacatedIds {
            guard !assignedIds.contains(id) else {
                logger.log("Giving `\(id)` to another model of the same changes, as the one that had it moved away from it")
                continue
            }
            setRemoval(id: id, zoneId: zoneId)
        }
    }
}
