import CloudKit

extension CKShare {
    
    /// Whether another user owns the share and shared it with the current user.
    ///
    /// The current user's shares are in their own zones. This doesn't rely on `currentUserParticipant`,
    /// which might not be set, e.g. for a share that was stored by another sync engine.
    var isSharedByOtherUser: Bool {
        recordID.zoneID.ownerName != CKCurrentUserDefaultName
    }
}
