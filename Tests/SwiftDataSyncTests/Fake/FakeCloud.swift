import Foundation
import CloudKit
import os
@testable import SwiftDataSync

/// Change tokens have no public initializer. They're made from an archive like the one `CKServerChangeToken` writes, with
/// the fake server's own data, and read the same way.
enum FakeChangeToken {

    /// Encodes and decodes like `CKServerChangeToken`, which archives its data under `ChangeTokenData`.
    @objc(SDSFakeChangeTokenArchive)
    private final class Archive: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let data: Data

        init(data: Data) {
            self.data = data
        }

        required init?(coder: NSCoder) {
            data = (coder.decodeObject(of: NSData.self, forKey: "ChangeTokenData") as Data?) ?? Data()
        }

        func encode(with coder: NSCoder) {
            coder.encode(data, forKey: "ChangeTokenData")
        }
    }

    struct Content: Codable, Equatable {
        /// Which incarnation of the zone the token belongs to. A zone that was deleted and created again has another one.
        let incarnation: UUID
        /// The last change the token includes.
        let sequence: Int
    }

    static func make(_ content: Content) -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: Archive.self)
        archiver.encode(Archive(data: try! JSONEncoder().encode(content)), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return try! NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: archiver.encodedData)!
    }

    static func content(of token: CKServerChangeToken?) -> Content? {
        guard
            let token,
            let archived = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true),
            let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archived)
        else { return nil }
        unarchiver.setClass(Archive.self, forClassName: "CKServerChangeToken")
        guard let archive = unarchiver.decodeObject(of: Archive.self, forKey: NSKeyedArchiveRootObjectKey) else { return nil }
        return try? JSONDecoder().decode(Content.self, from: archive.data)
    }
}

/// An in-memory CloudKit server shared by several fake devices, see `FakeCloudContainer`.
///
/// It interprets the operations the synchronizer adds by calling their blocks like CloudKit: zones with change tokens and
/// pages, `.changedKeys`, `.allKeys` and `.ifServerRecordUnchanged` saves, deletions in the change feed, record and request
/// limits, a development or production schema, and errors that tests inject.
final class FakeCloudServer: @unchecked Sendable {

    /// Records hold at most 1 MB, not counting assets.
    static let recordSizeLimit = 1_000_000
    static let maximumRecordsPerOperation = 400

    enum StoredValue {
        case value(CKRecordValue)
        case asset(Data)
    }

    struct StoredRecord {
        var recordType: String
        var values: [String: StoredValue] = [:]
        var parent: CKRecord.Reference?
        var tag: String
        var sequence: Int
    }

    private struct LogEntry {
        let sequence: Int
        let recordName: String
        let recordType: String
        let isDeletion: Bool
    }

    private final class Zone {
        var incarnation = UUID()
        var sequence = 0
        var records: [String: StoredRecord] = [:]
        var log: [LogEntry] = []
    }

    private final class Account {
        var zones: [String: Zone] = [:]
        /// Zones that were deleted, and whether the user deleted them, e.g. in the iCloud settings.
        var deletedZones: [String: Bool] = [:]
        var subscriptions: [String: [CKSubscription.ID: CKSubscription]] = [:]
    }

    /// What a device asked the server to do, for tests to check.
    struct Event: Sendable {
        enum Kind: Sendable { case modifyRecords, fetchChanges, modifyZones, other }
        let device: String
        let kind: Kind
        let date = Date()
        /// For record saves: the changed keys of every saved record, by name.
        var savedKeys: [String: Set<String>] = [:]
        var deletedNames: [String] = []
        var savePolicy: CKModifyRecordsOperation.RecordSavePolicy?
        /// For downloads: where the device's change token said it is.
        var tokenSequence: Int?
        var failed = false
    }

    private let lock = NSRecursiveLock()
    private var accounts: [String: Account] = [:]
    private var _events: [Event] = []

    // MARK: Behaviour

    /// Whether saving a record that has no change tag over an existing one fails with `serverRecordChanged` with
    /// `.changedKeys`, rather than saving its changed keys over it.
    var freshRecordsConflict: Bool {
        get { lock.withLock { _freshRecordsConflict } }
        set { lock.withLock { _freshRecordsConflict = newValue } }
    }
    private var _freshRecordsConflict = true

    /// Whether deleting a record deletes the records whose `.deleteSelf` references point at it, like CloudKit does.
    var cascadesDeleteSelf: Bool {
        get { lock.withLock { _cascadesDeleteSelf } }
        set { lock.withLock { _cascadesDeleteSelf = newValue } }
    }
    private var _cascadesDeleteSelf = false

    /// How many changes a download receives per page, between change token updates.
    var pageSize: Int {
        get { lock.withLock { _pageSize } }
        set { lock.withLock { _pageSize = newValue } }
    }
    private var _pageSize = 200

    /// In production, records and fields that the schema doesn't have are rejected. In development, saving them adds them.
    var isProduction: Bool {
        get { lock.withLock { _isProduction } }
        set { lock.withLock { _isProduction = newValue } }
    }
    private var _isProduction = false
    /// Record types and their fields.
    private(set) var schema: [String: Set<String>] {
        get { lock.withLock { _schema } }
        set { lock.withLock { _schema = newValue } }
    }
    private var _schema: [String: Set<String>] = [:]

