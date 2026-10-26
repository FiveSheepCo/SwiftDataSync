import CloudKit
import CoreData
import Foundation
import SwiftData

/// Existing CloudKit records, shares and pending changes for models that were created outside of the synchronizer,
/// e.g. when migrating from another sync engine that used the same record format.
public struct SDSAdoption: Sendable {
    
    /// A model that already has a record in CloudKit.
    public struct Record: Sendable {
        /// The model's identifier. It must be permanent, so the model has to be saved before.
        public var modelID: PersistentIdentifier
        /// The name of the model's existing record.
        public var recordName: String
        /// Keys that changed locally but weren't uploaded yet. They are uploaded with the next synchronization.
        public var pendingKeys: [String]
        /// The shared zone the record is in, if it belongs to a share of another user.
        public var sharedZoneID: CKRecordZone.ID?
        
        public init(modelID: PersistentIdentifier, recordName: String, pendingKeys: [String] = [], sharedZoneID: CKRecordZone.ID? = nil) {
            self.modelID = modelID
            self.recordName = recordName
            self.pendingKeys = pendingKeys
            self.sharedZoneID = sharedZoneID
        }
    }
    
    /// A record that was deleted locally but not in CloudKit yet.
    public struct Removal: Sendable {
        public var recordName: String
        public var sharedZoneID: CKRecordZone.ID?
        
        public init(recordName: String, sharedZoneID: CKRecordZone.ID? = nil) {
            self.recordName = recordName
            self.sharedZoneID = sharedZoneID
        }
    }
    
    /// The share of a root record, shared by the current user or with them.
    public struct Share: @unchecked Sendable {
        public var rootRecordName: String
        // `CKShare` isn't marked `Sendable`, but it's only read after being handed over.
        public var share: CKShare
        
        public init(rootRecordName: String, share: CKShare) {
            self.rootRecordName = rootRecordName
            self.share = share
        }
    }
    
    public var records: [Record]
    public var removals: [Removal]
    public var shares: [Share]
    
    public init(records: [Record] = [], removals: [Removal] = [], shares: [Share] = []) {
        self.records = records
        self.removals = removals
        self.shares = shares
    }
}

extension SDSSynchronizer {
    
    /// Adopts existing records for models that were created outside of the synchronizer, so they aren't uploaded as new records.
    ///
    /// Must be called before `setup`, as the first synchronization would otherwise download the existing records as new models.
    /// Adopting a record name again replaces its model, so a migration that was interrupted can be repeated.
    public func adopt(_ adoption: SDSAdoption) throws {
        // `setup` sets the CloudKit container first
        guard cloudContainer == nil else {
            throw SDSSyncError(title: "adoption.error.alreadySetUp")
        }
        
        let mappings = try adoption.records.map { record in
            let representation = try PersistentIdentifierRepresentation(record.modelID)
            guard !representation.implementation.isTemporary else {
                throw SDSSyncError(title: "adoption.error.temporaryIdentifier")
            }
            return (record, representation.implementation)
        }
        
        let context = self.context
        try context.performAndWait {
            for (record, implementation) in mappings {
                if let entity = existingLocalEntity(for: record.recordName) {
                    entity.localId = implementation.uriRepresentation
                } else {
                    _ = CloudKitLocalEntity(id: record.recordName, localId: implementation.uriRepresentation, context: context)
                }
                
                if let zoneID = record.sharedZoneID {
                    CloudKitZone.getZone(with: zoneID, context: context)
                }
            }
            
            for share in adoption.shares {
                CloudKitShare.updateShare(share.share, for: share.rootRecordName, context: context)
                if share.share.recordID.zoneID.ownerName != CKCurrentUserDefaultName {
                    CloudKitZone.getZone(with: share.share.recordID.zoneID, context: context)
                }
            }
            
            try context.save()
        }
        
        // Pending changes are only added once every record is known, as uploading them needs their objects.
        for (record, implementation) in mappings where !record.pendingKeys.isEmpty {
            setUpdate(idBlock: { record.recordName }, zoneId: record.sharedZoneID, entityName: implementation.entityName, changedKeys: record.pendingKeys)
        }
        for removal in adoption.removals {
            setRemoval(idBlock: { removal.recordName }, zoneId: removal.sharedZoneID)
        }
        
        try context.performAndWait {
            try context.save()
        }
    }
}
