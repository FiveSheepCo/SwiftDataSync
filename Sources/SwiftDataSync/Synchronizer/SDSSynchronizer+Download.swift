import Foundation
import CoreData
import CloudKit
import OSLog

/// How long the zone of an accepted share is kept although the shared database doesn't list it.
private let acceptedShareZoneListingDelay: TimeInterval = 5 * 60

/// How long a failed catch-up waits before it's tried again, as it downloads every record.
private let catchUpRetryDelay: TimeInterval = 60 * 60

/// Which models and keys a download stores. Keys are given as `Entity.key`, and a whole model by its entity name.
private enum DownloadScope {
    /// Everything that is synchronized, from the changes since the last download.
    /// While a catch-up is pending, records whose references are missing might reference records only it downloads.
    case all(catchUpIsPending: Bool)
    /// Only models and keys to catch up on, from every record rather than the changes since the last download.
    case catchingUp(on: Set<String>)
    
    var isCatchingUp: Bool {
        if case .catchingUp = self { true } else { false }
    }
    
    func includes(entity: String) -> Bool {
        switch self {
        case .all: true
        case .catchingUp(let keys): keys.contains(entity) || keys.contains { $0.hasPrefix("\(entity).") }
        }
    }
    
    func includes(entity: String, key: String) -> Bool {
        switch self {
        case .all: true
        case .catchingUp(let keys): keys.contains(entity) || keys.contains("\(entity).\(key)")
        }
    }
    
    /// Whether missing objects are inserted. A catch-up only adds keys to existing objects of models that were synchronized before.
    func insertsObjects(of entity: String) -> Bool {
        switch self {
        case .all: true
        case .catchingUp(let keys): keys.contains(entity)
        }
    }
}

extension SDSSynchronizer {
    
    /// How many records are downloaded again at once, see `_downloadOnce`. CloudKit fetches at most 400.
    static let downloadAgainBatchSize = 200

    /// Downloads the private database, then the shared one.
    ///
    /// Returns the error of the shared database's download instead of throwing it, e.g. for a zone of another user that keeps
    /// failing, as it mustn't keep the private database from being uploaded. Its own changes aren't uploaded then, as they're
    /// only uploaded after a download.
    /// - Parameter refreshingSharedZones: Whether the shared zones have to be refreshed, which `synchronize()` usually did already.
    func download(refreshingSharedZones: Bool = true) async throws -> (any Error)? {
        // Downloads skip models and keys this version doesn't synchronize, e.g. ones a newer version added, while their change
        // tokens move on. Once more is synchronized, they are caught up on by downloading every record once more.
        let catchUp = pendingCatchUp
        let scope = DownloadScope.all(catchUpIsPending: catchUp != nil)
        _ = takeRecoveryMissedRecords()
        
        try await _download(scope: scope)
        try checkNotStopped()

        do {
            if refreshingSharedZones {
                try await refreshSharedZoneIDs()
            }
            try await self._download(sharedDatabase: true, scope: scope)
        } catch let error where !Self.endsSynchronization(error) {
            logger.error("Failed to download the shared database: \(error.localizedDescription)")
            // Unless it keeps failing, which would keep anything from being uploaded, see `synchronize()`
            if isRecoveringVanishedObjects && countIncompleteRecovery() >= Self.maximumIncompleteRecoveries {
                finishRecoveringVanishedObjects()
            }
            return error
        }

        // Every record was downloaded again, also the shared database's, whose objects are copies of records in other users'
        // zones. Not while records failed, which local objects without records can be copies of: they'd be uploaded as new
        // records, and the records downloaded as duplicates. Unless they keep failing, which would keep anything from being
        // uploaded, see `synchronize()`.
        if isRecoveringVanishedObjects && (!takeRecoveryMissedRecords() || countIncompleteRecovery() >= Self.maximumIncompleteRecoveries) {
            finishRecoveringVanishedObjects()
        }

        // Extensions can have little memory and time, so the app catches up
        if let catchUp, !isAppExtension, catchUp.retryDate.map({ $0 <= .now }) ?? true {
            try checkNotStopped()
            logger.log("More models or keys are synchronized than before, catching up on them")
            func catchUpLater(recordsLeft: Set<String>? = nil) {
                postponeCatchUp(until: .now.addingTimeInterval(catchUpRetryDelay), recordsLeft: recordsLeft)
                // Nothing else might start a synchronization by then
                startTask(at: \.catchUpRetry) {
                    try? await Task.sleep(for: .seconds(catchUpRetryDelay))

                    self.finishTask(at: \.catchUpRetry)
                    self.startSync()
                }
            }
            do {
                _ = takeRecordsSkippedWhileCatchingUp()
                _ = takeCaughtUpKeysOfRecords()
                // The change tokens are kept, as downloading every record doesn't include deletions, which would then be missed
                try await _download(scope: .catchingUp(on: catchUp.newKeys))
                try await _download(sharedDatabase: true, scope: .catchingUp(on: catchUp.newKeys))

                // Local values of the newly synchronized keys were never uploaded, so records leave them out. Once caught up,
                // a record leaving out a key clears it (see `SDSValueCoding.clearedValues`), so they're uploaded first.
                // Until then, downloads leave them alone, as they're local changes. The upload follows this download.
                // Records that couldn't be stored might have the keys already, which the local values mustn't overwrite.
                // Keys that records had were downloaded, and aren't uploaded again.
                let skipped = takeRecordsSkippedWhileCatchingUp()
                let downloadedKeys = takeCaughtUpKeysOfRecords()
                if let recordsLeft = catchUp.recordsLeft {
                    // The other objects' values were uploaded by an earlier try
                    try uploadLocalObjects(keysByEntity: keysByEntity(catchUp.newKeys), onlyRecordNames: recordsLeft.subtracting(skipped.keys), downloadedKeys: downloadedKeys)
                } else {
                    try uploadLocalObjects(keysByEntity: keysByEntity(catchUp.newKeys), skippingRecordNames: Set(skipped.keys), downloadedKeys: downloadedKeys)
                }
                if skipped.values.contains(true) && countIncompleteCatchUp(catchUp) < Self.maximumCatchUpAttempts {
                    // Their records might lack the keys, which would clear the local values once caught up. Downloads leave
                    // the keys alone until the catch-up is done.
                    logger.log("Couldn't catch up on \(skipped.count) records, catching up again later")
                    catchUpLater(recordsLeft: Set(skipped.keys))
                } else {
                    if !skipped.isEmpty {
                        logger.error("Caught up without \(skipped.count) records that couldn't be stored: \(skipped.keys.sorted())")
                    }
                    finishCatchUp(catchUp)
                }
            } catch let error where !Self.endsSynchronization(error) {
                // The synchronization itself succeeded
                logger.log("Failed to catch up, retrying later: \(error.localizedDescription)")
                catchUpLater()
                return nil
            }

            // Records were held back if they reference records only the catch-up downloaded.
            // Their zones' change tokens weren't saved, so they are downloaded again now.
            let isCatchUpPending = pendingCatchUp != nil
            try await _download(scope: .all(catchUpIsPending: isCatchUpPending))
            do {
                try await _download(sharedDatabase: true, scope: .all(catchUpIsPending: isCatchUpPending))
            } catch let error where !Self.endsSynchronization(error) {
                // Like the shared database's download above, it doesn't keep the private database from being uploaded
                logger.error("Failed to download the shared database after catching up: \(error.localizedDescription)")
                return error
            }
        }
        return nil
    }

    /// Whether an error ends the synchronization, rather than only the download of the shared database or a catch-up.
    private static func endsSynchronization(_ error: any Error) -> Bool {
        error is StoppedError || error is AccountChangedError || error is SDSSyncLease.UnavailableError || isNotAuthenticated(error)
    }
    
    /// Registers newly shared zones, and cleans up after zones that are no longer shared with the current user.
    ///
    /// Called before downloading and uploading, as pending changes for a zone that is gone can never be uploaded and would
    /// fail the upload.
    func refreshSharedZoneIDs() async throws {
        // CloudKit shared zones always have the zoneName of the private zone that originally shared it. That said, all shared zones should always have the name of the default zone.
        let ids = try await cloudSharedDatabase.allRecordZones().map(\.zoneID).filter({ $0.zoneName == defaultZoneID.zoneName })
        
        // Zones of just accepted shares are kept even if the shared database doesn't list them yet
        let acceptedZoneIds = withAcceptedShareZones { acceptedShareZones in
            acceptedShareZones = acceptedShareZones.filter { zoneId, acceptanceDate in
                !ids.contains(zoneId) && -acceptanceDate.timeIntervalSinceNow < acceptedShareZoneListingDelay
            }
            return Set(acceptedShareZones.keys)
        }
        let existingZoneIds = Set(ids).union(acceptedZoneIds)
        
        let context = self.context
        let rootIdsInRemovedZones = try context.performAndWait {
            for id in ids {
                CloudKitZone.getZone(with: id, context: context)
            }
            
            // Zones that are no longer in the shared database were left, or their owner stopped sharing them
            let removedZones = try CloudKitZone.getAll().filter { !existingZoneIds.contains($0.calculatedId) }
            let removedZoneIds = Set(removedZones.map(\.calculatedId))
            
            // Their pending changes can never be uploaded
            if !removedZones.isEmpty {
                for entityName in ["CloudKitUpdate", "CloudKitRemoval"] {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                    request.predicate = NSPredicate(format: "sharedZone IN %@", removedZones)
                    ((try? context.fetch(request)) ?? []).forEach(context.delete)
                }
            }
            try context.save()
            
            return ((try? context.fetch(CloudKitShare.fetchRequest())) ?? [])
                .filter { entry in entry.share.map { removedZoneIds.contains($0.recordID.zoneID) } ?? false }
                .map(\.id)
        }
        let revokedRootIds = try await rootIdsInRemovedZones + revokedSharesInRemainingZones(sharedZoneIds: ids)
        
        for id in revokedRootIds {
            if let container = find(for: id) {
                logger.log("Removing local copy of revoked share \(id)")
                do {
                    try removeLocalCopy(of: container)
                } catch {
                    // The share and zone are kept, so the removal is retried with the next refresh
                    logger.log("Failed to remove local copy of revoked share \(id): \(error.localizedDescription)")
                }
            } else {
                try context.performAndWait {
                    CloudKitShare.updateShare(nil, for: id, context: context)
                    try context.save()
                }
            }
        }
        
        // Zones are only forgotten once none of their shares are left, so failed removals are retried
        try context.performAndWait {
            let remainingShareZoneIds = Set(((try? context.fetch(CloudKitShare.fetchRequest())) ?? []).compactMap { $0.share?.recordID.zoneID })
            for zone in try CloudKitZone.getAll() where !existingZoneIds.contains(zone.calculatedId) && !remainingShareZoneIds.contains(zone.calculatedId) {
                context.delete(zone)
            }
            try context.save()
        }
    }
    
    /// Root ids of shares of other users that are gone or no longer accessible, although their zone still exists.
    ///
    /// All shares of an owner are in the same zone, so the zone outlives a share when its owner stops sharing one of several roots.
    /// Their pending changes could never be uploaded, so this is checked before uploading.
    private func revokedSharesInRemainingZones(sharedZoneIds: [CKRecordZone.ID]) async throws -> [String] {
        let context = self.context
        let shares: [(rootId: String, recordID: CKRecord.ID)] = context.performAndWait {
            ((try? context.fetch(CloudKitShare.fetchRequest())) ?? []).compactMap { entry in
                guard
                    let share = entry.share,
                    share.isSharedByOtherUser,
                    sharedZoneIds.contains(share.recordID.zoneID)
                else { return nil }
                return (entry.id, share.recordID)
            }
        }
        guard !shares.isEmpty else { return [] }
        
        let results = try await cloudSharedDatabase.records(for: shares.map(\.recordID), desiredKeys: [])
        return shares.compactMap { share in
            // The share was deleted, or the current user was removed from it
            guard
                case .failure(let error) = results[share.recordID],
                let code = (error as? CKError)?.code,
                code == .unknownItem || code == .permissionFailure
            else { return nil }
            return share.rootId
        }
    }
    