    /// Called with the device and how many pages a download delivered so far, after each change token update.
    var pageDelivered: (@Sendable (_ device: String, _ pages: Int) -> Void)? {
        get { lock.withLock { _pageDelivered } }
        set { lock.withLock { _pageDelivered = newValue } }
    }
    private var _pageDelivered: (@Sendable (String, Int) -> Void)?

    /// Called with the device and the number of the page, after a page's records were delivered and before its change token
    /// update, which saves the page.
    var beforePageTokenUpdate: (@Sendable (_ device: String, _ page: Int) -> Void)? {
        get { lock.withLock { _beforePageTokenUpdate } }
        set { lock.withLock { _beforePageTokenUpdate = newValue } }
    }
    private var _beforePageTokenUpdate: (@Sendable (String, Int) -> Void)?

    /// Makes the next download stop after this many pages and never finish, like a process that is terminated meanwhile.
    var hangDownloadAfterPages: Int? {
        get { lock.withLock { _hangDownloadAfterPages } }
        set { lock.withLock { _hangDownloadAfterPages = newValue } }
    }
    private var _hangDownloadAfterPages: Int?
    /// Downloads that never finish keep their operations, so their continuations aren't reported as leaked.
    private var hungOperations: [CKOperation] = []
    private(set) var hungDownloads: Int {
        get { lock.withLock { _hungDownloads } }
        set { lock.withLock { _hungDownloads = newValue } }
    }
    private var _hungDownloads = 0

    /// Called before a device's record operation is applied, with the names of the records it saves, e.g. to change the
    /// server in between, like another device that uploads right then.
    var beforeModifyRecords: (@Sendable (_ device: String, _ savedNames: [String]) -> Void)? {
        get { lock.withLock { _beforeModifyRecords } }
        set { lock.withLock { _beforeModifyRecords = newValue } }
    }
    private var _beforeModifyRecords: (@Sendable (String, [String]) -> Void)?

    /// Called after a device's download failed, with the error.
    var fetchFailed: (@Sendable (_ device: String, _ error: CKError) -> Void)? {
        get { lock.withLock { _fetchFailed } }
        set { lock.withLock { _fetchFailed = newValue } }
    }
    private var _fetchFailed: (@Sendable (String, CKError) -> Void)?

    /// How many operations of a device ran at the same time at most.
    func maximumConcurrentOperations(of device: String) -> Int {
        lock.withLock { maximumRunning[device] ?? 0 }
    }
    private var running: [String: Int] = [:]
    private var maximumRunning: [String: Int] = [:]

    private func beginOperation(_ device: String) {
        lock.withLock {
            running[device, default: 0] += 1
            maximumRunning[device] = max(maximumRunning[device] ?? 0, running[device] ?? 0)
        }
    }

    private func endOperation(_ device: String) {
        lock.withLock { running[device, default: 1] -= 1 }
    }

    // MARK: Injected Errors

    private struct RecordFailure {
        let matches: @Sendable (CKRecord.ID) -> Bool
        let error: CKError
        var remaining: Int
    }
    private var recordFailures: [RecordFailure] = []
    private var modifyFailures: [CKError] = []
    private var fetchFailures: [CKError] = []
    private var downloadFailures: [RecordFailure] = []
    private var deleteFailures: [RecordFailure] = []
    private var brokenAssets: [RecordFailure] = []

    /// Fails deleting the matching records with `error`, `count` times in all.
    func failDeleting(where matches: @escaping @Sendable (CKRecord.ID) -> Bool, with error: CKError, count: Int = .max) {
        lock.withLock { deleteFailures.append(RecordFailure(matches: matches, error: error, remaining: count)) }
    }

    /// Delivers the assets of the matching records with files that don't exist, e.g. as the system removed them, `count` times in all.
    func breakAssetFiles(where matches: @escaping @Sendable (CKRecord.ID) -> Bool, count: Int = .max) {
        lock.withLock { brokenAssets.append(RecordFailure(matches: matches, error: CKError(.assetFileNotFound), remaining: count)) }
    }

    /// Deletes records directly, e.g. on another device.
    func delete(_ recordNames: [String], account: String, zone: CKRecordZone.ID = .scenario) {
        lock.withLock {
            guard let stored = self.account(account).zones[zone.zoneName] else { return }
            for name in recordNames {
                guard let existing = stored.records[name] else { continue }
                stored.records[name] = nil
                stored.sequence += 1
                stored.log.append(LogEntry(sequence: stored.sequence, recordName: name, recordType: existing.recordType, isDeletion: true))
            }
        }
    }

    /// Fails downloading the matching records, like a record whose asset couldn't be downloaded, `count` times in all.
    func failDownloading(where matches: @escaping @Sendable (CKRecord.ID) -> Bool, with error: CKError, count: Int = .max) {
        lock.withLock { downloadFailures.append(RecordFailure(matches: matches, error: error, remaining: count)) }
    }

