import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {
    
    func setUpdate(idBlock: () -> String, zoneId: CKRecordZone.ID?, entityName: String, changedKeys: [String]) {
        let context = self.context
        
        context.performAndWait {
            let id = idBlock()
            
            let update = CloudKitUpdate.retrieve(for: id, entityName: entityName, context: context)
            var storageChangedKeys = update.changedKeys
            for changedKey in changedKeys {
                if !storageChangedKeys.contains(changedKey) {
                    storageChangedKeys.append(changedKey)
                }
            }
            update.changedKeys = storageChangedKeys
            if let zoneId = zoneId {
                update.sharedZone = CloudKitZone.addZone(with: zoneId, context: context)
            }
        }
    }
    
    func setRemoval(idBlock: () -> String, zoneId: CKRecordZone.ID?) {
        let context = self.context
        
        context.performAndWait {
            let id = idBlock()
            
            CloudKitUpdate.find(for: id)?.delete()
            let removal = CloudKitRemoval.retrieve(for: id, context: context)
            
            if let zoneId = zoneId {
                removal.sharedZone = CloudKitZone.addZone(with: zoneId, context: context)
            }
        }
    }
}
