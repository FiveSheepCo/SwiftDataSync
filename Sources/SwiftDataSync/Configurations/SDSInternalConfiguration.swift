import Foundation
import CoreData

struct SDSInternalConfiguration {

    /// Required attributes without a default value that aren't synchronized. Models downloaded from other devices are inserted
    /// with the values of their records, so they couldn't be saved.
    static func unsynchronizedRequiredAttributes(of entity: NSEntityDescription, syncedProperties: [String]) -> [String] {
        entity.attributesByName.values.filter { attribute in
            !attribute.isOptional
                && !attribute.isTransient
                && !(attribute is NSDerivedAttributeDescription)
                && attribute.defaultValue == nil
                && !syncedProperties.contains(attribute.name)
        }.map(\.name).sorted()
    }

    struct Entity {
        let syncedProperties: [String]
        let assetProperties: [String]
        let parentKey: String?
        let isSharable: Bool
        /// How many levels of entities this entity references through synced relationships. Records with a lower depth are uploaded first.
        let referenceDepth: Int
        /// The attributes whose values name the records, empty for random names. See `SDSConfiguration.Entity.sync`.
        let identity: [String]
        
        init(syncedProperties: [String], assetProperties: [String], parentKey: String?, isSharable: Bool, referenceDepth: Int, identity: [String] = []) {
            self.syncedProperties = syncedProperties
            self.assetProperties = assetProperties
            self.parentKey = parentKey
            self.isSharable = isSharable
            self.referenceDepth = referenceDepth
            self.identity = identity
        }
    }
    
    let entities: [String: Entity]
    
    init(entities: [String : Entity]) {
        self.entities = entities
    }
}
