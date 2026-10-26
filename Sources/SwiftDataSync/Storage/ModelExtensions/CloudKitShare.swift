import CloudKit
import Foundation
import CoreData

extension CloudKitShare {
    
    // MARK: Initializers
    
    convenience init(id: String, share: CKShare, context: NSManagedObjectContext) {
        self.init(entity: Self.entity(), insertInto: context)
        
        self.id = id
        self.share = share
    }
    
    static func updateShare(_ share: CKShare?, for id: String, context: NSManagedObjectContext) {
        let update = entry(for: id, in: context)
        
        if let share = share {
            if let update = update {
                update.share = share
            } else {
                _ = CloudKitShare(id: id, share: share, context: context)
            }
        } else {
            update?.delete()
        }
    }
    
    /// The share for an id, fetched in `context`. Has to be called on `context`.
    static func share(for id: String, in context: NSManagedObjectContext) -> CKShare? {
        guard let entry = entry(for: id, in: context) else { return nil }
        
        // Another context or process could have changed the share since it was fetched last
        context.refresh(entry, mergeChanges: true)
        return entry.share
    }
    
    private static func entry(for id: String, in context: NSManagedObjectContext) -> CloudKitShare? {
        let request: NSFetchRequest<CloudKitShare> = self.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: "id = %@", id)
        return try? context.fetch(request).first
    }
}
