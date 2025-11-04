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
        
        try context.performAndWait {
            context.delete(object)
        }
        
        let sync = SDSSynchronizer.shared
        sync.context.performAndWait {
            sync.existingLocalEntity(for: id)?.delete()
        }
    }
}

extension SDSSynchronizableContainer {
    var lastObjectChange: Date? {
        SDSSynchronizer.shared.context.performAndWait {
            CloudKitUpdate.find(for: id)?.lastChangeDate
        }
    }
    
    var recordId: CKRecord.ID {
        .init(recordName: id, zoneID: zoneId)
    }
    
    var cloudReference: CKRecord.Reference {
        .init(recordID: recordId, action: .none)
    }
    
    private func jsonData(for object: Any) -> Data? {
        do {
            return try JSONSerialization.data(withJSONObject: object)
        }
        catch {
            SDSSynchronizer.shared.logger.log("Failed to provide json data: \(error.localizedDescription)")
        }
        return nil
    }
    
    func changeDictionary(for keys: [String]) -> [String: CKRecordValue?] {
        keys.reduce(into: [:]) { result, key in
            let value = object.value(forKey: key)
            
            let cloudValue: CKRecordValue?
            if let referenceObjectContainer = (value as? NSManagedObject)?.synchronizableContainer {
                cloudValue = referenceObjectContainer.cloudReference
            } else if let referenceObjectList = value as? NSOrderedSet, referenceObjectList.count > 0 {
                cloudValue = (referenceObjectList.array as! [NSManagedObject]).compactMap { synchronizable in
                    synchronizable.synchronizableContainer?.cloudReference
                } as CKRecordValue
            } else if value is NSSet {
                fatalError("An unordered NSSet should use the reverse relationship. Found at \(object.entity.name!).\(key). If this is a many-to-many relationship, these are not currently supported. Please add an intermediary model.")
            } else if value == nil {
                cloudValue = nil
            } else
                if let transformerName = (object.entity.propertiesByName[key] as? NSAttributeDescription)?.valueTransformerName
            {
                let transformer = ValueTransformer(forName: .init(transformerName))!
                cloudValue = transformer.transformedValue(value) as? any CKRecordValue
            } else if let data = value as? Data, self.assetKeys.contains(key) {
                cloudValue = try! CKAsset(data: data)
            } else if let recordValue = value as? CKRecordValue {
                cloudValue = recordValue
            } else if
                JSONSerialization.isValidJSONObject(value),
                let data = jsonData(for: value)
            {
                cloudValue = data as any CKRecordValue
            } else if let url = value as? URL {
                cloudValue = url.absoluteString as any CKRecordValue
            } else {
                fatalError("`\(self.object.entity.name ?? "")`.`\(key)` is not a valid CKRecordValue or JSON object: \(value) \((object.entity.propertiesByName[key] as? NSAttributeDescription)?.type.rawValue.rawValue)")
            }
            
            result[self.object.entity.propertiesByName[key]?.renamingIdentifier ?? key] = cloudValue
        }
    }
    
    var sharedZoneId: CKRecordZone.ID? {
        var parent: SDSSynchronizableContainer = self
        
        while let newParent = parent.parent?.synchronizableContainer {
            parent = newParent
        }
        
        if let sharableContainer = parent as? SDSSharableContainer,
           sharableContainer.shareState == SDSShareState.sharedByOther,
           let parentZone = sharableContainer.share?.recordID.zoneID {
            return parentZone
        }
        
        return nil
    }
    
    var zoneId: CKRecordZone.ID {
        sharedZoneId ?? SDSSynchronizer.Constants.zoneId
    }
}
