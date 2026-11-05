import Foundation
import SwiftData
import CoreData
import CloudKit
import OSLog
import os
import Network

private let notificationCenter = NotificationCenter.default

private extension NSManagedObjectContext {
    var savedState: SDSSynchronizerSavedState {
        if let state = try? fetch(SDSSynchronizerSavedState.fetchRequest()).first {
            return state
        }
        
        let state = SDSSynchronizerSavedState(entity: NSEntityDescription.entity(forEntityName: "SDSSynchronizerSavedState", in: self)!, insertInto: self)
        // If this fails, e.g. while another process keeps the store busy, the state is saved with the context's next save
        try? self.save()
        return state
    }
}

public final class SDSSynchronizer: Sendable {
    public static let shared = SDSSynchronizer()
    
    /// The app group to store the synchronization data in, e.g. to share it with extensions. Has to be set before `shared` is used.
    public static var appGroupToStoreSyncData: String? {
        get { appGroupLock.withLock { $0 } }
        set { appGroupLock.withLock { $0 = newValue } }
    }
    private static let appGroupLock = OSAllocatedUnfairLock<String?>(initialState: nil)
    
    enum Constants {
        static let subscriptionName = "DatabaseSubscription"
        
        static let parentWorkaroundKey = "parentWorkaround"
    }
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SwiftDataSync", category: "SDSSynchronizer")
    
    let viewModel: SDSSynchronizationViewModel
    
    // MARK: - Properties
    
    let container: NSPersistentContainer
    /// The context of the synchronization data.
    ///
    /// The main thread must never wait for it, or for `observedUpdateContext`: their saves post `NSManagedObjectContextDidSave` on their queues,
    /// and an app observing it with `queue: .main` makes the save wait for the main thread, so both would wait for each other.
    let context: NSManagedObjectContext
    
    /// State that is set during setup or changes while synchronizing.
    /// It's used from CloudKit's callbacks, Core Data's queues and tasks, so it's guarded by a lock.
    struct MutableState: Sendable {
        var observedStore: NSPersistentStoreCoordinator?
        var observedUpdateContext: NSManagedObjectContext?
        var configuration: SDSInternalConfiguration?
        /// Whether local changes of the observed store are tracked, which isn't the case if setting up failed.
        var isObservingStore = false
        /// Whether `setup` was called, which must only happen once.
        var isSetUp = false
        /// Whether synchronizing was stopped, with `stop()`, or e.g. after the user deleted the app's data in iCloud.
        var isStopped = false
        /// Whether `stop()` stopped synchronizing, which the state shows, rather than e.g. the error that stopped it.
        var showsStopped = false
        /// Whether `resetSyncData` is about to forget the synchronization data, so changes made meanwhile aren't recorded.
        var isForgetting = false
        /// Whether objects without records still have to be queued, see `backfillIfNeeded()`.
        var needsBackfill = false
        /// Counts the changes of the iCloud account, see `accountChanged(_:)`.
        var accountChangeCount = 0
        /// The `accountChangeCount` when the running synchronization started.
        var synchronizationAccountChangeCount = 0
        /// Uploads to the private (`false`) and the shared database (`true`) pause until then, as the iCloud storage is
        /// full, see `QuotaExceededError`.
        var quotaPauseEnds: [Bool: Date] = [:]
        /// What runs: a synchronization, or something that mustn't run next to one, see `beginExclusiveActivity()`.
        var activity = Activity.none
        /// Whether a synchronization was requested while something else ran, which follows it.
        var isSynchronizationRequested = false
        /// Whether the account has to be checked before synchronizing, e.g. after it changed, see `accountChanged(_:)`.
        var accountNeedsCheck = true
        /// Counts the stored removals, so a download notices removals stored while it runs.
        var removalCount = 0
        var fileState = FileState()
        /// Whether the file state existed when the synchronizer was made, see `migrateFileStateIfNeeded()`.
        var hasFileState = false

        var defaultZoneID: CKRecordZone.ID?
        var cloud: (any SDSCloudContainer)?

        var lastCompletedUpload: Date?
        var lastCompletedDownload: Date?
        
        /// Zones of recently accepted shares with the date they were accepted, as the shared database might not list them right away.
        var acceptedShareZones: [CKRecordZone.ID: Date] = [:]
        
        /// Objects deleted by the synchronizer, which other contexts report like their own deletions once they merge them.
        /// IDs of deleted objects aren't reused, so they are kept.
        var deletionsBySynchronizer: Set<NSManagedObjectID> = []
        
        /// Models and keys that still have to be caught up on.
        var catchUp: CatchUp?
        
        /// The synchronized keys a context is saving to the store, by object. Read when the save starts, and taken when it's done.
        var keysBeingSaved: [ObjectIdentifier: [NSManagedObjectID: Set<String>]] = [:]
        
        /// Records that existed already when they were saved, e.g. because another device saved the same identity first, by
        /// name. Their next upload saves the changed keys over them, see `takeServerRecordOfConflict(named:)`.
        var serverRecordsOfConflicts: [String: CKRecord] = [:]

        /// Records CloudKit rejected, which aren't uploaded for a while.
        var quarantine = SDSRecordQuarantine()
        /// Why a record of the current upload failed last, which the state of an incomplete upload carries, see `SDSSyncError.underlyingError`.
        var lastRecordFailure: (any Error)?

        fileprivate var containerFinder: _ContainerFinder?

        var routineSync: Task<Void, Never>?
        /// When `routineSync` synchronizes, see `scheduleRoutineSync(after:)`.
        var routineSyncDate: Date?
        var catchUpRetry: Task<Void, Never>?
        var syncLeaseRetry: Task<Void, Never>?
        /// Saves the synchronization data and synchronizes shortly after the observed store was saved, see `contextSaved`.
        var saveSync: Task<Void, Never>?
        var startedSynchronizationCount = 0
        /// Counts the objects without records that were queued as a record references them, see `container(for:)`.
        var queuedReferencedObjectCount = 0
        /// The deletions a context is saving to the store, by object. Read when the save starts, and taken when it's done,
        /// like `keysBeingSaved`.
        var deletionsBeingSaved: [ObjectIdentifier: DeletionsBeingSaved] = [:]
        /// The URIs of objects whose deletions were saved, until their removals are stored, see `contextSaved`.
        var removalsBeingStored: [String: Int] = [:]
        /// Records a catch-up couldn't store, and whether it's tried again for them, see `download(refreshingSharedZones:)`.
        var recordsSkippedWhileCatchingUp: [String: Bool] = [:]
    }
    private let mutableState = OSAllocatedUnfairLock(initialState: MutableState())
    
    var observedStore: NSPersistentStoreCoordinator? { mutableState.withLock { $0.observedStore } }
    var observedUpdateContext: NSManagedObjectContext? { mutableState.withLock { $0.observedUpdateContext } }
    var configuration: SDSInternalConfiguration? { mutableState.withLock { $0.configuration } }
    var isObservingStore: Bool { mutableState.withLock { $0.isObservingStore } }
    var isStopped: Bool { mutableState.withLock { $0.isStopped } }
    var lastRecordFailure: (any Error)? {
        get { mutableState.withLock { $0.lastRecordFailure } }
        set { mutableState.withLock { $0.lastRecordFailure = newValue } }
    }

    var defaultZoneID: CKRecordZone.ID! { mutableState.withLock { $0.defaultZoneID } }
    var cloud: (any SDSCloudContainer)! { mutableState.withLock { $0.cloud } }
    var cloudPrivateDatabase: (any SDSCloudDatabase)! { cloud?.privateDatabase }
    var cloudSharedDatabase: (any SDSCloudDatabase)! { cloud?.sharedDatabase }
    
    // MARK: States
    
    var lastCompletedUpload: Date? {
        get { mutableState.withLock { $0.lastCompletedUpload } }
        set {
            mutableState.withLock { $0.lastCompletedUpload = newValue }
            newValue.map({ viewModel.set(lastCompletionDate: $0) })
        }
    }
    var lastCompletedDownload: Date? {
        get { mutableState.withLock { $0.lastCompletedDownload } }
        set {
            mutableState.withLock { $0.lastCompletedDownload = newValue }
            newValue.map({ viewModel.set(lastCompletionDate: $0) })
        }
    }
    
