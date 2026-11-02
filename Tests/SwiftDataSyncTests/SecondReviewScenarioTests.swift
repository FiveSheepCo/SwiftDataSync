import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// Blocks the thread forever, like a process that is terminated at this point.
private func hangForever() {
    DispatchSemaphore(value: 0).wait()
}

/// Subscriptions without an identity, like records that were uploaded before the identity was configured.
private let configurationWithoutIdentity = SDSConfiguration(swiftDataEntities: [
    .init(entity: ScenarioSubscription.self, description: .sync(.without([]))),
    .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
    .init(entity: ScenarioNote.self, description: .sync(.without([]))),
    .init(entity: ScenarioWorkspace.self, description: .sync(.without([]), isSharable: true)),
    .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
])

private func noteRecords(_ range: ClosedRange<Int>) -> [CKRecord] {
    range.map { index in
        let record = CKRecord(recordType: "ScenarioNote", recordID: CKRecord.ID(recordName: "note-\(index)", zoneID: .scenario))
        record["text"] = "Note \(index)"
        return record
    }
}

/// The scenarios of a second independent review.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct SecondReviewScenarioTests {

    // MARK: 1. Edits While Uploading

    /// The player saves a new position while the upload of the previous one is in flight. The new position is uploaded.
    /// Saves over existing records succeed, so no retry reads the newer value by chance.
    @Test func editWhileUploadingIsUploaded() async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        server.beforeModifyRecords = { [server, device] name, names in
            guard name == "A", names.contains(subscriptionRecordName("s1")) else { return }
            server.beforeModifyRecords = nil
            try? device.editSubscription("s1") { $0.position = 2 }
        }
        try device.editSubscription("s1") { $0.position = 1 }
        await device.settle()
        await device.sync()

        #expect(device.serverSubscriptions().first?.position == 2)
        #expect(try device.subscription("s1")?.position == 2)
        device.terminate()
    }

    // MARK: 2. Models Created Again While Downloading

    /// The deletion of an unsubscribed podcast is downloaded after the user subscribed again during the download.
    @Test func modelCreatedAgainBeforeItsDeletionIsDownloaded() async throws {
        let server = FakeCloudServer()
        server.pageSize = 100
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        // Another device uploads notes between this device's download and its upload of the deletion, so the next
        // download gets them first
        server.beforeModifyRecords = { [server] name, names in
            guard name == "A", names.isEmpty else { return }
            server.beforeModifyRecords = nil
            server.seed(noteRecords(1...150), account: "first")
        }
        try device.deleteSubscription("s1")
        await device.settle()

        server.pageDelivered = { [server, device] name, pages in
            guard name == "A", pages == 1 else { return }
            server.pageDelivered = nil
            try? device.insertSubscriptions(["s1"], title: { _ in "Again" })
        }
        await device.sync()
        await device.settle()
        await device.sync()

        #expect(try device.subscriptions().map(\.title) == ["Again"])
        #expect(device.serverSubscriptions().map(\.title) == ["Again"])
        device.terminate()
    }

    /// The user subscribes again after the deletion was downloaded, but before the download was saved.
    @Test func modelCreatedAgainAfterItsDeletionIsDownloaded() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()
        try device.deleteSubscription("s1")
        await device.settle()

        let isDone = OSAllocatedUnfairLock(initialState: false)
        device.synchronizer.afterSavingDownloadedObjects = { [device] in
            guard isDone.withLock({ done in defer { done = true }; return !done }) else { return }
            try? device.insertSubscriptions(["s1"], title: { _ in "Again" })
        }
        await device.sync()
        await device.settle()
        await device.sync()

        #expect(try device.subscriptions().map(\.title) == ["Again"])
        #expect(device.serverSubscriptions().map(\.title) == ["Again"])
        device.terminate()
    }

    // MARK: 3. Killed Within a Page's Save

    /// The app is killed while a page with new and deleted records is saved. The next launch continues the download where it
    /// was, rather than downloading everything again.
    @Test(arguments: [false, true])
    func killWithinAPageSave(afterTheObjects: Bool) async throws {
        let server = FakeCloudServer()
        server.pageSize = 100
        server.seed(noteRecords(1...300), account: "first")
        let device = TestDevice("B", server: server)
        try await device.launch()
        #expect(try device.notes().count == 300)

        // Another device deletes some notes and adds others
        server.delete((1...50).map { "note-\($0)" }, account: "first")
        server.seed(noteRecords(301...450), account: "first")
        let isHanging = OSAllocatedUnfairLock(initialState: false)
        let hang: @Sendable () -> Void = {
            isHanging.withLock { $0 = true }
            hangForever()
        }
        if afterTheObjects {
            device.synchronizer.afterSavingDownloadedObjects = hang
        } else {
            device.synchronizer.afterSavingDownloadedRecords = hang
        }
        Task { [device] in await device.synchronizer.synchronize() }
        #expect(await waitUntil { isHanging.withLock { $0 } })
        try await Task.sleep(for: .milliseconds(200))
        device.terminate()

        let fetches = server.events(of: "B", .fetchChanges).count
        try await device.launch()
        await device.sync()
        let resumed = try #require(server.events(of: "B", .fetchChanges).dropFirst(fetches).first)
        #expect((resumed.tokenSequence ?? 0) > 0, "Every change token was reset")
        #expect(!device.synchronizer.isRecoveringVanishedObjects)
        #expect(try device.notes().count == 400)
        #expect(device.serverNotes().count == 400)
        device.terminate()
    }

    // MARK: 4, 5. Accounts

    /// The account was switched while the app wasn't running. Until it's checked, the data isn't taken for downloaded.
    @Test func accountSwitchedWhileNotRunning() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        #expect(device.synchronizer.hasDownloadedOnce)
        device.terminate()

        device.cloud.account = .signedIn("second")
        try await device.launch(waitForSync: false, stopped: true)
        #expect(!device.synchronizer.hasDownloadedOnce)
        device.synchronizer.start()
        await device.settle()
        #expect(device.synchronizer.hasDownloadedOnce)
        device.terminate()
    }

    /// The account changes while it's checked. It's checked again, rather than taken for checked.
    @Test func accountChangedWhileItIsChecked() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        device.cloud.onUserRecordID = { [device] in
            device.cloud.onUserRecordID = nil
            device.switchAccount(to: .signedIn("second"))
        }
        device.switchAccount(to: .signedIn("first"))
        await device.sync()
        await device.sync()
        // The synchronization the change requested checked the new account
        #expect(device.synchronizer.accessState(\.userId)?.recordName == "_user_second")
        #expect(device.serverSubscriptions(account: "second").map(\.feedLink) == ["s1"])
        device.terminate()
    }

    // MARK: 6, 7. Held Records

    /// A newer version of a held record arrives while it's still held. Once it can be stored, the newer version is.
    @Test func newerVersionOfAHeldRecordIsKept() async throws {
        let server = FakeCloudServer()
        let missing = CKRecord.ID(recordName: UUID().uuidString, zoneID: .scenario)
        let orphan = { (title: String) in
            let record = CKRecord(recordType: "ScenarioDocument", recordID: CKRecord.ID(recordName: documentRecordName("Orphan"), zoneID: .scenario))
            record["title"] = "Orphan"
            record["workspace"] = CKRecord.Reference(recordID: missing, action: .none)
            record.setParent(missing)
            return record
        }
        server.seed([orphan("v1")], account: "first")
        let device = TestDevice("B", server: server)
        try await device.launch()

        // The orphan changes, e.g. its parent, while its workspace is still missing
        let second = orphan("v2")
        let other = CKRecord.ID(recordName: UUID().uuidString, zoneID: .scenario)
        second["workspace"] = CKRecord.Reference(recordID: other, action: .none)
        second.setParent(other)
        server.seed([second], account: "first")
        await device.sync()
        device.terminate()

        let workspace = CKRecord(recordType: "ScenarioWorkspace", recordID: other)
        workspace["title"] = "The newer parent"
        server.seed([workspace], account: "first")
        try await device.launch()
        await device.sync()
        let context = ModelContext(try #require(device.modelContainer))
        let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
        #expect(document.workspace?.title == "The newer parent")
        device.terminate()
    }

    /// A record whose asset file is missing when it's stored doesn't keep the download from being saved, and is downloaded again.
    @Test func recordWithAMissingAssetFileIsDownloadedAgain() async throws {
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        try await first.launch()
        try first.insertSubscriptions(["s1", "s2"])
        try first.editSubscription("s1") { $0.artwork = Data(count: 1_500_000) }
        await first.sync()

        let name = subscriptionRecordName("s1")
        server.breakAssetFiles(where: { $0.recordName == name }, count: 1)
        let second = TestDevice("B", server: server)
        try await second.launch()
        #expect(second.synchronizer.hasDownloadedOnce)
        #expect(try second.subscription("s2") != nil)
        await second.sync()
        #expect(try second.subscription("s1")?.artwork?.count == 1_500_000)
        first.terminate()
        second.terminate()
    }

    // MARK: 10. Moving the Synchronization Data

    /// Moving the synchronization data into the app group moves its side files first, so a move that's interrupted is
    /// continued with the next launch.
    @Test func interruptedMoveIsContinued() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let appURL = directory.appending(path: "App/CloudKitSync.sqlite")
        let groupURL = directory.appending(path: "Group/CloudKitSync.sqlite")
        for url in [appURL, groupURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: SDSSynchronizer.syncDataModel)
        try coordinator.remove(try coordinator.addPersistentStore(type: .sqlite, at: appURL))
        // A move that was interrupted after the state was moved
        try Data("{}".utf8).write(to: groupURL.deletingLastPathComponent().appending(path: "CloudKitSync.state.json"))
        try FileManager.default.createDirectory(at: appURL.deletingLastPathComponent().appending(path: "CloudKitSync.held"), withIntermediateDirectories: true)

        SDSSynchronizer.moveSyncData(from: appURL, to: groupURL, coordinator: NSPersistentStoreCoordinator(managedObjectModel: SDSSynchronizer.syncDataModel))
        #expect(FileManager.default.fileExists(atPath: groupURL.path))
        #expect(FileManager.default.fileExists(atPath: groupURL.deletingLastPathComponent().appending(path: "CloudKitSync.state.json").path))
        #expect(FileManager.default.fileExists(atPath: groupURL.deletingLastPathComponent().appending(path: "CloudKitSync.held").path))
    }

    // MARK: 11. Deletions CloudKit Asks to Wait For

    /// A removal CloudKit throttles waits as long as CloudKit asks, rather than being retried right away as incomplete.
    @Test func throttledRemovalWaits() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        server.failDeleting(where: { _ in true }, with: CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 30.0]), count: 1)
        try device.deleteSubscription("s1")
        await device.settle()
        #expect((await device.state.error as? CKError)?.retryAfterSeconds == 30)
        device.terminate()
    }

    // MARK: 12. Records Taken Over by an Identity

    /// A model whose record was uploaded before its entity had an identity was edited, when the record of its identity
    /// arrives from another device. The edit isn't lost.
    @Test func editIsKeptWhenTheIdentityRecordTakesOver() async throws {
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        try await first.launch(configuration: configurationWithoutIdentity)
        try first.insertSubscriptions(["s1"])
        await first.sync()
        first.terminate()

        try await first.launch(stopped: true)
        try first.editSubscription("s1") { $0.title = "Edited on A" }
        let second = TestDevice("B", server: server)
        try await second.launch()
        try second.insertSubscriptions(["s1"], title: { _ in "From B" })
        await second.sync()

        first.synchronizer.start()
        await first.settle()
        await first.sync()
        let identityRecord = try #require(server.record(named: subscriptionRecordName("s1"), account: "first"))
        #expect(identityRecord["title"] as? String == "Edited on A")
        #expect(try first.subscription("s1")?.title == "Edited on A")
        first.terminate()
        second.terminate()
    }

    // MARK: 13. Synchronizing Now While iCloud Is Full

    /// The app's "Sync Now" uploads again although uploads paused as iCloud was full, e.g. after the user freed up space.
    @Test func forceDownloadResumesUploads() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        server.failNextModify(with: CKError(.quotaExceeded))
        try device.insertSubscriptions(["s1"])
        await device.settle()
        #expect(device.serverSubscriptions().isEmpty)

        device.synchronizer.forceDownload()
        #expect(await waitUntil(timeout: 5) { device.serverSubscriptions().count == 1 })
        device.terminate()
    }
}
