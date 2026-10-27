import Foundation
import CoreData
import CloudKit
import OSLog

/// How long the zone of an accepted share is kept although the shared database doesn't list it.
private let acceptedShareZoneListingDelay: TimeInterval = 5 * 60

extension SDSSynchronizer {
    
    /// - Parameter refreshingSharedZones: Whether the shared zones have to be refreshed, which `synchronize()` usually did before uploading already.
    func download(refreshingSharedZones: Bool = true) async throws {
        try await _download()
        
        if refreshingSharedZones {
            try await refreshSharedZoneIDs()
        }
        
        try await self._download(sharedDatabase: true)
    }
    
    /// Registers newly shared zones, and cleans up after zones that are no longer shared with the current user.
    ///
    /// Called before uploading, as pending changes for a zone that is gone can never be uploaded and would fail the upload.
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
            let removedZones = CloudKitZone.getAll().filter { !existingZoneIds.contains($0.calculatedId) }
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
            for zone in CloudKitZone.getAll() where !existingZoneIds.contains(zone.calculatedId) && !remainingShareZoneIds.contains(zone.calculatedId) {
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
    
    private func _download(sharedDatabase: Bool = false) async throws {
        logger.log("Starting Download of \(sharedDatabase ? "shared" : "private") database")
        
        var configurations: [CKRecordZone.ID : CKFetchRecordZoneChangesOperation.ZoneConfiguration] = [:]
        
        if sharedDatabase {
            configurations = context.performAndWaitUnchecked {
                let zones = CloudKitZone.getAll()
                return Dictionary(zones.map { savedZone in
                    (savedZone.calculatedId, CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: savedZone.changeToken))
                }, uniquingKeysWith: { $1 })
            }
            
            if configurations.isEmpty {
                logger.log("No zones in shared database")
                return
            }
        } else {
            let token = accessState(\.changeToken)
            let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: token)
            
            configurations = [defaultZoneID: options]
        }
        
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: Array(configurations.keys),
            configurationsByRecordZoneID: configurations
        )
        operation.fetchAllChanges = true
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let handler = CKDownloadHandler(synchronizer: self, forSharedDatabase: sharedDatabase) { [weak self] error in
                guard let self else { return }
                
                if let error = error {
                    continuation.resume(throwing: error)
                    logger.log("Download completion Error: \(error, privacy: .public)")
                    return
                }
                
                logger.log("Download completed")
                
                self.lastCompletedDownload = Date()
                
                continuation.resume()
            }
            
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

private final class CKDownloadHandler {
    
    var recordsToAddLater: [CKRecord] = []
    var objectsToEnsureParentReferencesFor: [(container: SDSSynchronizableContainer, reference: CKRecord.Reference)] = []
    
    weak var synchronizer: SDSSynchronizer!
    weak var context: NSManagedObjectContext!
    private var tokensToUpdate: [CKRecordZone.ID?: CKServerChangeToken] = [:]
    let isForSharedDatabase: Bool
    let completionHandler: (Error?) -> Void
    
    init(synchronizer: SDSSynchronizer, forSharedDatabase: Bool, completionHandler: @escaping (Error?) -> Void) {
        self.synchronizer = synchronizer
        self.context = synchronizer.observedUpdateContext
        
        self.isForSharedDatabase = forSharedDatabase
        self.completionHandler = completionHandler
    }
    
    func changed(recordId: CKRecord.ID, result: Result<CKRecord, any Error>) {
        guard case .success(let record) = result else {
            synchronizer.logger.log("Error in `changed`: \(String(describing: result))")
            assertionFailure()
            return
        } // TODO(later): Should an error be handled here? What kind of error is this? A server error that this one specific record failed to be resolved? Very strange Apple API
        
        synchronizer.logger.log("[Download] Changed: \(record)")
        context.performAndWaitUnchecked {
            self._changed(record: record)
        }
    }

