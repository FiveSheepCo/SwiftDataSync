import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {
    
    func upload() async throws {
        try await _upload(sharedDatabase: false)
        try await _upload(sharedDatabase: true)
        
        try self.context.save()
    }
    
    private func _upload(sharedDatabase: Bool) async throws {
        await updateUpdatesToSend()
        
        let startDate = Date.now
        // Deletes are retrieved first so that every one of them is known when filtering out the updates
        let deletes = synchronizableDeletes(sharedDatabase: sharedDatabase, maximum: CKModifyRecordsOperation.maximumRecords)
        let records = synchronizableUpdates(sharedDatabase: sharedDatabase)
        // TODO(later): These records should ideally be top-down. Referenced records should be uploaded before referrers
        
        guard records.count + deletes.count > 0 else {
            self.lastCompletedUpload = Date()
            logger.log("No remaining changed records")
            return
        }
        
        let database = (sharedDatabase ? cloudSharedDatabase : cloudPrivateDatabase)!
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: deletes)
            operation.savePolicy = .changedKeys
            
            var doneRecords: [CKRecord] = []
            var doneDeletes: [CKRecord.ID] = []
            operation.perRecordSaveBlock = { _, result in
                switch result {
                case .success(let record): doneRecords.append(record)
                case .failure(let error): self.logger.log("Error while uploading single record: \(error, privacy: .public)") // TODO: This should propably hold the auto upload for 15 minutes or something and show the error for the user to display
                }
            }
            operation.perRecordDeleteBlock = { recordId, result in
                switch result {
                case .success: doneDeletes.append(recordId)
                case .failure(let error): self.logger.log("Error while deleting single record: \(error, privacy: .public)")
                }
            }
            operation.modifyRecordsResultBlock = { operationResult in
                switch operationResult {
                    case .success:
                        self.deleteObjects(for: doneRecords, deletes: doneDeletes, startDate: startDate)
                        
                        self.logger.log("Operation completed: \(doneRecords.count) \(doneDeletes.count)")
                        continuation.resume()
                    case .failure(let error):
                        // TODO: Handle limit exceeded error (requests can have 400 records, which is statically in this lib, but can also only have 2MB, which we cannot easily determine)
                        self.logger.log("Error while uploading records: \(error)")
                        continuation.resume(throwing: error)
                }
            }
            database.add(operation)
            logger.log("Operation added to \(sharedDatabase ? "shared" : "private") database")
        }
        
        try await _upload(sharedDatabase: sharedDatabase)
    }
    
    private func synchronizableUpdates(sharedDatabase: Bool) -> [CKRecord] {
        context.performAndWait {
            discardUpdatesOfRemovedRecords()
            
            let updates = CloudKitUpdate.retrieve()
            let records = updates.filter({ object -> Bool in
                (object.sharedZone != nil) == sharedDatabase
            }).compactMap(record(for:))
            
            return records
        }
    }
    
    /// CloudKit rejects saving and deleting the same record in a single operation.
    /// An update can still end up next to a removal, e.g. when an inserted object is deleted before its insertion was handled,
    /// so the removal wins, just like `setRemoval` deletes the pending update.
    /// Has to be called on `context`.
    private func discardUpdatesOfRemovedRecords() {
        let removalRequest: NSFetchRequest<CloudKitRemoval> = CloudKitRemoval.fetchRequest()
        removalRequest.sortDescriptors = []
        let removedIds = ((try? removalRequest.execute()) ?? []).map(\.id)
        guard !removedIds.isEmpty else { return }
        
        let updateRequest: NSFetchRequest<CloudKitUpdate> = CloudKitUpdate.fetchRequest()
        updateRequest.sortDescriptors = []
        updateRequest.predicate = NSPredicate(format: "id IN %@", removedIds)
        
        for update in (try? updateRequest.execute()) ?? [] {
            logger.log("[Upload] Discarding update for `\(update.id)` as it is also removed")
            update.delete()
        }
    }
    
    private func record(for update: CloudKitUpdate) -> CKRecord? {
        let id = update.id
        let recordId = update.recordId
        let record = CKRecord(recordType: update.recordType, recordID: recordId)
        
        let changedKeys = update.changedKeys
        logger.log("[Upload] Changed from `CloudKitUpdate`: \(changedKeys)")
        
        guard let container = find(for: id) else {
            fatalError("This should never happen, it cannot be that the object doesn't exist, unless the background context is out of sync with the viewContext.")
        }
        
        let shouldContinue = self.observedUpdateContext!.performAndWait {
            
            // Synchronize parent, but only if parent is changed
            if let parentKey = container.parentKey,
               changedKeys.contains(parentKey),
               let parent = container.parent,
               let parentRecordId = parent.synchronizableContainer?.recordId
            {
                record.setParent(parentRecordId)
                // This workaround is needed so that deletion of records with a parent works
                record[Constants.parentWorkaroundKey] = CKRecord.Reference(recordID: parentRecordId, action: .deleteSelf)
            }
            
            // Only sync keys that are actually in the syncKeys array
            // Important because `changedKeys` could also include the parent key
            let syncKeys = changedKeys.filter { key in
                container.syncKeys.contains(key)
            }
            if syncKeys.isEmpty {
                return false
            }
            
            for (key, value) in container.changeDictionary(for: syncKeys) {
                logger.log("Setting `\(String(describing: value), privacy: .private)` for \(key, privacy: .public)")
                record[key] = value
            }
            return true
        }
        
        if !shouldContinue {
            update.delete()
            return nil
        }
        
        return record
    }
    
    private func synchronizableDeletes(sharedDatabase: Bool, maximum: Int) -> [CKRecord.ID] {
        context.performAndWait {
            let deletes = CloudKitRemoval.retrieve(maximum: maximum)
            let recordIds = deletes.filter({ object -> Bool in
                (object.sharedZone != nil) == sharedDatabase
            }).map { removal in
                removal.recordId
            }
            
            return recordIds
        }
    }
    
    private func deleteObjects(for updates: [CKRecord], deletes: [CKRecord.ID], startDate: Date) {
        guard let observedUpdateContext else {
            assertionFailure()
            return
        }
        
        let context = self.context
        context.performAndWait {
            for record in updates {
                let update = CloudKitUpdate.retrieve(for: record.recordID.recordName, entityName: record.recordType, context: context)
                let id = update.id
                let changedKeys = update.changedKeys
                
                // TODO(later): make new "changedKeys" out of isDone, so that it uploads only the newly changed things
                var isDone: Bool = true
                
                guard let container = find(for: id) else {
                    fatalError("This should never happen, it cannot be that the object doesn't exist, unless the background context is out of sync with the viewContext.")
                }
                let lastChange = container.lastObjectChange
                
                observedUpdateContext.performAndWait {
                    // Check parent, but only if parent is changed
                    var expectedParentId: String? = nil
                    if let parentKey = container.parentKey,
                       changedKeys.contains(parentKey),
                       let parent = container.parent {
                        expectedParentId = parent.synchronizableContainer?.recordId.recordName
                    }
                    guard record.parent?.recordID.recordName == expectedParentId else {
                        logger.log("Scheduling another upload as parentId \(String(describing: expectedParentId)) does not match \(record.parent)")
                        isDone = false
                        return
                    }
                    
                    if let lastChange, lastChange > startDate {
                        isDone = false
                        logger.log("Scheduling another upload as for `\(record.recordType)` has changed")
                        return
                    }
                }
                
                if isDone {
                    logger.log("Update for `\(update.id)` deleted")
                    update.delete()
                }
            }
            
            for delete in deletes {
                CloudKitRemoval.retrieve(for: delete.recordName, context: context).delete()
            }
        }
    }
}
