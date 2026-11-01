import Foundation
import CoreData
import CloudKit

// All of this should be run on `observedUpdateContext`, but `lastObjectChange`
class SDSSynchronizableContainer {
    lazy var id: String = idBlock()
    let object: NSManagedObject
    
    let parentKey: String?
    let syncKeys: [String]
    let assetKeys: [String]
    
    private let idBlock: () -> String
    
    init(
        id: @escaping () -> String,
        object: NSManagedObject,
        parentKey: String? = nil,
        syncKeys: [String] = [],
        assetKeys: [String]
    ) {
        self.idBlock = id
        self.object = object
        self.parentKey = parentKey
        self.syncKeys = syncKeys
        self.assetKeys = assetKeys
    }
    
    var parent: NSManagedObject? {
        get { parentKey.map { object.value(forKey: $0) } as? NSManagedObject }
        set { parentKey.map { object.setValue(newValue, forKey: $0) } }
    }
    
    func delete() {
        guard let context = object.managedObjectContext else { return }
        
        context.performAndWaitUnchecked {
            context.delete(object)
        }
        
        let id = self.id
        let sync = SDSSynchronizer.shared
        sync.context.performAndWait {
            sync.existingLocalEntity(for: id)?.delete()
        }
    }
}

extension SDSSynchronizableContainer {
    var lastObjectChange: Date? {
        let id = self.id
        return SDSSynchronizer.shared.context.performAndWait {
            CloudKitUpdate.find(for: id)?.lastChangeDate
        }
    }
    
    var recordId: CKRecord.ID {
        .init(recordName: id, zoneID: zoneId)
    }
    
    var cloudReference: CKRecord.Reference {
        .init(recordID: recordId, action: .none)
    }
    
    /// Throws if an asset can't be prepared, e.g. while the disk is full.
    /// Values records can't store are left out with a logged error, see `SDSValueCoding`.
    func changeDictionary(for keys: [String]) throws -> [String: CKRecordValue?] {
        try keys.reduce(into: [:]) { result, key in
            let value = object.value(forKey: key)

            let cloudValue: CKRecordValue?
            if let referenceObjectContainer = (value as? NSManagedObject)?.synchronizableContainer {
                cloudValue = referenceObjectContainer.cloudReference
            } else if let referenceObjectList = value as? NSOrderedSet {
                // Records leave out empty lists, so an empty relationship is stored as no value
                cloudValue = referenceObjectList.count == 0 ? nil : (referenceObjectList.array as! [NSManagedObject]).compactMap { synchronizable in
                    synchronizable.synchronizableContainer?.cloudReference
                } as CKRecordValue
            } else if let set = value as? NSSet {
                guard set.count == 0 else {
                    SDSValueCoding.logger.error("Leaving out `\(self.object.entity.name ?? "", privacy: .public)`.`\(key, privacy: .public)`: An unordered relationship should be synchronized through its inverse relationship. Many-to-many relationships aren't supported, please add an intermediary model.")
                    return
                }
                cloudValue = nil
            } else if let value {
                if let data = value as? Data, self.assetKeys.contains(key) {
                    cloudValue = try CKAsset(data: data)
                } else {
                    do {
                        cloudValue = try SDSValueCoding.cloudValue(for: value, attribute: object.entity.attributesByName[key])
                    } catch {
                        SDSValueCoding.logger.error("Leaving out `\(self.object.entity.name ?? "", privacy: .public)`.`\(key, privacy: .public)`: \(String(describing: error), privacy: .public)")
                        return
                    }
                }
            } else {
                cloudValue = nil
            }

            result[self.object.entity.propertiesByName[key]?.renamingIdentifier ?? key] = cloudValue
        }
    }
    
    var sharedZoneId: CKRecordZone.ID? {
        var parent: SDSSynchronizableContainer = self
        
        while let newParent = parent.parent?.synchronizableContainer {
            parent = newParent
        }
        
        // A root that wasn't saved yet isn't shared, and must not get an id now, as saving it gives it another one
        if parent.object.objectID.isTemporaryID && !SDSSynchronizer.shared.isDownloadedObject(parent.object) {
            return nil
        }
        
        if let sharableContainer = parent as? SDSSharableContainer,
           sharableContainer.shareState == SDSShareState.sharedByOther,
           let parentZone = sharableContainer.share?.recordID.zoneID {
            return parentZone
        }
        
        return nil
    }

    /// The URI of the object ID of the root, which decides the record's zone like in `sharedZoneId`, if it can be shared and was saved.
    /// Has to be called on the queue of the object's context, while the zone is looked up on the synchronizer's, see `SDSObjectChange`.
    var sharableRootLocalId: String? {
        var root: SDSSynchronizableContainer = self

        while let newParent = root.parent?.synchronizableContainer {
            root = newParent
        }

        // A root that wasn't saved yet isn't shared. The app's contexts have no downloaded objects without saved ones.
        guard root is SDSSharableContainer, !root.object.objectID.isTemporaryID else { return nil }
        return root.object.objectID.uriRepresentation().absoluteString
    }

    var zoneId: CKRecordZone.ID {
        sharedZoneId ?? SDSSynchronizer.shared.defaultZoneID
    }
}