    /// - Parameter isRetryAfterExpiredTokens: Whether this downloads zones completely, as their change tokens expired.
    private func _download(sharedDatabase: Bool = false, scope: DownloadScope, isRetryAfterExpiredTokens: Bool = false) async throws {
        do {
            try await _downloadOnce(sharedDatabase: sharedDatabase, scope: scope)
        } catch is ChangeTokenExpiredError where !isRetryAfterExpiredTokens {
            // Their tokens were reset, so every record of the zones is downloaded. Deletions since the expired token can't be
            // downloaded anymore, so records deleted elsewhere meanwhile stay on this device.
            logger.log("Change tokens expired, downloading the zones completely")
            try await _download(sharedDatabase: sharedDatabase, scope: scope, isRetryAfterExpiredTokens: true)
        }
    }

    private func _downloadOnce(sharedDatabase: Bool, scope: DownloadScope) async throws {
        logger.log("Starting Download of \(sharedDatabase ? "shared" : "private") database")
        
        // A catch-up downloads every record, rather than the changes since the last download, but only the keys it needs
        let fromScratch = scope.isCatchingUp
        let desiredKeys: [CKRecord.FieldKey]? = if case .catchingUp(let keys) = scope { cloudKeys(for: keys) } else { nil }
        
        var configurations: [CKRecordZone.ID : CKFetchRecordZoneChangesOperation.ZoneConfiguration] = [:]
        
        if sharedDatabase {
            configurations = try context.performAndWaitUnchecked {
                let zones = try CloudKitZone.getAll()
                return Dictionary(zones.map { savedZone in
                    (savedZone.calculatedId, CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                        previousServerChangeToken: fromScratch ? nil : savedZone.changeToken,
                        desiredKeys: desiredKeys
                    ))
                }, uniquingKeysWith: { $1 })
            }
            
            if configurations.isEmpty {
                logger.log("No zones in shared database")
                return
            }
        } else {
            let token = fromScratch ? nil : accessState(\.changeToken)
            let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: token, desiredKeys: desiredKeys)
            
            configurations = [defaultZoneID: options]
        }
        
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: Array(configurations.keys),
            configurationsByRecordZoneID: configurations
        )
        operation.fetchAllChanges = true
        
        let handler = CKDownloadHandler(synchronizer: self, forSharedDatabase: sharedDatabase, scope: scope)
        if sharedDatabase {
            // Records of zones that are no longer shared mustn't be stored
            handler.forgetHeldRecords(outside: Set(configurations.keys))
        }
        // Records that failed to download before are downloaded again, rather than holding back the change token. In batches,
        // as CloudKit rejects fetching more than 400 records at once. Ones that fail are tried again by the next download.
        let failedRecordIDs = handler.recordIDsToDownloadAgain
        let database = (sharedDatabase ? cloudSharedDatabase : cloudPrivateDatabase)!
        var batchSize = Self.downloadAgainBatchSize
        var start = 0
        while start < failedRecordIDs.count {
            let batch = Array(failedRecordIDs[start ..< min(start + batchSize, failedRecordIDs.count)])
            do {
                handler.addDownloadedAgain(try await database.records(for: batch, desiredKeys: nil))
                start += batch.count
            } catch let error as CKError where error.code == .limitExceeded && batchSize > 1 {
                batchSize /= 2
            } catch {
                logger.error("Failed to download \(failedRecordIDs.count - start) records again, trying later: \(error.localizedDescription)")
                try checkNotStopped()
                break
            }
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            handler.completionHandler = { [weak self] error in
                guard let self else { return }
                
                if let error = error {
                    continuation.resume(throwing: error)
                    logger.log("Download completion Error: \(error, privacy: .public)")
                    return
                }
                
                logger.log("Download completed")
                
                self.lastCompletedDownload = Date()
                // Also if records were held back, e.g. as their references are missing. They might never be resolved.
                if !sharedDatabase, case .all = scope {
                    self.markDownloadedOnce()
                }
                // Recovering ends once both databases were downloaded, see `download(refreshingSharedZones:)`
                if case .all = scope, handler.hasFailedRecords {
                    self.noteRecoveryMissedRecords()
                }
                
                continuation.resume()
            }
            handler.operation = operation
            
            operation.recordWasChangedBlock = handler.changed
            operation.recordWithIDWasDeletedBlock = handler.deleted
            operation.recordZoneChangeTokensUpdatedBlock = handler.tokensUpdate
            operation.recordZoneFetchResultBlock = handler.fetchCompletion
            operation.fetchRecordZoneChangesResultBlock = handler.fetchOverallCompletion
            
            if sharedDatabase {
                cloudSharedDatabase.add(operation)
            } else {
                cloudPrivateDatabase.add(operation)
            }
        }
    }
}

extension SDSSynchronizer {
    /// The synchronized keys of models and keys given as entity names and `Entity.key`, by entity. `nil` for every key of an entity.
    fileprivate func keysByEntity(_ keys: Set<String>) -> [String: [String]?] {
        guard let configuration else { return [:] }

        var keysByEntity: [String: [String]?] = [:]
        for key in keys {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard configuration.entities[parts[0]] != nil else { continue }

            if parts.count == 1 {
                keysByEntity[parts[0]] = .some(nil)
            } else if case .some(.some(let entityKeys)) = keysByEntity[parts[0]] {
                keysByEntity[parts[0]] = entityKeys + [parts[1]]
            } else if keysByEntity[parts[0]] == nil {
                keysByEntity[parts[0]] = [parts[1]]
            }
        }
        return keysByEntity
    }

    /// The record keys of models and keys given as entity names and `Entity.key`. Records store keys under their renaming identifier.
    fileprivate func cloudKeys(for keys: Set<String>) -> [CKRecord.FieldKey] {
        guard let model = observedStore?.managedObjectModel, let configuration else { return [] }
        
        let cloudKeys = keys.flatMap { key -> [CKRecord.FieldKey] in
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard let entity = model.entitiesByName[parts[0]] else { return [] }
            let propertyNames = parts.count == 2 ? [parts[1]] : configuration.entities[parts[0]]?.syncedProperties ?? []
            // Large values can be in the record's overflow asset, see `SDSOverflow`
            let overflows = configuration.entities[parts[0]].map { SDSOverflow.keys(of: $0, description: entity).contains(where: propertyNames.contains) } ?? false
            return propertyNames.map { entity.propertiesByName[$0]?.renamingIdentifier ?? $0 } + (overflows ? [SDSOverflow.key] : [])
        }
        return Array(Set(cloudKeys))
    }
}

/// Records by their IDs, in the order they were added, so every downloaded record can be looked for among the held ones
/// without going through all of them. A record that is added again replaces its earlier version.
private struct RecordList: Sequence {
    private var records: [CKRecord.ID: (order: Int, record: CKRecord)] = [:]
    private var nextOrder = 0

    init(_ records: [CKRecord] = []) {
        records.forEach { append($0) }
    }

    var count: Int { records.count }
    var isEmpty: Bool { records.isEmpty }
    var ids: Set<CKRecord.ID> { Set(records.keys) }

    mutating func append(_ record: CKRecord) {
        records[record.recordID] = (nextOrder, record)
        nextOrder += 1
    }

    mutating func remove(_ recordID: CKRecord.ID) {
        records[recordID] = nil
    }

    mutating func removeAll(where shouldBeRemoved: (CKRecord) -> Bool) {
        records = records.filter { !shouldBeRemoved($0.value.record) }
    }

    func makeIterator() -> IndexingIterator<[CKRecord]> {
        records.values.sorted { $0.order < $1.order }.map(\.record).makeIterator()
    }
}

/// Stores the records of a download.
///
/// What's downloaded is saved at every change token update, together with the token. A long first download thus doesn't
/// keep every record in memory, and continues where it was if the app is suspended or terminated meanwhile. Records that
/// can't be stored yet, e.g. as their references weren't downloaded yet, are held in files (see `SDSHeldRecords`), so they
/// don't keep the token from moving on. What wasn't saved yet is discarded if storing fails, so it's downloaded again.
///
/// The operation's callbacks run one after another, like the other accesses of the handler's state.
private final class CKDownloadHandler {
    
    /// Records that can't be stored yet, e.g. as their references weren't downloaded yet, which are tried again once the
    /// records they wait for arrived, and kept for later downloads otherwise.
    private var recordsToAddLater = RecordList()
    /// The name of the record each held record waits for, so it's only tried again once that arrived. Unknown for records
    /// held by an earlier download.
    private var heldBlockers: [CKRecord.ID: String] = [:]
    /// Names of the records stored since held records were tried last.
    private var storedSinceRetry: Set<String> = []
    /// Records that couldn't be stored as they are, e.g. as their overflow asset is corrupt, or their values are invalid.
    /// They're kept for later downloads, rather than discarding the download over and over.
    private var setAsideRecords = RecordList()
    /// The held records whose files exist, with the change tags of the versions in the files, see `SDSHeldRecords`.
    private var persistedHeld: [CKRecord.ID: String] = [:]
    private var persistedHeldIDs: Set<CKRecord.ID> { Set(persistedHeld.keys) }

    /// How often a page's save is fixed before the download is discarded, see `save()`.
    private static let maximumSaveFixes = 100
    
    /// What tells versions of a record apart.
    private static func version(of record: CKRecord) -> String {
        record.recordChangeTag ?? record.modificationDate.map { "\($0.timeIntervalSince1970)" } ?? UUID().uuidString
    }
    /// Downloaded deletions of objects whose entities have uniqueness constraints, which are applied at the end of their
    /// zone's download. Another record of the same unique values can still give the object a record there, e.g. when the
    /// device that merged two duplicate records deleted the one this device's object has. Kept in a file once a page is
    /// saved, like held records. See `SDSUniqueMatch`.
    private var deferredDeletions: Set<CKRecord.ID> = []
    private var persistedDeferredDeletions: Set<CKRecord.ID> = []
    /// Whether the zone's download ended, so records of the same unique values as local objects with records of their own
    /// are decided on, and deferred deletions applied, see `SDSUniqueMatch`.
    private var isAtEndOfZone = false
    /// Records `uniqueMatch(for:...)` held, see `SDSUniqueMatch.keepsItsRecord`.
    private var heldForUniqueValues: Set<CKRecord.ID> = []
    /// Held records that reference each other, which are stored without those references first, see
    /// `storeRecordsThatReferenceEachOther(in:)`.
    private var referencesSetLater: Set<CKRecord.ID> = []
    /// A reference of a record to records of `referencesSetLater`, set once they're stored.
    private struct LaterReference {
        let recordID: CKRecord.ID
        let rawKey: String
        let targets: [CKRecord.ID]
        let isList: Bool
    }
    private var laterReferences: [LaterReference] = []
    /// Records and deletions an extension that synchronizes less skipped, as their models or keys are only synchronized by
    /// the app, see `SDSSynchronizer.keysOnlyOthersSynchronize`. The change token moves past them, so the app downloads them
    /// again by their IDs, and deletes the objects of the ones that are gone. Kept in a file once a page is saved.
    private var skippedRecordIDs: Set<CKRecord.ID> = []
    private var persistedSkippedRecordIDs: Set<CKRecord.ID> = []
    /// The models and keys this process skips, see `skippedRecordIDs`.
    private let skippedKeys: Set<String>
    /// Whether this process downloads the records others skipped again, see `skippedRecordIDs`.
    private let downloadsSkippedRecords: Bool
    /// Records that failed to download, which later downloads download again.
    private var failedRecordIDs: Set<CKRecord.ID> = []
    private var persistedFailedRecordIDs: Set<CKRecord.ID> = []
    /// Keeps the held records of the database, `nil` for a catch-up, whose records only have some keys.
    private let heldRecords: SDSHeldRecords?
    /// The records stored since the last save, by name, to set aside one that turns out to be invalid when saving.
    private var pageRecords: [String: CKRecord] = [:]
    
