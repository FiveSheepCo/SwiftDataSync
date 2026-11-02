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
    /// A root without a record isn't shared, so it isn't given one.
    var share: CKShare? {
        synchronizer?.existingRecordId(of: object).flatMap { synchronizer?.storedShare(for: $0) }
    }

    override init(
        id: @escaping () -> String,
        object: NSManagedObject,
        parentKey: String? = nil,
        syncKeys: [String] = [],
        assetKeys: [String],
        synchronizer: SDSSynchronizer? = nil
    ) {
        super.init(id: id, object: object, parentKey: parentKey, syncKeys: syncKeys, assetKeys: assetKeys, synchronizer: synchronizer)
    }
}
