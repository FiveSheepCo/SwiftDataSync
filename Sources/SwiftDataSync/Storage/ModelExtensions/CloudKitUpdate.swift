import CloudKit
import Foundation
import CoreData

extension CloudKitUpdate {
    
    var recordId: CKRecord.ID {
        .init(recordName: id, zoneID: sharedZone?.calculatedId ?? SDSSynchronizer.shared.defaultZoneID)
    }
    
    var changedKeys: [String] {
        get { return rawChangedKeys.components(separatedBy: ",").filter({ !$0.isEmpty }) }
        set { rawChangedKeys = newValue.joined(separator: ",") ; lastChangeDate = .now }
    }
    
    static func retrieveAll() -> [CloudKitUpdate] {
        let request: NSFetchRequest<CloudKitUpdate> = self.fetchRequest()
        request.sortDescriptors = []
        return (try? request.execute()) ?? []
    }
    
    static func find(for id: String) -> CloudKitUpdate? {
        let request: NSFetchRequest<CloudKitUpdate> = self.fetchRequest()
        request.sortDescriptors = []
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id = %@", id)
        
        let update = try? request.execute().first
        if let update {
            // Another process could have changed the update since it was fetched last
            update.managedObjectContext?.refresh(update, mergeChanges: true)
        }
        return update
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
