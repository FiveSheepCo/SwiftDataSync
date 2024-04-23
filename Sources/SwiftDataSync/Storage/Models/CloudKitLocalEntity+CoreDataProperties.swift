import Foundation
import CoreData

extension CloudKitLocalEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CloudKitLocalEntity> {
        return NSFetchRequest<CloudKitLocalEntity>(entityName: "CloudKitLocalEntity")
    }

    @NSManaged public var id: String
    @NSManaged public var localId: String
}

extension CloudKitLocalEntity : Identifiable {

}
