import CloudKit
import Foundation
import CoreData

extension CloudKitUpdate {

    /// The record's id, in its shared zone or else in the default zone of the private database.
    func recordId(defaultZoneID: CKRecordZone.ID) -> CKRecord.ID {
        .init(recordName: id, zoneID: sharedZone?.calculatedId ?? defaultZoneID)
    }

    /// Prefixes keys in `rawChangedKeys` whose values were backfilled, see `backfilledKeys`. Property names can't contain it,
    /// so the data model doesn't change.
    static let backfillMarker = "~"
    
    /// Stands in `rawChangedKeys` for an update whose record this device named, and doesn't know to exist, see `isLocalInsert`.
    static let insertMarker = "+"
    
    private var storedKeys: [String] {
        rawChangedKeys.components(separatedBy: ",").filter({ !$0.isEmpty && $0 != Self.insertMarker })
    }
    
    /// Keys that changed locally. Their local values win over downloaded ones, as they're uploaded over them next.
    var changedKeys: [String] {
        storedKeys.filter { !$0.hasPrefix(Self.backfillMarker) }
    }
    
    /// Keys whose local values are of unknown age, e.g. of objects that were saved before synchronizing started, see
    /// `SDSSynchronizer.backfill(onlyUntracked:)`. They mustn't overwrite what's in iCloud: once the record turns out to
    /// exist, they're dropped, and only records that don't exist are uploaded with them. A local change of a key makes it a
    /// changed key.
    var backfilledKeys: [String] {
        storedKeys.filter { $0.hasPrefix(Self.backfillMarker) }.map { String($0.dropFirst(Self.backfillMarker.count)) }
    }
    
    /// Every key whose value is uploaded.
    var keysToUpload: [String] {
        changedKeys + backfilledKeys
    }
    
    /// Whether the object got its record on this device, e.g. as it was inserted, and the record isn't known to exist yet.
    /// A deletion of a record of the same name, e.g. one this device uploaded before the object was created again, doesn't
    /// delete the object. Downloading or uploading the record ends it.
    var isLocalInsert: Bool {
        rawChangedKeys.components(separatedBy: ",").contains(Self.insertMarker)
    }
    
    func addChangedKeys(_ keys: [String]) {
        var changed = changedKeys
        for key in keys where !changed.contains(key) {
            changed.append(key)
        }
        setKeys(changed: changed, backfilled: backfilledKeys.filter { !changed.contains($0) }, isLocalInsert: isLocalInsert)
        // Also if the keys were pending already: an upload that read the previous values mustn't take the update for done,
        // and a record CloudKit rejected is tried again once it changes, see `SDSRecordQuarantine`
        if !keys.isEmpty {
            touch()
        }
    }
    
    /// Notes that the update changed, later than before, also if the clock was turned back.
    private func touch() {
        lastChangeDate = max(.now, lastChangeDate.addingTimeInterval(0.001))
    }
    
    /// Adds keys as backfilled, unless they changed locally already.
    func addBackfilledKeys(_ keys: [String]) {
        let changed = changedKeys
        var backfilled = backfilledKeys
        for key in keys where !changed.contains(key) && !backfilled.contains(key) {
            backfilled.append(key)
        }
        setKeys(changed: changed, backfilled: backfilled, isLocalInsert: isLocalInsert)
    }
    
    func markAsLocalInsert() {
        setKeys(changed: changedKeys, backfilled: backfilledKeys, isLocalInsert: true)
    }
    
    /// The record exists: backfilled values are dropped, as the record's values win, and it's no local insert anymore.
    func recordExists() {
        setKeys(changed: changedKeys, backfilled: [], isLocalInsert: false)
    }
    
    private func setKeys(changed: [String], backfilled: [String], isLocalInsert: Bool) {
        let raw = ((isLocalInsert ? [Self.insertMarker] : []) + changed + backfilled.map { Self.backfillMarker + $0 }).joined(separator: ",")
        guard raw != rawChangedKeys else { return }
        rawChangedKeys = raw
        touch()
    }
    
    static func find(for id: String) -> CloudKitUpdate? {
        let request: NSFetchRequest<CloudKitUpdate> = self.fetchRequest()
        request.sortDescriptors = []
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id = %@", id)

        let update = try? request.execute().first
        if let update {
            // Another process could have changed the update since it was fetched last
            update.managedObjectContext?.refresh(update, mergeChanges: true)
        }
        return update
    }

    /// The updates with the given ids, by id. Has to be called on `context`'s queue.
    static func find(ids: [String], in context: NSManagedObjectContext) -> [String: CloudKitUpdate] {
        guard !ids.isEmpty else { return [:] }
        let request: NSFetchRequest<CloudKitUpdate> = self.fetchRequest()
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: "id IN %@", ids)
        // Another process could have changed them since they were fetched last
        request.shouldRefreshRefetchedObjects = true
        return Dictionary(((try? context.fetch(request)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func retrieve(for id: String, entityName: String, context: NSManagedObjectContext) -> CloudKitUpdate {
        if let update = find(for: id) {
            return update
        } else {
            return CloudKitUpdate(id: id, entityName: entityName, context: context)
        }
    }

    convenience init(id: String, entityName: String, context: NSManagedObjectContext) {
        // The entity of the context's model, as the class could belong to several models, e.g. in tests
        self.init(entity: NSEntityDescription.entity(forEntityName: "CloudKitUpdate", in: context)!, insertInto: context)

        self.id = id
        self.recordType = entityName
        self.lastChangeDate = .now
    }
}
