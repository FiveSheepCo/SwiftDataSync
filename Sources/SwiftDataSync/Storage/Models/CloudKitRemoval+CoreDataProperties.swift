import Foundation
import CoreData


extension CloudKitRemoval {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CloudKitRemoval> {
        return NSFetchRequest<CloudKitRemoval>(entityName: "CloudKitRemoval")
    }
    
    // MARK: Attributes

    @NSManaged public var id: String
    
    // MARK: Relationships
    
    @NSManaged public var sharedZone: CloudKitZone?

}

extension CloudKitRemoval : Identifiable {

}
