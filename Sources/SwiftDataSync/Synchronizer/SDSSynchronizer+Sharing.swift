import CoreData
import SwiftData
import CloudKit

let staticShareExtension = "-Share"

extension SDSSynchronizer {
    
    public func share(
        title: String,
        imageData: Data?,
        model: any PersistentModel
    ) async throws -> URL {
        let rep = try JSONDecoder().decode(PersistentIdentifierRepresentation.self, from: JSONEncoder().encode(model.persistentModelID))
        
        guard
            let id = observedUpdateContext?.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: rep.implementation.uriRepresentation)!),
            let object = observedUpdateContext?.object(with: id)
        else {
            throw SDSSyncError(title: "share.error.couldNotFindObject")
        }
        
        return try await share(title: title, imageData: imageData, object: object)
    }
    
    public func share(
        title: String,
        imageData: Data?,
        object: NSManagedObject
    ) async throws -> URL {
        guard let container = container(for: object) as? SDSSharableContainer else {
            throw SDSSyncError(title: "share.error.objectIsNotSharable")
        }
        
        let share = try await save(
            sharable: container,
            title: title,
            imageData: imageData
        )
        
        return share.url!
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
            operation.perRecordSaveBlock = { [weak self] recordIDs, result in
                guard let self else { return }
                
                switch result {
                case .success(let record):
                    if let share = record as? CKShare {
                        logger.log("Saved Share successfully")
                        self.context.perform {
                            CloudKitShare.updateShare(share, for: id.recordName, context: self.context)
                            continuation.resume(returning: share)
                        }
                    }
                case .failure(let error):
                    logger.log("Save error: \(error.localizedDescription)")
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
            try self.context.save()
            
            Task {
                await viewModel.set(state: .idle)
                
                self.forceDownload() // TODO(later): return new root object
            }
        }
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
