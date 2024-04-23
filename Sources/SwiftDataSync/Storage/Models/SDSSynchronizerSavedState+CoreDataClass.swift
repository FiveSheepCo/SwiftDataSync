import Foundation
import CoreData
import CloudKit

@objc(SDSSynchronizerSavedState)
class SDSSynchronizerSavedState: NSManagedObject {
    
    @NSCodableManagedStorage(keyPath: \SDSSynchronizerSavedState.rawChangeToken)
    var changeToken: CKServerChangeToken? = nil
    
    @NSCodableManagedStorage(keyPath: \SDSSynchronizerSavedState.rawUserId)
    var userId: CKRecord.ID? = nil
}
