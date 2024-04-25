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
            case .sync(let properties, let parentKey, _):
                (shouldDefinetelySync, shouldDefinetelyNotSync) = relationship.syncProperties(properties: properties, parentKey: parentKey)
            }
            
            if let inverse = relationship.inverseRelationship {
                allRelationships.removeAll(where: { $0 == inverse })
                
                var inverseShouldDefinetelySync: Bool = false
                var inverseShouldDefinetelyNotSync: Bool = false
                switch externalDescriptions[inverse.entity.name ?? ""] {
                case .none: break
                case .noSync: continue // Entities that are not synced should not have their relationships synced either.
                case .sync(let properties, let parentKey, _):
                    (inverseShouldDefinetelySync, inverseShouldDefinetelyNotSync) = relationship.syncProperties(properties: properties, parentKey: parentKey)
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
        
        let relationshipsToSync = self.relationshipsToSync(
            relationships: entities.values.flatMap(\.relationshipsByName.values),
            externalDescriptions: externalDescriptions
        )
        
        var configurationEntities: [String: SDSInternalConfiguration.Entity] = [:]
        
        for (entityName, entityDescription) in entities {
            let description = externalDescriptions[entityDescription.name ?? ""] ?? .sync(.all, parentKey: nil)
            guard case .sync(let properties, let parentKey, let isSharable) = description else { continue }
            
            configurationEntities[entityName] =
                SDSInternalConfiguration.Entity(
                    syncedProperties: entityDescription.properties.filter({ property in
                        if let relationship = property as? NSRelationshipDescription {
                            return relationshipsToSync.contains(where: { $0 == relationship })
                        }
                        
                        let name = property.name
//                        if name == "download" {
//                            print("x:", (property as? NSCompositeAttributeDescription)?.elements.map(\.name), (property as? NSCompositeAttributeDescription)?.elements.first?.type.rawValue.rawValue, (property as? NSCompositeAttributeDescription)?.elements.first?.entity.name)
//                        }
                        
                        return switch properties {
                        case .with(let with): with.contains(name)
                        case .without(let without): !without.contains(name)
                        }
                    }).map(\.name),
                    parentKey: parentKey,
                    isSharable: isSharable
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
