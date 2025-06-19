import CloudKit
import Foundation
import CoreData

extension CloudKitZone {
    
    // MARK: Initializers
    
    convenience init(name: String, owner: String, context: NSManagedObjectContext) {
        self.init(entity: Self.entity(), insertInto: context)
        
        self.name = name
        self.owner = owner
    }
    
    var calculatedId: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: owner)
    }
    
    /// Retrieves the zone if it exists, creates a new one if not.
    @discardableResult
    static func getZone(with zoneId: CKRecordZone.ID, context: NSManagedObjectContext) -> CloudKitZone {
        if let zone = retrieveZone(for: zoneId) {
            return zone
        }
        
        return CloudKitZone(name: zoneId.zoneName, owner: zoneId.ownerName, context: context)
    }
    
    static func retrieveZone(for zoneId: CKRecordZone.ID) -> CloudKitZone? {
        let request: NSFetchRequest<CloudKitZone> = self.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: "name = %@ AND owner = %@", zoneId.zoneName, zoneId.ownerName)
        
       return try? request.execute().first
    }
    
    static func getAll() -> [CloudKitZone] {
        let request: NSFetchRequest<CloudKitZone> = self.fetchRequest()
        request.sortDescriptors = []
        
        return try! request.execute()
    }
}