    /// Fails saving the matching records with `error`, `count` times in all.
    func failSaving(where matches: @escaping @Sendable (CKRecord.ID) -> Bool, with error: CKError, count: Int = .max) {
        lock.withLock { recordFailures.append(RecordFailure(matches: matches, error: error, remaining: count)) }
    }

    /// Fails the next record operation as a whole.
    func failNextModify(with error: CKError) {
        lock.withLock { modifyFailures.append(error) }
    }

    /// Fails the next download as a whole.
    func failNextFetch(with error: CKError) {
        lock.withLock { fetchFailures.append(error) }
    }

    /// Fails downloading every zone until it's set to `nil`, which fails the download partially.
    var zoneFetchFailure: CKError? {
        get { lock.withLock { _zoneFetchFailure } }
        set { lock.withLock { _zoneFetchFailure = newValue } }
    }
    private var _zoneFetchFailure: CKError?

    /// Fails every download as a whole until it's set to `nil`.
    var fetchFailure: CKError? {
        get { lock.withLock { _fetchFailure } }
        set { lock.withLock { _fetchFailure = newValue } }
    }
    private var _fetchFailure: CKError?

    // MARK: Inspecting

    var events: [Event] {
        lock.withLock { _events }
    }

    func events(of device: String, _ kind: Event.Kind) -> [Event] {
        events.filter { $0.device == device && $0.kind == kind }
    }

    private func record(_ event: Event) {
        lock.withLock { _events.append(event) }
    }

    /// The records of a zone, as a download would deliver them.
    func records(account: String, zone: CKRecordZone.ID = .scenario) -> [CKRecord] {
        lock.withLock {
            guard let stored = accounts[account]?.zones[zone.zoneName] else { return [] }
            return stored.records.map { makeRecord(name: $0.key, stored: $0.value, zoneID: zone, desiredKeys: nil) }
        }
    }

    func record(named name: String, account: String, zone: CKRecordZone.ID = .scenario) -> CKRecord? {
        lock.withLock {
            accounts[account]?.zones[zone.zoneName]?.records[name].map { makeRecord(name: name, stored: $0, zoneID: zone, desiredKeys: nil) }
        }
    }

    func hasZone(_ zone: CKRecordZone.ID = .scenario, account: String) -> Bool {
        lock.withLock { accounts[account]?.zones[zone.zoneName] != nil }
    }

    // MARK: Changing the Server

    func createZone(_ zone: CKRecordZone.ID = .scenario, account: String) {
        lock.withLock {
            let account = self.account(account)
            if account.zones[zone.zoneName] == nil {
                account.zones[zone.zoneName] = Zone()
                account.deletedZones[zone.zoneName] = nil
            }
        }
    }

    /// Deletes a zone, e.g. on another device, or by the user in the iCloud settings (`byUser`).
    func deleteZone(_ zone: CKRecordZone.ID = .scenario, account: String, byUser: Bool) {
        lock.withLock {
            let account = self.account(account)
            account.zones[zone.zoneName] = nil
            account.deletedZones[zone.zoneName] = byUser
        }
    }

    /// Saves records directly, e.g. ones other devices uploaded long ago.
    func seed(_ records: [CKRecord], account: String, zone: CKRecordZone.ID = .scenario) {
        lock.withLock {
            createZone(zone, account: account)
            let stored = self.account(account).zones[zone.zoneName]!
            for record in records {
                apply(record, keys: record.allKeys(), to: stored, existing: nil, assets: assetData(of: record))
            }
        }
    }

    private func account(_ name: String) -> Account {
        if let account = accounts[name] { return account }
        let account = Account()
        accounts[name] = account
        return account
    }

    // MARK: Operations

    /// - Parameter currentAccount: The account signed in on the device, which can change while an operation runs.
    func run(_ operation: CKDatabaseOperation, device: String, currentAccount: @escaping @Sendable () -> String?, isShared: Bool) {
        let accountName = currentAccount()
        switch operation {
        case let operation as CKModifyRecordsOperation:
            // CloudKit reads the files of assets while uploading. Their files are removed once the operation is done.
            let assets = (operation.recordsToSave ?? []).map(assetData(of:))
            DispatchQueue.global().async {
                self.beginOperation(device)
                self.modifyRecords(operation, assets: assets, device: device, accountName: accountName, isShared: isShared)
                self.endOperation(device)
            }
        case let operation as CKFetchRecordZoneChangesOperation:
            DispatchQueue.global().async {
                self.beginOperation(device)
                self.fetchChanges(operation, device: device, currentAccount: currentAccount, isShared: isShared)
                self.endOperation(device)
            }
        case let operation as CKModifyRecordZonesOperation:
            DispatchQueue.global().async {
                self.modifyZones(operation, device: device, accountName: accountName, isShared: isShared)
            }
        case let operation as CKModifySubscriptionsOperation:
            DispatchQueue.global().async {
                self.lock.withLock {
                    if let accountName {
                        let scope = isShared ? "shared" : "private"
                        for subscription in operation.subscriptionsToSave ?? [] {
                            self.account(accountName).subscriptions[scope, default: [:]][subscription.subscriptionID] = subscription
                        }
                    }
                }
                self.record(Event(device: device, kind: .other))
                operation.modifySubscriptionsResultBlock?(accountName == nil ? .failure(CKError(.notAuthenticated)) : .success(()))
            }
        default:
            fatalError("The fake server doesn't support \(type(of: operation))")
        }
    }

