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
        
        let state = SDSSynchronizerSavedState(entity: SDSSynchronizerSavedState.entity(), insertInto: self)
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
        /// Whether synchronizing was stopped with `stop()`.
        var isStopped = false

        var defaultZoneID: CKRecordZone.ID?
        var cloudContainer: CKContainer?
        var cloudPrivateDatabase: CKDatabase?
        var cloudSharedDatabase: CKDatabase?
        
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
        
        /// Records of entities with an identity that another device saved first, by name. Their next upload saves the
        /// changed keys over them, see `takeServerRecordOfConflict(named:)`.
        var serverRecordsOfConflicts: [String: CKRecord] = [:]

        /// Records CloudKit rejected, which aren't uploaded for a while.
        var quarantine = SDSRecordQuarantine()

        fileprivate var containerFinder: _ContainerFinder?

        var routineSync: Task<Void, Never>?
        var catchUpRetry: Task<Void, Never>?
        var syncLeaseRetry: Task<Void, Never>?
        /// Saves the synchronization data and synchronizes shortly after the observed store was saved, see `contextSaved`.
        var saveSync: Task<Void, Never>?
    }
    private let mutableState = OSAllocatedUnfairLock(initialState: MutableState())
    
    var observedStore: NSPersistentStoreCoordinator? { mutableState.withLock { $0.observedStore } }
    var observedUpdateContext: NSManagedObjectContext? { mutableState.withLock { $0.observedUpdateContext } }
    var configuration: SDSInternalConfiguration? { mutableState.withLock { $0.configuration } }
    var isObservingStore: Bool { mutableState.withLock { $0.isObservingStore } }
    var isStopped: Bool { mutableState.withLock { $0.isStopped } }

    var defaultZoneID: CKRecordZone.ID! { mutableState.withLock { $0.defaultZoneID } }
    var cloudContainer: CKContainer! { mutableState.withLock { $0.cloudContainer } }
    var cloudPrivateDatabase: CKDatabase! { mutableState.withLock { $0.cloudPrivateDatabase } }
    var cloudSharedDatabase: CKDatabase! { mutableState.withLock { $0.cloudSharedDatabase } }
    
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
    
    /// Saves `observedUpdateContext`. Has to be called on its queue.
    ///
    /// Contexts that merge its changes report its deletions like deletions made in them, which must not be uploaded:
    /// they are deletions downloaded from iCloud, or local copies of shares that were left, whose records belong to someone else.
    func saveObservedUpdateContext(_ observedUpdateContext: NSManagedObjectContext) throws {
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
    
    /// Returns and forgets the synchronized keys a context saved to the store.
    func takeKeysBeingSaved(by context: NSManagedObjectContext) -> [NSManagedObjectID: Set<String>] {
        mutableState.withLock { $0.keysBeingSaved.removeValue(forKey: ObjectIdentifier(context)) ?? [:] }
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

    func quarantine(_ recordNames: [String: Date]) {
        mutableState.withLock { state in
            for (recordName, lastChangeDate) in recordNames {
                state.quarantine.add(recordName, lastChangeDate: lastChangeDate)
            }
        }
    }

    func resetQuarantine() {
        mutableState.withLock { $0.quarantine = SDSRecordQuarantine() }
    }
    
    /// Reads and changes the zones of recently accepted shares at once, as accepting a share can happen while synchronizing.
    func withAcceptedShareZones<T: Sendable>(_ body: @Sendable (inout [CKRecordZone.ID: Date]) -> T) -> T {
        mutableState.withLock { body(&$0.acceptedShareZones) }
    }
    
    let networkMonitor = NWPathMonitor()
    
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
        temporaryObjectIds[object] = id
        temporaryObjectsById[id] = object
    }

    /// Has to be called on `context`'s queue.
    func removeAllTemporaryObjects() {
        temporaryObjectIds = [:]
        temporaryObjectsById = [:]
    }
    
    // MARK: - Initializer
    
    private init() {
        self.viewModel = SDSSynchronizationViewModel.shared
        
        let model = NSManagedObjectModel.mergedModel(from: [.module])!
        for entity in model.entities {
            entity.managedObjectClassName = "SwiftDataSync.\(entity.name!)"
        }
        let container = NSPersistentContainer(
            name: "CloudKitSync",
            managedObjectModel: model
        )
        
        if
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
        
        self.networkMonitor.pathUpdateHandler = { [weak self] path in
            self?.networkPathWasUpdated(with: path)
        }
        self.networkMonitor.start(queue: .main)
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
            try coordinator.replacePersistentStore(at: url, withPersistentStoreFrom: sourceURL, type: .sqlite)
            try coordinator.destroyPersistentStore(at: sourceURL, type: .sqlite)

            // What was synchronized when everything was caught up on last, see `checkForNewlySynchronizedKeys(_:)`
            let keysURL = sourceURL.deletingLastPathComponent().appendingPathComponent("CloudKitSync.keys.json")
            if fileManager.fileExists(atPath: keysURL.path) {
                try fileManager.moveItem(at: keysURL, to: url.deletingLastPathComponent().appendingPathComponent("CloudKitSync.keys.json"))
            }
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
        await self.forceDownloadSync()
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

        Task {
            await viewModel.set(state: .stopped)
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
            defer { state.isStopped = false }
            return state.isStopped
        }
        guard wasStopped else { return }

        Task {
            // Unless it was never set up, or setting up failed
            guard self.isObservingStore else { return }
            await viewModel.endStop()
            await synchronize()
        }
    }

    /// Thrown when a running synchronization notices that synchronizing was stopped, see `stop()`.
    struct StoppedError: Error {}

    /// Throws if synchronizing was stopped, so a running synchronization ends at its next step.
    func checkNotStopped() throws {
        if isStopped {
            throw StoppedError()
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
        let cloudContainer = CKContainer(identifier: containerName)
        mutableState.withLock { state in
            state.defaultZoneID = CKRecordZone.ID(zoneName: defaultZoneID)
            state.cloudContainer = cloudContainer
            state.cloudPrivateDatabase = cloudContainer.privateCloudDatabase
            state.cloudSharedDatabase = cloudContainer.sharedCloudDatabase
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
        observedUpdateContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
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
        
        setupNotifications()
        mutableState.withLock { $0.isObservingStore = true }

        Task {
            // `stop()` can be called before the store is found
            await viewModel.set(state: isStopped ? .stopped : .idle)
            await synchronize()
        }
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
    }
    
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
    }
    
    func postponeCatchUp(until date: Date) {
        mutableState.withLock { $0.catchUp?.retryDate = date }
    }
    
    /// The keys of a record that changed locally and weren't uploaded yet, and whether it was deleted locally and that wasn't uploaded yet.
    func pendingLocalChange(of id: String) -> (keys: Set<String>, isRemoved: Bool) {
        let context = self.context
        return context.performAndWait {
            let request = CloudKitRemoval.fetchRequest()
            request.predicate = NSPredicate(format: "id = %@", id)
            let isRemoved = ((try? context.count(for: request)) ?? 0) > 0
            return (Set(CloudKitUpdate.find(for: id)?.changedKeys ?? []), isRemoved)
        }
    }
    
    // MARK: - Helper Functions
    
    func onlyIfSyncronizable(object: Any) -> SDSSynchronizableContainer? {
        (object as? NSManagedObject)?.synchronizableContainer
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
