import Foundation
import CoreData
import CloudKit
import OSLog

private let bootstrapFailedError: SDSSyncError = SDSSyncError(title: "ckerror.bootstrapFailed")

extension SDSSynchronizer {
    
    /// Synchronizes now, e.g. when the user asks for it. Uploads that paused as iCloud was full are tried again, e.g. after
    /// the user freed up storage, see `QuotaExceededError`.
    public func forceDownload() {
        lastCompletedDownload = nil
        resumeUploads()
        startSync()
    }
    
    /// Like `forceDownload()`, and returns once the synchronization is done.
    public func forceDownloadSync() async {
        lastCompletedDownload = nil
        resumeUploads()
        await synchronize()
    }
    
    func forceUpload() {
        lastCompletedUpload = nil
        startSync()
    }
    
    /// Synchronizes now, e.g. when the user asks for it, also if uploads paused as iCloud was full, see `QuotaExceededError`.
    func forceSyncEverything() {
        lastCompletedUpload = nil
        lastCompletedDownload = nil
        resumeUploads()
        startSync()
    }
    
    /// Checks the account once, and again after it changed, see `accountChanged(_:)`.
    private func checkLoggedIntoIcloud() async throws {
        if accountNeedsCheck {
            // An account change while checking isn't taken for checked
            let accountChangeCount = self.accountChangeCount
            let accountStatus: CKAccountStatus
            do {
                accountStatus = try await cloud.accountStatus()
            } catch {
                logger.log("No Account Status: \(error.localizedDescription)")
                throw AccountUnavailableError(isTemporary: true)
            }
            
            switch accountStatus {
            case .available:
                break
            case .temporarilyUnavailable, .couldNotDetermine:
                // E.g. until the user enters their password again. Nothing is reset, and `CKAccountChanged` might not be posted.
                logger.log("Account Status is temporarily not `available`: \(accountStatus.rawValue, privacy: .public)")
                throw AccountUnavailableError(isTemporary: true)
            default:
                logger.log("Account Status is not `available`: \(accountStatus.rawValue, privacy: .public)")
                throw AccountUnavailableError(isTemporary: false)
            }
            
            let userRecordID: CKRecord.ID
            do {
                userRecordID = try await cloud.userRecordID()
            } catch {
                logger.log("No user record id: \(error.localizedDescription)")
                throw AccountUnavailableError(isTemporary: true)
            }
            
            // The synchronization data of another account doesn't apply to this one
            let isOtherAccount = accessState(\.userId).map { $0 != userRecordID } ?? false
            if isOtherAccount {
                logger.log("The iCloud account changed, starting over with the new account")
                try resetForNewAccount()
            }

            logger.log("Logged in to iCloud")
            setState(\.userId, value: userRecordID)
            try context.performAndWait {
                try context.save()
            }
            
            confirmAccount(ifUnchangedSince: accountChangeCount)
            await viewModel.set(loggedIntoiCloud: true)
        }
    }
    
    /// Thrown when there's no iCloud account to synchronize with. A temporary state, e.g. while the user has to enter their
    /// password again, or an error checking it, is checked again later, as iCloud doesn't always tell when it's over.
    struct AccountUnavailableError: Error {
        let isTemporary: Bool
    }

    /// Forgets the shares, zones, change tokens and pending changes of the previous account, so the new account is
    /// synchronized from scratch, and every local model is uploaded to it like a backfilled one, see `backfill(onlyUntracked:)`.
    ///
    /// Local copies of other users' shares are removed, as they were shared with the previous account. Other local models stay,
    /// and keep their record names: a model the new account has a record of, e.g. because the user switches back to an
    /// account the device synchronized before, gets the record's values instead of becoming a duplicate.
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
        
        // Nothing of this device is in the new account yet. Its data isn't overwritten, see `backfill(onlyUntracked:)`.
        // Written first, so it's also done if the app is terminated before the reset is saved.
        updateFileState { state in
            state = FileState()
            state.needsFullBackfill = true
        }
        heldRecords(sharedDatabase: false).removeAll()
        heldRecords(sharedDatabase: true).removeAll()

