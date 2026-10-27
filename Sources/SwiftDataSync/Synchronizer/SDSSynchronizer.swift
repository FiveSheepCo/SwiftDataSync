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
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SDSSynchronizer")
    
    let viewModel: SDSSynchronizationViewModel
    
    // MARK: - Properties
    
    let container: NSPersistentContainer
    let context: NSManagedObjectContext
    
    /// State that is set during setup or changes while synchronizing.
    /// It's used from CloudKit's callbacks, Core Data's queues and tasks, so it's guarded by a lock.
    struct MutableState: Sendable {
        var observedStore: NSPersistentStoreCoordinator?
        var observedUpdateContext: NSManagedObjectContext?
        var configuration: SDSInternalConfiguration?
        /// Whether local changes of the observed store are tracked, which isn't the case if setting up failed.
        var isObservingStore = false
        
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
        
        /// Keys of objects that were changed in a context but not saved yet.
        var unsavedChanges: [UnsavedChangeKey: Set<String>] = [:]
        
        fileprivate var containerFinder: _ContainerFinder?
        
        var routineSync: Task<Void, Never>?
        var syncLeaseRetry: Task<Void, Never>?
    }
    private let mutableState = OSAllocatedUnfairLock(initialState: MutableState())
    
    var observedStore: NSPersistentStoreCoordinator? { mutableState.withLock { $0.observedStore } }
    var observedUpdateContext: NSManagedObjectContext? { mutableState.withLock { $0.observedUpdateContext } }
    var configuration: SDSInternalConfiguration? { mutableState.withLock { $0.configuration } }
    var isObservingStore: Bool { mutableState.withLock { $0.isObservingStore } }
    
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
    
    /// An object's changes in the context that saves them to the store.
    ///
    /// Several contexts can change the same object, and each one's changes are only saved by its own save.
    struct UnsavedChangeKey: Hashable, Sendable {
        let rootContext: ObjectIdentifier
        let objectId: NSManagedObjectID
        
        /// Changes of a child context are saved to the store by its topmost parent.
        init(context: NSManagedObjectContext, objectId: NSManagedObjectID) {
            var rootContext = context
            while let parent = rootContext.parent {
                rootContext = parent
            }
            self.rootContext = ObjectIdentifier(rootContext)
            self.objectId = objectId
        }
    }
    
    /// Uploads read values from the store, so a change that isn't saved yet isn't uploaded.
    /// Its keys are remembered, so the change is stored again once it is saved, see `contextSaved`.
    func rememberUnsavedChanges(_ changes: [SDSObjectChange], in context: NSManagedObjectContext) {
        mutableState.withLock { state in
            for change in changes {
                state.unsavedChanges[UnsavedChangeKey(context: context, objectId: change.objectId), default: []].formUnion(change.changedKeys)
            }
        }
    }
    
    /// Returns and forgets the changed keys of objects that a root context saved.
    func takeUnsavedChanges(of objectIds: [NSManagedObjectID], savedBy context: NSManagedObjectContext) -> [NSManagedObjectID: Set<String>] {
        mutableState.withLock { state in
            var changes: [NSManagedObjectID: Set<String>] = [:]
            for objectId in objectIds {
                changes[objectId] = state.unsavedChanges.removeValue(forKey: UnsavedChangeKey(context: context, objectId: objectId))
            }
            return changes
        }
    }
    
    func wasDeletedBySynchronizer(_ objectId: NSManagedObjectID) -> Bool {
        mutableState.withLock { $0.deletionsBySynchronizer.contains(objectId) }
    }
    
    /// Whether a download inserted the object and gave it its record's id. Objects that weren't saved yet otherwise have no id.
    func isDownloadedObject(_ object: NSManagedObject) -> Bool {
        context.performAndWaitUnchecked {
            temporaryObjectContainers[object] != nil
        }
    }
    
    /// Reads and changes the zones of recently accepted shares at once, as accepting a share can happen while synchronizing.
    func withAcceptedShareZones<T: Sendable>(_ body: @Sendable (inout [CKRecordZone.ID: Date]) -> T) -> T {
        mutableState.withLock { body(&$0.acceptedShareZones) }
    }
    
    let networkMonitor = NWPathMonitor()
    
    /// The `CloudKitLocalEntity`s for temporary objects. Only accessed on `context`'s queue, which serializes the access.
    nonisolated(unsafe) var temporaryObjectContainers: [NSManagedObject: CloudKitLocalEntity] = [:]
    
    /// Has to be called on `context`'s queue.
    func temporaryObject(for id: String) -> NSManagedObject? {
        temporaryObjectContainers.first { (key: NSManagedObject, value: CloudKitLocalEntity) in
            value.id == id
        }?.key
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
            container.persistentStoreDescriptions = [
                .init(url: containerUrl.appendingPathComponent("CloudKitSync.sqlite"))
            ]
        }
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error {
                fatalError("Unresolved error \(error)")
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
    
    /// Should be called when a remote notification was received.
    public func didReceiveRemoteNotification(userInfo: [AnyHashable : Any]) async {
        // TODO(later): selectively download based on the user info
        await self.forceDownloadSync()
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
            await viewModel.set(state: .idle)
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