    /// Makes sure only one process using the same synchronization data synchronizes at a time.
    let syncLease: SDSSyncLease
    
    /// What the synchronizer stores in a file next to the synchronization data instead of in it, so its data model doesn't
    /// change. Processes using the same synchronization data read it again before synchronizing. It's moved with the
    /// synchronization data, and written before the saves of the synchronization data that rely on it.
    struct FileState: Codable, Sendable, Equatable {
        /// The account whose private database was downloaded completely, see `hasDownloadedOnce`.
        var downloadedOnceUserRecordName: String?
        /// The record keys in the overflow asset of records, by record name, see `SDSOverflow`.
        var overflowKeys: [String: [String]] = [:]
        /// Whether every local object still has to be queued, e.g. after switching accounts, see `backfillIfNeeded()`.
        /// Stored, so it's also done if the app is terminated before.
        var needsFullBackfill = false
        /// Whether objects vanished, and every record is downloaded again, see `backfill(onlyUntracked:)`.
        var isRecoveringVanishedObjects = false
        /// How many downloads while recovering couldn't download every record, see `countIncompleteRecovery()`.
        var incompleteRecoveries: Int?
        /// What the save of a download's page changes, until it's done, see `repairInterruptedPageSave()`.
        var interruptedPageSave: PageSave?
        /// How often the catch-up of the keys couldn't store every record, see `maximumCatchUpAttempts`.
        var incompleteCatchUp: IncompleteCatchUp?
        
        /// See `incompleteCatchUp`.
        struct IncompleteCatchUp: Codable, Sendable, Equatable {
            /// See `CatchUp.newKeys`. A catch-up of other keys, e.g. after another update, counts anew.
            var newKeys: Set<String>
            var count: Int
        }

        /// The local entities a page creates for the objects it inserts, by the URIs of the objects, and the records it deletes.
        struct PageSave: Codable, Sendable, Equatable {
            var createdLocalIds: [String]
            var deletedRecordNames: [String]
        }
    }
    
    /// What runs, see `MutableState.activity`.
    enum Activity: Sendable {
        case none
        case synchronizing
        /// E.g. saving a share, which a running synchronization's download could interfere with.
        case exclusive
    }
    
    private var fileStateURL: URL? {
        container.persistentStoreDescriptions.first?.url?.deletingLastPathComponent().appendingPathComponent("CloudKitSync.state.json")
    }
    
    /// Reads the file state, and returns whether the file exists.
    @discardableResult
    func loadFileState() -> Bool {
        guard
            let data = fileStateURL.flatMap({ try? Data(contentsOf: $0) }),
            let state = try? JSONDecoder().decode(FileState.self, from: data)
        else { return false }
        mutableState.withLock { $0.fileState = state }
        return true
    }
    
    /// Changes the file state, and writes it if it changed, or the file doesn't exist yet.
    func updateFileState(_ update: (inout FileState) -> Void) {
        let changed: FileState? = mutableState.withLockUnchecked { mutableState in
            var state = mutableState.fileState
            update(&state)
            let previous = mutableState.fileState
            let wasWritten = mutableState.hasFileState
            mutableState.fileState = state
            mutableState.hasFileState = true
            return previous == state && wasWritten ? nil : state
        }
        guard let changed, let url = fileStateURL else { return }
        do {
            try JSONEncoder().encode(changed).write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to store the synchronization state: \(error.localizedDescription)")
        }
    }
    
    /// The record keys in a record's overflow asset, empty if it has none, see `SDSOverflow`.
    func overflowKeys(of recordName: String) -> Set<String> {
        mutableState.withLock { Set($0.fileState.overflowKeys[recordName] ?? []) }
    }
    
    /// Remembers the keys in the overflow assets of records, by name, empty for records without one.
    func setOverflowKeys(_ changes: [String: Set<String>]) {
        guard !changes.isEmpty else { return }
        updateFileState { state in
            for (recordName, keys) in changes {
                state.overflowKeys[recordName] = keys.isEmpty ? nil : keys.sorted()
            }
        }
    }
    
    /// See `FileState.interruptedPageSave`.
    var interruptedPageSave: FileState.PageSave? {
        mutableState.withLock { $0.fileState.interruptedPageSave }
    }
    
    /// See `FileState.isRecoveringVanishedObjects`.
    var isRecoveringVanishedObjects: Bool {
        mutableState.withLock { $0.fileState.isRecoveringVanishedObjects }
    }

    /// See `MutableState.isForgetting`.
    var isForgetting: Bool {
        mutableState.withLock { $0.isForgetting }
    }

    /// See `MutableState.queuedReferencedObjectCount`.
    var queuedReferencedObjectCount: Int {
        mutableState.withLock { $0.queuedReferencedObjectCount }
    }

    func countQueuedReferencedObject() {
        mutableState.withLock { $0.queuedReferencedObjectCount += 1 }
    }

    /// Remembers a record that a catch-up couldn't store, e.g. as its asset couldn't be read. Unlike other downloads, a catch-up
    /// doesn't keep such records for later.
    /// - Parameter isTriedAgain: Whether the catch-up is done again for it, rather than for a record that won't change, e.g.
    ///   one whose reference was deleted.
    func skippedWhileCatchingUp(_ recordName: String, isTriedAgain: Bool = true) {
        mutableState.withLock { state in
            state.recordsSkippedWhileCatchingUp[recordName] = isTriedAgain || state.recordsSkippedWhileCatchingUp[recordName] == true
        }
    }

    func takeRecordsSkippedWhileCatchingUp() -> [String: Bool] {
        mutableState.withLock { state in
            defer { state.recordsSkippedWhileCatchingUp = [:] }
            return state.recordsSkippedWhileCatchingUp
        }
    }

    /// Remembers the deletions a context is about to save to the store, see `contextWillSave`.
    func rememberDeletionsBeingSaved(_ deletions: [NSManagedObjectID: SDSObjectDeletion], by context: NSManagedObjectContext) {
        mutableState.withLock { $0.deletionsBeingSaved[ObjectIdentifier(context)] = deletions.isEmpty ? nil : .init(date: .now, deletions: deletions) }
    }

    /// Returns the deletions a context saved to the store. Downloads keep leaving their records alone until
    /// `finishStoringRemovals(of:)`.
    func takeDeletionsBeingSaved(by context: NSManagedObjectContext) -> [NSManagedObjectID: SDSObjectDeletion] {
        mutableState.withLock { state in
            let deletions = state.deletionsBeingSaved.removeValue(forKey: ObjectIdentifier(context))?.deletions ?? [:]
            for deletion in deletions.values {
                state.removalsBeingStored[deletion.localId, default: 0] += 1
            }
            return deletions
        }
    }

    /// The removals of the deletions are stored, see `takeDeletionsBeingSaved(by:)`.
    func finishStoringRemovals(of deletions: [SDSObjectDeletion]) {
        guard !deletions.isEmpty else { return }
        mutableState.withLock { state in
            for deletion in deletions {
                let count = (state.removalsBeingStored[deletion.localId] ?? 1) - 1
                state.removalsBeingStored[deletion.localId] = count > 0 ? count : nil
            }
        }
    }

    /// Whether the object's deletion is being saved, or was saved, but its removal isn't stored yet. Downloads leave its
    /// record alone meanwhile, and backfill doesn't take it for vanished, if the object is gone: they'd otherwise insert the
    /// record's object again, see `lookUp(for:)`, and `forgetVanishedObjects`. Callers check that the object is gone, as
    /// the save can fail, which leaves the deletion here until the context saves again, or for a while, see
    /// `DeletionsBeingSaved`.
    func isDeletionPending(localId: String) -> Bool {
        mutableState.withLock { state in
            state.removalsBeingStored[localId] != nil || state.deletionsBeingSaved.values.contains { saving in
                saving.isCurrent && saving.localIds.contains(localId)
            }
        }
    }

    /// Whether `isDeletionPending(localId:)` can be true for any object.
    var hasPendingDeletions: Bool {
        mutableState.withLock { !$0.removalsBeingStored.isEmpty || $0.deletionsBeingSaved.values.contains(where: \.isCurrent) }
    }

    /// The deletions a context is saving, see `MutableState.deletionsBeingSaved`.
    struct DeletionsBeingSaved {
        let date: Date
        let deletions: [NSManagedObjectID: SDSObjectDeletion]
        /// The URIs of the deleted objects, so `isDeletionPending(localId:)` doesn't go through every deletion for each object.
        let localIds: Set<String>