    func allRecordZones(accountName: String?, isShared: Bool) throws -> [CKRecordZone] {
        guard let accountName else { throw CKError(.notAuthenticated) }
        guard !isShared else { return [] }
        return lock.withLock {
            account(accountName).zones.keys.map { CKRecordZone(zoneID: CKRecordZone.ID(zoneName: $0)) }
        }
    }

    func allSubscriptions(accountName: String?, isShared: Bool) throws -> [CKSubscription] {
        guard let accountName else { throw CKError(.notAuthenticated) }
        return lock.withLock {
            Array((account(accountName).subscriptions[isShared ? "shared" : "private"] ?? [:]).values)
        }
    }

    // MARK: Saving

    private func assetData(of record: CKRecord) -> [String: Data] {
        var assets: [String: Data] = [:]
        for key in record.allKeys() {
            guard let fileURL = (record[key] as? CKAsset)?.fileURL else { continue }
            assets[key] = try? Data(contentsOf: fileURL)
        }
        return assets
    }

    private func modifyRecords(_ operation: CKModifyRecordsOperation, assets: [[String: Data]], device: String, accountName: String?, isShared: Bool) {
        let recordsToSave = operation.recordsToSave ?? []
        let recordIDsToDelete = operation.recordIDsToDelete ?? []
        var event = Event(device: device, kind: .modifyRecords, savePolicy: operation.savePolicy)

        let finish = { (error: CKError) in
            event.failed = true
            self.record(event)
            operation.modifyRecordsResultBlock?(.failure(error))
        }
        guard let accountName else { return finish(CKError(.notAuthenticated)) }
        if let error = lock.withLock({ modifyFailures.isEmpty ? nil : modifyFailures.removeFirst() }) {
            return finish(error)
        }
        guard recordsToSave.count + recordIDsToDelete.count <= Self.maximumRecordsPerOperation else {
            return finish(CKError(.limitExceeded))
        }
        // CloudKit rejects saving a record twice, or saving and deleting it, in one operation
        let recordIDs = recordsToSave.map(\.recordID) + recordIDsToDelete
        guard Set(recordIDs).count == recordIDs.count else {
            return finish(CKError(.invalidArguments))
        }
        guard !isShared else {
            // This fake has no shares
            return finish(CKError(.zoneNotFound))
        }
        beforeModifyRecords?(device, recordsToSave.map(\.recordID.recordName))

        var saveResults: [(CKRecord.ID, Result<CKRecord, any Error>)] = []
        var deleteResults: [(CKRecord.ID, Result<Void, any Error>)] = []
        lock.withLock {
            let account = self.account(accountName)
            var savedInOperation: Set<String> = []
            for (record, assets) in zip(recordsToSave, assets) {
                // Parents and references that delete the record with their target need the target, also saved earlier in the operation
                if let error = referenceError(of: record, in: account, savedInOperation: savedInOperation) {
                    saveResults.append((record.recordID, .failure(error)))
                    continue
                }
                let result = save(record, assets: assets, policy: operation.savePolicy, in: account)
                if case .success = result {
                    savedInOperation.insert(record.recordID.recordName)
                }
                if case .success = result {
                    event.savedKeys[record.recordID.recordName] = Set(record.changedKeys())
                }
                saveResults.append((record.recordID, result))
            }
            for recordID in recordIDsToDelete {
                if let index = deleteFailures.firstIndex(where: { $0.remaining > 0 && $0.matches(recordID) }) {
                    deleteFailures[index].remaining -= 1
                    deleteResults.append((recordID, .failure(deleteFailures[index].error)))
                    continue
                }
                guard let zone = account.zones[recordID.zoneID.zoneName] else {
                    deleteResults.append((recordID, .failure(zoneError(recordID.zoneID, in: account))))
                    continue
                }
                guard let existing = zone.records[recordID.recordName] else {
                    deleteResults.append((recordID, .failure(CKError(.unknownItem))))
                    continue
                }
                zone.records[recordID.recordName] = nil
                zone.sequence += 1
                zone.log.append(LogEntry(sequence: zone.sequence, recordName: recordID.recordName, recordType: existing.recordType, isDeletion: true))
                event.deletedNames.append(recordID.recordName)
                deleteResults.append((recordID, .success(())))
                guard _cascadesDeleteSelf else { continue }
                var deletedNames = [recordID.recordName]
                while let deletedName = deletedNames.popLast() {
                    for (name, stored) in zone.records {
                        let references = stored.values.values.compactMap { value -> CKRecord.Reference? in
                            if case .value(let value) = value { value as? CKRecord.Reference } else { nil }
                        }
                        guard references.contains(where: { $0.action == .deleteSelf && $0.recordID.recordName == deletedName }) else { continue }
                        zone.records[name] = nil
                        zone.sequence += 1
                        zone.log.append(LogEntry(sequence: zone.sequence, recordName: name, recordType: stored.recordType, isDeletion: true))
                        deletedNames.append(name)
                    }
                }
            }
        }

        for (recordID, result) in saveResults {
            operation.perRecordSaveBlock?(recordID, result)
        }
        for (recordID, result) in deleteResults {
            operation.perRecordDeleteBlock?(recordID, result)
        }

        var partialErrors: [CKRecord.ID: any Error] = [:]
        for (recordID, result) in saveResults {
            if case .failure(let error) = result { partialErrors[recordID] = error }
        }
        for (recordID, result) in deleteResults {
            if case .failure(let error) = result { partialErrors[recordID] = error }
        }
        record(event)
        if partialErrors.isEmpty {
            operation.modifyRecordsResultBlock?(.success(()))
        } else {
            operation.modifyRecordsResultBlock?(.failure(CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: partialErrors])))
        }
    }

    /// Has to be called while locked.
    private func referenceError(of record: CKRecord, in account: Account, savedInOperation: Set<String>) -> CKError? {
        var targets: [CKRecord.ID] = []
        if let parent = record.parent {
            targets.append(parent.recordID)
        }
        for key in record.changedKeys() {
            if let reference = record[key] as? CKRecord.Reference, reference.action == .deleteSelf {
                targets.append(reference.recordID)
            }
        }
        for target in targets {
            let exists = account.zones[target.zoneID.zoneName]?.records[target.recordName] != nil || savedInOperation.contains(target.recordName)
            if target == record.recordID || !exists {
                return CKError(.referenceViolation, userInfo: [NSLocalizedDescriptionKey: "The target of a parent or delete-self reference of \(record.recordID.recordName) was not found"])
            }
        }
        return nil
    }

    private func zoneError(_ zoneID: CKRecordZone.ID, in account: Account) -> CKError {
        account.deletedZones[zoneID.zoneName] == true ? CKError(.userDeletedZone) : CKError(.zoneNotFound)
    }

    /// Has to be called while locked.
    private func save(_ record: CKRecord, assets: [String: Data], policy: CKModifyRecordsOperation.RecordSavePolicy, in account: Account) -> Result<CKRecord, any Error> {
        let recordID = record.recordID
        if let index = recordFailures.firstIndex(where: { $0.remaining > 0 && $0.matches(recordID) }) {
            recordFailures[index].remaining -= 1
            return .failure(recordFailures[index].error)
        }
        guard let zone = account.zones[recordID.zoneID.zoneName] else {
            return .failure(zoneError(recordID.zoneID, in: account))
        }

        let changedKeys = record.changedKeys()
        // CloudKit reads the file of every asset it saves
        if changedKeys.contains(where: { record[$0] is CKAsset && assets[$0] == nil }) {
            return .failure(CKError(.assetFileNotFound))
        }
        // The limit is on the whole record as stored, not only on the keys that change (assets don't count)
        let existingRecord = account.zones[recordID.zoneID.zoneName]?.records[recordID.recordName]
        let savedKeys = policy == .allKeys ? record.allKeys() : changedKeys
        let keptSize = policy == .allKeys ? 0 : (existingRecord?.values ?? [:]).reduce(0) { sum, entry in
            guard !savedKeys.contains(entry.key), case .value(let value) = entry.value else { return sum }
            return sum + Self.size(of: value)
        }
        let size = savedKeys.reduce(keptSize) { $0 + Self.size(of: record[$1]) }
        guard size <= Self.recordSizeLimit else {
            return .failure(CKError(.limitExceeded, userInfo: [NSLocalizedDescriptionKey: "Record too large"]))
        }

        if let error = checkSchema(record, keys: changedKeys) {
            return .failure(error)
        }

        let existing = zone.records[recordID.recordName]
        let conflict = { (existing: StoredRecord) -> Result<CKRecord, any Error> in
            .failure(CKError(.serverRecordChanged, userInfo: [
                CKRecordChangedErrorServerRecordKey: self.makeRecord(name: recordID.recordName, stored: existing, zoneID: recordID.zoneID, desiredKeys: nil),
                CKRecordChangedErrorClientRecordKey: record
            ]))
        }
        switch (policy, existing) {
        case (.ifServerRecordUnchanged, let existing?):
            // Saving a record without a change tag inserts it, which fails once it exists
            guard record.recordChangeTag == existing.tag else { return conflict(existing) }
        case (.changedKeys, let existing?):
            if record.recordChangeTag == nil && freshRecordsConflictUnlocked {
                return conflict(existing)
            }
        case (_, nil):
            // A record that was saved before, as it has a change tag, was deleted since
            if record.recordChangeTag != nil {
                return .failure(CKError(.unknownItem))
            }
        default:
            break
        }

        let keys = policy == .allKeys ? record.allKeys() : changedKeys
        let stored = apply(record, keys: keys, to: zone, existing: policy == .allKeys ? nil : existing, assets: assets)
        return .success(makeRecord(name: recordID.recordName, stored: stored, zoneID: recordID.zoneID, desiredKeys: nil))
    }

    private var freshRecordsConflictUnlocked: Bool { _freshRecordsConflict }

    /// Has to be called while locked.
    @discardableResult
    private func apply(_ record: CKRecord, keys: [String], to zone: Zone, existing: StoredRecord?, assets: [String: Data]) -> StoredRecord {
        var stored = existing ?? StoredRecord(recordType: record.recordType, tag: "", sequence: 0)
        for key in keys {
            if let data = assets[key] {
                stored.values[key] = .asset(data)
            } else if let value = record[key] {
                stored.values[key] = .value(value)
            } else {
                stored.values[key] = nil
            }
        }
        if record.parent != nil || keys.contains(SDSSynchronizer.Constants.parentWorkaroundKey) {
            stored.parent = record.parent
        }
        zone.sequence += 1
        stored.sequence = zone.sequence
        stored.tag = UUID().uuidString
        zone.records[record.recordID.recordName] = stored
        zone.log.append(LogEntry(sequence: zone.sequence, recordName: record.recordID.recordName, recordType: record.recordType, isDeletion: false))
        return stored
    }

    /// Has to be called while locked.
    private func checkSchema(_ record: CKRecord, keys: [String]) -> CKError? {
        if _isProduction {
            guard let fields = _schema[record.recordType] else {
                return CKError(.invalidArguments, userInfo: [NSLocalizedDescriptionKey: "Cannot create new type \(record.recordType) in production schema"])
            }
            // Also keys that are cleared, which name a field the record type has to have
            if let unknown = keys.first(where: { !fields.contains($0) }) {
                return CKError(.invalidArguments, userInfo: [NSLocalizedDescriptionKey: "Cannot create new field \(unknown) in production schema"])
            }
        } else {
            _schema[record.recordType, default: []].formUnion(keys.filter { record[$0] != nil })
        }
        return nil
    }

    private static func size(of value: Any?) -> Int {
        switch value {
        case nil, is CKAsset: 0
        case let string as String: string.utf8.count
        case let data as Data: data.count
        case let reference as CKRecord.Reference: reference.recordID.recordName.utf8.count + 32
        case let array as [Any]: array.reduce(0) { $0 + size(of: $1) }
        default: 8
        }
    }

    // MARK: Downloading

    private enum Change {
        case changed(CKRecord)
        case deleted(CKRecord.ID, CKRecord.RecordType)
    }

    private func fetchChanges(_ operation: CKFetchRecordZoneChangesOperation, device: String, currentAccount: @Sendable () -> String?, isShared: Bool) {
        let accountName = currentAccount()
        let zoneIDs = operation.recordZoneIDs ?? []
        var event = Event(device: device, kind: .fetchChanges)

        let fail = { (error: CKError) in
            event.failed = true
            self.record(event)
            for zoneID in zoneIDs {
                operation.recordZoneFetchResultBlock?(zoneID, .failure(error))
            }
            operation.fetchRecordZoneChangesResultBlock?(.failure(error))
            self.fetchFailed?(device, error)
        }
        guard let accountName else { return fail(CKError(.notAuthenticated)) }
        if let error = lock.withLock({ fetchFailures.isEmpty ? _fetchFailure : fetchFailures.removeFirst() }) {
            return fail(error)
        }

        // CloudKit removes the files of downloaded assets once the operation is over, so they have to be copied before
        let assetsDirectory = Self.downloadedAssetsDirectory.appending(component: "fetch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assetsDirectory) }

        var zoneErrors: [CKRecordZone.ID: any Error] = [:]
        for zoneID in zoneIDs {
            let configuration = operation.configurationsByRecordZoneID?[zoneID]
            let token = FakeChangeToken.content(of: configuration?.previousServerChangeToken)
            if event.tokenSequence == nil {
                event.tokenSequence = token?.sequence ?? 0
            }

            // The changes since the token, read at once like a snapshot
            let snapshot: Result<(changes: [(sequence: Int, change: Change)], incarnation: UUID, end: Int), CKError> = lock.withLock {
                let account = self.account(accountName)
                if let zoneFetchFailure = _zoneFetchFailure {
                    return .failure(zoneFetchFailure)
                }
                guard !isShared, let zone = account.zones[zoneID.zoneName] else {
                    return .failure(isShared ? CKError(.zoneNotFound) : zoneError(zoneID, in: account))
                }
                if let token, token.incarnation != zone.incarnation {
                    return .failure(CKError(.changeTokenExpired))
                }
                let since = token?.sequence ?? 0
                var latest: [String: LogEntry] = [:]
                for entry in zone.log where entry.sequence > since {
                    latest[entry.recordName] = entry
                }
                let changes = latest.values.sorted { $0.sequence < $1.sequence }.map { entry -> (Int, Change) in
                    let recordID = CKRecord.ID(recordName: entry.recordName, zoneID: zoneID)
                    if !entry.isDeletion, let stored = zone.records[entry.recordName] {
                        let record = makeRecord(name: entry.recordName, stored: stored, zoneID: zoneID, desiredKeys: configuration?.desiredKeys, assetsDirectory: assetsDirectory)
                        if let index = brokenAssets.firstIndex(where: { $0.remaining > 0 && $0.matches(recordID) }) {
                            brokenAssets[index].remaining -= 1
                            for key in record.allKeys() where record[key] is CKAsset {
                                record[key] = CKAsset(fileURL: Self.downloadedAssetsDirectory.appending(component: "missing-\(UUID().uuidString)"))
                            }
                            _ = record.perform(NSSelectorFromString("resetChangedKeys"))
                        }
                        return (entry.sequence, .changed(record))
                    }
                    return (entry.sequence, .deleted(recordID, entry.recordType))
                }
                return .success((changes, zone.incarnation, zone.sequence))
            }

            switch snapshot {
            case .failure(let error):
                zoneErrors[zoneID] = error
                operation.recordZoneFetchResultBlock?(zoneID, .failure(error))
            case .success(let snapshot):
                let pageSize = self.pageSize
                var pages = 0
                var index = 0
                var moreComing = false
                while index < snapshot.changes.count {
                    // E.g. the user signed out meanwhile
                    guard currentAccount() == accountName else { return fail(CKError(.notAuthenticated)) }
                    let page = snapshot.changes[index ..< min(index + pageSize, snapshot.changes.count)]
                    for (_, change) in page {
                        if operation.isCancelled {
                            record(event)
                            operation.fetchRecordZoneChangesResultBlock?(.failure(CKError(.operationCancelled)))
                            return
                        }
                        switch change {
                        case .changed(let record):
                            let failure: CKError? = lock.withLock {
                                guard let index = downloadFailures.firstIndex(where: { $0.remaining > 0 && $0.matches(record.recordID) }) else { return nil }
                                downloadFailures[index].remaining -= 1
                                return downloadFailures[index].error
                            }
                            operation.recordWasChangedBlock?(record.recordID, failure.map { .failure($0) } ?? .success(record))
                        case .deleted(let recordID, let recordType): operation.recordWithIDWasDeletedBlock?(recordID, recordType)
                        }
                    }
                    index += page.count
                    pages += 1

                    // CloudKit only calls the token update block between pages: the last token comes with the zone's result
                    let isLastPage = index >= snapshot.changes.count
                    if !isLastPage {
                        let token = FakeChangeToken.make(.init(incarnation: snapshot.incarnation, sequence: page.last!.sequence))
                        beforePageTokenUpdate?(device, pages)
                        operation.recordZoneChangeTokensUpdatedBlock?(zoneID, token, nil)
                        pageDelivered?(device, pages)
                    }

                    let hangs: Bool = lock.withLock {
                        guard let hangAfter = _hangDownloadAfterPages, pages >= hangAfter else { return false }
                        _hangDownloadAfterPages = nil
                        hungOperations.append(operation)
                        _hungDownloads += 1
                        return true
                    }
                    if hangs {
                        record(event)
                        return
                    }
                    if !operation.fetchAllChanges && index < snapshot.changes.count {
                        moreComing = true
                        break
                    }
                }
                let endSequence = moreComing ? snapshot.changes[index - 1].sequence : snapshot.end
                let token = FakeChangeToken.make(.init(incarnation: snapshot.incarnation, sequence: endSequence))
                // The hooks of the zone's last page run around its result, which brings that page's token
                let deliversLastPage = !moreComing && pages > 0
                if deliversLastPage {
                    beforePageTokenUpdate?(device, pages)
                }
                operation.recordZoneFetchResultBlock?(zoneID, .success((serverChangeToken: token, clientChangeTokenData: nil, moreComing: moreComing)))
                if deliversLastPage {
                    pageDelivered?(device, pages)
                }
            }
        }

        if operation.isCancelled {
            record(event)
            operation.fetchRecordZoneChangesResultBlock?(.failure(CKError(.operationCancelled)))
            return
        }
        if zoneErrors.isEmpty {
            record(event)
            operation.fetchRecordZoneChangesResultBlock?(.success(()))
        } else {
            event.failed = true
            record(event)
            let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: zoneErrors])
            operation.fetchRecordZoneChangesResultBlock?(.failure(error))
            for zoneError in zoneErrors.values {
                if let zoneError = zoneError as? CKError {
                    fetchFailed?(device, zoneError)
                }
            }
        }
    }

    /// A record as CloudKit returns it: with a change tag, assets in files, and no changed keys. Has to be called while locked.
    private func makeRecord(name: String, stored: StoredRecord, zoneID: CKRecordZone.ID, desiredKeys: [CKRecord.FieldKey]?, assetsDirectory: URL? = nil) -> CKRecord {
        let record = CKRecord(recordType: stored.recordType, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        for (key, value) in stored.values where desiredKeys?.contains(key) ?? true {
            switch value {
            case .value(let value):
                record[key] = value
            case .asset(let data):
                let url = (assetsDirectory ?? Self.downloadedAssetsDirectory).appending(component: UUID().uuidString)
                try! data.write(to: url)
                record[key] = CKAsset(fileURL: url)
            }
        }
        record.parent = stored.parent
        _ = record.perform(NSSelectorFromString("setEtag:"), with: stored.tag)
        _ = record.perform(NSSelectorFromString("resetChangedKeys"))
        return record
    }

    static let downloadedAssetsDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "FakeCloud Assets \(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: Zones

    private func modifyZones(_ operation: CKModifyRecordZonesOperation, device: String, accountName: String?, isShared: Bool) {
        record(Event(device: device, kind: .modifyZones))
        guard let accountName, !isShared else {
            operation.modifyRecordZonesResultBlock?(.failure(CKError(.notAuthenticated)))
            return
        }
        lock.withLock {
            let account = self.account(accountName)
            for zone in operation.recordZonesToSave ?? [] where account.zones[zone.zoneID.zoneName] == nil {
                account.zones[zone.zoneID.zoneName] = Zone()
                account.deletedZones[zone.zoneID.zoneName] = nil
            }
            for zoneID in operation.recordZoneIDsToDelete ?? [] {
                account.zones[zoneID.zoneName] = nil
                account.deletedZones[zoneID.zoneName] = false
            }
        }
        for zone in operation.recordZonesToSave ?? [] {
            operation.perRecordZoneSaveBlock?(zone.zoneID, .success(zone))
        }
        for zoneID in operation.recordZoneIDsToDelete ?? [] {
            operation.perRecordZoneDeleteBlock?(zoneID, .success(()))
        }
        operation.modifyRecordZonesResultBlock?(.success(()))
    }
}

