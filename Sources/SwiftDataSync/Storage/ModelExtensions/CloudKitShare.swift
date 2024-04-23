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
        let request: NSFetchRequest<CloudKitShare> = self.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: "id = %@", id)
        
        let update = try? request.execute().first
        
        if let share = share {
            if let update = update {
                update.share = share
            } else {
                _ = CloudKitShare(id: id, share: share, context: context)
                do {
                    try context.save()
                    SDSSynchronizer.shared.logger.log("Saved sync context after adding Share")
                }
                catch let error {
                    SDSSynchronizer.shared.logger.log("Could not save sync context after adding Share with error: \(error)")
                }
            }
        } else {
            update?.delete()
        }
    }
    
    static func retrieveShare(for id: String) -> CKShare? {
        let request: NSFetchRequest<CloudKitShare> = self.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: "id = %@", id)
        
        if Thread.isMainThread {
            return try? SDSSynchronizer.shared.container.viewContext.fetch(request).first?.share
        }
        if let update = try? request.execute().first {
            return update.share
        }
        return nil
    }
}