    /// An object whose parent is set once every record of the download is stored, as the parent might be downloaded later.
    /// This also restores the parent of an object that a parent's ordered relationship lost when two devices added an
    /// object at the same time.
    private struct ParentReference {
        /// The object until it's saved, its ID afterwards, so saved objects aren't kept in memory.
        var object: NSManagedObject?
        var objectID: NSManagedObjectID?
        let parentKey: String
        let record: CKRecord
        var parentRecordID: CKRecord.ID { record.parent!.recordID }
        /// Whether the parent was found already.
        var isResolved = false
    }
    private var parentReferences: [ParentReference] = []
    
    weak var synchronizer: SDSSynchronizer!
    weak var context: NSManagedObjectContext!
    /// The download's operation, which is cancelled once the download can't go on.
    weak var operation: CKOperation?
    private var tokensToUpdate: [CKRecordZone.ID?: CKServerChangeToken] = [:]
    /// Records this download deletes. Their metadata is only removed once the download is saved, as discarding it restores their objects.
    private var deletedRecordIds: Set<String> = []
    /// Keeps a record from being stored incompletely, e.g. as the store can't be read. The download is discarded, so the
    /// record is downloaded again.
    private var applyError: (any Error)?
    /// Ends the download, e.g. after storing a page failed, or synchronizing was stopped. What wasn't saved was discarded,
    /// and later changes of the operation are ignored.
    private var failure: (any Error)?
    let isForSharedDatabase: Bool
    /// The models and keys that are stored.
    let scope: DownloadScope
    /// Whether the change tokens are saved, which a catch-up doesn't do, as it doesn't include deletions.
    var savesChangeTokens: Bool { !scope.isCatchingUp }
    /// Zones whose change tokens expired. Their tokens are reset once the download is saved, see `SDSSynchronizer.ChangeTokenExpiredError`.
    private var zonesWithExpiredTokens: Set<CKRecordZone.ID> = []
    /// The error if the zone of the private database is gone, see `SDSSynchronizer.PrivateZoneMissingError`.
    private var privateZoneError: CKError?
    /// The errors of zones that failed, which CloudKit only reports for each zone: the operation's result is a success
    /// although some zones failed.
    private var zoneErrors: [CKRecordZone.ID: any Error] = [:]
    /// The local entities of the downloaded objects, which are removed if the download is discarded.
    private var createdLocalEntities: [CloudKitLocalEntity] = []
    /// Whether objects changed locally while downloading, whose downloaded values were discarded, see `save()`.
    private var hadLocalChanges = false
    /// Records with pending updates that turned out to exist, see `CloudKitUpdate.recordExists()`.
    private var existingRecords: Set<String> = []
    /// The keys in the overflow asset of records, by name, see `SDSOverflow`.
    private var overflowChanges: [String: Set<String>] = [:]
    /// Saved local objects by their identity, for records that aren't known yet.
    private let identityIndex: SDSIdentityIndex
    /// Local objects without records by their values, while vanished objects are recovered, see `SDSContentIndex`.
    private var contentIndex: SDSContentIndex?
    /// The records with pending updates or removals when the download started, so records without any don't need a fetch.
    /// Changes saved while downloading are noticed when saving, see `save()`, and removals are read again once they change.
    private let pendingUpdateIds: Set<String>
    private var pendingRemovalIds: Set<String>
    private var removalCount: Int
    var completionHandler: (Error?) -> Void = { _ in }
    
    init(synchronizer: SDSSynchronizer, forSharedDatabase: Bool, scope: DownloadScope) {
        self.synchronizer = synchronizer
        self.context = synchronizer.observedUpdateContext
        self.identityIndex = SDSIdentityIndex(context: synchronizer.observedUpdateContext!)
        
        self.isForSharedDatabase = forSharedDatabase
        self.scope = scope
        self.skippedKeys = synchronizer.keysOnlyOthersSynchronize
        self.downloadsSkippedRecords = !synchronizer.isAppExtension
        
        self.removalCount = synchronizer.removalCount
        self.pendingUpdateIds = Self.ids(of: "CloudKitUpdate", in: synchronizer.context)
        self.pendingRemovalIds = Self.ids(of: "CloudKitRemoval", in: synchronizer.context)
        
        if case .all = scope {
            let heldRecords = synchronizer.heldRecords(sharedDatabase: forSharedDatabase)
            self.heldRecords = heldRecords
            // Tried again at the first page or at the end
            recordsToAddLater = RecordList(heldRecords.load())
            persistedHeld = Dictionary(recordsToAddLater.map { ($0.recordID, Self.version(of: $0)) }, uniquingKeysWith: { $1 })
            failedRecordIDs = heldRecords.loadFailedIDs()
            persistedFailedRecordIDs = failedRecordIDs
            deferredDeletions = heldRecords.loadDeferredDeletions()
            persistedDeferredDeletions = deferredDeletions
            skippedRecordIDs = heldRecords.loadSkippedIDs()
            persistedSkippedRecordIDs = skippedRecordIDs
            // Also the shared database's, whose local objects are copies of records in other users' zones. It's downloaded
            // after the private one, so the objects that got their records there aren't matched again.
            if synchronizer.isRecoveringVanishedObjects {
                contentIndex = SDSContentIndex(
                    synchronizer: synchronizer,
                    context: synchronizer.observedUpdateContext!,
                    trackedLocalIds: Self.localIdsOfConfirmedRecords(in: synchronizer.context),
                    onlyCopiesOfShares: forSharedDatabase
                )
            }
        } else {
            heldRecords = nil
        }
    }
    
    /// Forgets the held records of zones that are no longer shared with the user.
    func forgetHeldRecords(outside zoneIDs: Set<CKRecordZone.ID>) {
        recordsToAddLater.removeAll { !zoneIDs.contains($0.recordID.zoneID) }
        failedRecordIDs = failedRecordIDs.filter { zoneIDs.contains($0.zoneID) }
        deferredDeletions = deferredDeletions.filter { zoneIDs.contains($0.zoneID) }
        skippedRecordIDs = skippedRecordIDs.filter { zoneIDs.contains($0.zoneID) }
    }
    
    /// The records that failed to download before, which are downloaded again before the zone's changes.
    /// Whether records of this download failed, which the next one downloads again, see `recordIDsToDownloadAgain`.
    var hasFailedRecords: Bool {
        !failedRecordIDs.isEmpty
    }

    var recordIDsToDownloadAgain: [CKRecord.ID] {
        Array(downloadsSkippedRecords ? failedRecordIDs.union(skippedRecordIDs) : failedRecordIDs)
    }
    
    /// Adds records that were downloaded again, see `recordIDsToDownloadAgain`. Records that are gone aren't downloaded again.
    /// Objects of skipped records that are gone are deleted, as their deletions were skipped too.
    func addDownloadedAgain(_ results: [CKRecord.ID: Result<CKRecord, any Error>]) {
        for (recordID, result) in results {
            switch result {
            case .success(let record):
                failedRecordIDs.remove(recordID)
                skippedRecordIDs.remove(recordID)
                recordsToAddLater.append(record)
            case .failure(let error as CKError) where error.code == .unknownItem:
                failedRecordIDs.remove(recordID)
                if skippedRecordIDs.remove(recordID) != nil {
                    context.performAndWaitUnchecked {
                        _deleted(recordID: recordID, recordType: "")
                    }
                }
            case .failure:
                break
            }
        }
    }
    
    /// The URIs of the objects whose records are known to exist. Objects whose records were only named here, and that were
    /// saved before, as some values are of unknown age, e.g. ones changed while every record is downloaded again, can still
    /// be copies of the records' objects, see `SDSContentIndex`. Objects created since can't.
    private static func localIdsOfConfirmedRecords(in context: NSManagedObjectContext) -> Set<String> {
        context.performAndWait {
            // Saved first, as dictionaries are only read from the store
            try? context.save()
            let inserts = NSFetchRequest<NSDictionary>(entityName: "CloudKitUpdate")
            inserts.resultType = .dictionaryResultType
            inserts.propertiesToFetch = ["id"]
            inserts.predicate = NSPredicate(format: "rawChangedKeys BEGINSWITH %@ AND rawChangedKeys CONTAINS %@", CloudKitUpdate.insertMarker, CloudKitUpdate.backfillMarker)
            let unconfirmed = Set(((try? context.fetch(inserts)) ?? []).compactMap { $0["id"] as? String })
            let entities = NSFetchRequest<NSDictionary>(entityName: "CloudKitLocalEntity")
            entities.resultType = .dictionaryResultType
            entities.propertiesToFetch = ["id", "localId"]
            return Set(((try? context.fetch(entities)) ?? []).compactMap { row in
                guard let id = row["id"] as? String, !unconfirmed.contains(id) else { return nil }
                return row["localId"] as? String
            })
        }
    }

    private static func ids(of entityName: String, key: String = "id", in context: NSManagedObjectContext) -> Set<String> {
        context.performAndWait {
            // Saved first, as dictionaries are only read from the store
            try? context.save()
            let request = NSFetchRequest<NSDictionary>(entityName: entityName)
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = [key]
            return Set(((try? context.fetch(request)) ?? []).compactMap { $0[key] as? String })
        }
    }
    
    /// The record's changes that weren't uploaded yet, see `SDSSynchronizer.pendingLocalChange(of:)`.
    private func pendingLocalChange(of id: String) -> SDSSynchronizer.PendingLocalChange {
        // E.g. a record that this download replaced with another one of the same identity
        if synchronizer.removalCount != removalCount {
            removalCount = synchronizer.removalCount
            pendingRemovalIds = Self.ids(of: "CloudKitRemoval", in: synchronizer.context)
        }
        guard pendingUpdateIds.contains(id) || pendingRemovalIds.contains(id) || synchronizer.hasPendingDeletions else { return .init() }
        return synchronizer.pendingLocalChange(of: id)
    }
    
    func changed(recordId: CKRecord.ID, result: Result<CKRecord, any Error>) {
        guard failure == nil else { return }
        guard case .success(let record) = result else {
            // E.g. an asset of the record couldn't be downloaded. It's downloaded again by the next download, rather than
            // holding back the change token, which would skip the record until it changes again.
            synchronizer.logger.error("Failed to download `\(recordId.recordName)`, downloading it again later: \(String(describing: result))")
            if heldRecords != nil {
                failedRecordIDs.insert(recordId)
            } else {
                synchronizer.skippedWhileCatchingUp(recordId.recordName)
            }
            return
        }

        synchronizer.logger.log("[Download] Changed: \(record)")
        context.performAndWaitUnchecked {
            // A newer version replaces the one that was held
            recordsToAddLater.remove(record.recordID)
            setAsideRecords.remove(record.recordID)
            failedRecordIDs.remove(record.recordID)
            // E.g. a record of an identity that was created again
            deferredDeletions.remove(record.recordID)
            self._changed(record: record)
        }
        failIfNotApplied()
    }
    
