import Foundation
import CoreData
import CloudKit
import OSLog

@MainActor
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
    
    /// Checks the account once, and again after it changed, see `accountChanged(_:)`.
    private func checkLoggedIntoIcloud() async throws {
        if await !viewModel.isLoggedIntoiCloud {
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
            
            // The synchronization data of another account doesn't apply to this one
            if let previousUserRecordID = accessState(\.userId), previousUserRecordID != userRecordID {
                logger.log("The iCloud account changed, starting over with the new account")
                try resetForNewAccount()
            }

            logger.log("Logged in to iCloud")
            setState(\.userId, value: userRecordID)
            try context.performAndWait {
                try context.save()
            }
            await viewModel.set(loggedIntoiCloud: true)
        }
    }

    /// Forgets the records, shares, zones and change tokens of the previous account, so the new account is synchronized from scratch.
    ///
    /// Local copies of other users' shares are removed, as they were shared with the previous account. Other local models stay.
    /// They're uploaded to the new account if this device creates its zone (see `bootstrap()`), and otherwise once they change.
    private func resetForNewAccount() throws {
        let context = self.context
        let sharedRootIds: [String] = context.performAndWait {
            ((try? context.fetch(CloudKitShare.fetchRequest())) ?? []).compactMap { entry in
                entry.share?.isSharedByOtherUser == true ? entry.id : nil
            }
        }
        for id in sharedRootIds {
            if let root = find(for: id) {
                try removeLocalCopy(of: root)
            }
        }

        try context.performAndWaitUnchecked {
            for entityName in ["CloudKitLocalEntity", "CloudKitUpdate", "CloudKitRemoval", "CloudKitShare", "CloudKitZone"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.includesPropertyValues = false
                try context.fetch(request).forEach(context.delete)
            }
            accessState { state in
                state.changeToken = nil
                state.didCreateZone = false
                state.didCreatePrivateSubscription = false
                state.didCreateSharedSubscription = false
            }
            try context.save()
        }

        withAcceptedShareZones { $0 = [:] }
        resetQuarantine()
    }

    /// Thrown when the zone of the private database is gone, e.g. because it was deleted on another device, or because the
    /// user deleted the app's data in iCloud (`CKError.Code.userDeletedZone`).
    struct PrivateZoneMissingError: Error {
        let error: CKError
    }

    /// Thrown when change tokens expired. They're reset, so the zones are downloaded completely next.
    struct ChangeTokenExpiredError: Error {}

    /// The error of an operation of the private database if its zone is gone. Zones of the shared database disappear when they
    /// are no longer shared, which `refreshSharedZoneIDs()` handles.
    func privateZoneMissingError(in error: Error) -> CKError? {
        Self.privateZoneMissingError(in: error, defaultZoneID: defaultZoneID)
    }

    static func privateZoneMissingError(in error: Error, defaultZoneID: CKRecordZone.ID) -> CKError? {
        guard let error = error as? CKError else { return nil }

        let codes: Set<CKError.Code> = [.zoneNotFound, .userDeletedZone]
        if codes.contains(error.code) {
            return error
        }
        guard error.code == .partialFailure else { return nil }

        for (itemId, itemError) in error.partialErrorsByItemID ?? [:] {
            guard let itemError = itemError as? CKError, codes.contains(itemError.code) else { continue }
            let zoneID = (itemId as? CKRecordZone.ID) ?? (itemId as? CKRecord.ID)?.zoneID
            if zoneID == nil || zoneID == defaultZoneID {
                return itemError
            }
        }
        return nil
    }

    /// The zone is created again with the next synchronization, which uploads every local model, see `bootstrap()`.
    ///
    /// If the user deleted the app's data in iCloud, the data isn't uploaded again without asking: synchronizing stops until
    /// it's started again (`start()`, or the next launch), and the state shows the error, so the app can ask the user.
    private func handlePrivateZoneMissing(_ error: PrivateZoneMissingError) async {
        let isDeletedByUser = error.error.code == .userDeletedZone
        logger.error("The zone of the private database is gone\(isDeletedByUser ? ", deleted by the user" : ""): \(error.error)")

        let context = self.context
        context.performAndWaitUnchecked {
            accessState { state in
                state.changeToken = nil
                state.didCreateZone = false
            }
            if isDeletedByUser {
                // The changes of the data that was deleted aren't uploaded anymore
                for entityName in ["CloudKitUpdate", "CloudKitRemoval"] {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                    request.predicate = NSPredicate(format: "sharedZone == nil")
                    ((try? context.fetch(request)) ?? []).forEach(context.delete)
                }
            }
            do {
                try context.save()
            } catch {
                logger.error("Failed to save after the zone was gone: \(error.localizedDescription)")
            }
        }

        if isDeletedByUser {
            stopSynchronizing()
            await viewModel.set(state: .error(error.error))
        } else {
            await set(state: .idle)
            startSync()
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
    
    /// Sets the state, or `.stopped` once synchronizing was stopped, which a running synchronization only notices at its next step.
    func set(state: SDSSynchronizationViewModel.State) async {
        await viewModel.set(state: isStopped ? .stopped : state)
    }

    func synchronize() async {
        // E.g. after a failed adoption, the error state would allow a forced or push-triggered synchronization,
        // whose download would add the existing records as duplicates
        guard isObservingStore, !isStopped else { return }

        do {
            guard await viewModel.attemptSyncStart() else {
                // E.g. while CloudKit asks to wait after an error, a retry has to be scheduled, as a pending one might have been used up
                await setRoutineTimer()
                return
            }
            
            guard syncLease.acquire() else { throw SDSSyncLease.UnavailableError() }
            defer { syncLease.release() }
            
            // E.g. while the device is locked, data protection can keep the stores from being read.
            // Data that can't be read mustn't be taken for missing data, so nothing is synchronized then.
            try checkStoresAreReadable()
            
            refreshSharedData()
            
            await updateUpdatesToSend()
            
            try checkNetwork()
            
            try await checkLoggedIntoIcloud()
            
            try await bootstrap()
            try checkNotStopped()

            // Pending changes for shares that are gone would fail the upload, so they are cleaned up first.
            // This is best effort: a failure here shouldn't keep the private database from uploading. The download retries it.
            var didRefreshSharedZones = false
            do {
                try await refreshSharedZoneIDs()
                didRefreshSharedZones = true
            } catch {
                logger.log("Failed to refresh shared zones before uploading: \(error.localizedDescription)")
            }
            
            await set(state: .uploading)
            let rejectedCount = try await upload()
            try checkNotStopped()

            // Also after records were rejected, as downloads don't overwrite changes that weren't uploaded yet
            await set(state: .downloading)
            try await download(refreshingSharedZones: !didRefreshSharedZones)

            if rejectedCount > 0 {
                // They're uploaded once they change, or after a while, see `SDSRecordQuarantine`
                await set(state: .error(SDSSyncError(title: "error.uploadIncomplete")))
                await setRoutineTimer(interval: SDSRecordQuarantine.duration)
                await synchronizeAgainIfRequested()
                return
            }
            await set(state: .idle)
        }
        catch is ChangesStillPendingError {
            // Not an error: the changes are uploaded and downloads resume once the app stops changing the records
            await set(state: .idle)
            await setRoutineTimer(onlyAfterError: false)
            await synchronizeAgainIfRequested()
            return
        }
        catch is SDSSyncLease.UnavailableError {
            // The other process uploads the pending changes of this one too, but changes made after its upload still need to be synchronized
            logger.log("Another process is synchronizing, retrying later")
            await set(state: .idle)
            retryAfterSyncLease()
        }
        catch is StoppedError {
            logger.log("Synchronizing was stopped")
            await set(state: .stopped)
            return
        }
        catch let error as PrivateZoneMissingError {
            await handlePrivateZoneMissing(error)
            return
        }
        catch let error as CKError where error.code == .notAuthenticated {
            // E.g. signed out of iCloud. The account is checked again with the next synchronization, see `accountChanged(_:)`.
            logger.log("Not logged in to iCloud anymore: \(error)")
            await viewModel.set(loggedIntoiCloud: false)
            await set(state: .notLoggedIntoIcloud)
            return
        }
        catch {
            await set(state: (error as? SDSStateError)?.state ?? .error(error))
        }

        await self.setRoutineTimer()
        await synchronizeAgainIfRequested()
    }

    /// Synchronizes again if that was requested while synchronizing, e.g. by a push for a change the download might have missed.
    private func synchronizeAgainIfRequested() async {
        if await viewModel.takeSyncRequestedWhileSyncing() {
            startSync()
        }
    }
    
    private func checkStoresAreReadable() throws {
        let context = self.context
        try context.performAndWait {
            _ = try context.count(for: SDSSynchronizerSavedState.fetchRequest())
        }
        
        guard let observedUpdateContext, let entityName = configuration?.entities.keys.first else { return }
        try observedUpdateContext.performAndWait {
            _ = try observedUpdateContext.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entityName))
        }
    }
    
    /// Makes changes of other processes using the same synchronization data visible to this process.
    private func refreshSharedData() {
        let context = self.context
        context.performAndWait {
            context.refreshAllObjects()
        }
        
        if let observedUpdateContext {
            observedUpdateContext.performAndWait {
                observedUpdateContext.refreshAllObjects()
            }
        }
    }
    
    private func retryAfterSyncLease() {
        startTask(at: \.syncLeaseRetry) {
            try? await Task.sleep(for: .seconds(SDSSyncLease.duration / 3))
            
            self.finishTask(at: \.syncLeaseRetry)
            self.startSync()
        }
    }
    
    internal func updateUpdatesToSend() async {
        let context = self.context
        let updatesToSend = context.performAndWait {
            ((try? context.count(for: CloudKitUpdate.fetchRequest())) ?? 0) + ((try? context.count(for: CloudKitRemoval.fetchRequest())) ?? 0)
        }
        
        await viewModel.set(updatesToSend: updatesToSend)
    }
    
    /// Schedules a synchronization after an error, or also without one.
    /// - Parameter interval: How long it waits, rather than depending on the error.
    private func setRoutineTimer(onlyAfterError: Bool = true, interval: TimeInterval? = nil) async {
        if onlyAfterError {
            guard case .error = await viewModel.state else { return }
        }

        startTask(at: \.routineSync) { @MainActor in
            let minInterval: TimeInterval
            if let interval {
                minInterval = interval
            } else if case .error(let error) = self.viewModel.state, let retryAfterSeconds = (error as? CKError)?.retryAfterSeconds {
                minInterval = retryAfterSeconds * 1.5
            } else {
                minInterval = minRoutineDownloadDeltaInterval
            }
            
            try? await Task.sleep(for: .milliseconds(minInterval * 1000))
            
            self.finishTask(at: \.routineSync)
            self.startSync()
        }
    }
    
    /// Checks whether the synchronizer is bootstrapped. Should only be called by `synchronize()`.
    private func bootstrap() async throws {
        // Private DB Zone
        if !accessState(\.didCreateZone) {
            logger.log("Zone not created")
            let isNewZone = try await createZone()
            setState(\.didCreateZone, value: true)

            // It holds none of the local models, e.g. on the first device that synchronizes, or after the zone was deleted
            if isNewZone {
                uploadLocalObjects(keysByEntity: (configuration?.entities ?? [:]).mapValues { _ -> [String]? in nil })
            }
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
    
    /// Creates the `CoreData` record zone, if needed, and returns whether it was created.
    func createZone() async throws -> Bool {
        logger.log("Checking for existing zones")
        let zones = try await self.cloudPrivateDatabase.allRecordZones()

        guard !zones.contains(where: { zone -> Bool in
            zone.zoneID.zoneName == defaultZoneID.zoneName
        }) else {
            logger.log("Existing zone found")
            return false
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
        return true
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
