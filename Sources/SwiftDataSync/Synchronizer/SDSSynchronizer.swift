import Foundation
import SwiftData
import CoreData
import CloudKit
import OSLog
import Network

private let notificationCenter = NotificationCenter.default

public class SDSSynchronizer {
    
    public static let shared = SDSSynchronizer()
    
    enum Constants {
        static let zoneName = "CoreData"
        static let subscriptionName = "DatabaseSubscription"
        
        static let parentWorkaroundKey = "parentWorkaround"
        
        static let zoneId = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }
    
    static func recordId(id: String) -> CKRecord.ID {
        return .init(recordName: id, zoneID: Constants.zoneId)
    }
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SDSSynchronizer")
    
    @MainActor
    let viewModel = SDSSynchronizationViewModel.shared
    
    // MARK: - Properties
    
    let container: NSPersistentContainer
    let context: NSManagedObjectContext
    
    var observedStore: NSPersistentStoreCoordinator?
    var observedUpdateContext: NSManagedObjectContext?
    var configuration: SDSInternalConfiguration?
    
    var cloudContainer: CKContainer!
    var cloudPrivateDatabase: CKDatabase!
    var cloudSharedDatabase: CKDatabase!
    
    // MARK: States
    
    var lastCompletedUpload: Date? {
        didSet { lastCompletedUpload.map({ viewModel.set(lastCompletionDate: $0) }) }
    }
    var lastCompletedDownload: Date? {
        didSet { lastCompletedDownload.map({ viewModel.set(lastCompletionDate: $0) }) }
    }
    
    var latestError: Error?
    
    var routineSyncTimer: Timer?
    
    let networkMonitor = NWPathMonitor()
    
    let savedState: SDSSynchronizerSavedState
    
    // MARK: - Initializer
    
    private init() {
        let model = NSManagedObjectModel.mergedModel(from: [.module])!
        for entity in model.entities {
            entity.managedObjectClassName = "SwiftDataSync.\(entity.name!)"
        }
        let container = NSPersistentContainer(
            name: "CloudKitSync",
            managedObjectModel: model
        )
        
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error {
                fatalError("Unresolved error \(error)")
            }
        })
        self.container = container
        let context = container.newBackgroundContext()
        self.context = context
        self.savedState = context.performAndWait({
            (try? context.fetch(SDSSynchronizerSavedState.fetchRequest()).first) ??
            SDSSynchronizerSavedState(entity: SDSSynchronizerSavedState.entity(), insertInto: context)
        })
        
        self.networkMonitor.pathUpdateHandler = networkPathWasUpdated
        self.networkMonitor.start(queue: .main)
    }
    
    private var containerFinder: _ContainerFinder?
    
    /// Used to setup the synchronizer. Should be called as early as possible.
    /// - Parameters:
    ///   - containerName: The name of the iCloud container to sync to.
    ///   - configuration: The configuration.
    ///   - coordinator: The ``NSPersistentStoreCoordinator`` to sync.
    public func setup(
        containerName: String,
        configuration: SDSConfiguration = .init(rawEntities: [:]),
        coordinator: NSPersistentStoreCoordinator
    ) {
        self.cloudContainer = CKContainer(identifier: containerName)
        self.cloudPrivateDatabase = cloudContainer.privateCloudDatabase
        self.cloudSharedDatabase = cloudContainer.sharedCloudDatabase
        
        Task {
            await viewModel.setWaitingForContainerDetection()
        }
        self.setup(storeToObserve: coordinator, configuration: configuration)
    }
    
    /// Used to setup the synchronizer. Should be called as early as possible.
    /// - Parameters:
    ///   - containerName: The name of the iCloud container to sync to.
    ///   - configuration: The configuration.
    ///   - modelContainer: The ``ModelContainer`` to sync. This should be the first time that container is called.
    public func setup(
        containerName: String,
        configuration: SDSConfiguration = .init(swiftDataEntities: []),
        modelContainer: @autoclosure () -> ModelContainer
    ) {
        self.cloudContainer = CKContainer(identifier: containerName)
        self.cloudPrivateDatabase = cloudContainer.privateCloudDatabase
        self.cloudSharedDatabase = cloudContainer.sharedCloudDatabase
        
        self.containerFinder = .init(
            closure: modelContainer,
            completion: { [weak self] coordinator in
                guard let self else { return }
                
                self.containerFinder = nil
                self.setup(storeToObserve: coordinator, configuration: configuration)
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
    
    private func setup(storeToObserve: NSPersistentStoreCoordinator, configuration: SDSConfiguration) {
        self.configuration = storeToObserve.makeConfiguration(externalConfiguration: configuration)
        
        self.observedStore = storeToObserve
        
        let observedUpdateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        observedUpdateContext.persistentStoreCoordinator = storeToObserve
        observedUpdateContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        observedUpdateContext.automaticallyMergesChangesFromParent = true
        self.observedUpdateContext = observedUpdateContext
        
        setupNotifications()
        
        Task {
            await viewModel.set(state: .idle)
            await synchronize()
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
}



private class _ContainerFinder {
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
        closure: () -> ModelContainer,
        completion: @escaping (NSPersistentStoreCoordinator) -> Void
    ) {
        self.containerObservation = NotificationCenter.default.addObserver(forName: .NSPersistentStoreCoordinatorStoresDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let store = notification.object as? NSPersistentStoreCoordinator else { return }
            
            self?.coordinatorFound(coordinator: store)
        }
        self.completion = completion
        
        let container = closure()
        let urls = container.configurations.map(\.url)
        
        assert(!urls.isEmpty, "The ModelContainer supplied to SDSSynchronizer should have at least one URL.")
        
        let coordinators = state.retrievedCoordinators
        state = .done(urls)
        
        for coordinator in coordinators {
            coordinatorFound(coordinator: coordinator)
        }
    }
    
    func coordinatorFound(coordinator: NSPersistentStoreCoordinator) {
        switch state {
        case .retrieved(let array):
            if !array.contains(coordinator) {
                state = .retrieved(array + [coordinator])
            }
        case .done(let urls):
            let containerUrls = coordinator.persistentStores.compactMap(\.url)
            if urls.contains(where: { containerUrls.contains($0) }) {
                completion?(coordinator)
                completion = nil
                containerObservation = nil
            }
        }
    }
}
