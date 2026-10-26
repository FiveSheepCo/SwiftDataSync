import Foundation

struct SDSInternalConfiguration {
    struct Entity {
        let syncedProperties: [String]
        let assetProperties: [String]
        let parentKey: String?
        let isSharable: Bool
        /// How many levels of entities this entity references through synced relationships. Records with a lower depth are uploaded first.
        let referenceDepth: Int
        
        init(syncedProperties: [String], assetProperties: [String], parentKey: String?, isSharable: Bool, referenceDepth: Int) {
            self.syncedProperties = syncedProperties
            self.assetProperties = assetProperties
            self.parentKey = parentKey
            self.isSharable = isSharable
            self.referenceDepth = referenceDepth
        }
    }
    
    let entities: [String: Entity]
    
    init(entities: [String : Entity]) {
        self.entities = entities
    }
}
