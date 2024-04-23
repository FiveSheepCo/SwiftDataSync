import Foundation

struct SDSInternalConfiguration {
    struct Entity {
        let syncedProperties: [String]
        let parentKey: String?
        let isSharable: Bool
        
        init(syncedProperties: [String], parentKey: String?, isSharable: Bool) {
            self.syncedProperties = syncedProperties
            self.parentKey = parentKey
            self.isSharable = isSharable
        }
    }
    
    let entities: [String: Entity]
    
    init(entities: [String : Entity]) {
        self.entities = entities
    }
}
