import Foundation
import OSLog

/// A model which contains the current sync state.
@Observable @MainActor
public class SDSSynchronizationViewModel {
    /// The shared instance of the view model.
    public static let shared = SDSSynchronizationViewModel()
    
    public enum State {
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
    
    public var isSavingShare: Bool {
        if case .savingShare = state {
            return true
        }
        return false
    }
    
    // MARK: Initializer
    
    private init() {}
    
    // MARK: Functions
    
    func setWaitingForContainerDetection() {
        guard case .waitingForSetup = state else { return }
        
        self.set(state: .waitingForContainerDetection)
    }
    
    func attemptSyncStart() -> Bool {
        switch state {
        case .idle, .error, .waitingForNetwork, .notLoggedIntoIcloud: break
        default: return false
        }
        
        self.set(state: .bootstrapping)
        return true
    }
    
    private var isSettable: Bool {
        switch state {
        case .idle, .error, .waitingForNetwork, .notLoggedIntoIcloud: true
        default: false
        }
    }
    
    func waitForIdle(setting state: State) async {
        while !isSettable {
            try! await Task.sleep(for: .seconds(1))
        }
        
        self.set(state: state)
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