    /// Ends the download right away once a record couldn't be stored, e.g. as the store can't be read, rather than keeping
    /// every later record in memory only to discard it.
    private func failIfNotApplied() {
        if let applyError {
            fail(with: applyError)
        }
    }

    private func _changed(record: CKRecord) {
        // Catch CKShare
        if let share = record as? CKShare {
            // A catch-up only downloads some keys, so it would store the share without its title and thumbnail.
            // Shares are stored by the other downloads.
            guard !scope.isCatchingUp else { return }
            
            let context = synchronizer.context
            context.perform {
                CloudKitShare.updateShare(
                    share,
                    for: share.recordID.recordName.replacingOccurrences(of: staticShareExtension, with: ""),
                    context: context
                )
            }
            return
        }

        // A newer version of the app can add models, which can't be stored by this one
        guard let entity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[record.recordType] else {
            synchronizer.logger.error("Skipping record of unknown type `\(record.recordType, privacy: .public)`")
            return
        }
        guard scope.includes(entity: record.recordType) else { return }
        // Models this process doesn't synchronize, e.g. in an extension that synchronizes less, are left alone. Their objects
        // couldn't be found by their records, so every change would insert another object without values.
        guard let entityConfiguration = synchronizer.configuration?.entities[record.recordType] else {
            synchronizer.logger.log("Skipping record of `\(record.recordType, privacy: .public)`, which isn't synchronized")
            if heldRecords != nil && skippedKeys.contains(record.recordType) {
                skippedRecordIDs.insert(record.recordID)
            }
            return
        }
        let recordName = record.recordID.recordName

        // Large values can be in an asset, see `SDSOverflow`. They're values like the record's own. Assets are read before
        // anything is stored, so a record whose asset can't be read is set aside rather than stored partially.
        let overflowValues: [String: Any]
        var assetData: [String: Data] = [:]
        do {
            overflowValues = try SDSOverflow.values(in: record) ?? [:]
            for key in record.allKeys() where key != SDSOverflow.key {
                guard let asset = record[key] as? CKAsset else { continue }
                // An asset without a file is read like one whose file is gone, rather than clearing the value
                guard let fileURL = asset.fileURL else { throw CocoaError(.fileNoSuchFile) }
                assetData[key] = try Data(contentsOf: fileURL)
            }
        } catch let error as CocoaError where error.isFileError {
            // E.g. the file was removed meanwhile. The record is downloaded again by the next download.
            synchronizer.logger.error("Failed reading an asset of `\(recordName)`, downloading it again later: \(error.localizedDescription)")
            if heldRecords != nil {
                failedRecordIDs.insert(record.recordID)
            } else {
                synchronizer.skippedWhileCatchingUp(recordName)
            }
            return
        } catch {
            synchronizer.logger.error("Failed reading an asset of `\(recordName)`, setting it aside: \(error.localizedDescription)")
            setAside(record)
            return
        }

        // Keys only other processes synchronize are downloaded again by the app, see `skippedRecordIDs`
        if heldRecords != nil, !skippedKeys.isEmpty {
            let keys = Set(record.allKeys()).union(overflowValues.keys).map { findCorrespondingKey(entity: entity, rawKey: $0) }
            if keys.contains(where: { skippedKeys.contains("\(record.recordType).\($0)") }) {
                skippedRecordIDs.insert(record.recordID)
            }
        }

        // Make sure dependent objects exist, and prefill all values if they do
        guard var kVPs = self.valuesIfAllReferencesExist(for: record, entity: entity, syncedKeys: entityConfiguration.syncedProperties) else {
            self.recordsToAddLater.append(record)
            return
        }
        // Values of the record win over the asset's, e.g. ones a version without overflow assets saved
        for (rawKey, value) in overflowValues where record[rawKey] == nil && isStored(rawKey, entity: entity, syncedKeys: entityConfiguration.syncedProperties) {
            kVPs[rawKey] = value
        }

        // Local changes that weren't uploaded yet win, as they are uploaded over the record next. E.g. a change saved after
        // the last upload would otherwise be overwritten with the downloaded value.
        // A catch-up also downloads every record rather than the ones that changed since, with values older than local changes.
        // Backfilled values are of unknown age, so they're dropped once the record exists, see `CloudKitUpdate.backfilledKeys`.
        let pendingChange = pendingLocalChange(of: recordName)
        guard !pendingChange.isRemoved else {
            // The object was deleted locally, which is uploaded next
            synchronizer.logger.log("Skipping record `\(recordName)`, which was deleted locally")
            return
        }
        if !pendingChange.keys.isEmpty {
            kVPs = kVPs.filter { rawKey, _ in !pendingChange.keys.contains(findCorrespondingKey(entity: entity, rawKey: rawKey)) }
        }
        if case .all = scope {
            kVPs.merge(clearedValues(of: record, entity: entity, syncedKeys: entityConfiguration.syncedProperties, pendingKeys: pendingChange.keys, presentKeys: Set(overflowValues.keys))) { current, _ in current }
            overflowChanges[recordName] = Set(overflowValues.keys)
            if !pendingChange.backfilledKeys.isEmpty || pendingChange.isLocalInsert {
                existingRecords.insert(recordName)
            }
        }

        let insertsObject = scope.insertsObjects(of: record.recordType)
        if scope.isCatchingUp {
            let caughtUpKeys = Set(record.allKeys().map { findCorrespondingKey(entity: entity, rawKey: $0) } + overflowValues.keys.map { findCorrespondingKey(entity: entity, rawKey: $0) })
                .filter { scope.includes(entity: record.recordType, key: $0) }
            synchronizer.noteCaughtUpKeys(caughtUpKeys, of: recordName)
            guard !kVPs.isEmpty || insertsObject else { return }
        }

        guard let container = retrieveObject(for: record, entity: entity, configuration: entityConfiguration, overflowValues: overflowValues, insertingIfMissing: insertsObject, preliminaryUpdateHandler: { container, movedPendingKeys in
            guard let container else { return }

            let object = container.object
            // Local changes of an object that got this record, see `SDSSynchronizer.retrieve`
            let kVPs = movedPendingKeys.isEmpty ? kVPs : kVPs.filter { rawKey, _ in !movedPendingKeys.contains(findCorrespondingKey(entity: entity, rawKey: rawKey)) }
            for (rawKey, value) in kVPs {
                guard rawKey != SDSSynchronizer.Constants.parentWorkaroundKey else { continue }

                let key = findCorrespondingKey(entity: object.entity, rawKey: rawKey)
                // This is needed to exclude keys that are excluded but were synced before. Otherwise they will be synced again.
                guard container.syncKeys.contains(key) else { continue }

                let attribute = object.entity.attributesByName[key]
                let type = attribute?.type
                if let value = value as? SDSSynchronizableContainer {
                    object.setValue(value.object, forKey: key)
                } else if value is CKAsset {
                    set(assetData[rawKey], forKey: key, of: object)
                } else if let attribute, value is Data || value is String {
                    // E.g. transformed values, `Codable` values, URLs and UUIDs, see `SDSValueCoding`
                    do {
                        set(try SDSValueCoding.localValue(for: value, attribute: attribute), forKey: key, of: object)
                    } catch {
                        synchronizer.logger.error("Failed setting the value of `\(object.entity.name ?? "")`.`\(key)`: \(String(describing: error))")
                        // The local value stays, which mustn't be uploaded over the record's. It can't be read by a retry either.
                        if scope.isCatchingUp {
                            synchronizer.skippedWhileCatchingUp(recordName, isTriedAgain: false)
                        }
                    }
                } else if attribute == nil {
                    // Relationships
                    object.setValue(value, forKey: key)
                } else {
                    // Also apply some sanity checks
                    if let attribute, type == .boolean {
                        let possibleValues: [Int?] = attribute.isOptional ? [nil, 0, 1] : [0, 1]
                        if !possibleValues.contains(value as? Int) {
                            set(attribute.defaultValue, forKey: key, of: object)
                            continue
                        }
                    }
                    
                    set(value, forKey: key, of: object)
                }
            }

            synchronizer.logger.log("Object updated: \(object)")
        }) else {
            if heldForUniqueValues.remove(record.recordID) != nil {
                recordsToAddLater.append(record)
            }
            return
        }
        
        pageRecords[recordName] = record
        storedSinceRetry.insert(recordName)

        if
            record.parent != nil,
            let parentKey = container.parentKey,
            scope.includes(entity: record.recordType, key: parentKey),
            !pendingChange.keys.contains(parentKey)
        {
            // The parent is set once every record of the download is stored, as it might be downloaded after this record
            parentReferences.append(ParentReference(object: container.object, parentKey: parentKey, record: record))
        }
    }
    
    /// Keeps a record that can't be stored as it is for later downloads, see `setAsideRecords`.
    private func setAside(_ record: CKRecord) {
        guard heldRecords != nil else {
            // E.g. it lacks a required value, which trying again doesn't change. Once it changes, a download stores it.
            synchronizer.skippedWhileCatchingUp(record.recordID.recordName, isTriedAgain: false)
            return
        }
        setAsideRecords.append(record)
    }
    
    /// Sets an attribute's value unless it has it already, so records that didn't change, e.g. when every record is
    /// downloaded again, don't change the objects for the app's contexts.
    private func set(_ value: Any?, forKey key: String, of object: NSManagedObject) {
        let current = object.value(forKey: key)
        switch (current, value) {
        case (nil, nil):
            return
        case (let current as NSObject, let value as NSObject) where current.isEqual(value):
            return
        default:
            object.setValue(value, forKey: key)
        }
    }

    /// See `SDSValueCoding.clearedValues(of:entity:syncedKeys:excludedKeys:catchUpKeys:presentKeys:)`.
    private func clearedValues(of record: CKRecord, entity: NSEntityDescription, syncedKeys: [String], pendingKeys: Set<String>, presentKeys: Set<String>) -> [String: Any?] {
        SDSValueCoding.clearedValues(
            of: record,
            entity: entity,
            syncedKeys: syncedKeys,
            excludedKeys: pendingKeys,
            catchUpKeys: synchronizer.pendingCatchUp?.newKeys ?? [],
            presentKeys: presentKeys
        )
    }

    private func findCorrespondingKey(entity: NSEntityDescription, rawKey: String) -> String {
        if let name = propertyName(entity: entity, rawKey: rawKey) {
            return name
        }
        assertionFailure()
        return rawKey
    }
    
    /// The name of the property a record stores under `rawKey`, its renaming identifier, if the entity has one.
    private func propertyName(entity: NSEntityDescription, rawKey: String) -> String? {
        if entity.propertiesByName[rawKey] != nil {
            return rawKey
        }
        return entity.properties.first { $0.renamingIdentifier == rawKey }?.name
    }
    
    /// Whether a record key is stored: keys added by a newer version of the app aren't stored by this one, and neither are
    /// keys this process doesn't synchronize, e.g. a relationship to a model that an extension doesn't synchronize, whose
    /// objects it would never find. Keys outside of the download's scope are stored by another download.
    private func isStored(_ rawKey: String, entity: NSEntityDescription, syncedKeys: [String]) -> Bool {
        guard rawKey != SDSSynchronizer.Constants.parentWorkaroundKey, let key = propertyName(entity: entity, rawKey: rawKey) else { return false }
        return syncedKeys.contains(key) && scope.includes(entity: entity.name ?? "", key: key)
    }