        init(date: Date, deletions: [NSManagedObjectID: SDSObjectDeletion]) {
            self.date = date
            self.deletions = deletions
            self.localIds = Set(deletions.values.map(\.localId))
        }

        /// Whether the save may still be running. One that failed doesn't say so, and is left behind.
        var isCurrent: Bool {
            date.timeIntervalSinceNow > -60
        }
    }
    
    /// Whether a private database was downloaded completely with this synchronization data, with any account.
    var hasCompletedADownload: Bool {
        mutableState.withLock { $0.fileState.downloadedOnceUserRecordName != nil }
    }

    /// Remembers that the current account's private database was downloaded completely, see `hasDownloadedOnce`.
    func markDownloadedOnce() {
        let userRecordName = accessState(\.userId)?.recordName ?? ""
        updateFileState { $0.downloadedOnceUserRecordName = userRecordName }
    }
    
    /// See `hasDownloadedOnce`. Not until this launch checked the account, which could have changed while the app wasn't
    /// running, not after it changed until it's checked again, and not while every record is downloaded again after objects
    /// vanished, see `backfill(onlyUntracked:)`.
    var hasDownloadedOnceFlag: Bool {
        mutableState.withLock { state in
            state.fileState.downloadedOnceUserRecordName != nil && !state.accountNeedsCheck && !state.fileState.isRecoveringVanishedObjects
        }
    }
    
    /// Whether the file state existed when the synchronizer was made, or was written since.
    var hasFileState: Bool {
        mutableState.withLock { $0.hasFileState }
    }
    
    /// Notes that the iCloud account changed, so a running synchronization ends at its next step (see `checkNotStopped()`),
    /// and the next one checks the account first. It's noted right away, rather than in a task, so a synchronization that
    /// starts meanwhile doesn't upload the changes of the previous account to the new one.
    func noteAccountChange() {
        mutableState.withLock { state in
            state.accountChangeCount += 1
            state.accountNeedsCheck = true
        }
    }
    
    /// Whether the account has to be checked before synchronizing, see `MutableState.accountNeedsCheck`.
    var accountNeedsCheck: Bool {
        get { mutableState.withLock { $0.accountNeedsCheck } }
        set { mutableState.withLock { $0.accountNeedsCheck = newValue } }
    }
    
    var accountChangeCount: Int {
        mutableState.withLock { $0.accountChangeCount }
    }
    
    /// Notes that the account was checked, unless it changed since the check began, which is checked again then.
    func confirmAccount(ifUnchangedSince accountChangeCount: Int) {
        mutableState.withLock { state in
            if state.accountChangeCount == accountChangeCount {
                state.accountNeedsCheck = false
            }
        }
    }
    
    /// Notes that a synchronization starts with the current account.
    func beginSynchronizationWithCurrentAccount() {
        mutableState.withLock { $0.synchronizationAccountChangeCount = $0.accountChangeCount }
    }
    
    /// Counts the stored removals, see `MutableState.removalCount`.
    var removalCount: Int {
        mutableState.withLock { $0.removalCount }
    }
    
    func countRemoval() {
        mutableState.withLock { $0.removalCount += 1 }
    }
    
    /// When uploads to a database resume, if its iCloud storage was full, see `QuotaExceededError`.
    func quotaPauseEnd(sharedDatabase: Bool) -> Date? {
        mutableState.withLock { state in state.quotaPauseEnds[sharedDatabase].flatMap { $0 > .now ? $0 : nil } }
    }
    
    func pauseUploads(sharedDatabase: Bool, until date: Date) {
        mutableState.withLock { $0.quotaPauseEnds[sharedDatabase] = date }
    }
    
    /// Resumes uploads that paused as iCloud was full, e.g. when the user asks for a synchronization.
    func resumeUploads() {
        mutableState.withLock { $0.quotaPauseEnds = [:] }
    }
    
    /// Has another synchronization follow the running one, or whatever else runs, e.g. to download what an upload changed.
    func requestSynchronization() {
        mutableState.withLock { $0.isSynchronizationRequested = true }
    }
    
    /// Starts synchronizing, unless something else runs, after which another synchronization follows instead. Two
    /// synchronizations never run at once: they'd share the observed update context and the objects a download inserted.
    func claimSynchronization() -> Bool {
        mutableState.withLock { state in
            guard state.activity == .none else {
                state.isSynchronizationRequested = true
                return false
            }
            state.activity = .synchronizing
            return true
        }
    }
    
    var isSynchronizing: Bool {
        mutableState.withLock { $0.activity == .synchronizing }
    }
    
