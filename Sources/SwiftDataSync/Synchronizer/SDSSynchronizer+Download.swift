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
    
    /// - Parameter refreshingSharedZones: Whether the shared zones have to be refreshed, which `synchronize()` usually did before uploading already.
    func download(refreshingSharedZones: Bool = true) async throws {
        // Downloads skip models and keys this version doesn't synchronize, e.g. ones a newer version added, while their change
        // tokens move on. Once more is synchronized, they are caught up on by downloading every record once more.
        let catchUp = pendingCatchUp
        let scope = DownloadScope.all(catchUpIsPending: catchUp != nil)
        
        try await _download(scope: scope)
        try checkNotStopped()

        if refreshingSharedZones {
            try await refreshSharedZoneIDs()
        }

        try await self._download(sharedDatabase: true, scope: scope)

        // Extensions can have little memory and time, so the app catches up
        let isAppExtension = Bundle.main.bundleURL.pathExtension == "appex"
        if let catchUp, !isAppExtension, catchUp.retryDate.map({ $0 <= .now }) ?? true {
            try checkNotStopped()
            logger.log("More models or keys are synchronized than before, catching up on them")
            do {
                // The change tokens are kept, as downloading every record doesn't include deletions, which would then be missed
                try await _download(scope: .catchingUp(on: catchUp.newKeys))
                try await _download(sharedDatabase: true, scope: .catchingUp(on: catchUp.newKeys))

                // Local values of the newly synchronized keys were never uploaded, so records leave them out. Once caught up,
                // a record leaving out a key clears it (see `SDSValueCoding.clearedValues`), so they're uploaded first.
                // Until then, downloads leave them alone, as they're local changes.
                uploadLocalObjects(keysByEntity: keysByEntity(catchUp.newKeys))
                finishCatchUp(catchUp)
                // They're uploaded by the next synchronization
                startSync()
            } catch {
                // The synchronization itself succeeded
                logger.log("Failed to catch up, retrying later: \(error.localizedDescription)")
                postponeCatchUp(until: .now.addingTimeInterval(catchUpRetryDelay))
                
                // Nothing else might start a synchronization by then
                startTask(at: \.catchUpRetry) {
                    try? await Task.sleep(for: .seconds(catchUpRetryDelay))
                    
                    self.finishTask(at: \.catchUpRetry)
                    self.startSync()
                }
                return
            }

            // Records were held back if they reference records only the catch-up downloaded.
            // Their zones' change tokens weren't saved, so they are downloaded again now.
            try await _download(scope: .all(catchUpIsPending: false))
            try await _download(sharedDatabase: true, scope: .all(catchUpIsPending: false))
        }
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
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let handler = CKDownloadHandler(synchronizer: self, forSharedDatabase: sharedDatabase, scope: scope) { [weak self] error in
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
        
        return keys.flatMap { key -> [CKRecord.FieldKey] in
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard let entity = model.entitiesByName[parts[0]] else { return [] }
            let propertyNames = parts.count == 2 ? [parts[1]] : configuration.entities[parts[0]]?.syncedProperties ?? []
            return propertyNames.map { entity.propertiesByName[$0]?.renamingIdentifier ?? $0 }
        }
    }
}

private final class CKDownloadHandler {
    
    var recordsToAddLater: [CKRecord] = []
    var objectsToEnsureParentReferencesFor: [(container: SDSSynchronizableContainer, reference: CKRecord.Reference)] = []
    
    weak var synchronizer: SDSSynchronizer!
    weak var context: NSManagedObjectContext!
    private var tokensToUpdate: [CKRecordZone.ID?: CKServerChangeToken] = [:]
    /// Records this download deletes. Their metadata is only removed once the download is saved, as discarding it restores their objects.
    private var deletedRecordIds: Set<String> = []
    /// Keeps a record from being stored incompletely. The download is discarded, so the record is downloaded again.
    private var applyError: (any Error)?
    let isForSharedDatabase: Bool
    /// The models and keys that are stored.
    let scope: DownloadScope
    /// Whether the change tokens are saved, which a catch-up doesn't do, as it doesn't include deletions.
    var savesChangeTokens: Bool { !scope.isCatchingUp }
    /// Zones whose change tokens aren't saved, as their records with missing references are downloaded again later.
    private var zonesWithHeldRecords: Set<CKRecordZone.ID> = []
    /// Zones whose change tokens expired. Their tokens are reset once the download is saved, see `SDSSynchronizer.ChangeTokenExpiredError`.
    private var zonesWithExpiredTokens: Set<CKRecordZone.ID> = []
    /// The error if the zone of the private database is gone, see `SDSSynchronizer.PrivateZoneMissingError`.
    private var privateZoneError: CKError?
    /// The local entities of the downloaded objects, which are removed if the download is discarded.
    private var createdLocalEntities: [CloudKitLocalEntity] = []
    let completionHandler: (Error?) -> Void
    
