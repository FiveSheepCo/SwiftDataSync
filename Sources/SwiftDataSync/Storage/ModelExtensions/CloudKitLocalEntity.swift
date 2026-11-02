import Foundation
import CoreData
import CloudKit

extension CloudKitLocalEntity {
    convenience init(id: String, localId: String, context: NSManagedObjectContext) {
        // The entity of the context's model, as the class could belong to several models, e.g. in tests
        self.init(entity: NSEntityDescription.entity(forEntityName: "CloudKitLocalEntity", in: context)!, insertInto: context)
        
        self.id = id
        self.localId = localId
    }
    
    /// The entity of the object with the given URI. Has to be called on `context`.
    static func entry(forLocalId localId: String, in context: NSManagedObjectContext) -> CloudKitLocalEntity? {
        let request = fetchRequest()
        request.sortDescriptors = []
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "localId = %@", localId)
        return try? context.fetch(request).first
    }
    
    /// The entities of the objects with the given URIs, by URI. Has to be called on `context`.
    static func entries(forLocalIds localIds: [String], in context: NSManagedObjectContext) -> [String: CloudKitLocalEntity] {
        guard !localIds.isEmpty else { return [:] }
        let request = fetchRequest()
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: "localId IN %@", localIds)
        return Dictionary(((try? context.fetch(request)) ?? []).map { ($0.localId, $0) }, uniquingKeysWith: { first, _ in first })
    }
    
    /// Which of the record ids are taken by an entity. Has to be called on `context`.
    static func existingIds(_ ids: [String], in context: NSManagedObjectContext) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        // Objects rather than dictionaries, which would leave out entities that weren't saved yet
        let request = fetchRequest()
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: "id IN %@", ids)
        return Set(((try? context.fetch(request)) ?? []).map(\.id))
    }
    
    /// The entity with the record id. Has to be called on `context`.
    static func entry(forId id: String, in context: NSManagedObjectContext) -> CloudKitLocalEntity? {
        let request = fetchRequest()
        request.sortDescriptors = []
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id = %@", id)
        return try? context.fetch(request).first
    }
}
