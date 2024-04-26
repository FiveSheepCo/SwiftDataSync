import Foundation
import SwiftData

/// Configuration struct for defining synchronization settings for SwiftData and CoreData entities.
public struct SDSConfiguration {
    
    /// Configuration for a SwiftData entity.
    public struct SwiftDataEntity {
        
        /// Description of synchronization settings for a SwiftData entity.
        public enum Description {
            
            /// Indicates that no synchronization is needed.
            case noSync
            
            /// Indicates synchronization with specified properties.
            case sync(PropertiesSync, parentKey: String? = nil, isSharable: Bool = false)
            
            /// Description of properties synchronization settings.
            public enum PropertiesSync {
                
                /// Sync with specified properties.
                case with([String])
                
                /// Sync without specified properties.
                case without([String])
                
                /// Convert PropertiesSync enum to its raw form.
                var raw: Entity.PropertiesSync {
                    switch self {
                    case .with(let with):
                        return .with(with)
                    case .without(let without):
                        return .without(without)
                    }
                }
            }
        }
        
        /// The type of the SwiftData entity.
        let entity: any PersistentModel.Type
        
        /// The description of synchronization settings for the entity.
        let description: Description
        
        public init(entity: any PersistentModel.Type, description: Description) {
            self.entity = entity
            self.description = description
        }
    }
    
    /// Configuration for a CoreData entity.
    public enum Entity {
        
        /// Description of synchronization settings for properties of a CoreData entity.
        public enum PropertiesSync {
            
            /// Sync with specified properties.
            case with([String])
            
            /// Sync without specified properties.
            case without([String])
            
            /// Default synchronization setting, sync without any properties.
            static var all: PropertiesSync {
                .without([])
            }
        }
        
        /// Indicates that no synchronization is needed.
        case noSync
        
        /// Indicates synchronization with specified properties.
        case sync(PropertiesSync, parentKey: String? = nil, isSharable: Bool = false)
    }
    
    /// Dictionary containing entity descriptions keyed by entity names.
    let entityDescriptions: [String: Entity]
    
    /// Initializes configuration from an array of SwiftDataEntity instances.
    /// - Parameter swiftDataEntities: Array of SwiftDataEntity instances containing entity configurations.
    public init(swiftDataEntities: [SwiftDataEntity]) {
        var entityDescriptions: [String: Entity] = [:]
        
        for entity in swiftDataEntities {
            entityDescriptions[String(describing: entity.entity)] = switch entity.description {
            case .noSync:
                .noSync
            case .sync(let propertiesSync, let parentKey, let isSharable):
                .sync(
                    propertiesSync.raw,
                    parentKey: parentKey,
                    isSharable: isSharable
                )
            }
        }
        
        self.entityDescriptions = entityDescriptions
    }
    
    /// Initializes configuration from a dictionary of entity descriptions.
    /// - Parameter rawEntities: Dictionary containing raw entity descriptions.
    public init(rawEntities: [String: Entity]) {
        self.entityDescriptions = rawEntities
    }
}

private extension AnyKeyPath {
    var propertyString: String {
        String(describing: self).components(separatedBy: ".").last!
    }
}