    /// Waits until nothing else runs, e.g. a synchronization, and keeps synchronizations from starting until
    /// `endExclusiveActivity()`. Throws if the task is cancelled while waiting.
    func beginExclusiveActivity() async throws {
        while true {
            let isClaimed = mutableState.withLock { state in
                guard state.activity == .none else { return false }
                state.activity = .exclusive
                return true
            }
            if isClaimed { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    
    /// Ends a synchronization or an exclusive activity, and starts a synchronization that was requested meanwhile.
    func endActivity() {
        let (isRequested, isStopped) = mutableState.withLock { state in
            state.activity = .none
            defer { state.isSynchronizationRequested = false }
            return (state.isSynchronizationRequested, state.isStopped)
        }
        if isStopped {
            // `stop()` leaves the state of a running synchronization alone
            Task { await updateStoppedState() }
        } else if isRequested {
            startSync()
        }
    }
    
    /// Shows whether synchronizing is stopped. Read once it runs, so `stop()` and `start()` in quick succession end with the
    /// state of the last one, and not while a synchronization runs, which shows its own state until it notices.
    func updateStoppedState() async {
        await MainActor.run {
            let (isStopped, showsStopped, isSynchronizing) = mutableState.withLock { ($0.isStopped, $0.showsStopped, $0.activity == .synchronizing) }
            if !isStopped {
                viewModel.endStop()
            } else if showsStopped && !isSynchronizing {
                viewModel.set(state: .stopped)
            }
        }
    }
    
    func forgetServerRecordsOfConflicts() {
        mutableState.withLock { $0.serverRecordsOfConflicts = [:] }
    }
    
    /// Starts `task` unless a task stored at `keyPath` is still pending. The task has to clear it with `finishTask(at:)`.
    func startTask(at keyPath: WritableKeyPath<MutableState, Task<Void, Never>?> & Sendable, _ task: @escaping @Sendable () async -> Void) {
        mutableState.withLock { state in
            guard state[keyPath: keyPath] == nil else { return }
            state[keyPath: keyPath] = Task(operation: task)
        }
    }
    
    func finishTask(at keyPath: WritableKeyPath<MutableState, Task<Void, Never>?> & Sendable) {
        mutableState.withLock { $0[keyPath: keyPath] = nil }
    }

    /// Synchronizes after `delay`, unless a synchronization is scheduled sooner already. One scheduled later is replaced,
    /// e.g. the retry of rejected records in an hour by one that CloudKit asks for in a few seconds.
    func scheduleRoutineSync(after delay: TimeInterval) {
        let date = Date.now.addingTimeInterval(delay)
        mutableState.withLock { state in
            if state.routineSync != nil, let scheduledDate = state.routineSyncDate, scheduledDate <= date { return }
            state.routineSync?.cancel()
            state.routineSyncDate = date
            state.routineSync = Task {
                try? await Task.sleep(for: .milliseconds(delay * 1000))

                // Unless another one replaced it meanwhile
                let isScheduled = self.mutableState.withLock { state in
                    guard state.routineSyncDate == date else { return false }
                    state.routineSync = nil
                    state.routineSyncDate = nil
                    return true
                }
                if isScheduled {
                    self.startSync()
                }
            }
        }
    }
    
    /// Saves `observedUpdateContext`. Has to be called on its queue.
    ///
    /// Contexts that merge its changes report its deletions like deletions made in them, which must not be uploaded:
    /// they are deletions downloaded from iCloud, or local copies of shares that were left, whose records belong to someone else.
    func saveObservedUpdateContext(_ observedUpdateContext: NSManagedObjectContext) throws {
        // E.g. the app removed the store to replace it. Saving would raise an exception instead of throwing.
        guard observedUpdateContext.persistentStoreCoordinator?.persistentStores.isEmpty == false else {
            throw CocoaError(.persistentStoreSave)
        }
        // Deletions only reach related objects, e.g. through cascade rules, once pending changes are processed
        observedUpdateContext.processPendingChanges()
        let deletedIds = Set(observedUpdateContext.deletedObjects.map(\.objectID))
        let newIds = mutableState.withLock { state in
            let newIds = deletedIds.subtracting(state.deletionsBySynchronizer)
            state.deletionsBySynchronizer.formUnion(newIds)
            return newIds
        }
        
        do {
            try observedUpdateContext.save()
        } catch {
            // Deletions that weren't saved aren't merged into other contexts, and are uploaded if they are made there
            mutableState.withLock { $0.deletionsBySynchronizer.subtract(newIds) }
            throw error
        }
    }
    
    /// Remembers the synchronized keys a context is about to save to the store, see `contextWillSave`.
    func rememberKeysBeingSaved(_ keys: [NSManagedObjectID: Set<String>], by context: NSManagedObjectContext) {
        mutableState.withLock { $0.keysBeingSaved[ObjectIdentifier(context)] = keys }
    }
    
    /// Whether a context is saving to the store, between `contextWillSave` and `contextSaved`.
    func isSavingKeys(by context: NSManagedObjectContext) -> Bool {
        mutableState.withLock { $0.keysBeingSaved[ObjectIdentifier(context)] != nil }
    }

    /// Adds keys that changed while a context saves, see `contextChangedWhileSaving`.
    func addKeysBeingSaved(_ keys: [NSManagedObjectID: Set<String>], by context: NSManagedObjectContext) {
        guard !keys.isEmpty else { return }
        mutableState.withLock { state in
            guard state.keysBeingSaved[ObjectIdentifier(context)] != nil else { return }
            state.keysBeingSaved[ObjectIdentifier(context)]?.merge(keys) { $0.union($1) }
        }
    }

    /// The synchronized keys a context saved to the store.
    func keysBeingSaved(by context: NSManagedObjectContext) -> [NSManagedObjectID: Set<String>] {
        mutableState.withLock { $0.keysBeingSaved[ObjectIdentifier(context)] ?? [:] }
    }

    /// Forgets the keys a context saved, once they're stored.
    func forgetKeysBeingSaved(by contextId: ObjectIdentifier) {
        mutableState.withLock { _ = $0.keysBeingSaved.removeValue(forKey: contextId) }
    }

    /// The keys that contexts are saving, or saved and aren't stored yet, of every context, by object.
    func keysBeingSavedByAnyContext() -> [NSManagedObjectID: Set<String>] {
        mutableState.withLock { state in
            state.keysBeingSaved.values.reduce(into: [:]) { keys, contextKeys in
                keys.merge(contextKeys) { $0.union($1) }
            }
        }
    }
    
    func rememberServerRecordsOfConflicts(_ records: [String: CKRecord]) {
        mutableState.withLock { $0.serverRecordsOfConflicts.merge(records) { $1 } }
    }
    
    /// The record another device saved first under this name, which is only used once.
    func takeServerRecordOfConflict(named name: String) -> CKRecord? {
        mutableState.withLock { $0.serverRecordsOfConflicts.removeValue(forKey: name) }
    }
    
    func wasDeletedBySynchronizer(_ objectId: NSManagedObjectID) -> Bool {
        mutableState.withLock { $0.deletionsBySynchronizer.contains(objectId) }
    }
    
    /// Whether a download inserted the object and gave it its record's id. Objects that weren't saved yet otherwise have no id.
    func isDownloadedObject(_ object: NSManagedObject) -> Bool {
        context.performAndWaitUnchecked {
            temporaryObjectIds[object] != nil
        }
    }

    /// Whether a record CloudKit rejected isn't uploaded now. See `SDSRecordQuarantine`.
    func isQuarantined(_ recordName: String, lastChangeDate: Date) -> Bool {
        mutableState.withLock { $0.quarantine.contains(recordName, lastChangeDate: lastChangeDate) }
    }

    func quarantine(_ rejections: [String: SDSRecordQuarantine.Rejection]) {
        mutableState.withLock { $0.quarantine.add(rejections) }
    }

    /// How many records CloudKit rejected, see `SDSRecordQuarantine.count(now:)`.
    var quarantinedRecordCount: Int {
        mutableState.withLock { $0.quarantine.count() }
    }

    /// Why CloudKit rejected the record it rejected last, see `SDSRecordQuarantine.latestError(now:)`.
    var latestRejectionError: (any Error)? {
        mutableState.withLock { $0.quarantine.latestError() }
    }

    func resetQuarantine() {
        mutableState.withLock { $0.quarantine = SDSRecordQuarantine() }
    }
    
    /// Reads and changes the zones of recently accepted shares at once, as accepting a share can happen while synchronizing.
    func withAcceptedShareZones<T: Sendable>(_ body: @Sendable (inout [CKRecordZone.ID: Date]) -> T) -> T {
        mutableState.withLock { body(&$0.acceptedShareZones) }
    }
    
    /// `nil` if the network isn't monitored, e.g. in tests, which then take it as available.
    let networkMonitor: NWPathMonitor?

    /// Delays the synchronizer waits for. Tests shorten them.
    struct Timing: Sendable {
        /// How long a synchronization waits after a save, so saves in quick succession, e.g. while typing, synchronize once.
        var saveSynchronizationDelay: Duration = .seconds(1)
        /// How long a synchronization waits after an error that doesn't say how long to wait. `nil` for a delay that
        /// depends on the battery and network, see `generalLoadMultiplier`.
        var routineRetryInterval: TimeInterval? = nil
        /// How long uploads pause once the user's iCloud storage is full, see `QuotaExceededError`.
        var quotaExceededRetryInterval: TimeInterval = 30 * 60
        /// How often the records of an upload round are selected, see `synchronizableUpdates(sharedDatabase:maximum:)`.
        var maximumSelectionPasses = 10
    }
    let timing: Timing

    /// Makes the CloudKit container once `setup` names it. Tests make a fake one.
    private let makeCloudContainer: @Sendable (String) -> any SDSCloudContainer

    /// Called by downloads right after the downloaded objects were saved, before the change token, and right after their
    /// records were saved, before the objects. Tests use them to simulate a process that is terminated in between.
    nonisolated(unsafe) var afterSavingDownloadedObjects: (@Sendable () -> Void)?
    nonisolated(unsafe) var afterSavingDownloadedRecords: (@Sendable () -> Void)?
    /// Called by downloads right before the downloaded objects are saved, once local changes were looked for. Tests use it to
    /// save a local change in between.
    nonisolated(unsafe) var beforeSavingDownloadedObjects: (@Sendable () -> Void)?

    /// The record ids of objects that weren't saved yet, e.g. ones a download inserted. They get their `CloudKitLocalEntity`
    /// once they have permanent IDs, see `CKDownloadHandler.fetchOverallCompletion`.
    ///
    /// They're kept out of `context`, so it can be saved at any time, e.g. right after changes were stored, without saving
    /// entities that don't know their objects yet. Only accessed on `context`'s queue, which serializes the access.
    nonisolated(unsafe) private(set) var temporaryObjectIds: [NSManagedObject: String] = [:]
    /// The objects of `temporaryObjectIds` by record id.
    nonisolated(unsafe) private var temporaryObjectsById: [String: NSManagedObject] = [:]

    /// Has to be called on `context`'s queue.
    func temporaryObject(for id: String) -> NSManagedObject? {
        temporaryObjectsById[id]
    }

    /// Has to be called on `context`'s queue.
    func setTemporaryId(_ id: String, for object: NSManagedObject) {
        // An object that gets another record leaves its previous one, see `SDSUniqueMatch.inserted`
        if let previous = temporaryObjectIds[object], temporaryObjectsById[previous] === object {
            temporaryObjectsById[previous] = nil
        }
        temporaryObjectIds[object] = id
        temporaryObjectsById[id] = object
    }

    /// Has to be called on `context`'s queue.
    func removeAllTemporaryObjects() {
        temporaryObjectIds = [:]
        temporaryObjectsById = [:]
    }
    
    // MARK: - Initializer
    
    /// The model of the synchronization data, loaded once: several models claiming the same classes would confuse Core Data,
    /// e.g. when tests make several synchronizers. It isn't changed after it's made.
    nonisolated(unsafe) static let syncDataModel: NSManagedObjectModel = {
        let model = NSManagedObjectModel.mergedModel(from: [.module])!
        for entity in model.entities {
            entity.managedObjectClassName = "SwiftDataSync.\(entity.name!)"
        }
        return model
    }()

    private convenience init() {
        self.init(viewModel: .shared)
    }

    /// - Parameters:
    ///   - syncDataDirectory: Where the synchronization data is stored, rather than the app group or the app's container.
    ///     Tests give every synchronizer a directory of its own, so several of them act like several devices.
    ///   - makeCloudContainer: Makes the CloudKit container `setup` names. Tests make a fake one.
    ///   - monitorsNetwork: Whether synchronizing waits for a network connection.
    init(
        syncDataDirectory: URL? = nil,
        viewModel: SDSSynchronizationViewModel,
        makeCloudContainer: @escaping @Sendable (String) -> any SDSCloudContainer = { SDSCloudKitContainer(identifier: $0) },
        monitorsNetwork: Bool = true,
        timing: Timing = Timing()
    ) {
        self.viewModel = viewModel
        self.makeCloudContainer = makeCloudContainer
        self.timing = timing

        let container = NSPersistentContainer(
            name: "CloudKitSync",
            managedObjectModel: Self.syncDataModel
        )

        if let syncDataDirectory {
            container.persistentStoreDescriptions = [.init(url: syncDataDirectory.appendingPathComponent("CloudKitSync.sqlite"))]
        } else if
            let appGroup = Self.appGroupToStoreSyncData,
            let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        {
            let url = containerUrl.appendingPathComponent("CloudKitSync.sqlite")
            Self.moveSyncData(
                from: NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("CloudKitSync.sqlite"),
                to: url,
                coordinator: container.persistentStoreCoordinator
            )
            container.persistentStoreDescriptions = [.init(url: url)]
        } else if let appGroup = Self.appGroupToStoreSyncData {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "SwiftDataSync", category: "SDSSynchronizer")
                .error("The app group `\(appGroup, privacy: .public)` isn't available, is it in the app's entitlements? Storing the synchronization data in the app's container instead.")
        }
        // E.g. while the device is locked before it was unlocked once, data protection keeps the store from being loaded.
        // That mustn't crash the app: setting up loads it again, and doesn't synchronize if it can't, see `loadSyncData()`.
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "SwiftDataSync", category: "SDSSynchronizer")
                    .error("Failed to load the synchronization data: \(error)")
            }
        })
        self.container = container
        let context = container.newBackgroundContext()
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        // Other processes can change the synchronization data, so cached values cannot be trusted
        context.stalenessInterval = 0
        self.context = context
        
        self.syncLease = SDSSyncLease(
            url: container.persistentStoreDescriptions.first?.url?.deletingLastPathComponent().appendingPathComponent("CloudKitSync.lease")
        )

        if monitorsNetwork {
            let networkMonitor = NWPathMonitor()
            self.networkMonitor = networkMonitor
            networkMonitor.pathUpdateHandler = { [weak self] path in
                self?.networkPathWasUpdated(with: path)
            }
            networkMonitor.start(queue: .main)
        } else {
            self.networkMonitor = nil
        }
        viewModel.synchronizer = self
        
        // It's small, and read right away, so `hasDownloadedOnce` is known from the start
        let hasFileState = loadFileState()
        mutableState.withLock { $0.hasFileState = hasFileState }
    }
    
    /// Moves the synchronization data to `url` unless something is stored there already, e.g. into the app group once an app that
    /// synchronized before sets `appGroupToStoreSyncData`. Starting over without it would download every record again as new models.
    static func moveSyncData(from sourceURL: URL, to url: URL, coordinator: NSPersistentStoreCoordinator) {
        let fileManager = FileManager.default
        guard
            sourceURL.standardizedFileURL != url.standardizedFileURL,
            !fileManager.fileExists(atPath: url.path),
            fileManager.fileExists(atPath: sourceURL.path)
        else { return }

        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SwiftDataSync", category: "SDSSynchronizer")
        do {
            // What was synchronized when everything was caught up on last (see `checkForNewlySynchronizedKeys(_:)`), the
            // state that belongs to the synchronization data (see `FileState`), and the records downloads held (see
            // `SDSHeldRecords`). They're moved first: if the app is terminated before the store is moved, the next launch
            // moves the store, which it wouldn't do anymore for files left behind once the store was moved.
            for name in ["CloudKitSync.keys.json", "CloudKitSync.state.json", "CloudKitSync.held"] {
                let fileURL = sourceURL.deletingLastPathComponent().appendingPathComponent(name)
                let destinationURL = url.deletingLastPathComponent().appendingPathComponent(name)
                if fileManager.fileExists(atPath: fileURL.path) && !fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.moveItem(at: fileURL, to: destinationURL)
                }
            }
            try coordinator.replacePersistentStore(at: url, withPersistentStoreFrom: sourceURL, type: .sqlite)
            try coordinator.destroyPersistentStore(at: sourceURL, type: .sqlite)
            logger.log("Moved the synchronization data to \(url.path, privacy: .public)")
        } catch {
            logger.error("Failed to move the synchronization data to \(url.path, privacy: .public): \(error)")
        }
    }

    private var containerFinder: _ContainerFinder? {
        get { mutableState.withLock { $0.containerFinder } }
        set { mutableState.withLock { $0.containerFinder = newValue } }
    }
    
    /// Used to setup the synchronizer. Should be called as early as possible.
    /// - Parameters:
    ///   - containerName: The name of the iCloud container to sync to.
    ///   - configuration: The configuration.
    ///   - coordinator: The ``NSPersistentStoreCoordinator`` to sync.
    ///   - adoption: Saves models that already have records in CloudKit, e.g. when migrating from another sync engine, and returns them.
    ///     It's called once the store was found, before observing it and synchronizing for the first time.
    ///     Synchronization doesn't start if it throws.
    public func setup(
        containerName: String,
        configuration: SDSConfiguration = .init(rawEntities: [:]),
        coordinator: NSPersistentStoreCoordinator,
        defaultZoneID: String = "CoreData",
        adoption: (() throws -> SDSAdoption)? = nil
    ) {
        guard markSetUp() else { return }
        setupCloudKit(containerName: containerName, defaultZoneID: defaultZoneID)

        Task {
            await viewModel.setWaitingForContainerDetection()
        }
        self.setup(storeToObserve: coordinator, configuration: configuration, adoption: adoption)
    }
    
    /// Used to setup the synchronizer. Should be called as early as possible.
    /// - Parameters:
    ///   - containerName: The name of the iCloud container to sync to.
    ///   - configuration: The configuration.
    ///   - modelContainer: The ``ModelContainer`` to sync. This should be the first time that container is called.
    ///   - adoption: Saves models that already have records in CloudKit, e.g. when migrating from another sync engine, and returns them.
    ///     It's called once the store was found, before observing it and synchronizing for the first time.
    ///     Synchronization doesn't start if it throws.
    public func setup(
        containerName: String,
        configuration: SDSConfiguration = .init(swiftDataEntities: []),
        modelContainer: @autoclosure () -> ModelContainer?,
        defaultZoneID: String = "CoreData",
        adoption: (() throws -> SDSAdoption)? = nil
    ) {
        guard markSetUp() else { return }
        setupCloudKit(containerName: containerName, defaultZoneID: defaultZoneID)

        self.containerFinder = .init(
            closure: modelContainer,
            completion: { [weak self] coordinator in
                guard let self else { return }
                
                self.containerFinder = nil
                self.setup(storeToObserve: coordinator, configuration: configuration, adoption: adoption)
            }
        )
        
        Task {
            await viewModel.setWaitingForContainerDetection()
        }
    }
    
    /// Should be called when a remote notification was received. It's ignored while synchronizing is stopped.
    public func didReceiveRemoteNotification(userInfo: [AnyHashable : Any]) async {
        // TODO(later): selectively download based on the user info
        // Unlike `forceDownloadSync()`, uploads that paused as iCloud was full stay paused
        lastCompletedDownload = nil
        await synchronize()
    }

    /// Stops synchronizing until `start()` is called, e.g. when the app's setting for it is turned off, without relaunching the app.
    ///
    /// Nothing is uploaded or downloaded anymore: synchronizations that saves, pushes (`didReceiveRemoteNotification(userInfo:)`),
    /// network changes or retries would start are skipped, and scheduled retries are cancelled. A running synchronization stops
    /// at its next step. The state becomes `.stopped`.
    ///
    /// Local changes are still recorded, without contacting iCloud, so they're uploaded once synchronizing starts again.
    public func stop() {
        stopSynchronizing()
        mutableState.withLock { $0.showsStopped = true }

        Task {
            await updateStoppedState()
        }
    }

    /// Stops synchronizing like `stop()`, but leaves the state as it is.
    func stopSynchronizing() {
        let tasks = mutableState.withLock { state in
            state.isStopped = true
            return [state.routineSync, state.catchUpRetry, state.syncLeaseRetry].compactMap { $0 }
        }
        // They clear themselves once they end
        tasks.forEach { $0.cancel() }
    }

    /// Starts synchronizing again after `stop()`, and synchronizes right away.
    public func start() {
        let wasStopped = mutableState.withLock { state in
            defer {
                state.isStopped = false
                state.showsStopped = false
            }
            if state.isStopped {
                // E.g. the user freed up iCloud storage meanwhile
                state.quotaPauseEnds = [:]
            }
            return state.isStopped
        }
        guard wasStopped else { return }

        Task {
            // Unless it was never set up, or setting up failed
            guard self.isObservingStore else { return }
            await updateStoppedState()
            await synchronize()
        }
    }

    /// Forgets everything the synchronizer stored about iCloud's data, as if it never synchronized: which objects have
    /// records, the changes that weren't uploaded yet, the change tokens, zones and shares, whether everything was
    /// downloaded, and the records that were held or set aside. iCloud's data stays as it is.
    ///
    /// Synchronizing stops (like `stop()`, without showing it), and starts again with `start()`. That synchronization
    /// downloads everything, and uploads the local objects iCloud doesn't have, like a new device would (see
    /// `backfill(onlyUntracked:)`), so `hasDownloadedOnce` is `false` until it's done. Local objects without an identity, or
    /// without all of its values, are matched with their records by their values first, as after objects vanished (see
    /// `SDSContentIndex`), so they aren't duplicated. Local copies of other users' shares are removed, and downloaded again.
    ///
    /// Throws if the data couldn't be forgotten, which then stays as it is, apart from the changes of `beforeForgetting`, and
    /// local copies of other users' shares that were removed already, which are downloaded again once a reset succeeds.
    /// Synchronizing stays stopped then too, until `start()`.
    /// - Parameter beforeForgetting: Runs once no synchronization runs anymore, before the data is forgotten. Its changes
    ///   aren't recorded, so they're never uploaded, e.g. an app can empty the observed store there, and start again to
    ///   download iCloud's data into it.
    public func resetSyncData(beforeForgetting: @escaping @MainActor @Sendable () async -> Void = {}) async throws {
        stopSynchronizing()
        // In a task of its own, as a cancelled caller would stop waiting for a running synchronization
        try await Task {
            try await self.forgetSyncData(beforeForgetting: beforeForgetting)
        }.value
        logger.log("Reset the synchronization data")
    }

    private func forgetSyncData(beforeForgetting: @MainActor @Sendable () async -> Void) async throws {
        // Without its data, e.g. as it couldn't be loaded at launch, saving the context would raise an exception rather than
        // throw. It's loaded again, e.g. once data protection allows it, and the reset fails if it still can't be.
        if let error = loadSyncData() {
            logger.error("Failed to load the synchronization data, not resetting it: \(error)")
            throw error
        }
        // Waits until a running synchronization, or a save's, noticed it's stopped. None starts until the reset is done.
        try await beginExclusiveActivity()
        defer { endActivity() }
        // Nor in another process using the same synchronization data, e.g. an extension
        while !syncLease.acquire() {
            try await Task.sleep(for: .seconds(1))
        }
        defer { syncLease.release() }

        // Changes made meanwhile aren't recorded, rather than forgotten, so they're never uploaded, also if forgetting fails
        mutableState.withLock { $0.isForgetting = true }
        defer { mutableState.withLock { $0.isForgetting = false } }
        await beforeForgetting()

        // Otherwise they'd be uploaded to the user's own zone, as nothing tells they belong to someone else's once the data is
        // forgotten. They're removed first, while their shares are known, so nothing is forgotten if one can't be removed.
        // The download of the shared database brings them back.
        try removeLocalCopiesOfOtherUsersShares()

        // Written first, so objects without an identity aren't uploaded as duplicates if the app is terminated before the
        // file state is replaced
        let wasRecovering = isRecoveringVanishedObjects
        updateFileState { $0.isRecoveringVanishedObjects = true }
        let context = self.context
        do {
            try context.performAndWaitUnchecked {
                for entityName in ["CloudKitLocalEntity", "CloudKitUpdate", "CloudKitRemoval", "CloudKitZone", "CloudKitShare", "SDSSynchronizerSavedState"] {
                    ((try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: entityName))) ?? []).forEach(context.delete)
                }
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
            }
        } catch {
            logger.error("Failed to reset the synchronization data: \(error.localizedDescription)")
            updateFileState { $0.isRecoveringVanishedObjects = wasRecovering }
            throw error
        }
        // Changes saved from now on are recorded, like ones saved before a device synchronized for the first time
        mutableState.withLock { $0.isForgetting = false }

        heldRecords(sharedDatabase: false).removeAll()
        heldRecords(sharedDatabase: true).removeAll()
        updateFileState { state in
            state = FileState()
            state.isRecoveringVanishedObjects = true
        }
        mutableState.withLock { state in
            state.needsBackfill = false
            state.quotaPauseEnds = [:]
            state.accountNeedsCheck = true
            state.lastCompletedUpload = nil
            state.lastCompletedDownload = nil
            state.acceptedShareZones = [:]
            // A pending catch-up is kept, as records of older versions still lack its keys. It starts over, as the updates
            // its earlier tries queued were forgotten.
            state.catchUp?.recordsLeft = nil
            state.catchUp?.retryDate = nil
            state.serverRecordsOfConflicts = [:]
            state.quarantine = SDSRecordQuarantine()
            state.lastRecordFailure = nil
        }
    }

    /// Stops observing and synchronizing for good, like a process that is terminated: nothing is saved, the lease is given up
    /// and the store isn't observed anymore. Tests use it to launch another synchronizer on the same data.
    func invalidate() {
        stopSynchronizing()
        NotificationCenter.default.removeObserver(self)
        mutableState.withLock { $0.isObservingStore = false }
        syncLease.release()
    }

    /// Whether a save scheduled a synchronization that hasn't started yet, see `synchronizeAfterSave()`.
    var hasPendingSaveSync: Bool {
        mutableState.withLock { $0.saveSync != nil }
    }

    /// How many synchronizations started, e.g. for tests to tell whether one ran.
    var startedSynchronizationCount: Int {
        mutableState.withLock { $0.startedSynchronizationCount }
    }

    func countStartedSynchronization() {
        mutableState.withLock { $0.startedSynchronizationCount += 1 }
    }

    /// Thrown when a running synchronization notices that synchronizing was stopped, see `stop()`.
    struct StoppedError: Error {}

    /// Thrown when a running synchronization notices that the iCloud account changed. Its next step could upload to or
    /// download from another account with the data of the previous one, so it ends, and the next one checks the account.
    struct AccountChangedError: Error {}

    /// Throws if synchronizing was stopped, or the account changed since the synchronization started, so a running
    /// synchronization ends at its next step.
    func checkNotStopped() throws {
        let (isStopped, accountChanged) = mutableState.withLock { ($0.isStopped, $0.accountChangeCount != $0.synchronizationAccountChangeCount) }
        if isStopped {
            throw StoppedError()
        }
        if accountChanged {
            throw AccountChangedError()
        }
    }

    /// Marks the synchronizer as set up, and returns whether it wasn't before. It must only be set up once.
    private func markSetUp() -> Bool {
        let wasSetUp = mutableState.withLock { state in
            defer { state.isSetUp = true }
            return state.isSetUp
        }
        if wasSetUp {
            logger.error("`setup` was called again, which is ignored. Use `stop()` and `start()` to turn synchronizing off and on.")
        }
        return !wasSetUp
    }

    /// Whether the synchronization data is loaded. It isn't if loading it failed, see `loadSyncData()`.
    var isSyncDataLoaded: Bool {
        !container.persistentStoreCoordinator.persistentStores.isEmpty
    }

    /// Loads the synchronization data if loading it failed before, and returns the error if it fails again.
    private func loadSyncData() -> (any Error)? {
        guard !isSyncDataLoaded else { return nil }

        var loadError: (any Error)?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        return loadError
    }

    private func setupCloudKit(containerName: String, defaultZoneID: String) {
        let cloud = makeCloudContainer(containerName)
        mutableState.withLock { state in
            state.defaultZoneID = CKRecordZone.ID(zoneName: defaultZoneID)
            state.cloud = cloud
        }
    }
    
    private func setup(storeToObserve: NSPersistentStoreCoordinator, configuration: SDSConfiguration, adoption: (() throws -> SDSAdoption)?) {
        // Without its data, the synchronizer can't track changes, and using its context would raise exceptions
        if let error = loadSyncData() {
            logger.error("Failed to load the synchronization data, not synchronizing: \(error)")
            Task {
                await viewModel.set(state: .error(error))
            }
            return
        }

        let configuration = storeToObserve.makeConfiguration(externalConfiguration: configuration)
        
        let observedUpdateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        observedUpdateContext.persistentStoreCoordinator = storeToObserve
        observedUpdateContext.mergePolicy = SDSDownloadMergePolicy()
        observedUpdateContext.automaticallyMergesChangesFromParent = true
        // Other processes can change the observed store, so cached values cannot be trusted
        observedUpdateContext.stalenessInterval = 0
        
        mutableState.withLock { state in
            state.configuration = configuration
            state.observedStore = storeToObserve
            state.observedUpdateContext = observedUpdateContext
        }
        
        removeSavedPlaceholders()
        checkForNewlySynchronizedKeys(configuration)
        // Files of assets that earlier uploads couldn't remove, e.g. because the app was terminated while uploading
        CKAsset.removeAllTemporaryFiles()
        
        // Adopted models are saved before observing the store, so they aren't uploaded as new records
        if let adoption {
            do {
                try adopt(adoption())
            } catch {
                // Synchronizing without the adopted records would duplicate them
                logger.log("Failed to adopt existing records: \(error.localizedDescription)")
                Task {
                    await viewModel.set(state: .error(error))
                }
                return
            }
        }
        
        // Saves are observed before the objects without records are looked for, so none fall in between
        setupNotifications()
        mutableState.withLock { state in
            state.isObservingStore = true
            state.needsBackfill = true
        }

        Task {
            // `stop()` can be called before the store is found
            await viewModel.set(state: isStopped ? .stopped : .idle)
            await synchronize()
        }
    }

    /// Writes the file state if it doesn't exist, e.g. for synchronization data of an earlier version. A missing state isn't
    /// taken for a complete download, as a saved change token can be the one of a page, so `hasDownloadedOnce` only becomes
    /// `true` once a download completes.
    func writeFileStateIfNeeded() {
        guard !hasFileState else { return }
        updateFileState { _ in }
    }

    /// Queues the objects that were saved without the synchronizer, once after setting up, and every object once the zone
    /// or the account is new, before the next download, see `backfill(onlyUntracked:)`. It's part of a synchronization,
    /// which runs off the main thread, and no download runs meanwhile. Throws if the store can't be read, e.g. while data
    /// protection keeps it locked, so it's tried again.
    func backfillIfNeeded() throws {
        // Every object includes the ones without records
        if mutableState.withLock({ $0.fileState.needsFullBackfill }) {
            try backfill(onlyUntracked: false)
            updateFileState { $0.needsFullBackfill = false }
            mutableState.withLock { $0.needsBackfill = false }
        } else if mutableState.withLock({ $0.needsBackfill }) {
            try backfill(onlyUntracked: true)
            mutableState.withLock { $0.needsBackfill = false }
        }
    }
    
    /// Has the next synchronization look for objects without records, see `backfillIfNeeded()`.
    func mutableStateNeedsBackfill() {
        mutableState.withLock { $0.needsBackfill = true }
    }
    
    /// Removes placeholders of downloaded objects that earlier versions could save, e.g. when a download failed.
    ///
    /// Placeholders only exist while a download runs, and nothing is downloading yet. A saved one has no object, but would
    /// keep its record from being found, so a download would insert the record's object again with every change.
    private func removeSavedPlaceholders() {
        let context = self.context
        context.performAndWait {
            let request = CloudKitLocalEntity.fetchRequest()
            request.sortDescriptors = []
            request.predicate = NSPredicate(format: "localId == %@", "")
            
            let placeholders = (try? context.fetch(request)) ?? []
            guard !placeholders.isEmpty else { return }
            
            placeholders.forEach(context.delete)
            do {
                try context.save()
                logger.log("Removed \(placeholders.count) saved placeholders")
            } catch {
                // They are removed with the next save
                logger.log("Failed to remove saved placeholders: \(error.localizedDescription)")
            }
        }
    }
    
    /// Models and keys that are synchronized now, but weren't when everything was downloaded last.
    struct CatchUp: Sendable {
        /// What is synchronized now, stored once the catch-up succeeded.
        let keys: Set<String>
        /// Entity names, and keys as `Entity.key`.
        let newKeys: Set<String>
        /// After a failure, the catch-up waits until then, as it downloads every record.
        var retryDate: Date?
        /// The records the last try couldn't store, whose objects' values the next try uploads once it stores them, rather
        /// than every object's again. `nil` before the first try of this process.
        var recordsLeft: Set<String>?
    }

    /// How often catching up is tried, if records couldn't be downloaded, before it's done without them. Their local values
    /// aren't uploaded then, and a later download can clear them, if their records still lack the keys.
    static let maximumCatchUpAttempts = 3
    
    /// Downloads skip models and keys this version of the app doesn't synchronize, e.g. ones a newer version added, while their
    /// change tokens move on. Once more is synchronized, they are caught up on, see `download(refreshingSharedZones:)`.
    ///
    /// What was synchronized when everything was caught up on last is stored next to the synchronization data,
    /// so the data model doesn't change.
    private func checkForNewlySynchronizedKeys(_ configuration: SDSInternalConfiguration) {
        let keys = Set(configuration.entities.flatMap { name, entity in
            [name] + entity.syncedProperties.map { "\(name).\($0)" }
        })
        let previousKeys = synchronizedKeysURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }
        
        // Without stored keys, e.g. on the first launch of a version that stores them, what was skipped before is unknown.
        // Catching up on every key would overwrite local changes with older values, so only later additions are caught up on.
        guard let previousKeys else {
            storeSynchronizedKeys(keys)
            return
        }
        // The stored keys aren't reduced, as another process using the same synchronization data, e.g. an extension,
        // can synchronize less, which would make the others catch up again every time
        guard !keys.isSubset(of: previousKeys) else { return }
        
        mutableState.withLock { $0.catchUp = CatchUp(keys: keys.union(previousKeys), newKeys: keys.subtracting(previousKeys)) }
    }
    
    private var synchronizedKeysURL: URL? {
        container.persistentStoreDescriptions.first?.url?.deletingLastPathComponent().appendingPathComponent("CloudKitSync.keys.json")
    }
    
    private func storeSynchronizedKeys(_ keys: Set<String>) {
        guard let url = synchronizedKeysURL else { return }
        do {
            try JSONEncoder().encode(keys).write(to: url, options: .atomic)
        } catch {
            logger.log("Failed to store the synchronized models and keys: \(error.localizedDescription)")
        }
    }
    
    /// Models and keys that still have to be caught up on.
    var pendingCatchUp: CatchUp? {
        mutableState.withLock { $0.catchUp }
    }
    
    func finishCatchUp(_ catchUp: CatchUp) {
        storeSynchronizedKeys(catchUp.keys)
        mutableState.withLock { $0.catchUp = nil }
        updateFileState { $0.incompleteCatchUp = nil }
    }

    /// A pending catch-up starts over, rather than only uploading the values of the records an earlier try couldn't store:
    /// the updates the earlier tries queued were forgotten, e.g. by a reset.
    func restartCatchUp() {
        mutableState.withLock { state in
            state.catchUp?.recordsLeft = nil
            state.catchUp?.retryDate = nil
        }
    }
    
    /// - Parameter recordsLeft: See `CatchUp.recordsLeft`, `nil` to leave it as it is.
    func postponeCatchUp(until date: Date, recordsLeft: Set<String>? = nil) {
        mutableState.withLock { state in
            state.catchUp?.retryDate = date
            if let recordsLeft {
                state.catchUp?.recordsLeft = recordsLeft
            }
        }
    }

    /// Counts a catch-up that couldn't store every record, and returns how often that happened for its keys, also in earlier
    /// processes.
    func countIncompleteCatchUp(_ catchUp: CatchUp) -> Int {
        var count = 0
        updateFileState { state in
            count = (state.incompleteCatchUp.flatMap { $0.newKeys == catchUp.newKeys ? $0.count : nil } ?? 0) + 1
            state.incompleteCatchUp = .init(newKeys: catchUp.newKeys, count: count)
        }
        return count
    }

    /// The keys that changed locally and weren't uploaded yet, like `pendingLocalChange(of:)`, of the records of many saved
    /// objects at once, by the URIs of the objects. Objects without records or without such keys are left out.
    func pendingLocalKeys(ofLocalIds localIds: [String]) -> [String: Set<String>] {
        let context = self.context
        return context.performAndWait {
            let entries = CloudKitLocalEntity.entries(forLocalIds: localIds, in: context)
            let updates = CloudKitUpdate.find(ids: entries.values.map(\.id), in: context)
            return entries.compactMapValues { entry in
                guard let keys = updates[entry.id]?.changedKeys, !keys.isEmpty else { return nil }
                return Set(keys)
            }
        }
    }

    /// A record's changes that weren't uploaded yet: the keys that changed locally, the ones with backfilled values (see
    /// `CloudKitUpdate.backfilledKeys`), and whether it was deleted locally.
    func pendingLocalChange(of id: String) -> PendingLocalChange {
        let context = self.context
        // On `context`'s queue, where removals are stored, so a deletion is either pending or stored
        let (pending, pendingLocalId) = context.performAndWait { () -> (PendingLocalChange, String?) in
            let request = CloudKitRemoval.fetchRequest()
            request.predicate = NSPredicate(format: "id = %@", id)
            let isRemoved = ((try? context.count(for: request)) ?? 0) > 0
            let update = CloudKitUpdate.find(for: id)
            let change = PendingLocalChange(
                keys: Set(update?.changedKeys ?? []),
                backfilledKeys: Set(update?.backfilledKeys ?? []),
                isLocalInsert: update?.isLocalInsert ?? false,
                isRemoved: isRemoved
            )
            guard !isRemoved, hasPendingDeletions, let localId = CloudKitLocalEntity.entry(forId: id, in: context)?.localId, isDeletionPending(localId: localId) else {
                return (change, nil)
            }
            return (change, localId)
        }
        var change = pending
        // Deleted, but its removal isn't stored yet
        if let pendingLocalId, isObjectGone(localId: pendingLocalId) {
            change.isRemoved = true
        }
        return change
    }

    /// Whether the store doesn't have the object anymore. Read from the store, as a context can still have an object whose
    /// row another context deleted.
    func isObjectGone(localId: String) -> Bool {
        guard
            let observedUpdateContext,
            let objectID = URL(string: localId).flatMap({ observedStore?.managedObjectID(forURIRepresentation: $0) }),
            let entityName = objectID.entity.name
        else { return true }
        return observedUpdateContext.performAndWaitUnchecked {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: entityName)
            request.predicate = NSPredicate(format: "self == %@", objectID)
            request.includesPendingChanges = false
            request.includesSubentities = false
            return ((try? observedUpdateContext.count(for: request)) ?? 0) == 0
        }
    }
    
    struct PendingLocalChange: Sendable {
        var keys: Set<String> = []
        var backfilledKeys: Set<String> = []
        /// See `CloudKitUpdate.isLocalInsert`.
        var isLocalInsert = false
        var isRemoved = false
    }
    
    /// The records of a database that downloads couldn't store yet, see `SDSHeldRecords`.
    func heldRecords(sharedDatabase: Bool) -> SDSHeldRecords {
        let directory = container.persistentStoreDescriptions.first?.url?.deletingLastPathComponent() ?? URL.temporaryDirectory
        return SDSHeldRecords(directory: directory.appending(component: "CloudKitSync.held/\(sharedDatabase ? "shared" : "private")", directoryHint: .isDirectory))
    }
    
    /// The error of a failed operation, or of the item CloudKit asks to wait for the longest, e.g. for a zone of a download,
    /// so the next synchronization waits that long.
    static func errorWithLongestRetryDelay(in error: Error) -> Error {
        guard let ckError = error as? CKError, ckError.code == .partialFailure else { return error }
        let itemErrors = (ckError.partialErrorsByItemID ?? [:]).values.compactMap { $0 as? CKError }
        return itemErrors.filter { $0.retryAfterSeconds != nil }.max { ($0.retryAfterSeconds ?? 0) < ($1.retryAfterSeconds ?? 0) } ?? error
    }
    
    // MARK: - Helper Functions
    
    func onlyIfSyncronizable(object: Any) -> SDSSynchronizableContainer? {
        (object as? NSManagedObject).flatMap(container(for:))
    }
    
    private func networkPathWasUpdated(with path: NWPath) {
        Task {
            if case .waitingForNetwork = await viewModel.state {
                await self.synchronize()
            }
        }
    }
    
    func accessState<T>(_ block: (SDSSynchronizerSavedState) -> T) -> T {
        context.performAndWaitUnchecked {
            block(context.savedState)
        }
    }
    
    func setState<T>(_ path: ReferenceWritableKeyPath<SDSSynchronizerSavedState, T>, value: T) {
        accessState { state in
            state[keyPath: path] = value
        }
    }
}



