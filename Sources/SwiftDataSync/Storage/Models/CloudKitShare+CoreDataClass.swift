import CloudKit
import Foundation
import CoreData

@objc(CloudKitShare)
class CloudKitShare: NSManagedObject {

    @NSCodableManagedStorage(keyPath: \CloudKitShare.rawShare)
    var share: CKShare? = nil
}
