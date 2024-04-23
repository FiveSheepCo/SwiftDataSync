import Foundation
import CoreData


extension CloudKitUpdate {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CloudKitUpdate> {
        return NSFetchRequest<CloudKitUpdate>(entityName: "CloudKitUpdate")
    }
    
    // MARK: Attributes

    @NSManaged public var id: String
    @NSManaged public var rawChangedKeys: String
    @NSManaged public var recordType: String
    @NSManaged public var lastChangeDate: Date
    
    // MARK: Relationships
    
    @NSManaged public var sharedZone: CloudKitZone?
}

extension CloudKitUpdate : Identifiable {

}
