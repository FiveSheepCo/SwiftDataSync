import Foundation
import CloudKit
import CoreData

class SDSSharableContainer: SDSSynchronizableContainer {
    
    var shareState: SDSShareState {
        if let share = share {
            return (share.currentUserParticipant == share.owner) ? .shared : .sharedByOther
        }
        return .none
    }
    
    var share: CKShare? {
        var share: CKShare? = nil
        if Thread.isMainThread {
            share = CloudKitShare.retrieveShare(for: id)
        } else {
            SDSSynchronizer.shared.context.performAndWait {
                share = CloudKitShare.retrieveShare(for: id)
            }
        }
        return share
    }
    
    override init(
        id: @escaping () -> String,
        object: NSManagedObject,
        parentKey: String? = nil,
        syncKeys: [String] = []
    ) {
        super.init(id: id, object: object, parentKey: parentKey, syncKeys: syncKeys)
    }
}
