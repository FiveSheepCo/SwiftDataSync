import Foundation
import CoreData
import CloudKit
import OSLog

extension SDSSynchronizer {
    
    func download() async throws {
        try await _download()
        
        try await refreshSharedZoneIDs()
        
        try await self._download(sharedDatabase: true)
    }
    
    private func refreshSharedZoneIDs() async throws {
        // CloudKit shared zones always have the zoneName of the private zone that originally shared it. That said, all shared zones should always have the name of the default zone.
        let ids = try await cloudSharedDatabase.allRecordZones().map(\.zoneID).filter({ $0.zoneName == defaultZoneID.zoneName })
        
        let context = self.context
        self.context.performAndWait {
            for id in ids {
                CloudKitZone.getZone(with: id, context: context)
            }
        }
    }
    
    private func _download(sharedDatabase: Bool = false) async throws {
        logger.log("Starting Download of \(sharedDatabase ? "shared" : "private") database")
        
        var configurations: [CKRecordZone.ID : CKFetchRecordZoneChangesOperation.ZoneConfiguration] = [:]
        
        if sharedDatabase {
            context.performAndWait {
                let zones = CloudKitZone.getAll()
                for savedZone in zones {
                    configurations[savedZone.calculatedId] = CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: savedZone.changeToken)
                }
            }
            
            if configurations.isEmpty {
                logger.log("No zones in shared database")
                return
            }
        } else {
            context.performAndWait {
                let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: savedState.changeToken)
                
                configurations = [defaultZoneID: options]
            }
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

private class CKDownloadHandler {
    
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
        context.performAndWait {
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
                
                let type = object.entity.attributesByName[key]?.type
                if let value = value as? SDSSynchronizableContainer {
                    object.setValue(value.object, forKey: key)
                } else if let asset = value as? CKAsset {
                    let data = asset.fileURL.map({ try! Data(contentsOf: $0) })
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
        context.performAndWait {
            self._deleted(recordID: recordID, recordType: recordType)
        }
    }
    
    func _deleted(recordID: CKRecord.ID, recordType:String) {
        if let object = findObject(for: recordID) {
            object.delete()
        }
    }
    
    func tokensUpdate(
        for zoneID: CKRecordZone.ID,
        changeToken: CKServerChangeToken?,
        userToken: Data?
    ) {
        context.performAndWait {
            self._tokensUpdate(for: zoneID, changeToken: changeToken, userToken: userToken)
        }
    }
    
    func _tokensUpdate(
        for zoneID: CKRecordZone.ID,
        changeToken: CKServerChangeToken?,
        userToken: Data?,
        finalCompletion: Bool = false
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
        
        if let changeToken = changeToken {
            if isForSharedDatabase {
                tokensToUpdate[zoneID] = changeToken
            } else {
                tokensToUpdate[nil] = changeToken
            }
            synchronizer.logger.log("ChangeToken updated")
        }
        
        guard finalCompletion else { return }
        
        // The problem this solves is described in a huge comment above.
        for (container, reference) in objectsToEnsureParentReferencesFor {
            if let parent = findObject(for: reference.recordID)?.object,
               !container.object.isDeleted,
               container.parent != parent {
                container.parent = parent
            }
        }
        objectsToEnsureParentReferencesFor = []
        
        if !recordsToAddLater.isEmpty {
            synchronizer.logger.log("RecordsToAddLater not empty!")
            
            assertionFailure("This should not happen in a shipping application. We will try to fix this up by deleting all records in question in a non-debug scenario.")
            
            let db = isForSharedDatabase ? synchronizer.cloudSharedDatabase : synchronizer.cloudPrivateDatabase
            db?.add(CKModifyRecordsOperation(recordIDsToDelete: recordsToAddLater.map(\.recordID)))
        } else {
            synchronizer.logger.log("All current records added.")
        }
    }
    
    func fetchCompletion(
        for zoneID: CKRecordZone.ID,
        result: Result<(serverChangeToken: CKServerChangeToken, clientChangeTokenData: Data?, moreComing: Bool), any Error>
    ) {
        switch result {
        case .success((let changeToken, let userToken, _)):
            synchronizer.logger.log("Zone \(zoneID.zoneName) fetch completed successfully")
            
            context.performAndWait {
                self._tokensUpdate(for: zoneID, changeToken: changeToken, userToken: userToken, finalCompletion: true)
            }
        case .failure(let error):
            synchronizer.logger.log("Zone \(zoneID.zoneName) fetch error: \(error)")
            
            context.performAndWait {
                self._tokensUpdate(for: zoneID, changeToken: nil, userToken: nil, finalCompletion: true)
            }
        }
    }
    
    func fetchOverallCompletion(result: Result<Void, Error>) {
        synchronizer.logger.log("Fetch Overall Completion")
        
        guard let observedContext = synchronizer.observedUpdateContext else {
            synchronizer.logger.log("No observed context")
            completionHandler(SDSSyncError(title: "error.noObservedContext"))
            return
        }
        
        do { try observedContext.save() }
        catch {
            synchronizer.logger.log("Observed Context save error: \(error)")
            
            if tryFixingObservedContext(error: error) {
                synchronizer.logger.log("Succeeded trying to fix save errors. Trying to save again.")
                fetchOverallCompletion(result: result)
            } else {
                synchronizer.logger.log("Failed fixing the save errors")
                completionHandler(error)
            }
            
            return
        }
        
        for (object, container) in synchronizer.temporaryObjectContainers {
            container.localId = object.objectID.uriRepresentation().absoluteString
        }
        synchronizer.temporaryObjectContainers = [:]
        
        for (zoneID, changeToken) in tokensToUpdate {
            if let zoneID {
                CloudKitZone.getZone(with: zoneID, context: synchronizer.context).changeToken = changeToken
            } else {
                synchronizer.savedState.changeToken = changeToken
            }
        }
        tokensToUpdate = [:]
        
        do { try synchronizer.context.save() }
        catch {
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
    
    /// Tries fixing the given error and returns whether the context should try to save again or a fix was not possible.
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
        db?.add(CKModifyRecordsOperation(recordIDsToDelete: recordsToAddLater.map(\.recordID)))
        
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