    private func valuesIfAllReferencesExist(for record: CKRecord, entity: NSEntityDescription, syncedKeys: [String]) -> [String: Any?]? {
        var values = [String: Any?]()

        // References of keys that aren't stored might never be found, which would keep the record from being stored
        for key in record.allKeys() where isStored(key, entity: entity, syncedKeys: syncedKeys) {
            let value = record[key]
            
            if let reference = value as? CKRecord.Reference {
                if let object = findObject(for: reference.recordID) {
                    values[key] = object
                } else if referencesSetLater.contains(reference.recordID) {
                    laterReferences.append(LaterReference(recordID: record.recordID, rawKey: key, targets: [reference.recordID], isList: false))
                } else {
                    synchronizer.logger.log("noObject1: \(reference.recordID) for \(key)")
                    heldBlockers[record.recordID] = reference.recordID.recordName
                    return nil
                }
            } else if let references = value as? [CKRecord.Reference] {
                if references.contains(where: { referencesSetLater.contains($0.recordID) && findObject(for: $0.recordID) == nil }) {
                    laterReferences.append(LaterReference(recordID: record.recordID, rawKey: key, targets: references.map(\.recordID), isList: true))
                    continue
                }
                var objects = [SDSSynchronizableContainer]()
                for reference in references {
                    if let container = findObject(for: reference.recordID) {
                        objects.append(container)
                    } else {
                        synchronizer.logger.log("noObject2: \(reference.recordID)")
                        heldBlockers[record.recordID] = reference.recordID.recordName
                        return nil
                    }
                }
                values[key] = NSOrderedSet(array: objects.map(\.object))
            } else {
                values[key] = value
            }
        }
        
        return values
    }
    
    /// A failed read isn't taken for a missing object, which could duplicate it or get records deleted.
    /// The download is discarded instead, so the records are downloaded again.
    private func findObject(for recordID: CKRecord.ID) -> SDSSynchronizableContainer? {
        do {
            return try synchronizer.lookUp(for: recordID.recordName)
        } catch {
            synchronizer.logger.error("Failed to look up `\(recordID.recordName)`: \(error.localizedDescription)")
            applyError = error
            return nil
        }
    }
    
    private func retrieveObject(
        for record: CKRecord,
        entity: NSEntityDescription,
        configuration: SDSInternalConfiguration.Entity,
        overflowValues: [String: Any],
        insertingIfMissing: Bool,
        preliminaryUpdateHandler: (SDSSynchronizableContainer?, _ movedPendingKeys: Set<String>) -> Void
    ) -> SDSSynchronizableContainer? {
        guard insertingIfMissing else {
            // An object with only some of its keys would be incomplete
            let container = findObject(for: record.recordID)
            preliminaryUpdateHandler(container, [])
            return container
        }
        
        // A record of an entity with an identity can belong to a local object that has no record yet. After objects
        // vanished, one without an identity can belong to a copy of its object without a record, see `SDSContentIndex`.
        let entityName = record.recordType
        let identity = configuration.identity
        var identityRecordName: String?
        var matchingObject: (() throws -> NSManagedObject?)?
        if !identity.isEmpty, let name = SDSIdentity.identityRecordName(entityName: entityName, values: SDSIdentity.values(in: record, entity: entity, keys: identity)) {
            identityRecordName = name
            matchingObject = { [identityIndex] in
                try identityIndex.object(entityName: entityName, keys: identity, recordName: name)
            }
        } else if let contentIndex {
            // Not the keys a pending catch-up adds, which the records of older versions lack, while the local values don't
            let newKeys = synchronizer.pendingCatchUp?.newKeys ?? []
            let keys = configuration.syncedProperties.filter { !newKeys.contains("\(entityName).\($0)") }
            matchingObject = {
                contentIndex.object(matching: record, overflowValues: overflowValues, entity: entity, keys: keys)
            }
        }
        
        do {
            let container = try synchronizer.retrieve(
                for: record.recordID.recordName,
                entityName: entityName,
                identityRecordName: identityRecordName,
                matchingObject: matchingObject,
                uniqueMatch: entity.uniquenessConstraints.isEmpty ? nil : { [unowned self] in
                    var match = try self.uniqueMatch(for: record, entity: entity, overflowValues: overflowValues, identityRecordName: identityRecordName)
                    // A record of another user's share never takes the place of the user's own object. Inserting it would make
                    // Core Data fold it into that object, with the share's values, so it's held instead, until the values differ.
                    if isForSharedDatabase, match != nil {
                        synchronizer.logger.error("Holding `\(record.recordID.recordName)` of a share, as a local model has the same unique values")
                        match = .keepsItsRecord
                    }
                    if case .keepsItsRecord = match {
                        heldForUniqueValues.insert(record.recordID)
                    }
                    return match
                },
                context: context,
                preliminaryUpdateHandler: preliminaryUpdateHandler
            )
            // Objects this download inserts can be matched once they're saved, e.g. by a record of the same identity in a later page
            if let container, let identityRecordName, container.object.isInserted {
                identityIndex.add(container.object, entityName: entityName, recordName: identityRecordName)
            }
            return container
        } catch {
            synchronizer.logger.error("Failed to look up `\(record.recordID.recordName)`: \(error.localizedDescription)")
            applyError = error
            return nil
        }
    }
    
    /// A local object the record would duplicate under a uniqueness constraint of its entity, e.g. as two devices created the
    /// same thing before they had identities, which gave them records of their own. See `SDSUniqueMatch`.
    ///
    /// An object without a record gets the downloaded one. One with a record of its own is only decided on at the end of the
    /// zone's download, as its record can still change in it, e.g. to other unique values when the unique value was renamed
    /// and used again. Of two records, the one named after its identity, if only one of them is, or else the one whose name
    /// comes first, is kept, the same on every device. Only constraints of attributes that records store are looked at.
    /// Has to be called on `context`'s queue.
    private func uniqueMatch(for record: CKRecord, entity: NSEntityDescription, overflowValues: [String: Any], identityRecordName: String?) throws -> SDSUniqueMatch? {
        guard let entityName = entity.name else { return nil }
        let syncedKeys = synchronizer.configuration?.entities[entityName]?.syncedProperties ?? []
        for constraint in entity.uniquenessConstraints {
            let keys = constraint.compactMap { ($0 as? String) ?? ($0 as? NSPropertyDescription)?.name }
            var predicates: [NSPredicate] = []
            for key in keys {
                // Records don't store unsynchronized values, and missing values don't conflict
                guard
                    let attribute = entity.attributesByName[key],
                    syncedKeys.contains(key),
                    let rawValue = record[attribute.renamingIdentifier ?? key] ?? overflowValues[attribute.renamingIdentifier ?? key]
                else { break }
                // E.g. URLs and UUIDs are stored as strings, see `SDSValueCoding`
                let value = (rawValue is String || rawValue is Data) ? (try? SDSValueCoding.localValue(for: rawValue, attribute: attribute)) ?? rawValue : rawValue
                predicates.append(NSPredicate(format: "%K == %@", argumentArray: [key, value]))
            }
            guard !predicates.isEmpty, predicates.count == keys.count else { continue }

            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            // Also objects this download inserted, which aren't saved yet
            guard let object = try context.fetch(request).first(where: { !$0.isDeleted }) else { continue }

            let recordName = record.recordID.recordName
            guard let ownName = synchronizer.existingRecordId(of: object) else {
                return .saved(object, replacingOwnRecord: false)
            }
            guard ownName != recordName else { return nil }
            guard isAtEndOfZone else { return .keepsItsRecord }
            // Each by its own values: two records can each be named after an identity, e.g. one whose keys differ from the
            // constraint's
            let isNamedAfterIdentity = identityRecordName == recordName
            let ownIsNamedAfterIdentity = synchronizer.identityRecordName(for: object) == ownName
            let isKept = isNamedAfterIdentity != ownIsNamedAfterIdentity ? isNamedAfterIdentity : recordName < ownName
            if !isKept {
                return .keepsItsRecord
            }
            return object.isInserted ? .inserted(object) : .saved(object, replacingOwnRecord: true)
        }
        return nil
    }

    func deleted(recordID: CKRecord.ID, recordType: String) {
        guard failure == nil else { return }
        context.performAndWaitUnchecked {
            self._deleted(recordID: recordID, recordType: recordType)
        }
        failIfNotApplied()
    }
    
    func _deleted(recordID: CKRecord.ID, recordType:String) {
        if recordType == CKRecord.SystemType.share {
            // A share of the current user was stopped, e.g. on another device. Shares of other users are checked before uploading.
            if !isForSharedDatabase, recordID.recordName.hasSuffix(staticShareExtension) {
                let rootId = String(recordID.recordName.dropLast(staticShareExtension.count))
                let syncContext = synchronizer.context
                syncContext.performAndWait {
                    CloudKitShare.updateShare(nil, for: rootId, context: syncContext)
                }
            }
            return
        }
        
        // Models only other processes synchronize, whose objects this one can't find, are deleted by the app, which needs
        // their metadata to find them
        if heldRecords != nil, skippedKeys.contains(recordType) {
            skippedRecordIDs.insert(recordID)
            return
        }

        // Earlier versions that were held are gone too
        recordsToAddLater.remove(recordID)
        setAsideRecords.remove(recordID)
        failedRecordIDs.remove(recordID)
        overflowChanges[recordID.recordName] = []
        applyDeletion(of: recordID)
    }

    /// Deletes the object of a record that was deleted elsewhere, unless it was created here again. Objects whose entities
    /// have uniqueness constraints are deleted at the end of the zone's download, see `deferredDeletions`.
    private func applyDeletion(of recordID: CKRecord.ID) {
        if !isAtEndOfZone, heldRecords != nil, let object = findObject(for: recordID), !object.object.entity.uniquenessConstraints.isEmpty {
            deferredDeletions.insert(recordID)
            return
        }
        
        // A model that was created here with the record's name, e.g. when the user subscribes again after unsubscribing,
        // stays: its record is uploaded again next. Edits of a record that was deleted elsewhere don't keep it. Read for
        // each deletion, as the model can be created while downloading, after the download looked at what's pending.
        if synchronizer.pendingLocalChange(of: recordID.recordName).isLocalInsert {
            synchronizer.logger.log("Keeping `\(recordID.recordName)`, which was created here again after it was deleted")
            return
        }
        
        // Pending changes of a record that was deleted elsewhere can never be uploaded. Without its object,
        // an update couldn't be built, and a removal would delete a record that is gone.
        // They are removed with the object's metadata once the download is saved.
        deletedRecordIds.insert(recordID.recordName)
        
        if let object = findObject(for: recordID) {
            context.delete(object.object)
        }
    }
    
    func tokensUpdate(
        for zoneID: CKRecordZone.ID,
        changeToken: CKServerChangeToken?,
        userToken: Data?
    ) {
        guard failure == nil else { return }
        context.performAndWaitUnchecked {
            self._tokensUpdate(for: zoneID, changeToken: changeToken, userToken: userToken)
        }
        failIfNotApplied()
        guard failure == nil else { return }
        
        // A page ends here. What was downloaded is saved with the token.
        guard canSavePage() else { return }
        if let error = save() {
            fail(with: error)
            return
        }
        do {
            // The pages so far are kept
            try synchronizer.checkNotStopped()
        } catch {
            fail(with: error)
        }
    }
    
