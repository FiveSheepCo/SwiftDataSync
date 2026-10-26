import Foundation
import CoreData
import CloudKit

extension CloudKitLocalEntity {
    convenience init(id: String, localId: String, context: NSManagedObjectContext) {
        self.init(entity: Self.entity(), insertInto: context)
        
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
}
