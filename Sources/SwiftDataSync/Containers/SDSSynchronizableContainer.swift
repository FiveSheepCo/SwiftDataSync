import Foundation
import CoreData
import CloudKit

/// A synchronized object with what its entity's configuration says about it. Has to be used on the queue of the object's context.
class SDSSynchronizableContainer {
    lazy var id: String = idBlock()
    let object: NSManagedObject
    
    let parentKey: String?
    let syncKeys: [String]
    let assetKeys: [String]
    /// The synchronizer that made the container, which knows the records of related objects and the zones.
    /// `nil` for containers made outside of one, e.g. in tests of the values.
    weak var synchronizer: SDSSynchronizer?
    
    private let idBlock: () -> String
    
    init(
        id: @escaping () -> String,
        object: NSManagedObject,
        parentKey: String? = nil,
        syncKeys: [String] = [],
        assetKeys: [String],
        synchronizer: SDSSynchronizer? = nil
    ) {
        self.idBlock = id
        self.object = object
        self.parentKey = parentKey
        self.syncKeys = syncKeys
        self.assetKeys = assetKeys
        self.synchronizer = synchronizer
    }
    
    var parent: NSManagedObject? {
        get { parentKey.map { object.value(forKey: $0) } as? NSManagedObject }
        set { parentKey.map { object.setValue(newValue, forKey: $0) } }
    }

    /// The container of a related object, made by the same synchronizer.
    func container(for object: NSManagedObject) -> SDSSynchronizableContainer? {
        synchronizer?.container(for: object)
    }
}

extension SDSSynchronizableContainer {
    
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
            if let referenceObject = value as? NSManagedObject, let referenceObjectContainer = container(for: referenceObject) {
                cloudValue = referenceObjectContainer.cloudReference
            } else if let referenceObjectList = value as? NSOrderedSet {
                // Records leave out empty lists, so an empty relationship is stored as no value
                cloudValue = referenceObjectList.count == 0 ? nil : (referenceObjectList.array as! [NSManagedObject]).compactMap { synchronizable in
                    self.container(for: synchronizable)?.cloudReference
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
        
        while let newParent = parent.parent.flatMap(container(for:)) {
            parent = newParent
        }
        
        // A root that wasn't saved yet isn't shared, and must not get an id now, as saving it gives it another one
        if parent.object.objectID.isTemporaryID && synchronizer?.isDownloadedObject(parent.object) != true {
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

        while let newParent = root.parent.flatMap(container(for:)) {
            root = newParent
        }

        // A root that wasn't saved yet isn't shared. The app's contexts have no downloaded objects without saved ones.
        guard root is SDSSharableContainer, !root.object.objectID.isTemporaryID else { return nil }
        return root.object.objectID.uriRepresentation().absoluteString
    }

    var zoneId: CKRecordZone.ID {
        sharedZoneId ?? synchronizer?.defaultZoneID ?? CKRecordZone.ID(zoneName: "CoreData")
    }
}
