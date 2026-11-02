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
                }
                takenIds.insert(id)

                let zoneId = zone(change.sharableRootLocalId)
                if onlyPrivate && zoneId != nil {
                    continue
                }
                stored.append((change, id, previousId, zoneId))
            }

            var updates = CloudKitUpdate.find(ids: stored.map(\.id), in: context)
            for (change, id, previousId, zoneId) in stored {
                let keys: [String]
                // Keys whose values are of unknown age
                var unchangedKeys: [String] = []
                if let previousId {
                    // An identity value changed: the record of the old values is deleted, and the object uploaded as a new record
                    logger.log("Moving `\(previousId)` to `\(id)`, as its identity changed")
                    setRemoval(id: previousId, zoneId: zoneId)
                    keys = change.allKeys
                } else if !hadRecord.contains(change.localId) && !change.allKeys.isEmpty {
                    // An object that was saved before synchronizing started, or by a process without the synchronizer, and
                    // changed now: its other values are backfilled, see `backfill(onlyUntracked:)`
                    keys = change.changedKeys
                    unchangedKeys = change.allKeys.filter { !change.changedKeys.contains($0) }
                } else {
                    keys = change.changedKeys
                }

                let update = updates[id] ?? CloudKitUpdate(id: id, entityName: change.entityName, context: context)
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
