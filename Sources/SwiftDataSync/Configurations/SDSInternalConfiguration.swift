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

    /// Why identities of the entities can't name their records, empty if they can. See `SDSConfiguration.Entity.sync`.
    static func identityProblems(of entities: [String: Entity], descriptions: [String: NSEntityDescription]) -> [String] {
        // The entities the parent keys point to, by entity name
        var parents: [String: NSEntityDescription] = [:]
        for (name, entity) in entities {
            if let parentKey = entity.parentKey, let parent = descriptions[name]?.relationshipsByName[parentKey]?.destinationEntity {
                parents[name] = parent
            }
        }
        let sharableEntities = entities.filter(\.value.isSharable).compactMap { descriptions[$0.key] }

        var problems: [String] = []
        for (name, entity) in entities.sorted(by: { $0.key < $1.key }) where !entity.identity.isEmpty {
            guard let description = descriptions[name] else { continue }

            // Downloads match records to models by these values, so the records have to contain them, rather than assets
            for key in entity.identity where description.attributesByName[key] == nil || !entity.syncedProperties.contains(key) || entity.assetProperties.contains(key) {
                problems.append("`\(name).\(key)`: An identity has to consist of synchronized attributes that aren't asset properties.")
            }
            // A model's values have to give the same name as its record's, see `SDSIdentity.canonicalString`. E.g. a float is
            // stored as a double, whose text differs.
            for key in entity.identity {
                guard let attribute = description.attributesByName[key], !Self.identityAttributeTypes.contains(attribute.attributeType) else { continue }
                problems.append("`\(name).\(key)`: Identity values have to be strings, integers, booleans, doubles, dates, UUIDs, URLs or data.")
            }

            // The zones of different users' shares can have records of the same identity, which a model can't tell apart
            var visited: Set<String> = []
            var ancestor: NSEntityDescription? = description
            while let current = ancestor, let currentName = current.name, visited.insert(currentName).inserted {
                // A parent can be a model of a subentity of the entity its key points to. The entity itself is configured on its own.
                let isSharable = current == description ? entity.isSharable : sharableEntities.contains(where: { $0.isKindOf(entity: current) })
                if isSharable {
                    problems.append("`\(name)`: Entities with an identity can't be sharable, or below a sharable entity.")
                    break
                }
                ancestor = parents[currentName]
            }

            // Changing an identity value deletes the record, which would delete the records of its children with it, see
            // `CKRecord.Reference.Action.deleteSelf`
            if parents.values.contains(where: { description.isKindOf(entity: $0) }) {
                problems.append("`\(name)`: Entities with an identity can't be the parent of other entities.")
            }
        }
        return problems
    }

    /// The types of attributes that can be identity values.
    private static let identityAttributeTypes: Set<NSAttributeType> = [
        .stringAttributeType, .integer16AttributeType, .integer32AttributeType, .integer64AttributeType, .booleanAttributeType,
        .doubleAttributeType, .dateAttributeType, .UUIDAttributeType, .URIAttributeType, .binaryDataAttributeType
    ]

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
