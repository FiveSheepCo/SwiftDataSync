import Foundation
import CoreData
import CloudKit

extension CloudKitRemoval {
    
    var recordId: CKRecord.ID {
        .init(recordName: id, zoneID: sharedZone?.calculatedId ?? SDSSynchronizer.shared.defaultZoneID)
    }
    
    static func retrieve(maximum: Int = CKModifyRecordsOperation.maximumRecords) -> [CloudKitRemoval] {
        let request: NSFetchRequest<CloudKitRemoval> = self.fetchRequest()
        request.fetchLimit = maximum
        request.sortDescriptors = []
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
        self.init(entity: Self.entity(), insertInto: context)
        
        self.id = id
    }
}
