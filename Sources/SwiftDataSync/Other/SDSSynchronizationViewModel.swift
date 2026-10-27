import Foundation
import OSLog
import CloudKit

/// A model which contains the current sync state.
@Observable @MainActor
public final class SDSSynchronizationViewModel {
    /// The shared instance of the view model.
    nonisolated public static let shared = SDSSynchronizationViewModel()
    
    public enum State: Sendable {
        case waitingForSetup
        case waitingForNetwork
        case waitingForContainerDetection
        case bootstrapping
        case uploading
        case downloading
        case idle
        
        case processingSaveEvent
        case savingShare
        
        case notLoggedIntoIcloud
        case error(Error)
    }
    
    // MARK: Properties
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SDSSynchronizationViewModel")
    
    public private(set) var lastStateChange: Date = .now
    public private(set) var state: State = .waitingForSetup
    
    public private(set) var lastCompletionDate: Date? = nil
    
    public internal(set) var isLoggedIntoiCloud: Bool = false
    
    public internal(set) var updatesToSend: Int = 0
    
    @ObservationIgnored
    private var syncWasRequestedWhileSavingShare = false
    
    public var isSavingShare: Bool {
        if case .savingShare = state {
            return true
        }
        return false
    }
    
    // MARK: Initializer
    
    private nonisolated init() {}
    
    // MARK: Functions
    
    func setWaitingForContainerDetection() {
        guard case .waitingForSetup = state else { return }
        
        self.set(state: .waitingForContainerDetection)
    }
    
    /// Starts a synchronization unless another one or another operation is running.
    ///
    /// The state is checked and set without suspending, so nothing else can start in between.
    func attemptSyncStart() -> Bool {
        switch state {
        case .idle, .waitingForNetwork, .notLoggedIntoIcloud: break
        case .error(let error):
            // CloudKit can ask to wait before retrying, e.g. while it throttles requests. The routine synchronization retries later.
            if let retrySeconds = (error as? CKError)?.retryAfterSeconds, -lastStateChange.timeIntervalSinceNow < retrySeconds {
                return false
            }
        case .savingShare:
            // Nothing else starts it once the share is saved
            syncWasRequestedWhileSavingShare = true
            return false
        default: return false
        }
        
        self.set(state: .bootstrapping)
        return true
    }
    
    /// Restores `state` after saving a share. Returns whether a synchronization was requested in the meantime.
    func endSavingShare(restoring state: State) -> Bool {
        let syncWasRequested = syncWasRequestedWhileSavingShare
        syncWasRequestedWhileSavingShare = false
        
        self.set(state: state)
        return syncWasRequested
    }
    
    private var isSettable: Bool {
        switch state {
        case .idle, .error, .waitingForNetwork, .notLoggedIntoIcloud: true
        default: false
        }
    }
    
    /// Waits until no synchronization is running, then sets `state`. Returns the state it replaced.
    /// Throws if the task is cancelled while waiting.
    @discardableResult
    func waitForIdle(setting state: State) async throws -> State {
        while !isSettable {
            try await Task.sleep(for: .seconds(1))
        }
        
        let previousState = self.state
        self.set(state: state)
        return previousState
    }
    
    func set(state: State) {
        logger.log("New State: \(String(describing: state), privacy: .public)")
        self.state = state
        self.lastStateChange = .now
    }
    
    nonisolated func set(lastCompletionDate: Date) {
        Task { @MainActor in
            self.lastCompletionDate = lastCompletionDate
        }
    }
    
    func set(loggedIntoiCloud: Bool) {
        self.isLoggedIntoiCloud = loggedIntoiCloud
    }
    
    func set(updatesToSend: Int) {
        self.updatesToSend = updatesToSend
    }
    
    func forceSync() {
        SDSSynchronizer.shared.forceSyncEverything()
    }
    
    var forceSyncDisabled: Bool {
        switch state {
        case .idle, .error: return false
        default: return true
        }
    }
}