extension CKRecordZone.ID {
    /// The zone the tests synchronize, the synchronizer's default.
    static let scenario = CKRecordZone.ID(zoneName: "CoreData")
}

/// A device's view of the fake server: its iCloud account, which tests sign out of or switch.
final class FakeCloudContainer: SDSCloudContainer, @unchecked Sendable {

    enum AccountState: Equatable, Sendable {
        case signedIn(String)
        case noAccount
        case temporarilyUnavailable
    }

    let server: FakeCloudServer
    let device: String
    private let state: OSAllocatedUnfairLock<AccountState>
    /// Called when the synchronizer asks for the user's record ID, e.g. to change the account meanwhile.
    private let userRecordIDHook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    var onUserRecordID: (@Sendable () -> Void)? {
        get { userRecordIDHook.withLock { $0 } }
        set { userRecordIDHook.withLock { $0 = newValue } }
    }

    init(server: FakeCloudServer, device: String, account: AccountState) {
        self.server = server
        self.device = device
        self.state = OSAllocatedUnfairLock(initialState: account)
    }

    var account: AccountState {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// The signed in account's name, which operations run with.
    var accountName: String? {
        if case .signedIn(let name) = account { name } else { nil }
    }

    var privateDatabase: any SDSCloudDatabase { FakeCloudDatabase(container: self, isShared: false) }
    var sharedDatabase: any SDSCloudDatabase { FakeCloudDatabase(container: self, isShared: true) }
    var ckContainer: CKContainer? { nil }

    func accountStatus() async throws -> CKAccountStatus {
        switch account {
        case .signedIn: .available
        case .noAccount: .noAccount
        case .temporarilyUnavailable: .temporarilyUnavailable
        }
    }

    func userRecordID() async throws -> CKRecord.ID {
        guard let accountName else { throw CKError(.notAuthenticated) }
        defer { onUserRecordID?() }
        return CKRecord.ID(recordName: "_user_\(accountName)")
    }

    func add(_ operation: CKOperation) {
        fatalError("The fake server doesn't support \(type(of: operation))")
    }

    func registerForRemoteNotifications() async {}
}

final class FakeCloudDatabase: SDSCloudDatabase, @unchecked Sendable {
    let container: FakeCloudContainer
    let isShared: Bool

    init(container: FakeCloudContainer, isShared: Bool) {
        self.container = container
        self.isShared = isShared
    }

    func add(_ operation: CKDatabaseOperation) {
        container.server.run(operation, device: container.device, currentAccount: { [container] in container.accountName }, isShared: isShared)
    }

    func allRecordZones() async throws -> [CKRecordZone] {
        try container.server.allRecordZones(accountName: container.accountName, isShared: isShared)
    }

    func allSubscriptions() async throws -> [CKSubscription] {
        try container.server.allSubscriptions(accountName: container.accountName, isShared: isShared)
    }

    func records(for ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        guard let accountName = container.accountName else { throw CKError(.notAuthenticated) }
        // Like CloudKit, which rejects operations of more than 400 items
        if ids.count > 400 { throw CKError(.limitExceeded) }
        return Dictionary(uniqueKeysWithValues: ids.map { id in
            let record = isShared ? nil : container.server.record(named: id.recordName, account: accountName, zone: id.zoneID)
            return (id, record.map { .success($0) } ?? .failure(CKError(.unknownItem)))
        })
    }
}
