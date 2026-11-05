import CoreData

/// The merge policy of the observed update context, which downloads save to.
///
/// A row the app saved after the download read it conflicts with the downloaded values. The app's values win for the keys
/// it changed, as they're local changes, which are uploaded over the record next, and the downloaded values for the others,
/// like local changes win key by key over downloaded records, see `CKDownloadHandler.keepLocalChanges(in:)`.
///
/// Uniqueness constraints are resolved like `NSMergePolicy.mergeByPropertyObjectTrump`, which folds a downloaded duplicate
/// into the local object with the downloaded values.
final class SDSDownloadMergePolicy: NSMergePolicy, @unchecked Sendable {
    init() {
        super.init(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    }

    override func resolve(optimisticLockingConflicts list: [NSMergeConflict]) throws {
        try NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType).resolve(optimisticLockingConflicts: list)
    }
}