        try context.performAndWaitUnchecked {
            // Changes of the previous account aren't uploaded over the new account's data, but every model is uploaded
            // to it once the account is checked
            for entityName in ["CloudKitUpdate", "CloudKitRemoval", "CloudKitShare", "CloudKitZone"] {
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
        forgetServerRecordsOfConflicts()
        resumeUploads()
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

        // Every local model is uploaded again, also if another device creates the zone first, which this one then finds.
        // Records that downloads held belonged to the zone that's gone.
        updateFileState { $0.needsFullBackfill = true }
        heldRecords(sharedDatabase: false).removeAll()

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
        if let networkMonitor, networkMonitor.currentPath.status != .satisfied {
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
        // Only one synchronization runs at a time. One requested meanwhile follows the running one.
        guard claimSynchronization() else { return }
        await _synchronize()
        endActivity()
    }

    private func _synchronize() async {
        do {
            guard await viewModel.attemptSyncStart() else {
                // E.g. while CloudKit asks to wait after an error, a retry has to be scheduled, as a pending one might have been used up
                await setRoutineTimer()
                return
            }
            
            countStartedSynchronization()
            beginSynchronizationWithCurrentAccount()
            guard syncLease.acquire() else { throw SDSSyncLease.UnavailableError() }
            defer { syncLease.release() }
            
            // E.g. while the device is locked, data protection can keep the stores from being read.
            // Data that can't be read mustn't be taken for missing data, so nothing is synchronized then.
            try checkStoresAreReadable()
            
            refreshSharedData()
            writeFileStateIfNeeded()
            
            await updateUpdatesToSend()
            
            try checkNetwork()
            
            try await checkLoggedIntoIcloud()
            
            try await bootstrap()
            try checkNotStopped()
            
            // Objects that were saved without the synchronizer, or every object once the zone or account is new, are queued
            // before the download, which then knows that their values mustn't overwrite what's in iCloud
            try backfillIfNeeded()
            await updateUpdatesToSend()

            // Pending changes for shares that are gone would fail the upload, so they are cleaned up first.
            // This is best effort: a failure here shouldn't keep the private database from uploading. The download retries it.
            var didRefreshSharedZones = false
            do {
                try await refreshSharedZoneIDs()
                didRefreshSharedZones = true
            } catch {
                logger.log("Failed to refresh shared zones: \(error.localizedDescription)")
            }
            
            // Downloading first means local changes are uploaded over the newest values, rather than colliding with records
            // whose values aren't known yet: backfilled values only fill what records lack (see `backfill(onlyUntracked:)`),
            // and an edit of a record that another device deleted is discarded with the deletion, rather than uploaded as a
            // partial record. Local changes that weren't uploaded yet still win over downloaded values.
            await set(state: .downloading)
            var downloadError: (any Error)?
            var sharedDownloadError: (any Error)?
            do {
                sharedDownloadError = try await download(refreshingSharedZones: !didRefreshSharedZones)
            } catch let error where Self.allowsUploading(after: error) {
                // A download that keeps failing mustn't keep the changes from being uploaded. Edits are only uploaded for
                // records that still exist, as one that was deleted elsewhere would be created again as a partial record.
                logger.error("Failed to download, uploading anyway: \(error.localizedDescription)")
                downloadError = error
            }
            try checkNotStopped()

            await set(state: .uploading)
            let upload = try await upload(
                includingSharedDatabase: downloadError == nil && sharedDownloadError == nil,
                checkingRecordsExist: downloadError != nil
            )
            try checkNotStopped()
            if let error = downloadError ?? sharedDownloadError {
                throw error
            }

            if let pauseEnd = upload.privateQuotaPauseEnd {
                // Uploads pause while iCloud is full, but downloads go on
                await set(state: .error(Self.quotaExceededError))
                await setRoutineTimer(interval: max(1, pauseEnd.timeIntervalSinceNow))
                await synchronizeAgainIfRequested()
                return
            }
            if let pauseEnd = upload.sharedQuotaPauseEnd {
                // The storage of the owner of a share is full, which doesn't keep the user's own data from being uploaded
                await set(state: .error(SDSSyncError(title: "error.uploadIncomplete")))
                await setRoutineTimer(interval: max(1, pauseEnd.timeIntervalSinceNow))
                await synchronizeAgainIfRequested()
                return
            }
            if upload.rejectedCount > 0 {
                // They're uploaded once they change, or after a while, see `SDSRecordQuarantine`
                await set(state: .error(SDSSyncError(title: "error.uploadIncomplete", underlyingError: lastRecordFailure)))
                await setRoutineTimer(interval: SDSRecordQuarantine.duration)
                await synchronizeAgainIfRequested()
                return
            }
            await set(state: .idle)
        }
        catch is ChangesStillPendingError {
            // Not an error: the changes are uploaded later, once the app stops changing the records
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
            // `.stopped`, unless `start()` was called meanwhile
            await set(state: .idle)
            return
        }
        catch is AccountChangedError {
            // The account change requested another synchronization, which checks the account
            logger.log("The iCloud account changed while synchronizing")
            await set(state: .idle)
            await synchronizeAgainIfRequested()
            return
        }
        catch let error as PrivateZoneMissingError {
            await handlePrivateZoneMissing(error)
            return
        }
        catch let error as AccountUnavailableError {
            accountNeedsCheck = true
            await viewModel.set(loggedIntoiCloud: false)
            await set(state: .notLoggedIntoIcloud)
            if error.isTemporary {
                await setRoutineTimer(onlyAfterError: false)
            }
            await synchronizeAgainIfRequested()
            return
        }
        catch let error where Self.isNotAuthenticated(error) {
            // E.g. signed out of iCloud. The account is checked again with the next synchronization, see `accountChanged(_:)`.
            logger.log("Not logged in to iCloud anymore: \(error)")
            accountNeedsCheck = true
            await viewModel.set(loggedIntoiCloud: false)
            await set(state: .notLoggedIntoIcloud)
            await synchronizeAgainIfRequested()
            return
        }
        catch {
            await set(state: (error as? SDSStateError)?.state ?? .error(error))
        }

        await self.setRoutineTimer()
        await synchronizeAgainIfRequested()
    }
    
    /// Thrown when the iCloud storage of a database is full: the user's, or for the shared database the share owner's.
    /// Uploads to it pause for a while, or until `start()` or a synchronization the user asks for, so they aren't retried
    /// over and over. Downloads go on.
    struct QuotaExceededError: Error {
        let sharedDatabase: Bool
    }
    
    /// Whether the changes are uploaded although the download failed: not if the account, the zone or the process changed,
    /// or CloudKit asks to wait.
    static func allowsUploading(after error: Error) -> Bool {
        switch error {
        case is StoppedError, is AccountChangedError, is PrivateZoneMissingError, is SDSSyncLease.UnavailableError, is AccountUnavailableError:
            return false
        default:
            return !isNotAuthenticated(error) && (errorWithLongestRetryDelay(in: error) as? CKError)?.retryAfterSeconds == nil
        }
    }
    
    /// The state's error while iCloud is full: CloudKit's, so apps can tell it by its code, with a description to show.
    static var quotaExceededError: CKError {
        CKError(.quotaExceeded, userInfo: [NSLocalizedDescriptionKey: SDSSyncError.localized("error.quotaExceeded")])
    }
    
    /// Whether an error, or the error of one of its items, says that the user isn't signed into iCloud anymore.
    static func isNotAuthenticated(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .notAuthenticated { return true }
        guard error.code == .partialFailure else { return false }
        return (error.partialErrorsByItemID ?? [:]).values.contains { ($0 as? CKError)?.code == .notAuthenticated }
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
        loadFileState()
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
                minInterval = self.timing.routineRetryInterval ?? generalLoadMultiplier(networkMonitor: self.networkMonitor) * 60
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
            // The zone might hold none of the local models, e.g. on the first device that synchronizes, after the zone was
            // deleted, or after another device created it again. They're backfilled, so they don't overwrite what another
            // device uploaded. Written before the zone is created, so it's also done if the app is terminated meanwhile.
            updateFileState { $0.needsFullBackfill = true }
            _ = try await createZone()
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
            await cloud.registerForRemoteNotifications()
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