    /// Whether the downloaded records can be saved: objects whose parents weren't downloaded yet are held, like records whose
    /// references weren't, so they don't keep the token from moving on.
    private func canSavePage() -> Bool {
        guard applyError == nil else { return false }
        for index in parentReferences.indices where !parentReferences[index].isResolved {
            if findObject(for: parentReferences[index].parentRecordID) != nil {
                parentReferences[index].isResolved = true
            } else if heldRecords != nil {
                let record = parentReferences[index].record
                recordsToAddLater.append(record)
                heldBlockers[record.recordID] = parentReferences[index].parentRecordID.recordName
            }
        }
        if heldRecords != nil {
            parentReferences.removeAll { !$0.isResolved }
        }
        return applyError == nil && parentReferences.allSatisfy(\.isResolved)
    }
    
    /// Ends the download: what wasn't saved is discarded, and the operation is cancelled.
    private func fail(with error: any Error) {
        synchronizer.logger.log("Ending the download: \(error.localizedDescription)")
        failure = error
        if let observedContext = synchronizer.observedUpdateContext {
            discardDownload(observedContext: observedContext)
        }
        operation?.cancel()
    }
    
    /// Tries held records again: at the end of a zone all of them, and otherwise the ones whose references arrived since.
    private func retryHeldRecords(all: Bool) {
        var tryingAll = all
        while true {
            let candidates = recordsToAddLater.filter { record in
                guard !tryingAll, let blocker = heldBlockers[record.recordID] else { return true }
                return storedSinceRetry.contains(blocker)
            }
            storedSinceRetry = []
            guard !candidates.isEmpty else { return }
            let candidateIDs = Set(candidates.map(\.recordID))
            candidateIDs.forEach { recordsToAddLater.remove($0) }
            let heldBefore = recordsToAddLater.count + candidates.count
            for record in candidates {
                heldBlockers[record.recordID] = nil
                _changed(record: record)
            }
            // Records that are stored can resolve others
            if recordsToAddLater.count == heldBefore { return }
            tryingAll = false
        }
    }
    
    func _tokensUpdate(
        for zoneID: CKRecordZone.ID,
        changeToken: CKServerChangeToken?,
        userToken: Data?,
        finalCompletion: Bool = false,
        fetchFailed: Bool = false
    ) {
        retryHeldRecords(all: finalCompletion)

        // Records held for their unique values are decided on once every other record of the zone is stored, and deferred
        // deletions applied afterwards, so objects that got other records keep them. Not when the zone failed, as later
        // records of it are missing.
        if finalCompletion && !fetchFailed {
            isAtEndOfZone = true
            retryHeldRecords(all: true)
            storeRecordsThatReferenceEachOther(in: zoneID)
            var appliedDeletions = false
            for recordID in deferredDeletions where !isForSharedDatabase || recordID.zoneID == zoneID {
                deferredDeletions.remove(recordID)
                applyDeletion(of: recordID)
                appliedDeletions = true
            }
            // A deletion can free unique values for a record that was held for them, e.g. one deleted and created again
            if appliedDeletions {
                retryHeldRecords(all: true)
            }
            isAtEndOfZone = false
        }

        if finalCompletion {
            for reference in parentReferences {
                guard
                    let object = reference.object ?? reference.objectID.flatMap({ try? context.existingObject(with: $0) }),
                    !object.isDeleted,
                    let parent = findObject(for: reference.parentRecordID)?.object,
                    object.value(forKey: reference.parentKey) as? NSManagedObject != parent
                else { continue }
                object.setValue(parent, forKey: reference.parentKey)
            }
            parentReferences = []
            
            let unresolvedRecords = recordsToAddLater.filter { isRecord($0, in: zoneID) }
            if unresolvedRecords.isEmpty {
                synchronizer.logger.log("All current records added.")
            } else if heldRecords != nil {
                // E.g. they reference a record that was deleted, or one only a pending catch-up downloads. They're kept, and
                // tried again by later downloads. They stay in iCloud: deleting them would delete them on every device.
                synchronizer.logger.log("Keeping \(unresolvedRecords.count) records with unresolved references for later: \(unresolvedRecords.map(\.recordID.recordName))")
            } else {
                // A catch-up downloads every record, also ones whose references were deleted long ago. They stay as they are,
                // and so do the local values of their objects.
                synchronizer.logger.log("Leaving \(unresolvedRecords.count) records with unresolved references alone while catching up")
                unresolvedRecords.forEach { synchronizer.skippedWhileCatchingUp($0.recordID.recordName, isTriedAgain: false) }
                recordsToAddLater.removeAll { isRecord($0, in: zoneID) }
            }
        }
        
        // Held records are kept in files once the page is saved, so they don't keep the token from moving on
        if let changeToken, savesChangeTokens {
            if isForSharedDatabase {
                tokensToUpdate[zoneID] = changeToken
            } else {
                tokensToUpdate[nil] = changeToken
            }
            synchronizer.logger.log("ChangeToken updated")
        }
    }
    
    /// Stores held records that only wait for each other, e.g. a podcast that references its current episode, which
    /// references the podcast, rather than holding them forever: each waits for the other to be stored. They're stored without
    /// those references first, which are set once all of them are, before the page is saved, so required relationships have
    /// their objects when it's saved.
    private func storeRecordsThatReferenceEachOther(in zoneID: CKRecordZone.ID) {
        var candidates: [CKRecord.ID: (record: CKRecord, missing: Set<CKRecord.ID>)] = [:]
        for record in recordsToAddLater where isRecord(record, in: zoneID) {
            let missing = missingReferences(of: record)
            if !missing.isEmpty {
                candidates[record.recordID] = (record, missing)
            }
        }
        // Only ones whose missing references are all held themselves, rather than e.g. deleted
        while true {
            let ids = Set(candidates.keys)
            let waiting = candidates.filter { !$0.value.missing.isSubset(of: ids) }.keys
            guard !waiting.isEmpty else { break }
            waiting.forEach { candidates[$0] = nil }
        }
        guard !candidates.isEmpty else { return }

        synchronizer.logger.log("Storing \(candidates.count) records that reference each other")
        referencesSetLater = Set(candidates.keys)
        for (recordID, candidate) in candidates {
            recordsToAddLater.remove(recordID)
            _changed(record: candidate.record)
        }
        referencesSetLater = []
        for reference in laterReferences {
            guard let object = findObject(for: reference.recordID)?.object else { continue }
            let targets = reference.targets.compactMap { findObject(for: $0)?.object }
            // E.g. one of them couldn't be stored. The relationship stays as it is.
            guard targets.count == reference.targets.count else { continue }
            let key = findCorrespondingKey(entity: object.entity, rawKey: reference.rawKey)
            object.setValue(reference.isList ? NSOrderedSet(array: targets) : targets.first, forKey: key)
        }
        laterReferences = []
    }

    /// The records a record references that aren't stored, in the keys that are stored. Has to be called on `context`'s queue.
    private func missingReferences(of record: CKRecord) -> Set<CKRecord.ID> {
        guard
            let entity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[record.recordType],
            let syncedKeys = synchronizer.configuration?.entities[record.recordType]?.syncedProperties
        else { return [] }
        var missing: Set<CKRecord.ID> = []
        for key in record.allKeys() where isStored(key, entity: entity, syncedKeys: syncedKeys) {
            let references = (record[key] as? CKRecord.Reference).map { [$0] } ?? (record[key] as? [CKRecord.Reference]) ?? []
            for reference in references where findObject(for: reference.recordID) == nil {
                missing.insert(reference.recordID)
            }
        }
        return missing
    }

    private func isRecord(_ record: CKRecord, in zoneID: CKRecordZone.ID) -> Bool {
        // The private database only uses a single zone
        !isForSharedDatabase || record.recordID.zoneID == zoneID
    }
    
    func fetchCompletion(
        for zoneID: CKRecordZone.ID,
        result: Result<(serverChangeToken: CKServerChangeToken, clientChangeTokenData: Data?, moreComing: Bool), any Error>
    ) {
        guard failure == nil else { return }
        switch result {
        case .success((let changeToken, let userToken, _)):
            synchronizer.logger.log("Zone \(zoneID.zoneName) fetch completed successfully")
            
            context.performAndWaitUnchecked {
                self._tokensUpdate(for: zoneID, changeToken: changeToken, userToken: userToken, finalCompletion: true)
            }
        case .failure(let error):
            synchronizer.logger.log("Zone \(zoneID.zoneName) fetch error: \(error)")

            switch (error as? CKError)?.code {
            case .changeTokenExpired?:
                zonesWithExpiredTokens.insert(zoneID)
            case .zoneNotFound?, .userDeletedZone?:
                // Zones of the shared database disappear when they are no longer shared, see `refreshSharedZoneIDs()`
                if !isForSharedDatabase {
                    privateZoneError = error as? CKError
                } else {
                    zoneErrors[zoneID] = error
                }
            default:
                zoneErrors[zoneID] = error
            }

            context.performAndWaitUnchecked {
                self._tokensUpdate(for: zoneID, changeToken: nil, userToken: nil, finalCompletion: true, fetchFailed: true)
            }
        }
    }
    
