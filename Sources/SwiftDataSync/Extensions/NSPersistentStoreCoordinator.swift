import Foundation
import CoreData

extension NSPersistentStoreCoordinator {
    
    private func relationshipsToSync(
        relationships: [NSRelationshipDescription],
        externalDescriptions: [String: SDSConfiguration.Entity]
    ) -> [NSRelationshipDescription] {
        var allRelationships: [NSRelationshipDescription] = relationships
        var relationshipsToSync: [NSRelationshipDescription] = []
        
        func name(for relationship: NSRelationshipDescription) -> String {
            "`\(relationship.entity.name ?? "").\(relationship.name)`"
        }
        
        while !allRelationships.isEmpty {
            let relationship = allRelationships.removeFirst()
            var shouldDefinetelySync: Bool = false
            var shouldDefinetelyNotSync: Bool = false
            switch externalDescriptions[relationship.entity.name ?? ""] {
            case .none: break
            case .noSync: continue // Entities that are not synced should not have their relationships synced either.
            case .sync(let properties, _, let parentKey, _, _):
                (shouldDefinetelySync, shouldDefinetelyNotSync) = relationship.syncProperties(properties: properties, parentKey: parentKey)
            }
            
            if let inverse = relationship.inverseRelationship {
                allRelationships.removeAll(where: { $0 == inverse })
                
                var inverseShouldDefinetelySync: Bool = false
                var inverseShouldDefinetelyNotSync: Bool = false
                switch externalDescriptions[inverse.entity.name ?? ""] {
                case .none: break
                case .noSync: continue // Entities that are not synced should not have their relationships synced either.
                case .sync(let properties, _, let parentKey, _, _):
                    (inverseShouldDefinetelySync, inverseShouldDefinetelyNotSync) = inverse.syncProperties(properties: properties, parentKey: parentKey)
                }
                
                if shouldDefinetelySync {
                    if inverseShouldDefinetelySync {
                        fatalError("\(name(for: relationship)) <> \(name(for: inverse)): Cannot sync both the relationship and its inverse. Please fix your configuration.")
                    }
                    relationshipsToSync.append(relationship)
                } else if inverseShouldDefinetelySync {
                    relationshipsToSync.append(inverse)
                } else if shouldDefinetelyNotSync {
                    if inverseShouldDefinetelyNotSync {
                        continue // Both relationships are marked as explicitly non-syncing, so this relationship will not be synced
                    }
                    relationshipsToSync.append(inverse)
                } else if inverseShouldDefinetelyNotSync {
                    relationshipsToSync.append(relationship)
                } else if relationship.isOrdered {
                    relationshipsToSync.append(relationship)
                } else if inverse.isOrdered {
                    relationshipsToSync.append(inverse)
                } else if inverse.isToMany {
                    if relationship.isToMany {
                        fatalError("\(name(for: relationship)) <> \(name(for: inverse)): Many-to-Many relationships are not supported in SDSSynchronizer yet.")
                    }
                    relationshipsToSync.append(relationship)
                } else if relationship.isToMany {
                    relationshipsToSync.append(inverse)
                } else if relationship.deleteRule == .cascadeDeleteRule {
                    relationshipsToSync.append(inverse)
                } else if inverse.deleteRule == .cascadeDeleteRule {
                    relationshipsToSync.append(relationship)
                } else {
                    fatalError("\(name(for: relationship)) <> \(name(for: inverse)): Direction could not be resolved automatically. Should one of the relationships have a cascading delete rule?")
                }
            } else {
                relationshipsToSync.append(relationship)
                assertionFailure("\(name(for: relationship)) has no implicit or explicit inverse. You should fix that.")
            }
        }
        
        return relationshipsToSync
    }
    
