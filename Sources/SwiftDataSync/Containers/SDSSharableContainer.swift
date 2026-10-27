import Foundation
import CloudKit
import CoreData

final class SDSSharableContainer: SDSSynchronizableContainer {
    
    var shareState: SDSShareState {
        if let share = share {
            return share.isSharedByOtherUser ? .sharedByOther : .shared
        }
        return .none
    }
    
    /// Read through the context it is written in, as other contexts aren't updated when it changes.
    var share: CKShare? {
        SDSSynchronizer.shared.storedShare(for: id)
    }
    
    override init(
        id: @escaping () -> String,
        object: NSManagedObject,
        parentKey: String? = nil,
        syncKeys: [String] = [],
        assetKeys: [String]
    ) {
        super.init(id: id, object: object, parentKey: parentKey, syncKeys: syncKeys, assetKeys: assetKeys)
    }
}
