import CloudKit
import Foundation
import CoreData

@objc(CloudKitZone)
class CloudKitZone: NSManagedObject {

    @NSCodableManagedStorage(keyPath: \CloudKitZone.rawChangeToken)
    var changeToken: CKServerChangeToken? = nil
}
