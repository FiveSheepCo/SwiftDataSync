import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {
    
    /// Uploads the pending changes, and returns how many records are left for later as CloudKit rejected them, see `SDSRecordQuarantine`.
    @discardableResult
    func upload() async throws -> Int {
        // Records that keep changing in one database don't keep the other's changes from being uploaded.
        // The download is still skipped afterwards, as it would overwrite their newer changes.
        var changesStillPending: ChangesStillPendingError?
        var rejectedCount = 0
        for sharedDatabase in [false, true] {
            do {
                rejectedCount += try await _upload(sharedDatabase: sharedDatabase)
            } catch let error as ChangesStillPendingError {
                changesStillPending = error
            }
        }

        let context = self.context
        try context.performAndWait {
            try context.save()
        }

        if let changesStillPending {
            throw changesStillPending
        }
        return rejectedCount
    }
    
    /// Thrown when records keep changing while they are uploaded, e.g. while the app edits them continuously.
    /// Downloading would overwrite the newer changes with the uploaded ones, so the synchronization ends without it.
    struct ChangesStillPendingError: Error {}
    
    /// How many rounds in a row may only upload records that changed again since, before the rest is left to a later synchronization.
    private static let maximumRoundsOfChangedRecords = 3
    
    /// Returns how many records are left for later as CloudKit rejected them, see `SDSRecordQuarantine`.
    /// - Parameter roundsOfChangedRecords: How many rounds in a row only uploaded records that changed again since.
    /// - Parameter didRetryConflicts: Whether records that another device saved first were uploaded again in this round already.
    private func _upload(
        sharedDatabase: Bool,
        maximumRecords: Int = CKModifyRecordsOperation.maximumRecords,
        roundsOfChangedRecords: Int = 0,
        didRetryConflicts: Bool = false
    ) async throws -> Int {
        // Another process could have taken over while this one was suspended
        guard syncLease.renew() else { throw SDSSyncLease.UnavailableError() }
        try checkNotStopped()

        await updateUpdatesToSend()

        // Deletes are retrieved first so that every one of them is known when filtering out the updates.
        // The maximum applies to saved and deleted records combined.
        let deletes = synchronizableDeletes(sharedDatabase: sharedDatabase, maximum: maximumRecords)
        let (records, lastChangeDates, quarantinedCount) = try synchronizableUpdates(sharedDatabase: sharedDatabase, maximum: maximumRecords - deletes.count)

        guard records.count + deletes.count > 0 else {
            self.lastCompletedUpload = Date()
            logger.log("No remaining changed records")
            return quarantinedCount
        }

        let database = (sharedDatabase ? cloudSharedDatabase : cloudPrivateDatabase)!

        let progress: UploadProgress
        do {
            progress = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UploadProgress, Error>) in

                let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: deletes)
                operation.savePolicy = .changedKeys
                // A record that fails doesn't keep the others from being saved, e.g. one CloudKit rejects
                operation.isAtomic = false

                var doneRecords: [CKRecord] = []
                var doneDeletes: [CKRecord.ID] = []
                var conflicts: [String: CKRecord] = [:]
                var rejected: [String: Date] = [:]
                operation.perRecordSaveBlock = { recordId, result in
                    switch result {
                    case .success(let record): doneRecords.append(record)
                    case .failure(let error):
                        if let serverRecord = self.serverRecordOfIdentityConflict(error, recordId: recordId) {
                            conflicts[recordId.recordName] = serverRecord
                        } else if SDSRecordQuarantine.isPermanentRejection(error), let lastChangeDate = lastChangeDates[recordId.recordName] {
                            rejected[recordId.recordName] = lastChangeDate
                        }
                        self.logger.log("Error while uploading single record: \(error, privacy: .public)")
                    }
                }
                operation.perRecordDeleteBlock = { recordId, result in
                    switch result {
                    case .success: doneDeletes.append(recordId)
                    // The record is already gone, e.g. because it was deleted on another device too
                    case .failure(let error as CKError) where error.code == .unknownItem: doneDeletes.append(recordId)
                    case .failure(let error): self.logger.log("Error while deleting single record: \(error, privacy: .public)")
                    }
                }
                operation.modifyRecordsResultBlock = { operationResult in
                    // The files of the assets were only written for this upload
                    CKAsset.removeTemporaryFiles(of: records)

                    switch operationResult {
                        case .success:
                            var progress = self.deleteObjects(for: doneRecords, deletes: doneDeletes, lastChangeDates: lastChangeDates)
                            progress.conflictCount = self.retryConflicts(conflicts)
                            progress.rejectedCount = self.quarantineRejectedRecords(rejected)

                            self.logger.log("Operation completed: \(doneRecords.count) \(doneDeletes.count)")
                            continuation.resume(returning: progress)
                        case .failure(let error):
                            // The zone is gone, e.g. because the user deleted the app's data in iCloud, see `PrivateZoneMissingError`
                            if !sharedDatabase, let zoneError = self.privateZoneMissingError(in: error) {
                                continuation.resume(throwing: PrivateZoneMissingError(error: zoneError))
                                return
                            }
                            guard (error as? CKError)?.code == .partialFailure else {
                                self.logger.log("Error while uploading records: \(error)")
                                continuation.resume(throwing: error)
                                return
                            }

                            // Records that failed don't keep the others from being saved, as the operation isn't atomic.
                            // Removals of records that are already gone are done. Records of an identity that another device
                            // saved first are saved over its records next. Records CloudKit rejected are left for later.
                            // The other records are uploaded again.
                            let alreadyDeleted = self.alreadyDeletedRecordIDs(in: error, deletes: deletes)
                            if !alreadyDeleted.isEmpty {
                                self.logger.log("Discarding removals of \(alreadyDeleted.count) records that are already deleted")
                            }
                            let conflicts = conflicts.merging(self.serverRecordsOfIdentityConflicts(in: error)) { $1 }
                            let rejected = rejected.merging(self.rejectedRecords(in: error, lastChangeDates: lastChangeDates)) { $1 }

                            var progress = self.deleteObjects(for: doneRecords, deletes: Array(Set(doneDeletes + alreadyDeleted)), lastChangeDates: lastChangeDates)
                            progress.conflictCount = self.retryConflicts(conflicts)
                            progress.rejectedCount = self.quarantineRejectedRecords(rejected)
                            continuation.resume(returning: progress)
                    }
                }
                database.add(operation)
                logger.log("Operation added to \(sharedDatabase ? "shared" : "private") database")
            }
        }
        catch let error as CKError where error.code == .limitExceeded {
            // Operations are also limited in size, which cannot easily be determined beforehand
            let count = records.count + deletes.count
            if count > 1 {
                logger.log("Operation too large, retrying with at most \(count / 2) records")
                return try await _upload(sharedDatabase: sharedDatabase, maximumRecords: count / 2, roundsOfChangedRecords: roundsOfChangedRecords)
            }
            // A single record that is too large on its own is left for later, see `SDSRecordQuarantine`
            guard let record = records.first, let lastChangeDate = lastChangeDates[record.recordID.recordName] else { throw error }
            _ = quarantineRejectedRecords([record.recordID.recordName: lastChangeDate])
            return try await _upload(sharedDatabase: sharedDatabase, roundsOfChangedRecords: roundsOfChangedRecords)
        }

        if progress.completedCount > 0 || progress.rejectedCount > 0 {
            return try await _upload(sharedDatabase: sharedDatabase, maximumRecords: maximumRecords)
        } else if progress.conflictCount > 0 && !didRetryConflicts {
            // Once more with the records another device saved first, but not indefinitely if they keep changing
            return try await _upload(sharedDatabase: sharedDatabase, maximumRecords: maximumRecords, roundsOfChangedRecords: roundsOfChangedRecords, didRetryConflicts: true)
        } else if progress.changedAgainCount > 0 {
            // The newer changes are uploaded next, but not indefinitely while the app keeps changing the records
            guard roundsOfChangedRecords + 1 < Self.maximumRoundsOfChangedRecords else {
                logger.log("Records keep changing while uploading, uploading them later")
                throw ChangesStillPendingError()
            }
            return try await _upload(sharedDatabase: sharedDatabase, maximumRecords: maximumRecords, roundsOfChangedRecords: roundsOfChangedRecords + 1)
        } else {
            // E.g. records that keep failing, or keep differing from what was uploaded. They are uploaded with a later synchronization.
            // Downloading now could overwrite their changes before they are uploaded.
            logger.log("No changes completed, uploading the remaining ones later")
            throw SDSSyncError(title: "error.uploadIncomplete")
        }
    }
    
    /// The record another device saved first, if saving a record of an entity with an identity failed because it exists.
    /// Two devices that created a model for the same thing save it under the same name, see `SDSConfiguration.Entity.sync`.
    private func serverRecordOfIdentityConflict(_ error: Error, recordId: CKRecord.ID) -> CKRecord? {
        guard
            let error = error as? CKError,
            error.code == .serverRecordChanged,
            let serverRecord = error.serverRecord,
            configuration?.entities[serverRecord.recordType]?.identity.isEmpty == false
        else { return nil }
        return serverRecord
    }
    
    /// Like `serverRecordOfIdentityConflict`, for the records of a failed operation, by name.
    private func serverRecordsOfIdentityConflicts(in error: Error) -> [String: CKRecord] {
        guard let error = error as? CKError, error.code == .partialFailure else { return [:] }
        
        var records: [String: CKRecord] = [:]
        for (itemId, itemError) in error.partialErrorsByItemID ?? [:] {
            guard let recordId = itemId as? CKRecord.ID, let serverRecord = serverRecordOfIdentityConflict(itemError, recordId: recordId) else { continue }
            records[recordId.recordName] = serverRecord
        }
        return records
    }
    
    /// Remembers the records another device saved first, so the next upload saves the changed keys over them, and returns how many.
    private func retryConflicts(_ conflicts: [String: CKRecord]) -> Int {
        guard !conflicts.isEmpty else { return 0 }
        logger.log("Saving \(conflicts.count) records over the ones another device saved first under the same identity")
        rememberServerRecordsOfConflicts(conflicts)
        return conflicts.count
    }
    
    /// The records of a failed operation that CloudKit rejected, with when their updates last changed, see `SDSRecordQuarantine`.
    private func rejectedRecords(in error: Error, lastChangeDates: [String: Date]) -> [String: Date] {
        guard let error = error as? CKError, error.code == .partialFailure else { return [:] }

        var records: [String: Date] = [:]
        for (itemId, itemError) in error.partialErrorsByItemID ?? [:] {
            guard
                let recordName = (itemId as? CKRecord.ID)?.recordName,
                let lastChangeDate = lastChangeDates[recordName],
                SDSRecordQuarantine.isPermanentRejection(itemError)
            else { continue }
            records[recordName] = lastChangeDate
        }
        return records
    }

    /// Leaves records that CloudKit rejected out of uploads for a while, and returns how many.
    private func quarantineRejectedRecords(_ records: [String: Date]) -> Int {
        guard !records.isEmpty else { return 0 }
        logger.error("Uploading \(records.count) records that CloudKit rejected later: \(records.keys.sorted())")
        quarantine(records)
        return records.count
    }

    /// The removals among `deletes` that failed because their record doesn't exist anymore.
    private func alreadyDeletedRecordIDs(in error: Error, deletes: [CKRecord.ID]) -> [CKRecord.ID] {
        guard let error = error as? CKError, error.code == .partialFailure else { return [] }
        
        return deletes.filter { recordId in
            (error.partialErrorsByItemID?[recordId] as? CKError)?.code == .unknownItem
        }
    }
    
    /// Up to `maximum` records to upload, and when their updates last changed, to notice changes made while uploading.
    ///
    /// Throws if a record can't be prepared. Downloading anyway could overwrite its changes before they are uploaded.
    /// Also returns how many records were left out as CloudKit rejected them, see `SDSRecordQuarantine`.
    private func synchronizableUpdates(sharedDatabase: Bool, maximum: Int) throws -> (records: [CKRecord], lastChangeDates: [String: Date], quarantinedCount: Int) {
        let referenceDepths = (configuration?.entities ?? [:]).mapValues(\.referenceDepth)

        return try context.performAndWaitUnchecked {
            discardUpdatesOfRemovedRecords()

            // Referenced records are uploaded in earlier operations than the records referencing them,
            // so that a download in between never receives a record whose references do not exist yet
            let updates = CloudKitUpdate.retrieveAll().filter({ object -> Bool in
                (object.sharedZone != nil) == sharedDatabase
            }).sorted(by: { lhs, rhs in
                referenceDepths[lhs.recordType, default: 0] < referenceDepths[rhs.recordType, default: 0]
            })

            // Discarded updates don't count towards the maximum, so the remaining ones aren't taken for uploaded
            var records: [CKRecord] = []
            var lastChangeDates: [String: Date] = [:]
            var quarantinedCount = 0
            for update in updates where records.count < maximum {
                let lastChangeDate = update.lastChangeDate
                guard !isQuarantined(update.id, lastChangeDate: lastChangeDate) else {
                    quarantinedCount += 1
                    continue
                }
                if let record = try record(for: update) {
                    records.append(record)
                    lastChangeDates[record.recordID.recordName] = lastChangeDate
                }
            }
            return (records, lastChangeDates, quarantinedCount)
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
    
    private func record(for update: CloudKitUpdate) throws -> CKRecord? {
        let id = update.id
        let recordId = update.recordId
        let newRecord = CKRecord(recordType: update.recordType, recordID: recordId)
        // A record that another device saved first is updated with this device's changes, see `serverRecordOfIdentityConflict`
        let serverRecord = takeServerRecordOfConflict(named: recordId.recordName)
        
        let changedKeys = update.changedKeys
        logger.log("[Upload] Changed from `CloudKitUpdate`: \(changedKeys)")
        
        // A failed read throws, rather than being taken for an object that's gone
        guard let container = try lookUp(for: id) else {
            // There is nothing left to upload
            logger.error("[Upload] Discarding update for `\(id)` as its object is unknown")
            update.delete()
            return nil
        }
        
        let observedUpdateContext = self.observedUpdateContext!
        let shouldContinue: Bool
        do {
            shouldContinue = try observedUpdateContext.performAndWaitUnchecked {
                // The object can be deleted before its removal is stored, e.g. while this runs, or by a batch delete.
                // Its values would be read as `nil` and overwrite the record's values. Other errors keep the update.
                do {
                    _ = try observedUpdateContext.existingObject(with: container.object.objectID)
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSManagedObjectReferentialIntegrityError {
                    logger.error("[Upload] Discarding update for `\(id)` as its object is deleted")
                    return false
                }
                
                // Synchronize parent, but only if parent is changed
                if let parentKey = container.parentKey, changedKeys.contains(parentKey) {
                    if let parent = container.parent, let parentRecordId = parent.synchronizableContainer?.recordId {
                        newRecord.setParent(parentRecordId)
                        // This workaround is needed so that deletion of records with a parent works
                        newRecord[Constants.parentWorkaroundKey] = CKRecord.Reference(recordID: parentRecordId, action: .deleteSelf)
                    } else if container.parent == nil {
                        // The server would keep the previous parent, which differs from the expected one once uploaded
                        newRecord.setParent(nil as CKRecord.ID?)
                        newRecord[Constants.parentWorkaroundKey] = nil
                    }
                }
                
                // Only sync keys that are actually in the syncKeys array
                // Important because `changedKeys` could also include the parent key
                let syncKeys = changedKeys.filter { key in
                    container.syncKeys.contains(key)
                }
                if syncKeys.isEmpty {
                    return false
                }
                
                for (key, value) in try container.changeDictionary(for: syncKeys) {
                    logger.log("Setting `\(String(describing: value), privacy: .private)` for \(key, privacy: .public)")
                    newRecord[key] = value
                }
                return true
            }
        } catch {
            // The update is kept, so the record is uploaded with a later synchronization
            logger.error("[Upload] Failed to prepare the record for `\(id)`: \(error.localizedDescription)")
            throw error
        }
        
        if !shouldContinue {
            update.delete()
            return nil
        }
        
        return serverRecord.map { SDSIdentity.merging(newRecord, into: $0) } ?? newRecord
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
    
    struct UploadProgress: Sendable {
        /// Updates and removals that were uploaded, or that turned out to have nothing left to upload.
        var completedCount = 0
        /// Updates that changed again while they were uploaded, so they are uploaded again.
        var changedAgainCount = 0
        /// Records of an identity that another device saved first, which are uploaded again over its records.
        var conflictCount = 0
        /// Records CloudKit rejected, which are uploaded later, see `SDSRecordQuarantine`.
        var rejectedCount = 0
    }
    
    /// Removes the updates and removals that were uploaded, and returns the progress.
    /// - Parameter lastChangeDates: When the updates last changed when their records were prepared, by record name.
    private func deleteObjects(for updates: [CKRecord], deletes: [CKRecord.ID], lastChangeDates: [String: Date]) -> UploadProgress {
        guard let observedUpdateContext else {
            assertionFailure()
            return UploadProgress()
        }
        
        let context = self.context
        return context.performAndWait {
            var progress = UploadProgress()
            
            for record in updates {
                guard let update = CloudKitUpdate.find(for: record.recordID.recordName) else {
                    // E.g. the object was deleted while uploading, and its removal replaced the update
                    progress.completedCount += 1
                    continue
                }
                let id = update.id
                let changedKeys = update.changedKeys
                
                // An update that changed while it was uploaded, e.g. because the object was changed again, is uploaded again.
                // It's compared with when it last changed before, rather than the clock, which can be changed.
                // TODO(later): make new "changedKeys" out of isDone, so that it uploads only the newly changed things
                guard update.lastChangeDate == lastChangeDates[record.recordID.recordName] else {
                    logger.log("Scheduling another upload as for `\(record.recordType)` has changed")
                    progress.changedAgainCount += 1
                    continue
                }
                
                var isDone: Bool = true
                
                let container: SDSSynchronizableContainer?
                do {
                    container = try lookUp(for: id)
                } catch {
                    // The update is kept, so it's uploaded again
                    logger.error("[Upload] Failed to look up `\(id)`: \(error.localizedDescription)")
                    continue
                }
                guard let container else {
                    // There is nothing left to upload
                    update.delete()
                    progress.completedCount += 1
                    continue
                }
                
                observedUpdateContext.performAndWaitUnchecked {
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
                }
                
                if isDone {
                    logger.log("Update for `\(update.id)` deleted")
                    update.delete()
                    progress.completedCount += 1
                }
            }
            
            for delete in deletes {
                CloudKitRemoval.retrieve(for: delete.recordName, context: context).delete()
                progress.completedCount += 1
            }
            return progress
        }
    }
}