    private func _changed(record: CKRecord) {
        // Catch CKShare
        if let share = record as? CKShare {
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

        // Make sure dependent objects exist, and prefill all values if they do
        guard let kVPs = self.valuesIfAllReferencesExist(for: record) else {
            self.recordsToAddLater.append(record)
            return
        }

        guard let container = retrieveObject(for: record, preliminaryUpdateHandler: { container in
            guard let container else { return }

            let object = container.object
            for (rawKey, value) in kVPs {
                guard rawKey != SDSSynchronizer.Constants.parentWorkaroundKey else { return }
                
                let key = findCorrespondingKey(entity: object.entity, rawKey: rawKey)
                // This is needed to exclude keys that are excluded but were synced before. Otherwise they will be synced again.
                guard container.syncKeys.contains(key) else { continue }
                
                // This workaround is needed for some records where there can be a merge conflict
                // when the parent object references the child because it uses an ordered set.
                // When 2 devices add an item at the same time this can create an item with a missing parent.
                // This is the sending end fix.
                // TODO(later): This is only done for parent references right now, should propably be done for others too?
                if
                    let value = (value as? NSOrderedSet)?.array as? [NSManagedObject],
                    let before = (object.value(forKey: key) as? NSOrderedSet)?.array as? [NSManagedObject]
                {
                    for child in before
                    where !value.contains(child) && child.synchronizableContainer?.parent == object
                    {
                        objectsToEnsureParentReferencesFor.append((container, CKRecord.Reference(record: record, action: .none)))
                    }
                }
                
                let attribute = object.entity.attributesByName[key]
                let type = attribute?.type
                if let value = value as? SDSSynchronizableContainer {
                    object.setValue(value.object, forKey: key)
                } else if let asset = value as? CKAsset {
                    let data: Data?
                    do {
                        data = try asset.fileURL.map { try Data(contentsOf: $0) }
                    } catch {
                        // The current value is kept rather than removed
                        synchronizer.logger.error("Failed reading asset for key `\(object.entity.name ?? "")`.`\(key)`: \(error.localizedDescription)")
                        continue
                    }
                    object.setValue(data, forKey: key)
                } else if let data = value as? Data, type != .binaryData {
                    if let transformerName = object.entity.attributesByName[key]?.valueTransformerName {
                        let transformer = ValueTransformer(forName: .init(transformerName))!
                        object.setValue(transformer.reverseTransformedValue(data), forKey: key)
                    } else {
                        do {
                            object.setValue(try JSONSerialization.jsonObject(with: data), forKey: key)
                        }
                        catch {
                            synchronizer.logger.log("Failed setting json object for key `\(object.entity.name ?? "")`.`\(key)`: \(String(data: data, encoding: .utf8) ?? "FAIL")")
                        }
                    }
                } else if let string = value as? String, type == .uri {
                    object.setValue(URL(string: string), forKey: key)
                } else {
                    // Also apply some sanity checks
                    if let attribute, type == .boolean {
                        let possibleValues: [Int?] = attribute.isOptional ? [nil, 0, 1] : [0, 1]
                        if !possibleValues.contains(value as? Int) {
                            object.setValue(attribute.defaultValue, forKey: key)
                            continue
                        }
                    }
                    
                    object.setValue(value, forKey: key)
                }
            }

            synchronizer.logger.log("Object updated: \(object)")
        }) else { return }

        if let reference = record.parent {
            // This is the receiving end fix for the problem a few lines above.
            objectsToEnsureParentReferencesFor.append((container, reference))
        }
    }

    private func findCorrespondingKey(entity: NSEntityDescription, rawKey: String) -> String {
        if entity.propertiesByName[rawKey] != nil {
            return rawKey
        }

        for property in entity.properties where property.renamingIdentifier == rawKey {
            return property.name
        }

        assertionFailure()
        return rawKey
    }

    private func valuesIfAllReferencesExist(for record: CKRecord) -> [String: Any?]? {
        var values = [String: Any?]()
        
        for key in record.allKeys() where key != SDSSynchronizer.Constants.parentWorkaroundKey {
            let value = record[key]
            
            if let reference = value as? CKRecord.Reference {
                if let object = findObject(for: reference.recordID) {
                    values[key] = object
                } else {
                    synchronizer.logger.log("noObject1: \(reference.recordID) for \(key)")
                    return nil
                }
            } else if let references = value as? [CKRecord.Reference] {
                var objects = [SDSSynchronizableContainer]()
                for reference in references {
                    if let container = findObject(for: reference.recordID) {
                        objects.append(container)
                    } else {
                        synchronizer.logger.log("noObject2: \(reference.recordID)")
                        return nil
                    }
                }
                values[key] = NSOrderedSet(array: objects)
            } else {
                values[key] = value
            }
        }
        
        return values
    }
    
    private func findObject(for recordID: CKRecord.ID) -> SDSSynchronizableContainer? {
        synchronizer.find(for: recordID.recordName)
    }
    
    private func retrieveObject(for record: CKRecord, preliminaryUpdateHandler: (SDSSynchronizableContainer?) -> Void) -> SDSSynchronizableContainer? {
        synchronizer.retrieve(
            for: record.recordID.recordName,
            entityName: record.recordType,
            context: context,
            preliminaryUpdateHandler: preliminaryUpdateHandler
        )
    }
    
    func deleted(recordID: CKRecord.ID, recordType:String) {
        context.performAndWaitUnchecked {
            self._deleted(recordID: recordID, recordType: recordType)
        }
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
        
        // Pending changes of a record that was deleted elsewhere can never be uploaded. Without its object,
        // an update couldn't be built, and a removal would delete a record that is gone.
        let syncContext = synchronizer.context
        syncContext.performAndWait {
            for entityName in ["CloudKitUpdate", "CloudKitRemoval"] {
                syncContext.metadataEntries(of: entityName, withIds: [recordID.recordName]).forEach(syncContext.delete)
            }
        }
        
        if let object = findObject(for: recordID) {
            object.delete()
        }
    }
    
    func tokensUpdate(
        for zoneID: CKRecordZone.ID,
        changeToken: CKServerChangeToken?,
        userToken: Data?
    ) {
        context.performAndWaitUnchecked {
            self._tokensUpdate(for: zoneID, changeToken: changeToken, userToken: userToken)
        }
    }
    
    func _tokensUpdate(
        for zoneID: CKRecordZone.ID,
        changeToken: CKServerChangeToken?,
        userToken: Data?,
        finalCompletion: Bool = false,
        fetchFailed: Bool = false
    ) {
        var lastNumberOfRecords: Int = 0
        while lastNumberOfRecords != recordsToAddLater.count {
            lastNumberOfRecords = recordsToAddLater.count
            
            let recordsToAddLater = self.recordsToAddLater
            self.recordsToAddLater = []
                
            for record in recordsToAddLater {
                self._changed(record: record)
            }
        }
        
        if finalCompletion {
            // The problem this solves is described in a huge comment above.
            for (container, reference) in objectsToEnsureParentReferencesFor {
                if let parent = findObject(for: reference.recordID)?.object,
                   !container.object.isDeleted,
                   container.parent != parent {
                    container.parent = parent
                }
            }
            objectsToEnsureParentReferencesFor = []
            
            let unresolvedRecords = recordsToAddLater.filter { isRecord($0, in: zoneID) }
            recordsToAddLater.removeAll { isRecord($0, in: zoneID) }
            
            if unresolvedRecords.isEmpty {
                synchronizer.logger.log("All current records added.")
            } else if fetchFailed {
                // The change token was not advanced past these records, so the next download fetches them again
                synchronizer.logger.log("Fetch failed with \(unresolvedRecords.count) unresolved records, retrying them with the next download")
            } else {
                synchronizer.logger.log("RecordsToAddLater not empty: \(unresolvedRecords.map(\.recordID))")
                
                assertionFailure("This should not happen in a shipping application. We will try to fix this up by deleting all records in question in a non-debug scenario.")
                
                let db = isForSharedDatabase ? synchronizer.cloudSharedDatabase : synchronizer.cloudPrivateDatabase
                db?.add(CKModifyRecordsOperation(recordIDsToDelete: unresolvedRecords.map(\.recordID)))
            }
        }
        
        // Records that still wait for their references were received before this token.
        // If the token was saved and the fetch failed before the references arrived, they would never be fetched again.
        if let changeToken = changeToken, !recordsToAddLater.contains(where: { isRecord($0, in: zoneID) }) {
            if isForSharedDatabase {
                tokensToUpdate[zoneID] = changeToken
            } else {
                tokensToUpdate[nil] = changeToken
            }
            synchronizer.logger.log("ChangeToken updated")
        }
    }
    
    private func isRecord(_ record: CKRecord, in zoneID: CKRecordZone.ID) -> Bool {
        // The private database only uses a single zone
        !isForSharedDatabase || record.recordID.zoneID == zoneID
    }
    
    func fetchCompletion(
        for zoneID: CKRecordZone.ID,
        result: Result<(serverChangeToken: CKServerChangeToken, clientChangeTokenData: Data?, moreComing: Bool), any Error>
    ) {
        switch result {
        case .success((let changeToken, let userToken, _)):
            synchronizer.logger.log("Zone \(zoneID.zoneName) fetch completed successfully")
            
            context.performAndWaitUnchecked {
                self._tokensUpdate(for: zoneID, changeToken: changeToken, userToken: userToken, finalCompletion: true)
            }
        case .failure(let error):
            synchronizer.logger.log("Zone \(zoneID.zoneName) fetch error: \(error)")
            
            context.performAndWaitUnchecked {
                self._tokensUpdate(for: zoneID, changeToken: nil, userToken: nil, finalCompletion: true, fetchFailed: true)
            }
        }
    }
    
    func fetchOverallCompletion(result: Result<Void, Error>) {
        let synchronizer = self.synchronizer!
        let syncContext = synchronizer.context
        
        synchronizer.logger.log("Fetch Overall Completion")
        
        guard let observedContext = synchronizer.observedUpdateContext else {
            synchronizer.logger.log("No observed context")
            completionHandler(SDSSyncError(title: "error.noObservedContext"))
            return
        }
        
        // Another process could have taken over while this one was suspended and downloaded the same records.
        // Saving them as well would duplicate them, so they are discarded and downloaded again later if needed.
        guard synchronizer.syncLease.renew() else {
            synchronizer.logger.log("Sync lease lost, discarding download")
            
            discardDownload(observedContext: observedContext)
            completionHandler(SDSSyncLease.UnavailableError())
            return
        }
        
        let saveError: (any Error)? = observedContext.performAndWait {
            do {
                try synchronizer.saveObservedUpdateContext(observedContext)
                return nil
            } catch {
                return error
            }
        }
        if let saveError {
            synchronizer.logger.log("Observed Context save error: \(saveError)")
            
            let isFixed = observedContext.performAndWaitUnchecked {
                tryFixingObservedContext(error: saveError)
            }
            if isFixed {
                synchronizer.logger.log("Succeeded trying to fix save errors. Trying to save again.")
                fetchOverallCompletion(result: result)
            } else {
                // The unsaved objects would fail every later save of the context, and their placeholders must not be saved.
                // The change tokens weren't saved either, so the records are downloaded again.
                synchronizer.logger.log("Failed fixing the save errors, discarding download")
                discardDownload(observedContext: observedContext)
                completionHandler(saveError)
            }
            
            return
        }
        
        let tokensToUpdate = self.tokensToUpdate
        self.tokensToUpdate = [:]
        
        do {
            try syncContext.performAndWaitUnchecked {
                // The objects have permanent IDs once they are saved
                for (object, container) in synchronizer.temporaryObjectContainers {
                    if object.objectID.isTemporaryID {
                        // E.g. an object that was deleted to fix a failed save
                        container.delete()
                    } else {
                        container.localId = object.objectID.uriRepresentation().absoluteString
                    }
                }
                synchronizer.temporaryObjectContainers = [:]
                
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
            completionHandler(error)
            return
        }
        
        switch result {
        case .success:
            synchronizer.logger.log("Database fetch completed successfully")
            completionHandler(nil)
        case .failure(let error):
            synchronizer.logger.log("Database fetch completed with error: \(error)")
            completionHandler(error)
        }
    }
    
    /// Discards the downloaded objects and their placeholders, and doesn't save the change tokens, so the records are downloaded again.
    private func discardDownload(observedContext: NSManagedObjectContext) {
        let synchronizer = self.synchronizer!
        let syncContext = synchronizer.context
        
        observedContext.performAndWait {
            observedContext.rollback()
        }
        syncContext.performAndWait {
            for container in synchronizer.temporaryObjectContainers.values {
                container.delete()
            }
            synchronizer.temporaryObjectContainers = [:]
        }
        tokensToUpdate = [:]
        objectsToEnsureParentReferencesFor = []
        recordsToAddLater = []
    }
    
    /// Tries fixing the given error and returns whether the context should try to save again or a fix was not possible.
    /// Has to be called on `context`'s queue.
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
        
        guard nsError.code == NSValidationMissingMandatoryPropertyError else {
            synchronizer.logger.log("tryFixingObservedContext: Code not correct: \(nsError.code, privacy: .public)")
            return false
        }
        
        guard let object = nsError.userInfo[NSValidationObjectErrorKey] as? NSManagedObject else {
            let keys = nsError.userInfo.keys.joined(separator: ", ")
            synchronizer.logger.log("tryFixingObservedContext: No error object: \(keys, privacy: .public)")
            return false
        }
        
        guard let container = object.synchronizableContainer else {
            synchronizer.logger.log("tryFixingObservedContext: Object is not a synchronizable object: \(object.entity.name ?? "Unknown")")
            return false
        }
        
        // Delete CloudKit entry
        let db = isForSharedDatabase ? synchronizer.cloudSharedDatabase : synchronizer.cloudPrivateDatabase
        db?.add(CKModifyRecordsOperation(recordIDsToDelete: [container.recordId]))
        
        // Delete object and reference
        container.delete()
        
        synchronizer.logger.log("tryFixingObservedContext: Fixed object by deleting: \(object.entity.name ?? "Unknown")")
        
        return true
    }
}

extension CKAsset {
    convenience init(data: Data) throws {
        let tempURL = URL.cachesDirectory.appending(component: UUID().uuidString, directoryHint: .notDirectory)
        try data.write(to: tempURL)
        
        self.init(fileURL: tempURL)
    }
}