    init(synchronizer: SDSSynchronizer, forSharedDatabase: Bool, scope: DownloadScope, completionHandler: @escaping (Error?) -> Void) {
        self.synchronizer = synchronizer
        self.context = synchronizer.observedUpdateContext
        
        self.isForSharedDatabase = forSharedDatabase
        self.scope = scope
        self.completionHandler = completionHandler
    }
    
    func changed(recordId: CKRecord.ID, result: Result<CKRecord, any Error>) {
        guard case .success(let record) = result else {
            // E.g. an asset of the record couldn't be downloaded. Saving the zone's change token would skip the record
            // until it changes again, so the token is kept and the zone's changes are downloaded again later.
            // The operation's callbacks run one after another, like the other accesses of the handler's state.
            synchronizer.logger.error("Failed to download `\(recordId.recordName)`, downloading it again later: \(String(describing: result))")
            zonesWithHeldRecords.insert(recordId.zoneID)
            return
        }

        synchronizer.logger.log("[Download] Changed: \(record)")
        context.performAndWaitUnchecked {
            self._changed(record: record)
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
            return
        }

        // Make sure dependent objects exist, and prefill all values if they do
        guard var kVPs = self.valuesIfAllReferencesExist(for: record, entity: entity, syncedKeys: entityConfiguration.syncedProperties) else {
            self.recordsToAddLater.append(record)
            return
        }

        // Local changes that weren't uploaded yet win, as they are uploaded over the record next. E.g. a change saved after
        // the upload this download follows would otherwise be overwritten with the uploaded value, which is then uploaded again.
        // A catch-up also downloads every record rather than the ones that changed since, with values older than local changes.
        let pendingChange = synchronizer.pendingLocalChange(of: record.recordID.recordName)
        guard !pendingChange.isRemoved else {
            // The object was deleted locally, which is uploaded next
            synchronizer.logger.log("Skipping record `\(record.recordID.recordName)`, which was deleted locally")
            return
        }
        if !pendingChange.keys.isEmpty {
            kVPs = kVPs.filter { rawKey, _ in !pendingChange.keys.contains(findCorrespondingKey(entity: entity, rawKey: rawKey)) }
        }
        if case .all = scope {
            kVPs.merge(clearedValues(of: record, entity: entity, syncedKeys: entityConfiguration.syncedProperties, pendingKeys: pendingChange.keys)) { current, _ in current }
        }

        let insertsObject = scope.insertsObjects(of: record.recordType)
        if scope.isCatchingUp {
            guard !kVPs.isEmpty || insertsObject else { return }
        }

        guard let container = retrieveObject(for: record, insertingIfMissing: insertsObject, preliminaryUpdateHandler: { container in
            guard let container else { return }

            let object = container.object
            for (rawKey, value) in kVPs {
                guard rawKey != SDSSynchronizer.Constants.parentWorkaroundKey else { continue }

                let key = findCorrespondingKey(entity: object.entity, rawKey: rawKey)
                // This is needed to exclude keys that are excluded but were synced before. Otherwise they will be synced again.
                guard container.syncKeys.contains(key) else { continue }

                let attribute = object.entity.attributesByName[key]
                let type = attribute?.type
                if let value = value as? SDSSynchronizableContainer {
                    object.setValue(value.object, forKey: key)
                } else if let asset = value as? CKAsset {
                    let data: Data?
                    do {
                        data = try asset.fileURL.map { try Data(contentsOf: $0) }
                    } catch {
                        // Storing the record without it would lose the value, or fail the save of a new object
                        synchronizer.logger.error("Failed reading asset for key `\(object.entity.name ?? "")`.`\(key)`: \(error.localizedDescription)")
                        applyError = error
                        continue
                    }
                    object.setValue(data, forKey: key)
                } else if let attribute, value is Data || value is String {
                    // E.g. transformed values, `Codable` values, URLs and UUIDs, see `SDSValueCoding`
                    do {
                        object.setValue(try SDSValueCoding.localValue(for: value, attribute: attribute), forKey: key)
                    } catch {
                        synchronizer.logger.error("Failed setting the value of `\(object.entity.name ?? "")`.`\(key)`: \(String(describing: error))")
                    }
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

        if
            let reference = record.parent,
            container.parentKey.map({ scope.includes(entity: record.recordType, key: $0) && !pendingChange.keys.contains($0) }) ?? true
        {
            // The parent is set once every record of the download is stored, as it might be downloaded after this record.
            // This also restores the parent of an object that a parent's ordered relationship lost when two devices added
            // an object at the same time.
            objectsToEnsureParentReferencesFor.append((container, reference))
        }
    }

    /// See `SDSValueCoding.clearedValues(of:entity:syncedKeys:excludedKeys:catchUpKeys:)`.
    private func clearedValues(of record: CKRecord, entity: NSEntityDescription, syncedKeys: [String], pendingKeys: Set<String>) -> [String: Any?] {
        SDSValueCoding.clearedValues(
            of: record,
            entity: entity,
            syncedKeys: syncedKeys,
            excludedKeys: pendingKeys,
            catchUpKeys: synchronizer.pendingCatchUp?.newKeys ?? []
        )
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

    private func valuesIfAllReferencesExist(for record: CKRecord, entity: NSEntityDescription, syncedKeys: [String]) -> [String: Any?]? {
        var values = [String: Any?]()

        // Keys added by a newer version of the app aren't stored by this one. Their references might never be found,
        // which would keep the record from being stored.
        let isKnownKey = { (key: String) in
            entity.propertiesByName[key] != nil || entity.properties.contains { $0.renamingIdentifier == key }
        }
        // Keys that this process doesn't synchronize aren't stored either, e.g. a relationship to a model that an extension
        // doesn't synchronize, whose objects it would never find.
        // Keys outside of the download's scope are stored by another download, so their references don't have to exist yet
        let isStored = { (key: String) in
            let correspondingKey = self.findCorrespondingKey(entity: entity, rawKey: key)
            return syncedKeys.contains(correspondingKey) && self.scope.includes(entity: entity.name ?? "", key: correspondingKey)
        }

        for key in record.allKeys() where key != SDSSynchronizer.Constants.parentWorkaroundKey && isKnownKey(key) && isStored(key) {
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
        insertingIfMissing: Bool,
        preliminaryUpdateHandler: (SDSSynchronizableContainer?) -> Void
    ) -> SDSSynchronizableContainer? {
        guard insertingIfMissing else {
            // An object with only some of its keys would be incomplete
            let container = findObject(for: record.recordID)
            preliminaryUpdateHandler(container)
            return container
        }
        
        // A record of an entity with an identity can belong to a local object that has no record yet
        var identityValues: [Any?]?
        if
            let identity = synchronizer.configuration?.entities[record.recordType]?.identity,
            !identity.isEmpty,
            let entity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[record.recordType]
        {
            identityValues = SDSIdentity.values(in: record, entity: entity, keys: identity)
        }
        
        do {
            return try synchronizer.retrieve(
                for: record.recordID.recordName,
                entityName: record.recordType,
                identityValues: identityValues,
                context: context,
                preliminaryUpdateHandler: preliminaryUpdateHandler
            )
        } catch {
            synchronizer.logger.error("Failed to look up `\(record.recordID.recordName)`: \(error.localizedDescription)")
            applyError = error
            return nil
        }
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
            } else if !savesChangeTokens {
                // A catch-up downloads every record, also ones whose references were deleted long ago. They stay as they are.
                synchronizer.logger.log("Leaving \(unresolvedRecords.count) records with unresolved references alone while catching up")
            } else if case .all(catchUpIsPending: true) = scope {
                // They might reference records of newly synchronized models, which only the pending catch-up downloads.
                // The change token isn't saved, so they are downloaded again.
                synchronizer.logger.log("Retrying \(unresolvedRecords.count) unresolved records once newly synchronized models are caught up on")
                zonesWithHeldRecords.insert(zoneID)
            } else if applyError != nil {
                // Their references might only be missing because they couldn't be read, and the download is discarded
                synchronizer.logger.log("Failed to apply records, retrying \(unresolvedRecords.count) unresolved records with the next download")
            } else {
                // E.g. they reference a record that was deleted. They are stored once they change again.
                // They stay in iCloud: deleting them would delete them on every device, also where they are complete.
                synchronizer.logger.error("Leaving \(unresolvedRecords.count) records with unresolved references alone: \(unresolvedRecords.map(\.recordID.recordName))")
            }
        }
        
        // Records that still wait for their references were received before this token.
        // If the token was saved and the fetch failed before the references arrived, they would never be fetched again.
        if let changeToken = changeToken, savesChangeTokens, !zonesWithHeldRecords.contains(zoneID), !recordsToAddLater.contains(where: { isRecord($0, in: zoneID) }) {
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

            switch (error as? CKError)?.code {
            case .changeTokenExpired?:
                zonesWithExpiredTokens.insert(zoneID)
            case .zoneNotFound?, .userDeletedZone?:
                // Zones of the shared database disappear when they are no longer shared, see `refreshSharedZoneIDs()`
                if !isForSharedDatabase {
                    privateZoneError = error as? CKError
                }
            default:
                break
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
        
        if let applyError {
            synchronizer.logger.log("Failed to apply downloaded records, discarding download: \(applyError.localizedDescription)")
            discardDownload(observedContext: observedContext)
            completionHandler(applyError)
            return
        }
        
        // Objects that were changed locally while downloading keep their changes, which would otherwise be overwritten with
        // the downloaded values. They're uploaded next, and the next download brings the record's other values again.
        // A catch-up downloads every record, which can take long, and it's done again later, after they're uploaded.
        let hasLocalChanges = observedContext.performAndWaitUnchecked {
            var hasLocalChanges = false
            for object in observedContext.updatedObjects {
                guard let id = synchronizer.container(for: object)?.id else { continue }
                if !synchronizer.pendingLocalChange(of: id).keys.isDisjoint(with: object.changedValues().keys) {
                    observedContext.refresh(object, mergeChanges: false)
                    hasLocalChanges = true
                }
            }
            return hasLocalChanges
        }

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
            completionHandler(permanentIdError)
            return
        }
        syncContext.performAndWaitUnchecked {
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
        let deletedRecordIds = Array(self.deletedRecordIds)
        self.deletedRecordIds = []
        
        let zonesWithExpiredTokens = self.zonesWithExpiredTokens
        let isForSharedDatabase = self.isForSharedDatabase

        do {
            try syncContext.performAndWaitUnchecked {
                // The downloaded objects' local entities were made before saving them
                synchronizer.removeAllTemporaryObjects()
                createdLocalEntities = []

                for entityName in ["CloudKitUpdate", "CloudKitRemoval", "CloudKitLocalEntity"] {
                    syncContext.metadataEntries(of: entityName, withIds: deletedRecordIds).forEach(syncContext.delete)
                }

                for (zoneID, changeToken) in tokensToUpdate {
                    if let zoneID {
                        CloudKitZone.getZone(with: zoneID, context: syncContext).changeToken = changeToken
                    } else {
                        synchronizer.setState(\.changeToken, value: changeToken)
                    }
                }

                // These zones are downloaded completely next, see `SDSSynchronizer.ChangeTokenExpiredError`
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

        if let privateZoneError {
            completionHandler(SDSSynchronizer.PrivateZoneMissingError(error: privateZoneError))
            return
        }
        if !zonesWithExpiredTokens.isEmpty {
            completionHandler(SDSSynchronizer.ChangeTokenExpiredError())
            return
        }

        switch result {
        case .success where hasLocalChanges && scope.isCatchingUp:
            synchronizer.logger.log("Database fetch completed, but objects changed locally meanwhile")
            completionHandler(SDSSyncError(title: "error.changedWhileCatchingUp"))
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
        let createdLocalEntities = self.createdLocalEntities
        self.createdLocalEntities = []
        syncContext.performAndWaitUnchecked {
            synchronizer.removeAllTemporaryObjects()
            // They can be saved already, e.g. with changes that were stored meanwhile
            guard !createdLocalEntities.isEmpty else { return }
            createdLocalEntities.forEach(syncContext.delete)
            do {
                try syncContext.save()
            } catch {
                synchronizer.logger.error("Failed to remove the local entities of a discarded download: \(error.localizedDescription)")
            }
        }
        tokensToUpdate = [:]
        deletedRecordIds = []
        applyError = nil
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
        
        // The record stays in iCloud, as deleting it would delete it on every device. A required value is missing e.g. because
        // it isn't synchronized (see `makeConfiguration`), or a newer version of the app made it required.
        if object.isInserted {
            // The object isn't stored, nor its local entity once the download is saved. It's stored once its record changes again.
            context.delete(object)
            deletedRecordIds.insert(container.id)
            synchronizer.logger.error("tryFixingObservedContext: Not storing a downloaded `\(object.entity.name ?? "Unknown")` without required values")
        } else {
            // The object keeps its saved values instead of the downloaded ones
            context.refresh(object, mergeChanges: false)
            synchronizer.logger.error("tryFixingObservedContext: Not storing downloaded values without required values of `\(object.entity.name ?? "Unknown")`")
        }

        return true
    }
}
