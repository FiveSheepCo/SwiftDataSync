import Foundation
import CoreData
import CloudKit
import OSLog

private var minUploadDeltaInterval: TimeInterval {
    return generalLoadMultiplier
}

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
            if let userRecordID = try? await cloudContainer.userRecordID() {
                logger.log("Logged in to iCloud")
                context.performAndWait {
                    savedState.userId = userRecordID
                }
                await viewModel.set(loggedIntoiCloud: true)
            } else {
                logger.log("Not logged in to iCloud")
                throw SDSStateError(state: .notLoggedIntoIcloud)
            }
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
            
            await set(state: .downloading)
            try await download()
            
            await set(state: .uploading)
            try await upload()
            
            await set(state: .idle)
        }
        catch {
            await set(state: (error as? SDSStateError)?.state ?? .error(error))
        }
        
        self.setRoutineTimer()
    }
    
    internal func updateUpdatesToSend() async {
        let updatesToSend = context.performAndWait {
            try! context.count(for: CloudKitUpdate.fetchRequest()) + context.count(for: CloudKitRemoval.fetchRequest())
        }
        
        await viewModel.set(updatesToSend: updatesToSend)
    }
    
    private func setRoutineTimer() {
        guard routineSyncTimer == nil else { return }
        
        Task { @MainActor in
            let minInterval: TimeInterval
            if case .error(let error) = viewModel.state, let retryAfterSeconds = (error as? CKError)?.retryAfterSeconds {
                minInterval = retryAfterSeconds * 1.5
            } else {
                minInterval = minRoutineDownloadDeltaInterval
            }
            self.routineSyncTimer = Timer.scheduledTimer(withTimeInterval: minInterval, repeats: false) { _ in
                self.routineSyncTimer = nil
                self.startSync()
            }
        }
    }
    
    /// Checks whether the synchronizer is bootstrapped. Should only be called by `synchronize()`.
    private func bootstrap() async throws {
        // Private DB Zone
        if !savedState.didCreateZone {
            logger.log("Zone not created")
            try await createZone()
            savedState.didCreateZone = true
        }
        
        // Private DB Subscription
        if !savedState.didCreatePrivateSubscription {
            logger.log("Private subscription not created")
            try await createSubscription()
            savedState.didCreatePrivateSubscription = true
        }
        
        // Shared DB Subscription
        if !savedState.didCreateSharedSubscription {
            logger.log("Shared subscription not created")
            try await createSubscription(sharedDatabase: true)
            savedState.didCreateSharedSubscription = true
        }
    }
    
    /// Creates the `CoreData` record zone, if needed.
    func createZone() async throws {
        logger.log("Checking for existing zones")
        let zones = try await self.cloudPrivateDatabase.allRecordZones()
        
        guard !zones.contains(where: { zone -> Bool in
            zone.zoneID.zoneName == Constants.zoneName
        }) else {
            logger.log("Existing zone found")
            return
        }
        
        logger.log("Zone not found, creating...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let zone = CKRecordZone(zoneName: Constants.zoneName)
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
