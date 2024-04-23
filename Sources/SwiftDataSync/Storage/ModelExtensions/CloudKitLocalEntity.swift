import Foundation
import CoreData
import CloudKit

extension CloudKitLocalEntity {
    convenience init(id: String, localId: String, context: NSManagedObjectContext) {
        self.init(entity: Self.entity(), insertInto: context)
        
        self.id = id
        self.localId = localId
    }
}
