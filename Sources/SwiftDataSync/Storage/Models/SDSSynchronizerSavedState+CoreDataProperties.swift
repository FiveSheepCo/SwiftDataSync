import Foundation
import CoreData
import CloudKit

extension SDSSynchronizerSavedState {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<SDSSynchronizerSavedState> {
        return NSFetchRequest<SDSSynchronizerSavedState>(entityName: "SDSSynchronizerSavedState")
    }

    @NSManaged public var didCreateZone: Bool
    @NSManaged public var didCreatePrivateSubscription: Bool
    @NSManaged public var didCreateSharedSubscription: Bool
    @NSManaged public var rawChangeToken: Data?
    @NSManaged public var rawUserId: Data?
}

extension SDSSynchronizerSavedState : Identifiable {}
