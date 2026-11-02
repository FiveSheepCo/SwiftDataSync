import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {

    struct UploadSummary: Sendable {
        /// How many records are left for later as CloudKit rejected them, see `SDSRecordQuarantine`.
        var rejectedCount = 0
        /// When uploads to a database resume, if they're paused as its iCloud storage is full, see `QuotaExceededError`.
        /// Removals are still uploaded.
        var privateQuotaPauseEnd: Date?
        var sharedQuotaPauseEnd: Date?
    }

    /// Uploads the pending changes.
    /// - Parameters:
    ///   - includingSharedDatabase: Whether the shared database's changes are uploaded, which only happens after it was downloaded.
    ///   - checkingRecordsExist: Whether edits are only uploaded for records that exist, e.g. as the download failed, which
    ///     would have deleted the edited objects of records that were deleted elsewhere.
    func upload(includingSharedDatabase: Bool = true, checkingRecordsExist: Bool = false) async throws -> UploadSummary {
        // Records that keep changing in one database don't keep the other's changes from being uploaded
        var changesStillPending: ChangesStillPendingError?
        var summary = UploadSummary()
        let context = self.context
        do {
            for sharedDatabase in includingSharedDatabase ? [false, true] : [false] {
                do {
                    summary.rejectedCount += try await _upload(sharedDatabase: sharedDatabase, checkingRecordsExist: checkingRecordsExist)
                } catch let error as ChangesStillPendingError {
                    changesStillPending = error
                } catch let error as QuotaExceededError {
                    // Records aren't set aside, as nothing is wrong with them, and they aren't retried over and over.
                    // A full storage of a share's owner doesn't keep the user's own data from being uploaded.
                    logger.error("The iCloud storage of the \(error.sharedDatabase ? "shared" : "private") database is full, uploading later")
                    pauseUploads(sharedDatabase: error.sharedDatabase, until: .now.addingTimeInterval(timing.quotaExceededRetryInterval))
                }
            }
            summary.privateQuotaPauseEnd = quotaPauseEnd(sharedDatabase: false)
            summary.sharedQuotaPauseEnd = includingSharedDatabase ? quotaPauseEnd(sharedDatabase: true) : nil
        } catch {
            // What was uploaded before isn't uploaded again
            context.performAndWait {
                try? context.save()
            }
            throw error
        }

        try context.performAndWait {
            try context.save()
        }

        if let changesStillPending {
            throw changesStillPending
        }
        return summary
    }

    /// Thrown when records keep changing while they are uploaded, e.g. while the app edits them continuously.
    /// The synchronization ends, and they're uploaded once the app stops changing them.
    struct ChangesStillPendingError: Error {}

    /// How many rounds in a row may only upload records that changed again since, before the rest is left to a later synchronization.
    private static let maximumRoundsOfChangedRecords = 3

    /// What an operation's records and removals came to.
    private struct UploadOutcome {
        var doneRecords: [CKRecord] = []
        var doneDeletes: [CKRecord.ID] = []
        /// Records that existed already, by name, whose changed keys are saved over them next.
        var conflicts: [String: CKRecord] = [:]
        /// Records CloudKit rejected, with when their updates last changed, see `SDSRecordQuarantine`.
        var rejected: [String: Date] = [:]
        /// The error of records CloudKit asked to retry later, with the longest delay.
        var throttle: CKError?
        var isQuotaExceeded = false
        /// The error of a record whose zone is gone, or one that says the user isn't signed in anymore. CloudKit only reports
        /// errors of single records for each record, while the operation's result is a success.
        var zoneOrAccountError: CKError?
    }
    
    /// Edits of records that don't exist anymore, which aren't uploaded, see `upload(includingSharedDatabase:checkingRecordsExist:)`.
    /// They stay pending until a download deletes their objects.
    private func recordsDeletedElsewhere(in round: UploadRound, database: any SDSCloudDatabase) async throws -> Set<CKRecord.ID> {
        let edited = round.records.map(\.recordID).filter { !round.localInserts.contains($0.recordName) }
        guard !edited.isEmpty else { return [] }
        let results = try await database.records(for: edited, desiredKeys: [])
        return Set(results.compactMap { recordID, result in
            if case .failure(let error as CKError) = result, error.code == .unknownItem { recordID } else { nil }
        })
    }

    /// Returns how many records are left for later as CloudKit rejected them, see `SDSRecordQuarantine`.
    /// - Parameter roundsOfChangedRecords: How many rounds in a row only uploaded records that changed again since.
    /// - Parameter didRetryConflicts: Whether records that existed already were uploaded again in this round already.
    private func _upload(
        sharedDatabase: Bool,
        checkingRecordsExist: Bool,
        maximumRecords: Int = CKModifyRecordsOperation.maximumRecords,
        roundsOfChangedRecords: Int = 0,
        didRetryConflicts: Bool = false
    ) async throws -> Int {
        // Another process could have taken over while this one was suspended
        guard syncLease.renew() else { throw SDSSyncLease.UnavailableError() }
        try checkNotStopped()

        await updateUpdatesToSend()
        let database = (sharedDatabase ? cloudSharedDatabase : cloudPrivateDatabase)!

        // Deletes are retrieved first. The maximum applies to saved and deleted records combined.
        // While iCloud is full, only removals are uploaded, which free up storage.
        let deletes = synchronizableDeletes(sharedDatabase: sharedDatabase, maximum: maximumRecords)
        var round = try synchronizableUpdates(sharedDatabase: sharedDatabase, maximum: quotaPauseEnd(sharedDatabase: sharedDatabase) == nil ? maximumRecords - deletes.count : 0)
        if checkingRecordsExist && !round.insertsBackfilledValues {
            let deleted = try await recordsDeletedElsewhere(in: round, database: database)
            if !deleted.isEmpty {
                logger.log("Not uploading edits of \(deleted.count) records that were deleted elsewhere")
                CKAsset.removeTemporaryFiles(of: round.records.filter { deleted.contains($0.recordID) })
                round.records.removeAll { deleted.contains($0.recordID) }
                // Their updates would be selected again and again, so the remaining edits wait for a download
                if round.records.isEmpty && deletes.isEmpty {
                    return round.quarantinedCount
                }
            }
        }
        let records = round.records
        let lastChangeDates = round.lastChangeDates

        guard records.count + deletes.count > 0 else {
            self.lastCompletedUpload = Date()
            logger.log("No remaining changed records")
            return round.quarantinedCount
        }

        let progress: UploadProgress
        do {
            progress = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UploadProgress, Error>) in

                let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: deletes)
                // Backfilled values mustn't overwrite what's in iCloud, so their records are inserted, which fails for
                // ones that exist. Their values are then only saved over the keys they lack, see `record(for:)`.
                // Other changes are saved over the records, also over records another device saved first.
                operation.savePolicy = round.insertsBackfilledValues ? .ifServerRecordUnchanged : .changedKeys
                // A record that fails doesn't keep the others from being saved, e.g. one CloudKit rejects
                operation.isAtomic = false

                var outcome = UploadOutcome()
                operation.perRecordSaveBlock = { recordId, result in
                    switch result {
                    case .success(let record): outcome.doneRecords.append(record)
                    case .failure(let error): self.classify(error, of: recordId, lastChangeDates: lastChangeDates, into: &outcome)
                    }
                }
                operation.perRecordDeleteBlock = { recordId, result in
                    switch result {
                    case .success: outcome.doneDeletes.append(recordId)
                    // The record is already gone, e.g. because it was deleted on another device too
                    case .failure(let error as CKError) where error.code == .unknownItem: outcome.doneDeletes.append(recordId)
                    // E.g. CloudKit asks to wait, or the zone is gone, like for saved records
                    case .failure(let error): self.classify(error, of: recordId, lastChangeDates: [:], into: &outcome)
                    }
                }
                operation.modifyRecordsResultBlock = { operationResult in
                    // The files of the assets were only written for this upload
                    CKAsset.removeTemporaryFiles(of: records)

                    if case .failure(let error) = operationResult {
                        // The zone is gone, e.g. because the user deleted the app's data in iCloud, see `PrivateZoneMissingError`
                        if !sharedDatabase, let zoneError = self.privateZoneMissingError(in: error) {
                            continuation.resume(throwing: PrivateZoneMissingError(error: zoneError))
                            return
                        }
                        guard let ckError = error as? CKError, ckError.code == .partialFailure else {
                            self.logger.log("Error while uploading records: \(error)")
                            continuation.resume(throwing: (error as? CKError)?.code == .quotaExceeded ? QuotaExceededError(sharedDatabase: sharedDatabase) : error)
                            return
                        }

                        // Records that failed don't keep the others from being saved, as the operation isn't atomic.
                        // Removals of records that are already gone are done. Records that existed already are saved over
                        // next. Records CloudKit rejected are left for later. The other records are uploaded again.
                        for (itemId, itemError) in ckError.partialErrorsByItemID ?? [:] {
                            guard let recordId = itemId as? CKRecord.ID else { continue }
                            if deletes.contains(recordId) {
                                if (itemError as? CKError)?.code == .unknownItem {
                                    if !outcome.doneDeletes.contains(recordId) {
                                        outcome.doneDeletes.append(recordId)
                                    }
                                } else {
                                    self.classify(itemError, of: recordId, lastChangeDates: [:], into: &outcome)
                                }
                            } else {
                                self.classify(itemError, of: recordId, lastChangeDates: lastChangeDates, into: &outcome)
                            }
                        }
                    }

                    var progress = self.deleteObjects(for: outcome.doneRecords, deletes: outcome.doneDeletes, round: round)
                    progress.conflictCount = self.retryConflicts(outcome.conflicts, ofBackfilledValues: round.insertsBackfilledValues)
                    progress.rejectedCount = self.quarantineRejectedRecords(outcome.rejected)
                    self.logger.log("Operation completed: \(outcome.doneRecords.count) \(outcome.doneDeletes.count)")

                    if let error = outcome.zoneOrAccountError {
                        // The zone is gone, e.g. because the user deleted the app's data in iCloud, see `PrivateZoneMissingError`.
                        // Zones of the shared database disappear when they're no longer shared, see `refreshSharedZoneIDs()`.
                        if error.code == .notAuthenticated {
                            continuation.resume(throwing: error)
                        } else if !sharedDatabase {
                            continuation.resume(throwing: PrivateZoneMissingError(error: error))
                        } else {
                            continuation.resume(returning: progress)
                        }
                    } else if outcome.isQuotaExceeded {
                        continuation.resume(throwing: QuotaExceededError(sharedDatabase: sharedDatabase))
                    } else if let throttle = outcome.throttle {
                        // Retrying right away, e.g. as other records were saved, would only be rejected again. The state and
                        // the routine synchronization wait as long as CloudKit asks.
                        self.logger.log("CloudKit asks to wait \(throttle.retryAfterSeconds ?? 0) seconds, uploading the remaining records later")
                        continuation.resume(throwing: throttle)
                    } else {
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
                return try await _upload(sharedDatabase: sharedDatabase, checkingRecordsExist: checkingRecordsExist, maximumRecords: count / 2, roundsOfChangedRecords: roundsOfChangedRecords)
            }
            // A single record that is too large on its own is left for later, see `SDSRecordQuarantine`
            guard let record = records.first, let lastChangeDate = lastChangeDates[record.recordID.recordName] else { throw error }
            _ = quarantineRejectedRecords([record.recordID.recordName: lastChangeDate])
            return try await _upload(sharedDatabase: sharedDatabase, checkingRecordsExist: checkingRecordsExist, roundsOfChangedRecords: roundsOfChangedRecords)
        }

        if progress.completedCount > 0 || progress.rejectedCount > 0 {
            return try await _upload(sharedDatabase: sharedDatabase, checkingRecordsExist: checkingRecordsExist, maximumRecords: maximumRecords)
        } else if progress.conflictCount > 0 && !didRetryConflicts {
            // Once more with the records that existed already, but not indefinitely if they keep changing
            return try await _upload(sharedDatabase: sharedDatabase, checkingRecordsExist: checkingRecordsExist, maximumRecords: maximumRecords, roundsOfChangedRecords: roundsOfChangedRecords, didRetryConflicts: true)
        } else if progress.changedAgainCount > 0 {
            // The newer changes are uploaded next, but not indefinitely while the app keeps changing the records
            guard roundsOfChangedRecords + 1 < Self.maximumRoundsOfChangedRecords else {
                logger.log("Records keep changing while uploading, uploading them later")
                throw ChangesStillPendingError()
            }
            return try await _upload(sharedDatabase: sharedDatabase, checkingRecordsExist: checkingRecordsExist, maximumRecords: maximumRecords, roundsOfChangedRecords: roundsOfChangedRecords + 1)
        } else {
            // E.g. records that keep failing, or keep differing from what was uploaded. They are uploaded with a later synchronization.
            logger.log("No changes completed, uploading the remaining ones later")
            throw SDSSyncError(title: "error.uploadIncomplete")
        }
    }

    /// Sorts out why saving a record failed.
    private func classify(_ error: Error, of recordId: CKRecord.ID, lastChangeDates: [String: Date], into outcome: inout UploadOutcome) {
        let recordName = recordId.recordName
        guard outcome.conflicts[recordName] == nil, outcome.rejected[recordName] == nil else { return }
        let ckError = error as? CKError

        if let serverRecord = serverRecordOfConflict(error) {
            outcome.conflicts[recordName] = serverRecord
        } else if let ckError, [.zoneNotFound, .userDeletedZone, .notAuthenticated].contains(ckError.code) {
            outcome.zoneOrAccountError = ckError
        } else if ckError?.code == .quotaExceeded {
            outcome.isQuotaExceeded = true
        } else if let ckError, let retryAfter = ckError.retryAfterSeconds {
            // E.g. `zoneBusy`, `requestRateLimited` or `serviceUnavailable`
            if retryAfter > outcome.throttle?.retryAfterSeconds ?? 0 {
                outcome.throttle = ckError
            }
        } else if SDSRecordQuarantine.isPermanentRejection(error), let lastChangeDate = lastChangeDates[recordName] {
            outcome.rejected[recordName] = lastChangeDate
        }
        logger.log("Error while uploading single record: \(error, privacy: .public)")
    }

    /// The record on the server, if saving a record failed because it exists, e.g. because another device saved the same
    /// identity first (see `SDSConfiguration.Entity.sync`), or a backfilled record was inserted.
    private func serverRecordOfConflict(_ error: Error) -> CKRecord? {
        guard let error = error as? CKError, error.code == .serverRecordChanged else { return nil }
        return error.serverRecord
    }

    /// Remembers the records that existed already, so the next upload saves the changed keys over them, and returns how many.
    /// - Parameter ofBackfilledValues: Whether they were inserted with backfilled values. Their records win over those
    ///   completely (see `CloudKitUpdate.recordExists()`), and are downloaded with another synchronization. Only the keys
    ///   that changed locally are saved over them.
    private func retryConflicts(_ conflicts: [String: CKRecord], ofBackfilledValues: Bool) -> Int {
        guard !conflicts.isEmpty else { return 0 }
        logger.log("Saving \(conflicts.count) records over the ones that existed already")
        // Also records whose updates are done now, which counts as progress
        let count = conflicts.count
        var conflicts = conflicts
        if ofBackfilledValues {
            let context = self.context
            let conflictNames = Array(conflicts.keys)
            let names = context.performAndWait {
                var withChanges: Set<String> = []
                for update in CloudKitUpdate.find(ids: conflictNames, in: context).values {
                    update.recordExists()
                    if update.keysToUpload.isEmpty {
                        update.delete()
                    } else {
                        withChanges.insert(update.id)
                    }
                }
                return withChanges
            }
            // Only records with local changes are saved over
            conflicts = conflicts.filter { names.contains($0.key) }
            requestSynchronization()
        }
        rememberServerRecordsOfConflicts(conflicts)
        return count
    }

    /// Leaves records that CloudKit rejected out of uploads for a while, and returns how many.
    private func quarantineRejectedRecords(_ records: [String: Date]) -> Int {
        guard !records.isEmpty else { return 0 }
        logger.error("Uploading \(records.count) records that CloudKit rejected later: \(records.keys.sorted())")
        quarantine(records)
        return records.count
    }

    /// The records of an upload operation.
    private struct UploadRound {
        var records: [CKRecord] = []
        /// When the records' updates last changed, by name, to notice changes made while uploading.
        var lastChangeDates: [String: Date] = [:]
        /// How many records were left out as CloudKit rejected them, see `SDSRecordQuarantine`.
        var quarantinedCount = 0
        /// Whether the records have backfilled values, which are inserted, see `_upload`.
        var insertsBackfilledValues = false
        /// The records of objects that got their records here, which aren't known to exist, see `CloudKitUpdate.isLocalInsert`.
        var localInserts: Set<String> = []
        /// The record keys in the overflow assets of records that send their split, by name, see `SDSOverflow`.
        var overflowKeys: [String: Set<String>] = [:]
    }

    /// Up to `maximum` records to upload.
    ///
    /// Only the updates a round needs are fetched, rather than every pending one for each round. Records with backfilled
    /// values come first, in rounds of their own, as they're saved differently. Referenced records come before the records
    /// referencing them, so a download in between never receives a record whose references don't exist yet.
    ///
    /// Throws if a record can't be prepared. Downloading anyway could overwrite its changes before they are uploaded.
    private func synchronizableUpdates(sharedDatabase: Bool, maximum: Int) throws -> UploadRound {
        guard maximum > 0 else { return UploadRound() }
        let referenceDepths = (configuration?.entities ?? [:]).mapValues(\.referenceDepth)
        let quarantinedCount = quarantinedRecordCount

        // By reference depth, lowest first. Updates of other entities, which can't be uploaded, are discarded with the first.
        let typesByDepth = Dictionary(grouping: referenceDepths.keys, by: { referenceDepths[$0] ?? 0 })
        let deeperTypes = referenceDepths.filter { $0.value > 0 }.map(\.key)
        let depthPredicates = [NSPredicate(format: "NOT (recordType IN %@)", deeperTypes)]
            + typesByDepth.keys.filter { $0 > 0 }.sorted().map { NSPredicate(format: "recordType IN %@", typesByDepth[$0] ?? []) }
        let zonePredicate = NSPredicate(format: sharedDatabase ? "sharedZone != nil" : "sharedZone == nil")
        let backfilledPredicate = NSPredicate(format: "rawChangedKeys CONTAINS %@", CloudKitUpdate.backfillMarker)

        return try context.performAndWaitUnchecked {
            var skippedCount = 0
            // A record's references are uploaded before it, also if only one of them has backfilled values
            for depthPredicate in depthPredicates {
                for insertsBackfilledValues in [true, false] {
                    var round = UploadRound(insertsBackfilledValues: insertsBackfilledValues)
                    let kindPredicate = insertsBackfilledValues ? backfilledPredicate : NSCompoundPredicate(notPredicateWithSubpredicate: backfilledPredicate)

                    while round.records.count < maximum {
                        // Quarantined updates are fetched again each time, so as many more are fetched
                        let limit = maximum - round.records.count + quarantinedCount
                        let request = CloudKitUpdate.fetchRequest()
                        request.sortDescriptors = []
                        request.fetchLimit = limit
                        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [zonePredicate, kindPredicate, depthPredicate])
                        let updates = try context.fetch(request)

                        // CloudKit rejects saving and deleting the same record in a single operation. An update can still
                        // end up next to a removal, e.g. when an inserted object is deleted before its insertion was handled,
                        // so the removal wins, just like `setRemoval` deletes the pending update.
                        let removedIds = Set(context.metadataEntries(of: "CloudKitRemoval", withIds: updates.map(\.id)).compactMap { $0.value(forKey: "id") as? String })

                        var discardedCount = 0
                        var quarantined = 0
                        for update in updates where round.records.count < maximum {
                            if removedIds.contains(update.id) {
                                logger.log("[Upload] Discarding update for `\(update.id)` as it is also removed")
                                update.delete()
                                discardedCount += 1
                                continue
                            }
                            let lastChangeDate = update.lastChangeDate
                            guard !isQuarantined(update.id, lastChangeDate: lastChangeDate) else {
                                quarantined += 1
                                continue
                            }
                            let isLocalInsert = update.isLocalInsert
                            if let record = try record(for: update, overflowKeys: &round.overflowKeys) {
                                round.records.append(record)
                                round.lastChangeDates[record.recordID.recordName] = lastChangeDate
                                if isLocalInsert {
                                    round.localInserts.insert(record.recordID.recordName)
                                }
                            } else {
                                discardedCount += 1
                            }
                        }
                        round.quarantinedCount = max(round.quarantinedCount, quarantined)
                        // Discarded updates are deleted, so the next fetch finds others
                        if updates.count < limit || discardedCount == 0 {
                            break
                        }
                    }
                    skippedCount += round.quarantinedCount
                    if !round.records.isEmpty {
                        return round
                    }
                }
            }
            return UploadRound(quarantinedCount: skippedCount)
        }
    }

    /// - Parameter overflowKeys: Gets the record keys of the record's overflow asset, if it sends them, see `SDSOverflow`.
    private func record(for update: CloudKitUpdate, overflowKeys: inout [String: Set<String>]) throws -> CKRecord? {
        let id = update.id
        let recordId = update.recordId(defaultZoneID: defaultZoneID)
        let newRecord = CKRecord(recordType: update.recordType, recordID: recordId)
        
        let changedKeys = update.changedKeys
        let backfilledKeys = update.backfilledKeys
        let keys = changedKeys + backfilledKeys
        logger.log("[Upload] Changed from `CloudKitUpdate`: \(changedKeys), backfilled: \(backfilledKeys)")
        
        // A failed read throws, rather than being taken for an object that's gone
        guard let container = try lookUp(for: id) else {
            // There is nothing left to upload
            logger.error("[Upload] Discarding update for `\(id)` as its object is unknown")
            update.delete()
            return nil
        }
        
        let observedUpdateContext = self.observedUpdateContext!
        let entityConfiguration = configuration?.entities[update.recordType]
        let previousOverflowKeys = self.overflowKeys(of: recordId.recordName)
        var recordOverflowKeys: Set<String>?
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
                let entity = container.object.entity
                let recordKey = { (key: String) in entity.propertiesByName[key]?.renamingIdentifier ?? key }
                
                // Synchronize parent, but only if parent is changed
                if let parentKey = container.parentKey, keys.contains(parentKey) {
                    if let parent = container.parent, let parentRecordId = self.container(for: parent)?.recordId {
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
                let syncKeys = keys.filter { key in
                    container.syncKeys.contains(key)
                }
                if syncKeys.isEmpty {
                    return false
                }
                
                for (key, value) in try container.changeDictionary(for: syncKeys) {
                    logger.log("Setting `\(String(describing: value), privacy: .private)` for \(key, privacy: .public)")
                    newRecord[key] = value
                }
                
                // Values too large for the record go into an asset. The split only depends on the object's values, so it's
                // made again for every upload of a key that can be large. Only what changed is sent: keys that move into or
                // out of the asset, changed keys that stay in it, and the asset if its keys or values changed. Unchanged keys
                // aren't sent, which would overwrite another device's edits of them. See `SDSOverflow`.
                let largeKeys = entityConfiguration.map { SDSOverflow.keys(of: $0, description: entity) } ?? []
                if largeKeys.contains(where: syncKeys.contains) {
                    let split = try container.overflowSplit(keys: largeKeys)
                    let current = Set(split.overflow?.keys.map { $0 } ?? [])
                    // Production schemas reject fields they don't have, so the field is only sent to records that need it or had it
                    if !current.isEmpty || !previousOverflowKeys.isEmpty {
                        let changedRecordKeys = Set(syncKeys.map(recordKey))
                        for (key, value) in split.fields {
                            if current.contains(key) {
                                if changedRecordKeys.contains(key) || !previousOverflowKeys.contains(key) {
                                    newRecord[key] = nil
                                }
                            } else if previousOverflowKeys.contains(key) {
                                newRecord[key] = value
                            }
                        }
                        if current != previousOverflowKeys || !current.isDisjoint(with: changedRecordKeys) {
                            newRecord[SDSOverflow.key] = try split.overflow.map(SDSOverflow.asset(for:))
                            recordOverflowKeys = current
                        }
                    }
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
        if let recordOverflowKeys {
            overflowKeys[recordId.recordName] = recordOverflowKeys
        }
        
        // A record that existed already is updated with this device's changes, see `serverRecordOfConflict`. Backfilled
        // values were dropped when it turned out to exist, see `retryConflicts(_:ofBackfilledValues:)`.
        guard let serverRecord = takeServerRecordOfConflict(named: recordId.recordName) else {
            return newRecord
        }
        return SDSIdentity.merging(newRecord, into: serverRecord)
    }
    
    private func synchronizableDeletes(sharedDatabase: Bool, maximum: Int) -> [CKRecord.ID] {
        let defaultZoneID = self.defaultZoneID!
        return context.performAndWait {
            CloudKitRemoval.retrieve(sharedDatabase: sharedDatabase, maximum: maximum).map { removal in
                removal.recordId(defaultZoneID: defaultZoneID)
            }
        }
    }

    struct UploadProgress: Sendable {
        /// Updates and removals that were uploaded, or that turned out to have nothing left to upload.
        var completedCount = 0
        /// Updates that changed again while they were uploaded, so they are uploaded again.
        var changedAgainCount = 0
        /// Records that existed already, which are uploaded again over them.
        var conflictCount = 0
        /// Records CloudKit rejected, which are uploaded later, see `SDSRecordQuarantine`.
        var rejectedCount = 0
    }

    /// Removes the updates and removals that were uploaded, and returns the progress.
    /// - Parameter round: The records that were uploaded, with when their updates last changed when they were prepared.
    private func deleteObjects(for updates: [CKRecord], deletes: [CKRecord.ID], round: UploadRound) -> UploadProgress {
        guard let observedUpdateContext, let observedStore else {
            assertionFailure()
            return UploadProgress()
        }
        let lastChangeDates = round.lastChangeDates

        // Which keys the records have in their overflow assets now, see `SDSOverflow`. Written before the updates are removed.
        var overflowChanges: [String: Set<String>] = [:]
        for record in updates {
            if let keys = round.overflowKeys[record.recordID.recordName] {
                overflowChanges[record.recordID.recordName] = keys
            }
        }
        for delete in deletes {
            overflowChanges[delete.recordName] = []
        }
        setOverflowKeys(overflowChanges)

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
                let keys = update.keysToUpload

                // An update that changed while it was uploaded, e.g. because the object was changed again, is uploaded again.
                // It's compared with when it last changed before, rather than the clock, which can be changed.
                // TODO(later): make new "changedKeys" out of isDone, so that it uploads only the newly changed things
                guard update.lastChangeDate == lastChangeDates[record.recordID.recordName] else {
                    logger.log("Scheduling another upload as for `\(record.recordType)` has changed")
                    // The record exists now, so its backfilled values were uploaded, and it's no local insert anymore
                    update.recordExists()
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
                       keys.contains(parentKey),
                       let parent = container.parent {
                        expectedParentId = self.existingRecordId(of: parent)
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

                // The record is gone, and so is its object, unless an identity change gave the object another record.
                // An entity left behind would be taken for an object that vanished, see `backfill(onlyUntracked:)`.
                if let entity = existingLocalEntity(for: delete.recordName) {
                    let objectExists = URL(string: entity.localId).flatMap(observedStore.managedObjectID(forURIRepresentation:)).map { objectID in
                        observedUpdateContext.performAndWait { (try? observedUpdateContext.existingObject(with: objectID)) != nil }
                    } ?? false
                    if !objectExists {
                        entity.delete()
                    }
                }
            }
            return progress
        }
    }
}