/// Finds the coordinator of the `ModelContainer` created by a closure, through the notification posted once its stores are loaded.
///
/// The notification is posted on the main queue, possibly while the closure is still running on another thread, so the state is guarded by a lock.
private final class _ContainerFinder: @unchecked Sendable {
    private let lock = NSLock()
    private var containerObservation: NSObjectProtocol?
    private var completion: ((NSPersistentStoreCoordinator) -> Void)?
    
    private var state: State = .retrieved([])
    
    enum State {
        case retrieved([NSPersistentStoreCoordinator])
        case done([URL])
        
        var retrievedCoordinators: [NSPersistentStoreCoordinator] {
            if case .retrieved(let array) = self {
                return array
            }
            return []
        }
    }
    
    init(
        closure: () -> ModelContainer?,
        completion: @escaping (NSPersistentStoreCoordinator) -> Void
    ) {
        self.completion = completion
        let containerObservation = NotificationCenter.default.addObserver(forName: .NSPersistentStoreCoordinatorStoresDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let store = notification.object as? NSPersistentStoreCoordinator else { return }
            
            self?.coordinatorFound(coordinator: store)
        }
        lock.withLock {
            self.containerObservation = containerObservation
        }
        
        guard let container = closure() else { return }
        let urls = container.configurations.map(\.url)
        
        assert(!urls.isEmpty, "The ModelContainer supplied to SDSSynchronizer should have at least one URL.")
        
        let coordinators = lock.withLock {
            let coordinators = state.retrievedCoordinators
            state = .done(urls)
            return coordinators
        }
        
        for coordinator in coordinators {
            coordinatorFound(coordinator: coordinator)
        }
    }
    
    func coordinatorFound(coordinator: NSPersistentStoreCoordinator) {
        // The completion is called outside of the lock, and only once
        let found: (completion: (NSPersistentStoreCoordinator) -> Void, observation: NSObjectProtocol?)? = lock.withLock {
            switch state {
            case .retrieved(let array):
                if !array.contains(coordinator) {
                    state = .retrieved(array + [coordinator])
                }
                return nil
            case .done(let urls):
                let containerUrls = coordinator.persistentStores.compactMap(\.url)
                guard urls.contains(where: { containerUrls.contains($0) }), let completion else { return nil }
                
                defer {
                    self.completion = nil
                    containerObservation = nil
                }
                return (completion, containerObservation)
            }
        }
        guard let found else { return }
        
        found.observation.map(NotificationCenter.default.removeObserver)
        found.completion(coordinator)
    }
}