    func fetchOverallCompletion(result: Result<Void, Error>) {
        let synchronizer = self.synchronizer!
        let syncContext = synchronizer.context
        
        synchronizer.logger.log("Fetch Overall Completion")
        
        if let failure {
            completionHandler(failure)
            return
        }
        // What was downloaded is saved, also after an error, with the change tokens of the pages that were complete
        if let error = save() {
            completionHandler(error)
            return
        }
        
        // These zones are downloaded completely next, see `SDSSynchronizer.ChangeTokenExpiredError`
        let zonesWithExpiredTokens = self.zonesWithExpiredTokens
        let isForSharedDatabase = self.isForSharedDatabase
        if !zonesWithExpiredTokens.isEmpty {
            do {
                try syncContext.performAndWaitUnchecked {
                    for zoneID in zonesWithExpiredTokens {
                        if isForSharedDatabase {
                            CloudKitZone.retrieveZone(for: zoneID)?.changeToken = nil
                        } else {
                            synchronizer.setState(\.changeToken, value: nil)
                        }
                    }
                    try syncContext.save()
                }
            } catch {
                synchronizer.logger.log("Sync Context save error: \(error)")
                completionHandler(error)
                return
            }
        }

        if let privateZoneError {
            completionHandler(SDSSynchronizer.PrivateZoneMissingError(error: privateZoneError))
            return
        }
        if !zonesWithExpiredTokens.isEmpty {
            completionHandler(SDSSynchronizer.ChangeTokenExpiredError())
            return
        }

        switch result {
        case .success where !zoneErrors.isEmpty:
            // E.g. zones CloudKit asks to wait for, which the next synchronization waits for, see `SDSSynchronizationViewModel.attemptSyncStart()`
            synchronizer.logger.log("Database fetch completed, but zones failed: \(self.zoneErrors)")
            completionHandler(SDSSynchronizer.errorWithLongestRetryDelay(in: CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: zoneErrors])))
        case .success where hadLocalChanges && scope.isCatchingUp:
            synchronizer.logger.log("Database fetch completed, but objects changed locally meanwhile")
            completionHandler(SDSSyncError(title: "error.changedWhileCatchingUp"))
        case .success:
            synchronizer.logger.log("Database fetch completed successfully")
            completionHandler(nil)
        case .failure(let error):
            synchronizer.logger.log("Database fetch completed with error: \(error)")
            // E.g. zones CloudKit asks to wait for, which the next synchronization waits for, see `SDSSynchronizationViewModel.attemptSyncStart()`
            completionHandler(SDSSynchronizer.errorWithLongestRetryDelay(in: error))
        }
    }
    
    /// Saves the downloaded objects with their local entities, and the change tokens received so far. Returns the error that
    /// made it discard what wasn't saved, so it's downloaded again.
    ///
    /// The local entities are saved before the objects, and the change tokens after them. If the app is terminated in
    /// between, objects never exist without their records, which would upload them as new records and download them again
    /// as duplicates. Entities without objects are taken care of, see `SDSSynchronizer.backfill(onlyUntracked:)`.
    private func save() -> (any Error)? {
        let synchronizer = self.synchronizer!
        let syncContext = synchronizer.context
        
        guard let observedContext = synchronizer.observedUpdateContext else {
            synchronizer.logger.log("No observed context")
            return SDSSyncError(title: "error.noObservedContext")
        }
        
        // Another process could have taken over while this one was suspended and downloaded the same records.
        // Saving them as well would duplicate them, so they are discarded and downloaded again later if needed.
        guard synchronizer.syncLease.renew() else {
            synchronizer.logger.log("Sync lease lost, discarding download")
            discardDownload(observedContext: observedContext)
            return SDSSyncLease.UnavailableError()
        }
        
        if let applyError {
            synchronizer.logger.log("Failed to apply downloaded records, discarding download: \(applyError.localizedDescription)")
            discardDownload(observedContext: observedContext)
            return applyError
        }
        
        // The records could be another account's, which mustn't end up in the previous one's data
        do {
            try synchronizer.checkNotStopped()
        } catch let error as SDSSynchronizer.AccountChangedError {
            discardDownload(observedContext: observedContext)
            return error
        } catch {
            // Once stopped, what was downloaded is still saved
        }
        
        var fixCount = 0
        while true {
            // Inserted objects get their permanent IDs before they are saved, so their local entities know them once other contexts
            // can change the objects. Otherwise a change could find no record id for an object, and give it a second one.
            let permanentIdError: (any Error)? = observedContext.performAndWait {
                do {
                    try observedContext.obtainPermanentIDs(for: Array(observedContext.insertedObjects))
                    return nil
                } catch {
                    return error
                }
            }
            if let permanentIdError {
                synchronizer.logger.log("Failed to get permanent IDs, discarding download: \(permanentIdError.localizedDescription)")
                discardDownload(observedContext: observedContext)
                return permanentIdError
            }
            let entitiesError: (any Error)? = syncContext.performAndWaitUnchecked {
                // Saving again after a fixed save, the entities exist already
                var createdLocalIds = Set(createdLocalEntities.map(\.localId))
                for (object, id) in synchronizer.temporaryObjectIds where !object.objectID.isTemporaryID {
                    let localId = object.objectID.uriRepresentation().absoluteString
                    guard !createdLocalIds.contains(localId) else { continue }
                    // Objects of the app's contexts got their entities when they were saved
                    if object.managedObjectContext !== observedContext, CloudKitLocalEntity.entry(forLocalId: localId, in: syncContext) != nil {
                        continue
                    }
                    createdLocalIds.insert(localId)
                    createdLocalEntities.append(CloudKitLocalEntity(id: id, localId: localId, context: syncContext))
                }
                // Written before anything of the page is saved, so a save that's interrupted is repaired with the next launch,
                // rather than its entities without objects being taken for objects that vanished
                let pageSave = SDSSynchronizer.FileState.PageSave(createdLocalIds: createdLocalEntities.map(\.localId), deletedRecordNames: Array(deletedRecordIds))
                synchronizer.updateFileState { $0.interruptedPageSave = pageSave }
                // Before the objects, see above
                do {
                    try syncContext.save()
                    return nil
                } catch {
                    return error
                }
            }
            if let entitiesError {
                synchronizer.logger.log("Failed to save the downloaded objects' records, discarding download: \(entitiesError.localizedDescription)")
                discardDownload(observedContext: observedContext)
                return entitiesError
            }
            synchronizer.afterSavingDownloadedRecords?()
            
            // Local changes are looked for right before saving, on the context's queue, so the app's saves aren't merged into
            // it in between, and one that's saved meanwhile conflicts, see `SDSDownloadMergePolicy`
            let saveError: (any Error)? = observedContext.performAndWaitUnchecked {
                hadLocalChanges = keepLocalChanges(in: observedContext) || hadLocalChanges
                synchronizer.beforeSavingDownloadedObjects?()
                let removals = removalsOfObjectsMovedIntoDeletedOnes(in: observedContext)
                do {
                    try synchronizer.saveObservedUpdateContext(observedContext)
                    synchronizer.storeRemovals(removals)
                    return nil
                } catch {
                    return error
                }
            }
            guard let saveError else {
                synchronizer.afterSavingDownloadedObjects?()
                break
            }
            synchronizer.logger.log("Observed Context save error: \(saveError)")
            
            let isFixed = observedContext.performAndWaitUnchecked {
                tryFixingObservedContext(error: saveError)
            }
            fixCount += 1
            // E.g. a fix that doesn't last, like an object a delete rule keeps from being deleted again and again
            guard isFixed, fixCount < Self.maximumSaveFixes else {
                // The unsaved objects would fail every later save of the context, and their placeholders must not be saved.
                // The change tokens weren't saved either, so the records are downloaded again.
                synchronizer.logger.log("Failed fixing the save errors, discarding download")
                discardDownload(observedContext: observedContext)
                return saveError
            }
            synchronizer.logger.log("Succeeded trying to fix save errors. Trying to save again.")
        }
        // Objects that fixing the save deleted, e.g. ones a deleted object cascaded to, don't keep their local entities, which
        // would be taken for objects that vanished
        let createdLocalIds = syncContext.performAndWaitUnchecked { createdLocalEntities.map(\.localId) }
        let unsavedLocalIds: Set<String> = observedContext.performAndWaitUnchecked {
            Set(createdLocalIds.filter { localId in
                guard let objectID = URL(string: localId).flatMap({ synchronizer.observedStore?.managedObjectID(forURIRepresentation: $0) }) else { return true }
                return (try? observedContext.existingObject(with: objectID)) == nil
            })
        }
        // The objects are saved, so their local entities stay if a later step fails, rather than the records being inserted
        // again as duplicates, see `discardDownload`
        let unsavedRecordNames: [String] = syncContext.performAndWaitUnchecked {
            let unsaved = createdLocalEntities.filter { unsavedLocalIds.contains($0.localId) }
            let names = unsaved.map(\.id)
            unsaved.forEach(syncContext.delete)
            synchronizer.removeAllTemporaryObjects()
            createdLocalEntities = []
            return names
        }
        // Their records are kept for later downloads too, like the one whose object couldn't be saved, rather than the change
        // token moving past them
        for name in unsavedRecordNames {
            if let record = pageRecords[name] {
                setAside(record)
            }
        }
        pageRecords = [:]
        
        // Held records are kept in files before the token moves past them. Files of records that were stored meanwhile are
        // only removed now that the objects are saved.
        if let heldRecords {
            // Also newer versions of records that were held already
            for record in Array(recordsToAddLater) + Array(setAsideRecords) where persistedHeld[record.recordID] != Self.version(of: record) {
                do {
                    try heldRecords.hold(record)
                    persistedHeld[record.recordID] = Self.version(of: record)
                } catch {
                    // E.g. its asset can't be copied. It's downloaded again instead.
                    synchronizer.logger.error("Failed to keep `\(record.recordID.recordName)`, downloading it again later: \(error.localizedDescription)")
                    recordsToAddLater.remove(record.recordID)
                    setAsideRecords.remove(record.recordID)
                    failedRecordIDs.insert(record.recordID)
                }
            }
            do {
                try heldRecords.storeFailedIDs(failedRecordIDs)
                try heldRecords.storeDeferredDeletions(deferredDeletions)
                try heldRecords.storeSkippedIDs(skippedRecordIDs)
            } catch {
                synchronizer.logger.error("Failed to keep the records that failed to download: \(error.localizedDescription)")
                return error
            }
            let heldIDs = recordsToAddLater.ids.union(setAsideRecords.ids)
            let released = persistedHeldIDs.subtracting(heldIDs)
            heldRecords.release(released)
            for recordID in released {
                persistedHeld[recordID] = nil
            }
            persistedFailedRecordIDs = failedRecordIDs
            persistedDeferredDeletions = deferredDeletions
            persistedSkippedRecordIDs = skippedRecordIDs
        }
        
        // Written before the token moves past the records it describes
        synchronizer.setOverflowKeys(overflowChanges)
        overflowChanges = [:]
        
        let tokensToUpdate = self.tokensToUpdate
        self.tokensToUpdate = [:]
        let deletedRecordIds = Array(self.deletedRecordIds)
        self.deletedRecordIds = []
        let existingRecords = self.existingRecords
        self.existingRecords = []

        do {
            try syncContext.performAndWaitUnchecked {
                // Models created again since their deletions were downloaded keep their records, see `_deleted`
                let createdAgain = Set(CloudKitUpdate.find(ids: deletedRecordIds, in: syncContext).values.filter(\.isLocalInsert).map(\.id))
                let deletedRecordIds = deletedRecordIds.filter { !createdAgain.contains($0) }
                for entityName in ["CloudKitUpdate", "CloudKitRemoval", "CloudKitLocalEntity"] {
                    syncContext.metadataEntries(of: entityName, withIds: deletedRecordIds).forEach(syncContext.delete)
                }
                
                // The records exist, so their values win over backfilled ones, and they're no local inserts anymore
                for update in CloudKitUpdate.find(ids: Array(existingRecords), in: syncContext).values {
                    update.recordExists()
                    if update.keysToUpload.isEmpty {
                        syncContext.delete(update)
                    }
                }

                for (zoneID, changeToken) in tokensToUpdate {
                    if let zoneID {
                        CloudKitZone.getZone(with: zoneID, context: syncContext).changeToken = changeToken
                    } else {
                        synchronizer.setState(\.changeToken, value: changeToken)
                    }
                }

                try syncContext.save()
            }
        } catch {
            synchronizer.logger.log("Sync Context save error: \(error)")
            return error
        }
        synchronizer.updateFileState { $0.interruptedPageSave = nil }
        
        // The saved objects are turned into faults, so a long download doesn't keep them in memory
        identityIndex.objectsWereSaved()
        for index in parentReferences.indices {
            if let object = parentReferences[index].object {
                parentReferences[index].objectID = object.objectID
                parentReferences[index].object = nil
            }
        }
        observedContext.performAndWait {
            observedContext.refreshAllObjects()
        }
        return nil
    }
    
    /// The removals of objects that delete rules delete with downloaded deletions, which this device moved into the deleted
    /// objects, e.g. a link moved into a subscription another device deleted. Other devices don't know about the move, as it
    /// wasn't uploaded, so they'd keep the object where it was, while this device deleted it. As it was moved into an object
    /// that's gone, it's gone everywhere instead. Objects that were already there are deleted by the other devices too.
    /// Has to be called on the queue of the observed update context, before it's saved.
    private func removalsOfObjectsMovedIntoDeletedOnes(in observedContext: NSManagedObjectContext) -> [SDSObjectDeletion] {
        observedContext.processPendingChanges()
        let deleted = observedContext.deletedObjects.filter { !$0.objectID.isTemporaryID }
        guard !deleted.isEmpty else { return [] }
        let localIds = Dictionary(deleted.map { ($0.objectID.uriRepresentation().absoluteString, $0) }, uniquingKeysWith: { first, _ in first })
        let deletedHere = deletedRecordIds
        let syncContext = synchronizer.context
        // The keys of objects that changed locally, which weren't uploaded, of objects whose records weren't deleted elsewhere
        let pendingKeys: [String: [String]] = syncContext.performAndWaitUnchecked {
            let entries = CloudKitLocalEntity.entries(forLocalIds: Array(localIds.keys), in: syncContext).filter { !deletedHere.contains($0.value.id) }
            let updates = CloudKitUpdate.find(ids: entries.values.map(\.id), in: syncContext)
            return entries.compactMapValues { updates[$0.id].map(\.changedKeys) }
        }
        var removals: [SDSObjectDeletion] = []
        for (localId, keys) in pendingKeys {
            guard let object = localIds[localId] else { continue }
            let relationshipKeys = keys.filter { object.entity.relationshipsByName[$0] != nil }
            guard !relationshipKeys.isEmpty else { continue }
            let movedIntoDeleted = object.committedValues(forKeys: relationshipKeys).values.contains { value in
                if let object = value as? NSManagedObject { return object.isDeleted }
                if let objects = value as? NSOrderedSet { return objects.contains { ($0 as? NSManagedObject)?.isDeleted == true } }
                if let objects = value as? NSSet { return objects.contains { ($0 as? NSManagedObject)?.isDeleted == true } }
                return false
            }
            guard movedIntoDeleted, let container = synchronizer.container(for: object) else { continue }
            synchronizer.logger.log("Deleting `\(localId)` everywhere, as it was moved into an object that was deleted elsewhere")
            removals.append(SDSObjectDeletion(localId: localId, sharableRootLocalId: container.sharableRootLocalId, isSharable: container is SDSSharableContainer))
        }
        return removals
    }

    /// Keys that were changed locally while downloading keep their changes, which would otherwise be overwritten with the
    /// downloaded values. They're uploaded next. The object's other keys keep the downloaded values, like local changes win
    /// key by key over records that are downloaded, see `_changed(record:)`. Returns whether there were any.
    /// A catch-up downloads every record, which can take long, and it's done again later, after they're uploaded.
    ///
    /// Also keys of saves that started, or that aren't stored yet: they're read first, as they're forgotten once they're
    /// stored. Has to be called on the queue of the observed update context.
    private func keepLocalChanges(in observedContext: NSManagedObjectContext) -> Bool {
        let updatedObjects = observedContext.updatedObjects.filter { !$0.objectID.isTemporaryID }
        guard !updatedObjects.isEmpty else { return false }
        let keysBeingSaved = synchronizer.keysBeingSavedByAnyContext()
        let localIds = Dictionary(updatedObjects.map { ($0, $0.objectID.uriRepresentation().absoluteString) }, uniquingKeysWith: { $1 })
        // One lookup for the page, rather than several for each object
        let pendingKeys = synchronizer.pendingLocalKeys(ofLocalIds: Array(localIds.values))
        var hasLocalChanges = false
        for object in updatedObjects {
            let keys = (localIds[object].flatMap { pendingKeys[$0] } ?? []).union(keysBeingSaved[object.objectID] ?? [])
            let downloaded = object.changedValues()
            guard !keys.isDisjoint(with: downloaded.keys) else { continue }
            // The object reads its saved values again, with the local changes, and gets the other downloaded values back
            observedContext.refresh(object, mergeChanges: false)
            for (key, value) in downloaded where !keys.contains(key) {
                object.setValue(value is NSNull ? nil : value, forKey: key)
            }
            hasLocalChanges = true
        }
        return hasLocalChanges
    }

    /// Discards the downloaded objects and their placeholders that weren't saved, and doesn't save the change tokens, so the
    /// records are downloaded again.
    private func discardDownload(observedContext: NSManagedObjectContext) {
        let synchronizer = self.synchronizer!
        let syncContext = synchronizer.context
        
        observedContext.performAndWait {
            observedContext.rollback()
        }
        let createdLocalEntities = self.createdLocalEntities
        self.createdLocalEntities = []
        let isRemoved = syncContext.performAndWaitUnchecked {
            synchronizer.removeAllTemporaryObjects()
            // They can be saved already, e.g. with changes that were stored meanwhile
            guard !createdLocalEntities.isEmpty else { return true }
            createdLocalEntities.forEach(syncContext.delete)
            do {
                try syncContext.save()
                return true
            } catch {
                synchronizer.logger.error("Failed to remove the local entities of a discarded download: \(error.localizedDescription)")
                return false
            }
        }
        if isRemoved {
            synchronizer.updateFileState { $0.interruptedPageSave = nil }
        }
        tokensToUpdate = [:]
        deletedRecordIds = []
        existingRecords = []
        overflowChanges = [:]
        pageRecords = [:]
        applyError = nil
        // Objects of saved pages keep their parents
        parentReferences.removeAll { $0.objectID == nil }
        // The records are downloaded again, also ones that were held since the last save
        recordsToAddLater.removeAll { !persistedHeldIDs.contains($0.recordID) }
        setAsideRecords.removeAll { !persistedHeldIDs.contains($0.recordID) }
        failedRecordIDs = persistedFailedRecordIDs
        deferredDeletions = persistedDeferredDeletions
        skippedRecordIDs = persistedSkippedRecordIDs
        heldForUniqueValues = []
        identityIndex.discardInsertedObjects()
    }

    /// Whether a required to-one relationship of a saved object lost its object, as the object was deleted, e.g. by a
    /// downloaded deletion. Has to be called on `context`'s queue.
    private func lostRequiredRelationship(_ key: String, of object: NSManagedObject) -> Bool {
        guard
            !object.isDeleted,
            !object.isInserted,
            let relationship = object.entity.relationshipsByName[key],
            !relationship.isToMany,
            !relationship.isOptional,
            object.value(forKey: key) == nil,
            let previous = object.committedValues(forKeys: [key])[key] as? NSManagedObject
        else { return false }
        return previous.isDeleted
    }

    /// Tries fixing the given error and returns whether the context should try to save again or a fix was not possible.
    /// Has to be called on `context`'s queue.
    ///
    /// Downloaded values that the store rejects, e.g. a missing required value, or one that's too long, are set aside with
    /// their records (see `setAsideRecords`), rather than discarding the download over and over, which would also keep
    /// every upload from running.
    private func tryFixingObservedContext(error: any Error) -> Bool {
        synchronizer.logger.log("tryFixingObservedContext starting: \(error.localizedDescription, privacy: .public)")
        let nsError = error as NSError
        
        // If there are detailed sub-errors, recursively try to fix each
        if let subErrorsAny = nsError.userInfo[NSDetailedErrorsKey] {
            guard let subErrorsArray = subErrorsAny as? [Any] else {
                synchronizer.logger.log("tryFixingObservedContext: NSDetailedErrors is no array: \("\(subErrorsAny)", privacy: .public)")
                return false
            }
            
            var subErrors: [NSError] = []
            for possible in subErrorsArray {
                guard let nsError = possible as? NSError else {
                    synchronizer.logger.log("tryFixingObservedContext: NSDetailedError single value is no NSError: \("\(possible)", privacy: .public)")
                    continue
                }
                subErrors.append(nsError)
            }
            
            synchronizer.logger.log("tryFixingObservedContext: Iterating over detailed errors: \(subErrors.count, privacy: .public)")
            var fixed = false
            for subError in subErrors {
                synchronizer.logger.log("tryFixingObservedContext: Detailed error start")
                fixed = tryFixingObservedContext(error: subError) || fixed
            }
            synchronizer.logger.log("tryFixingObservedContext: Detailed errors: \(fixed)")
            return fixed // Return whether any of the errors were fixed
        }
        
        guard (NSValidationErrorMinimum...NSValidationErrorMaximum).contains(nsError.code) else {
            synchronizer.logger.log("tryFixingObservedContext: Code not correct: \(nsError.code, privacy: .public)")
            return false
        }
        
        guard let object = nsError.userInfo[NSValidationObjectErrorKey] as? NSManagedObject else {
            let keys = nsError.userInfo.keys.joined(separator: ", ")
            synchronizer.logger.log("tryFixingObservedContext: No error object: \(keys, privacy: .public)")
            return false
        }
        
        // An object that can't exist without an object this download deleted, through a required relationship whose delete rule
        // only nullifies it, goes with it, like through a cascade rule. Otherwise every download would fail on the deletion,
        // whose change token would never be saved. Synchronized or not: refreshing a synchronized one would keep it pointing
        // at the deleted row. The device that deleted the object couldn't save without deleting it or moving it to another
        // object too, which is downloaded as well, and gives it back its record's values if it still exists.
        if let key = nsError.userInfo[NSValidationKeyErrorKey] as? String, lostRequiredRelationship(key, of: object) {
            let recordName = synchronizer.existingRecordId(of: object)
            context.delete(object)
            if let recordName {
                deletedRecordIds.insert(recordName)
            }
            synchronizer.logger.error("tryFixingObservedContext: Deleting a `\(object.entity.name ?? "Unknown")` that requires a deleted object")
            return true
        }

        guard let container = synchronizer.container(for: object) else {
            synchronizer.logger.log("tryFixingObservedContext: Object is not a synchronizable object: \(object.entity.name ?? "Unknown")")
            return false
        }
        
        // The record stays in iCloud, as deleting it would delete it on every device. A required value is missing e.g. because
        // it isn't synchronized (see `makeConfiguration`), or a newer version of the app made it required.
        let recordName = synchronizer.existingRecordId(of: object)
        if let recordName, let record = pageRecords[recordName] {
            setAside(record)
        }
        if object.isDeleted {
            // E.g. a delete rule denies deleting it. It stays, and the deletion isn't stored.
            context.refresh(object, mergeChanges: false)
            if let recordName {
                deletedRecordIds.remove(recordName)
            }
            synchronizer.logger.error("tryFixingObservedContext: Not deleting a `\(object.entity.name ?? "Unknown")` that can't be deleted")
        } else if object.isInserted {
            // Objects that were saved before don't go with it, e.g. ones its record moved into it, which a delete rule would
            // delete, without the deletion being uploaded. They keep their saved values, and their records are kept for later
            // downloads like this one's.
            for (name, relationship) in object.entity.relationshipsByName where relationship.deleteRule == .cascadeDeleteRule {
                let value = object.value(forKey: name)
                let related = (value as? NSSet)?.allObjects ?? (value as? NSOrderedSet)?.array ?? [value].compactMap { $0 }
                for case let existing as NSManagedObject in related where !existing.isInserted {
                    if relationship.isToMany {
                        if relationship.isOrdered {
                            object.mutableOrderedSetValue(forKey: name).remove(existing)
                        } else {
                            object.mutableSetValue(forKey: name).remove(existing)
                        }
                    } else {
                        object.setValue(nil, forKey: name)
                    }
                    context.refresh(existing, mergeChanges: false)
                    if let relatedName = synchronizer.existingRecordId(of: existing), let record = pageRecords[relatedName] {
                        setAside(record)
                    }
                }
            }
            // The object isn't stored, nor its local entity once the download is saved
            context.delete(object)
            deletedRecordIds.insert(container.id)
            synchronizer.logger.error("tryFixingObservedContext: Not storing a downloaded `\(object.entity.name ?? "Unknown")` with invalid values")
        } else {
            // The object keeps its saved values instead of the downloaded ones
            context.refresh(object, mergeChanges: false)
            synchronizer.logger.error("tryFixingObservedContext: Not storing invalid downloaded values of `\(object.entity.name ?? "Unknown")`")
        }

        return true
    }
}
