import Foundation
import CoreData


extension CloudKitZone {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CloudKitZone> {
        return NSFetchRequest<CloudKitZone>(entityName: "CloudKitZone")
    }
    
    // MARK: Attributes

    @NSManaged public var name: String
    @NSManaged public var owner: String
    @NSManaged public var rawChangeToken: Data?
}

extension CloudKitZone : Identifiable {

}
