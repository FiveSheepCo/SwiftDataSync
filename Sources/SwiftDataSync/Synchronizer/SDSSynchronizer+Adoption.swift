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
    
    /// Change tokens of the previous sync engine, so the first download continues where it stopped.
    ///
    /// Without them, the first download fetches every record again, but not the deletions that happened since,
    /// so records deleted elsewhere would stay locally.
    public struct ChangeTokens: @unchecked Sendable {
        // `CKServerChangeToken` isn't marked `Sendable`, but it's immutable.
        public var privateZone: CKServerChangeToken?
        public var sharedZones: [CKRecordZone.ID: CKServerChangeToken]
        
        public init(privateZone: CKServerChangeToken? = nil, sharedZones: [CKRecordZone.ID: CKServerChangeToken] = [:]) {
            self.privateZone = privateZone
            self.sharedZones = sharedZones
        }
    }
    
    public var records: [Record]
    public var removals: [Removal]
    public var shares: [Share]
    public var changeTokens: ChangeTokens
    
    public init(records: [Record] = [], removals: [Removal] = [], shares: [Share] = [], changeTokens: ChangeTokens = ChangeTokens()) {
        self.records = records
        self.removals = removals
        self.shares = shares
        self.changeTokens = changeTokens
    }
}

extension SDSSynchronizer {
    
    /// Adopts existing records for models that were created outside of the synchronizer, so they aren't uploaded as new records.
    ///
    /// Called by `setup` once the store was found, before observing it, as the first synchronization would otherwise download
    /// the existing records as new models, and saving the adopted models would upload them as new records.
    /// Adopting a record name again replaces its model, so a migration that was interrupted can be repeated.
    func adopt(_ adoption: SDSAdoption) throws {
        let mappings = try adoption.records.map { record in
            let representation = try PersistentIdentifierRepresentation(record.modelID)
            guard !representation.implementation.isTemporary else {
                throw SDSSyncError(title: "adoption.error.temporaryIdentifier")
            }
            return (record, representation.implementation)
        }
        
        try validate(adoption, mappings: mappings)
        
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
            
            for (zoneID, token) in adoption.changeTokens.sharedZones {
                CloudKitZone.getZone(with: zoneID, context: context).changeToken = token
            }
            
            for share in adoption.shares {
                CloudKitShare.updateShare(share.share, for: share.rootRecordName, context: context)
                if share.share.isSharedByOtherUser {
                    CloudKitZone.getZone(with: share.share.recordID.zoneID, context: context)
                }
            }
            
            try context.save()
        }
        
        if let token = adoption.changeTokens.privateZone {
            setState(\.changeToken, value: token)
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
    
    /// Makes sure the adoption matches what synchronizing expects later, before anything is written.
    ///
    /// Every record has to be an existing, synchronized model of the observed store, as uploading its pending changes needs it.
    /// Its zone has to be the one later changes are sent to, which is the zone of its root's share if another user shared it.
    /// Shares have to be named after their root record, as downloading finds the root of a share by its name.
    private func validate(_ adoption: SDSAdoption, mappings: [(SDSAdoption.Record, PersistentIdentifierRepresentation.Implementation)]) throws {
        guard let configuration, let observedStore, let observedUpdateContext else {
            throw SDSSyncError(title: "error.noObservedContext")
        }
        
        for share in adoption.shares where share.share.recordID.recordName != share.rootRecordName + staticShareExtension {
            throw SDSSyncError(title: "adoption.error.invalidShareName")
        }
        
        let adoptedRecordNames = Dictionary(mappings.map { ($1.uriRepresentation, $0.recordName) }, uniquingKeysWith: { $1 })
        let adoptedShares = Dictionary(adoption.shares.map { ($0.rootRecordName, $0.share) }, uniquingKeysWith: { $1 })
        
        let context = self.context
        for (record, implementation) in mappings {
            let root: (uri: String, isSharable: Bool)? = observedUpdateContext.performAndWait {
                guard
                    let objectID = implementation.objectID(in: observedStore),
                    var object = try? observedUpdateContext.existingObject(with: objectID),
                    var entity = configuration.entities[object.entity.name ?? ""]
                else { return nil }
                
                // Like `sharedZoneId`, the root is the topmost synchronized parent
                while
                    let parent = entity.parentKey.map({ object.value(forKey: $0) }) as? NSManagedObject,
                    let parentEntity = configuration.entities[parent.entity.name ?? ""]
                {
                    object = parent
                    entity = parentEntity
                }
                return (object.objectID.uriRepresentation().absoluteString, entity.isSharable)
            }
            guard let root else {
                throw SDSSyncError(title: "adoption.error.unknownModel")
            }
            
            let share: CKShare? = context.performAndWait {
                guard
                    root.isSharable,
                    let recordName = adoptedRecordNames[root.uri] ?? CloudKitLocalEntity.entry(forLocalId: root.uri, in: context)?.id
                else { return nil }

                return adoptedShares[recordName] ?? CloudKitShare.share(for: recordName, in: context)
            }
            // Decided like `sharedZoneId` does, which sends later changes to that zone
            let sharedZoneID = share.flatMap { $0.isSharedByOtherUser ? $0.recordID.zoneID : nil }
            guard sharedZoneID == record.sharedZoneID else {
                throw SDSSyncError(title: "adoption.error.sharedZoneMismatch")
            }
        }
    }
}
