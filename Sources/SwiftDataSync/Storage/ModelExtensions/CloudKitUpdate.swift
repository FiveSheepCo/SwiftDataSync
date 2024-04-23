import CloudKit
import Foundation
import CoreData

extension CloudKitUpdate {
    
    var recordId: CKRecord.ID {
        .init(recordName: id, zoneID: sharedZone?.calculatedId ?? SDSSynchronizer.Constants.zoneId)
    }
    
    var changedKeys: [String] {
        get { return rawChangedKeys.components(separatedBy: ",").filter({ !$0.isEmpty }) }
        set { rawChangedKeys = newValue.joined(separator: ",") ; lastChangeDate = .now }
    }
    
    static func retrieve(maximum: Int = CKModifyRecordsOperation.maximumRecords) -> [CloudKitUpdate] {
        let request: NSFetchRequest<CloudKitUpdate> = self.fetchRequest()
        request.fetchLimit = maximum
        request.sortDescriptors = []
        return (try? request.execute()) ?? []
    }
    
    static func find(for id: String) -> CloudKitUpdate? {
        let request: NSFetchRequest<CloudKitUpdate> = self.fetchRequest()
        request.sortDescriptors = []
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id = %@", id)
        
        return try? request.execute().first
    }
    
    static func retrieve(for id: String, entityName: String, context: NSManagedObjectContext) -> CloudKitUpdate {
        if let update = find(for: id) {
            return update
        } else {
            print("Creating `CloudKitUpdate`")
            return CloudKitUpdate(id: id, entityName: entityName, context: context)
        }
    }
    
    convenience init(id: String, entityName: String, context: NSManagedObjectContext) {
        self.init(entity: Self.entity(), insertInto: context)
        
        self.id = id
        self.recordType = entityName
        self.lastChangeDate = .now
    }
}
