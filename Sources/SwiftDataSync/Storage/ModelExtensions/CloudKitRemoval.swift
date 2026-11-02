import Foundation
import CoreData
import CloudKit

extension CloudKitRemoval {
    
    /// The record's id, in its shared zone or else in the default zone of the private database.
    func recordId(defaultZoneID: CKRecordZone.ID) -> CKRecord.ID {
        .init(recordName: id, zoneID: sharedZone?.calculatedId ?? defaultZoneID)
    }
    
    /// Up to `maximum` removals of records in the private database, or in zones of shares of other users (`sharedDatabase`).
    /// Filtered by the fetch, so removals of one database don't keep the other's from being found.
    static func retrieve(sharedDatabase: Bool, maximum: Int = CKModifyRecordsOperation.maximumRecords) -> [CloudKitRemoval] {
        guard maximum > 0 else { return [] }
        let request: NSFetchRequest<CloudKitRemoval> = self.fetchRequest()
        request.fetchLimit = maximum
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: sharedDatabase ? "sharedZone != nil" : "sharedZone == nil")
        return (try? request.execute()) ?? []
    }
    
    static func retrieve(for id: String, context: NSManagedObjectContext) -> CloudKitRemoval {
        let request: NSFetchRequest<CloudKitRemoval> = self.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: "id = %@", id)
        
        if let update = try? request.execute().first {
            return update
        } else {
            return CloudKitRemoval(id: id, context: context)
        }
    }
    
    convenience init(id: String, context: NSManagedObjectContext) {
        // The entity of the context's model, as the class could belong to several models, e.g. in tests
        self.init(entity: NSEntityDescription.entity(forEntityName: "CloudKitRemoval", in: context)!, insertInto: context)
        
        self.id = id
    }
}
