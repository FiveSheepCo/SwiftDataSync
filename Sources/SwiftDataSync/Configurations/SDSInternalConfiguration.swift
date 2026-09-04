import Foundation

struct SDSInternalConfiguration {
    var didDownloadEntities: (@Sendable (Set<String>) -> Void)?

    var privateRecordZones: [String: String] = [:]
    var recordIdentityProperties: [String: String] = [:]

    struct Entity {
        let syncedProperties: [String]
        let assetProperties: [String]
        let parentKey: String?
        let isSharable: Bool
        
        init(syncedProperties: [String], assetProperties: [String], parentKey: String?, isSharable: Bool) {
            self.syncedProperties = syncedProperties
            self.assetProperties = assetProperties
            self.parentKey = parentKey
            self.isSharable = isSharable
        }
    }
    
    let entities: [String: Entity]
    
    init(entities: [String : Entity]) {
        self.entities = entities
    }
}
