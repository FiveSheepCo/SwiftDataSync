import CoreData
import SwiftData
import CloudKit

let staticShareExtension = "-Share"

extension SDSSynchronizer {
    
    /// The CloudKit container that is synced, for example to present a `UICloudSharingController`.
    public var cloudKitContainer: CKContainer {
        cloudContainer
    }
    
    /// Shares the model, or returns the URL of its existing share.
    public func share(
        title: String,
        imageData: Data?,
        model: any PersistentModel
    ) async throws -> URL {
        try await share(title: title, imageData: imageData, modelID: model.persistentModelID)
    }
    
    /// Shares the model with the given identifier, or returns the URL of its existing share.
    ///
    /// Unlike models, identifiers are `Sendable`, so this can be called from any isolation.
    public func share(
        title: String,
        imageData: Data?,
        modelID: PersistentIdentifier
    ) async throws -> URL {
        try await share(title: title, imageData: imageData, object: managedObject(for: modelID))
    }
    
    /// Shares the object, or returns the URL of its existing share.
    public func share(
        title: String,
        imageData: Data?,
        object: NSManagedObject
    ) async throws -> URL {
        guard let container = container(for: object) as? SDSSharableContainer else {
            throw SDSSyncError(title: "share.error.objectIsNotSharable")
        }
        
        let share: CKShare
        if let existing = container.share {
            share = existing
        } else {
            share = try await save(sharable: container, title: title, imageData: imageData)
        }
        
        guard let url = share.url else {
            throw SDSSyncError(title: "share.error.noURL")
        }
        return url
    }
    
    /// Whether the model is shared, and by whom.
    public func shareState(for model: any PersistentModel) -> SDSShareState {
        (try? sharableContainer(for: model))?.shareState ?? .none
    }
    
    /// The model's share, if it is shared.
    public func existingShare(for model: any PersistentModel) -> CKShare? {
        (try? sharableContainer(for: model))?.share
    }
    
    /// Stores a share that was changed outside of the synchronizer, for example by a `UICloudSharingController`.
    public func didSaveShare(_ share: CKShare, for model: any PersistentModel) throws {
        let id = try sharableContainer(for: model).id
        let context = self.context
        try context.performAndWait {
            CloudKitShare.updateShare(share, for: id, context: context)
            try context.save()
        }
    }
    
    /// Handles a share that ended outside of the synchronizer, for example in a `UICloudSharingController`.
    ///
    /// If the current user owned the share, the model stays. If someone else shared it with the current user,
    /// they left the share, so the local copy of the model is removed without deleting it in iCloud.
    public func didStopSharing(for model: any PersistentModel) throws {
        let container = try sharableContainer(for: model)
        let wasSharedByOther = container.shareState == .sharedByOther
        let id = container.id
        
        let context = self.context
        try context.performAndWait {
            CloudKitShare.updateShare(nil, for: id, context: context)
            try context.save()
        }
        
        if wasSharedByOther {
            removeLocalCopy(of: container)
        }
    }
    
    /// Removes a shared object and its children locally, without uploading the deletion.
    func removeLocalCopy(of container: SDSSynchronizableContainer) {
        // Deletions in the observed update context are not uploaded.
        container.delete()
        observedUpdateContext?.performAndWait {
            do {
                try observedUpdateContext?.save()
            } catch {
                logger.log("Failed to remove local copy of shared object: \(error.localizedDescription)")
            }
        }
    }
    
    private func managedObject(for model: any PersistentModel) throws -> NSManagedObject {
        try managedObject(for: model.persistentModelID)
    }
    
    private func managedObject(for modelID: PersistentIdentifier) throws -> NSManagedObject {
        let rep = try JSONDecoder().decode(PersistentIdentifierRepresentation.self, from: JSONEncoder().encode(modelID))
        
        guard
            let url = URL(string: rep.implementation.uriRepresentation),
            let id = observedUpdateContext?.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
            let object = observedUpdateContext?.object(with: id)
        else {
            throw SDSSyncError(title: "share.error.couldNotFindObject")
        }
        
        return object
    }
    
    private func sharableContainer(for model: any PersistentModel) throws -> SDSSharableContainer {
        guard let container = container(for: try managedObject(for: model)) as? SDSSharableContainer else {
            throw SDSSyncError(title: "share.error.objectIsNotSharable")
        }
        return container
    }
    
    func save(
        sharable: SDSSharableContainer,
        title: String,
        imageData: Data?
    ) async throws -> CKShare {
        logger.log("Saving Share")
        
        let id = sharable.recordId
        let record = CKRecord(recordType: sharable.object.entity.name!, recordID: id)
        let shareId = CKRecord.ID(recordName: "\(id.recordName)\(staticShareExtension)", zoneID: SDSSynchronizer.shared.defaultZoneID)
        let share = CKShare(rootRecord: record, shareID: shareId)
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = title
        share[CKShare.SystemFieldKey.thumbnailImageData] = imageData
        
        let operation = CKModifyRecordsOperation(recordsToSave: [record, share], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        
        return try await withCheckedThrowingContinuation { continuation in
            // Both the root record and the share report a result, but the continuation must only resume once.
            // The operation's callbacks run serially, so this doesn't need a lock.
            nonisolated(unsafe) var didResume = false
            
            operation.perRecordSaveBlock = { [weak self] recordID, result in
                guard let self, !didResume else { return }
                
                switch result {
                case .success(let record):
                    if let share = record as? CKShare {
                        logger.log("Saved Share successfully")
                        didResume = true
                        let context = self.context
                        self.context.perform {
                            CloudKitShare.updateShare(share, for: id.recordName, context: context)
                            continuation.resume(returning: share)
                        }
                    }
                case .failure(let error):
                    logger.log("Save error: \(error.localizedDescription)")
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }
            
            operation.modifyRecordsResultBlock = { result in
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success:
                    continuation.resume(throwing: SDSSyncError(title: "share.error.notSaved"))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            self.cloudPrivateDatabase.add(operation)
        }
    }
    
    func waitForIdle() async {
        while case .idle = await viewModel.state {
            try! await Task.sleep(for: .seconds(1))
        }
    }
    
    public func acceptShare(with metadata: CKShare.Metadata) async throws {
        guard metadata.share.recordID.zoneID.zoneName == defaultZoneID.zoneName else {
            fatalError() // This should not be possible
        }
        
        let acceptSharesOperation = CKAcceptSharesOperation(shareMetadatas: [metadata])
        
        let share = try await withCheckedThrowingContinuation { continuation in
            acceptSharesOperation.perShareResultBlock = { metadata, result in
                switch result {
                case .success(let share):
                    self.logger.log("Share accepted: \(share)")
                    
                    continuation.resume(returning: share)
                case .failure(let error):
                    self.logger.log("Share could not be accepted: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
            
            cloudContainer.add(acceptSharesOperation)
        }
        
        await viewModel.waitForIdle(setting: .savingShare)
        
        let context = self.context
        try context.performAndWait {
            CloudKitZone.getZone(with: share.recordID.zoneID, context: context)
            try context.save()
        }
        
        await viewModel.set(state: .idle)
        
        self.forceDownload() // TODO(later): return new root object
    }
}

private struct PersistentIdentifierRepresentation: Codable {
    struct Implementation: Codable {
        let primaryKey: String
        let entityName: String
        let uriRepresentation: String
        let isTemporary: Bool
        let storeIdentifier: String?
    }
    
    let implementation: Implementation
}