    func makeConfiguration(externalConfiguration: SDSConfiguration) -> SDSInternalConfiguration {
        let externalDescriptions = externalConfiguration.entityDescriptions
        let entities = managedObjectModel.entitiesByName
        
        // In a stable order: dictionaries are ordered differently with every launch, which would otherwise decide
        // relationships that can be synchronized either way differently
        let relationshipsToSync = self.relationshipsToSync(
            relationships: entities.values.flatMap(\.relationshipsByName.values).sorted { lhs, rhs in
                (lhs.entity.name ?? "", lhs.name) < (rhs.entity.name ?? "", rhs.name)
            },
            externalDescriptions: externalDescriptions
        )
        
        var referencedEntities: [String: Set<String>] = [:]
        for relationship in relationshipsToSync {
            guard
                let entityName = relationship.entity.name,
                let destinationName = relationship.destinationEntity?.name,
                entityName != destinationName
            else { continue }
            
            referencedEntities[entityName, default: []].insert(destinationName)
        }
        
        func referenceDepth(of entityName: String, visited: Set<String> = []) -> Int {
            // Cycles cannot be ordered, so they are cut off here
            guard !visited.contains(entityName) else { return 0 }
            
            return (referencedEntities[entityName] ?? []).map { destinationName in
                referenceDepth(of: destinationName, visited: visited.union([entityName])) + 1
            }.max() ?? 0
        }
        
        var configurationEntities: [String: SDSInternalConfiguration.Entity] = [:]
        
        for (entityName, entityDescription) in entities {
            let description = externalDescriptions[entityDescription.name ?? ""] ?? .sync(.all, parentKey: nil)
            guard case .sync(let properties, let assetProperties, let parentKey, let isSharable, let identity) = description else { continue }
            
            let syncedProperties = entityDescription.properties.filter({ property in
                if let relationship = property as? NSRelationshipDescription {
                    return relationshipsToSync.contains(where: { $0 == relationship })
                }
                
                let name = property.name
                
                return switch properties {
                case .with(let with): with.contains(name)
                case .without(let without): !without.contains(name)
                }
            }).map(\.name)
            
            // Downloads match records to models by these values, so the records have to contain them
            for key in identity where entityDescription.attributesByName[key] == nil || !syncedProperties.contains(key) {
                fatalError("`\(entityName).\(key)`: An identity has to consist of synchronized attributes. Please fix your configuration.")
            }
            if !identity.isEmpty && isSharable {
                fatalError("`\(entityName)`: Entities with an identity can't be sharable. Please fix your configuration.")
            }
            // Downloaded models are inserted with the values of their records, so they couldn't be saved without these.
            // Not a crash, as apps could have such configurations already. Their downloaded models are skipped.
            for key in SDSInternalConfiguration.unsynchronizedRequiredAttributes(of: entityDescription, syncedProperties: syncedProperties) {
                assertionFailure("`\(entityName).\(key)` is required and has no default value, but isn't synchronized, so models downloaded from other devices can't be saved. Please give it a default value, make it optional or synchronize it.")
            }

            configurationEntities[entityName] =
                SDSInternalConfiguration.Entity(
                    syncedProperties: syncedProperties,
                    assetProperties: assetProperties,
                    parentKey: parentKey,
                    isSharable: isSharable,
                    referenceDepth: referenceDepth(of: entityName),
                    identity: identity
                )
        }
        
        return .init(entities: configurationEntities)
    }
}

private extension NSRelationshipDescription {
    func syncProperties(properties: SDSConfiguration.Entity.PropertiesSync, parentKey: String?) -> (definitely: Bool, definitelyNot: Bool) {
        
        var shouldDefinetelySync: Bool = false
        var shouldDefinetelyNotSync: Bool = false
        if parentKey == name {
            shouldDefinetelySync = true
        } else {
            switch properties {
            case .with(let with):
                if with.contains(name) {
                    shouldDefinetelySync = true
                } else {
                    shouldDefinetelyNotSync = true
                }
            case .without(let without):
                if without.contains(name) {
                    shouldDefinetelyNotSync = true
                }
            }
        }
        
        return (shouldDefinetelySync, shouldDefinetelyNotSync)
    }
}
