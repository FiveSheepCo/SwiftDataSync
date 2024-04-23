import Foundation
import CoreData
import CloudKit

extension CloudKitShare {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CloudKitShare> {
        return NSFetchRequest<CloudKitShare>(entityName: "CloudKitShare")
    }
    
    // MARK: Attributes

    @NSManaged public var id: String
    @NSManaged public var rawShare: Data?
    
}

extension CloudKitShare : Identifiable {
    
}
