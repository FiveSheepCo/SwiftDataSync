import Foundation
import CoreData
import CloudKit
import OSLog

private var minRoutineDownloadDeltaInterval: TimeInterval {
    return generalLoadMultiplier * 60
}

private let bootstrapFailedError: SDSSyncError = SDSSyncError(title: "ckerror.bootstrapFailed")

extension SDSSynchronizer {
    
    public func forceDownload() {
        lastCompletedDownload = nil
        startSync()
    }
    
    public func forceDownloadSync() async {
        lastCompletedDownload = nil
        await synchronize()
    }
    
    func forceUpload() {
        lastCompletedUpload = nil
        startSync()
    }
    
    func forceSyncEverything() {
        lastCompletedUpload = nil
        lastCompletedDownload = nil
        startSync()
    }
    
    private func checkLoggedIntoIcloud() async throws {
        if await !viewModel.isLoggedIntoiCloud {
            // TODO(later): Handle user change, CKAccountChanged notification
            
            guard let accountStatus = try? await cloudContainer.accountStatus() else {
                logger.log("No Account Status")
                throw SDSStateError(state: .notLoggedIntoIcloud)
            }
            
            guard accountStatus == .available else {
                logger.log("Account Status is not `available`: \(accountStatus.rawValue, privacy: .public)")
                throw SDSStateError(state: .notLoggedIntoIcloud)
            }
            
            guard let userRecordID = try? await cloudContainer.userRecordID() else {
                logger.log("No user record id")
                throw SDSStateError(state: .notLoggedIntoIcloud)
            }
            
            logger.log("Logged in to iCloud")
            setState(\.userId, value: userRecordID)
            await viewModel.set(loggedIntoiCloud: true)
        }
    }
    
    private func checkNetwork() throws {
        // TODO(later): Support disabling cellular etc
        if networkMonitor.currentPath.status != .satisfied {
            throw SDSStateError(state: .waitingForNetwork)
        }
    }
    
    func startSync() {
        Task {
            await synchronize()
        }
    }
    
    func set(state: SDSSynchronizationViewModel.State) async {
        await viewModel.set(state: state)
    }
    
    func checkErrorWaitTimeIsCompleted() async throws {
        guard
            case .error(let error) = await viewModel.state,
            let ckError = error as? CKError,
            let retrySeconds = ckError.retryAfterSeconds,
            await -viewModel.lastStateChange.timeIntervalSinceNow < retrySeconds
        else { return }
        
        throw error
    }
    
    func synchronize() async {
        do {
            try await checkErrorWaitTimeIsCompleted()
            
            guard await viewModel.attemptSyncStart() else { return }
            
            await updateUpdatesToSend()
            
            try checkNetwork()
            
            try await checkLoggedIntoIcloud()
            
            try await bootstrap()
            
            await set(state: .uploading)
            try await upload()
            
            await set(state: .downloading)
            try await download()
            
            await set(state: .idle)
        }
        catch {
            await set(state: (error as? SDSStateError)?.state ?? .error(error))
        }
        
        await self.setRoutineTimer()
    }
    
    internal func updateUpdatesToSend() async {
        let context = self.context
        let updatesToSend = context.performAndWait {
            try! context.count(for: CloudKitUpdate.fetchRequest()) + context.count(for: CloudKitRemoval.fetchRequest())
        }
        
        await viewModel.set(updatesToSend: updatesToSend)
    }
    
    private func setRoutineTimer() async {
        guard routineSyncTimer == nil, case .error = await viewModel.state else { return }
        
        Task { @MainActor in
            let minInterval: TimeInterval
            if case .error(let error) = viewModel.state, let retryAfterSeconds = (error as? CKError)?.retryAfterSeconds {
                minInterval = retryAfterSeconds * 1.5
            } else {
                minInterval = minRoutineDownloadDeltaInterval
            }
            
            try? await Task.sleep(for: .milliseconds(minInterval * 1000))
            
            self.routineSyncTimer = nil
            self.startSync()
        }
    }
    
    /// Checks whether the synchronizer is bootstrapped. Should only be called by `synchronize()`.
    private func bootstrap() async throws {
        // Private DB Zone
        if !accessState(\.didCreateZone) {
            logger.log("Zone not created")
            try await createZone()
            setState(\.didCreateZone, value: true)
        }
        
        // Private DB Subscription
        if !accessState(\.didCreatePrivateSubscription) {
            logger.log("Private subscription not created")
            try await createSubscription()
            setState(\.didCreatePrivateSubscription, value: true)
        }
        
        // Shared DB Subscription
        if !accessState(\.didCreateSharedSubscription) {
            logger.log("Shared subscription not created")
            try await createSubscription(sharedDatabase: true)
            setState(\.didCreateSharedSubscription, value: true)
        }
    }
    
    /// Creates the `CoreData` record zone, if needed.
    func createZone() async throws {
        logger.log("Checking for existing zones")
        let zones = try await self.cloudPrivateDatabase.allRecordZones()
        
        guard !zones.contains(where: { zone -> Bool in
            zone.zoneID.zoneName == defaultZoneID.zoneName
        }) else {
            logger.log("Existing zone found")
            return
        }
        
        logger.log("Zone not found, creating...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let zone = CKRecordZone(zoneName: defaultZoneID.zoneName)
            let modifyZonesOperation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            var doneAlready = false
            modifyZonesOperation.perRecordZoneSaveBlock = { _, result in
                doneAlready = true
                
                switch result {
                case .failure(let error):
                    self.logger.log("Zone creation failed with error: \(error)")
                    continuation.resume(throwing: error)
                case .success:
                    self.logger.log("Zone created successfully")
                    continuation.resume()
                }
            }
            modifyZonesOperation.modifyRecordZonesResultBlock = { result in
                if case .failure(let error) = result, !doneAlready {
                    self.logger.log("Zone creation (full) failed with error: \(error)")
                    continuation.resume(throwing: error)
                }
            }
            self.cloudPrivateDatabase.add(modifyZonesOperation)
        }
    }
    
    private func createSubscription(sharedDatabase: Bool = false) async throws {
        if !sharedDatabase {
            // Register for remote notifications so CKSubscriptions work
            await xPlatform.registerForNotifications()
        }
        
        func log(_ text: String) {
            logger.log("\(sharedDatabase ? "Shared" : "Private") Database Subscription: \(text)")
        }
        
        log("Checking for existing")
        let database = (sharedDatabase ? cloudSharedDatabase : cloudPrivateDatabase)!
        let subscriptions = try await database.allSubscriptions()
        
        if subscriptions.contains(where: { subscription -> Bool in
            subscription.subscriptionID == Constants.subscriptionName
        }) {
            log("Existing subscription found")
            return
        }
        
        log("Subscription not found, creating...")
        try await withCheckedThrowingContinuation { continuation in
            let subscription = CKDatabaseSubscription(subscriptionID: Constants.subscriptionName)
            subscription.notificationInfo = CKSubscription.NotificationInfo(shouldSendContentAvailable: true)
            let modifySubscriptionsOperation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription])
            modifySubscriptionsOperation.modifySubscriptionsResultBlock = { result in
                log("Subscription creation: \(String(describing: result))")
                continuation.resume(with: result)
            }
            database.add(modifySubscriptionsOperation)
        }
    }
}
