import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

func documentRecordName(_ title: String) -> String {
    SDSIdentity.recordName(entityName: "ScenarioDocument", values: [title])
}

/// Blocks the thread forever, like a process that is terminated at this point.
private func hangForever() {
    DispatchSemaphore(value: 0).wait()
}

/// The scenarios of an independent review of the changes for every state a user can be in.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct ReviewScenarioTests {

    // MARK: 1. Deletions of Models Created Again

    /// The user unsubscribes, which is uploaded, and subscribes again. The next download includes the earlier deletion,
    /// which mustn't delete the new subscription.
    @Test func modelCreatedAgainSurvivesItsOwnDeletion() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()
        // The deletion is uploaded by the synchronization the save starts, after its download
        try device.deleteSubscription("s1")
        await device.settle()
        #expect(device.serverSubscriptions().isEmpty)

        try device.insertSubscriptions(["s1"], title: { _ in "Again" })
        await device.sync()
        await device.sync()
        #expect(try device.subscriptions().map(\.title) == ["Again"])
        #expect(device.serverSubscriptions().map(\.title) == ["Again"])
        device.terminate()
    }

    /// Another device created and deleted a subscription that this device creates before it downloads either.
    @Test func modelCreatedWhileAnotherDeviceDeletesIt() async throws {
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        let second = TestDevice("B", server: server)
        try await first.launch()
        try await second.launch()
        first.synchronizer.stop()

        try second.insertSubscriptions(["s1"], title: { _ in "From B" })
        await second.sync()
        try second.deleteSubscription("s1")
        await second.sync()
        try first.insertSubscriptions(["s1"], title: { _ in "From A" })
        first.synchronizer.start()
        await first.settle()
        await first.sync()

        #expect(try first.subscriptions().map(\.title) == ["From A"])
        #expect(first.serverSubscriptions().map(\.title) == ["From A"])
        first.terminate()
        second.terminate()
    }

    /// Unsubscribing and subscribing again before synchronizing keeps the record of the identity, rather than deleting it
    /// and uploading the subscription under another name.
    @Test func modelDeletedAndCreatedAgainKeepsItsRecord() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        device.synchronizer.stop()
        try device.deleteSubscription("s1")
        try device.insertSubscriptions(["s1"], title: { _ in "Again" })
        device.synchronizer.start()
        await device.settle()
        await device.sync()

        let records = server.records(account: "first")
        #expect(records.map(\.recordID.recordName) == [subscriptionRecordName("s1")])
        #expect(device.serverSubscriptions().map(\.title) == ["Again"])
        device.terminate()
    }

    // MARK: 2. Killed Between Saving Objects and Their Records

    /// The objects of a page are saved, but the app is killed before their records are. The next launch neither uploads
    /// them under new names nor downloads them a second time.
    @Test func killAfterSavingDownloadedObjects() async throws {
        let server = FakeCloudServer()
        server.pageSize = 100
        server.seed((1...300).map { index in
            let record = CKRecord(recordType: "ScenarioNote", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: .scenario))
            record["text"] = "Note \(index)"
            return record
        }, account: "first")

        let device = TestDevice("B", server: server)
        let saves = OSAllocatedUnfairLock(initialState: 0)
        device.beforeSetup = { synchronizer in
            synchronizer.afterSavingDownloadedObjects = {
                let count = saves.withLock { $0 += 1; return $0 }
                if count == 2 { hangForever() }
            }
        }
        try await device.launch(waitForSync: false)
        #expect(await waitUntil { saves.withLock { $0 } >= 2 })
        try await Task.sleep(for: .milliseconds(100))
        device.terminate()

        device.beforeSetup = nil
        try await device.launch()
        await device.sync()
        #expect(try device.notes().count == 300)
        #expect(device.serverNotes().count == 300)
        device.terminate()
    }

    // MARK: 3. Records Made While Looking Up Others

    /// A sharable root and its document were saved while the app didn't observe the store. Looking up the document's zone
    /// mustn't give the root a record without uploading it.
    @Test func rootSavedBeforeSetupIsUploaded() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        device.terminate()
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "Workspace")
            let document = ScenarioDocument(title: "Document")
            context.insert(workspace)
            context.insert(document)
            document.workspace = workspace
        }
        try await device.launch()
        await device.sync()

        let types = server.records(account: "first").map(\.recordType).sorted()
        #expect(types == ["ScenarioDocument", "ScenarioWorkspace"])
        device.terminate()
    }

    /// A model another process saved is referenced by an upload. It's uploaded too, with every value.
    @Test func referencedModelOfAnotherProcessIsUploaded() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { $0.insert(ScenarioDocument(title: "Document")) }
        await device.sync()

        try device.changeInAnotherProcess { $0.insert(ScenarioWorkspace(title: "From an extension")) }
        try device.change { context in
            let workspace = try #require(try context.fetch(FetchDescriptor<ScenarioWorkspace>()).first)
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            document.workspace = workspace
        }
        await device.sync()

        let workspace = server.records(account: "first").first { $0.recordType == "ScenarioWorkspace" }
        #expect(workspace?["title"] as? String == "From an extension")
        device.terminate()
    }

    // MARK: 4. Zones Created Again by Another Device

    /// The zone is gone when this device downloads, and another device creates it again before this one synchronizes again.
    /// What only this device has still reaches iCloud.
    @Test func zoneCreatedAgainByAnotherDevice() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("B", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "only on B"])
        await device.sync()

        server.deleteZone(account: "first", byUser: false)
        server.fetchFailed = { [server] device, error in
            guard device == "B", error.code == .zoneNotFound else { return }
            server.fetchFailed = nil
            // Another device creates the zone again, with what it has
            server.seed([subscriptionRecord("s1", title: "From A")], account: "first")
        }
        await device.sync()
        await device.sync()
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink).sorted() == ["only on B", "s1"])
        device.terminate()
    }

    // MARK: 5. Stopping and Starting While Synchronizing

    /// Stopping and starting while a download runs doesn't run a second synchronization next to it.
    @Test func stopAndStartWhileSynchronizing() async throws {
        let server = FakeCloudServer()
        server.pageSize = 50
        server.seed(feedLinks(1...1000).map { subscriptionRecord($0, title: "Title") }, account: "first")
        server.pageDelivered = { _, _ in usleep(20_000) }
        let device = TestDevice("B", server: server)
        try await device.launch(waitForSync: false)
        #expect(await waitUntil { !server.events(of: "B", .fetchChanges).isEmpty || server.maximumConcurrentOperations(of: "B") > 0 })
        try await Task.sleep(for: .milliseconds(100))

        device.synchronizer.stop()
        device.synchronizer.start()
        try await Task.sleep(for: .milliseconds(50))
        await device.settle()
        server.pageDelivered = nil
        await device.sync()

        #expect(server.maximumConcurrentOperations(of: "B") == 1)
        #expect(try device.count(ScenarioSubscription.self) == 1000)
        device.terminate()
    }

    /// Stopping and starting in quick succession leaves a state that synchronizes.
    @Test func stopAndStartInQuickSuccession() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        for _ in 0..<30 {
            device.synchronizer.stop()
            device.synchronizer.start()
        }
        try await Task.sleep(for: .milliseconds(200))
        await device.settle()

        if case .stopped = await device.state {
            Issue.record("The state is stopped although synchronizing was started")
        }
        try device.insertSubscriptions(["s1"])
        #expect(await waitUntil(timeout: 5) { device.serverSubscriptions().count == 1 })
        device.terminate()
    }

    // MARK: 6. Records That Can't Be Stored

    /// A record that can't be stored, e.g. as its overflow asset is corrupt, doesn't keep the other records from being
    /// downloaded or the device's changes from being uploaded.
    @Test func recordThatCantBeStoredIsSetAside() async throws {
        let server = FakeCloudServer()
        let corrupt = CKRecord(recordType: "ScenarioNote", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: .scenario))
        let assetURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("not a property list".utf8).write(to: assetURL)
        corrupt[SDSOverflow.key] = CKAsset(fileURL: assetURL)
        server.seed([corrupt] + feedLinks(1...3).map { subscriptionRecord($0, title: "Title") }, account: "first")

        let device = TestDevice("A", server: server)
        try device.insertSubscriptions(["only on A"])
        try await device.launch()
        await device.sync()

        #expect(try device.count(ScenarioSubscription.self) == 4)
        #expect(device.serverSubscriptions().count == 4)
        device.terminate()
    }

    // MARK: 7. Records Held Back

    /// A record whose reference is missing, early in a large download, doesn't keep the following pages from being saved.
    @Test func orphanDoesNotKeepPagesFromBeingSaved() async throws {
        let server = FakeCloudServer()
        server.pageSize = 100
        let orphan = CKRecord(recordType: "ScenarioDocument", recordID: CKRecord.ID(recordName: documentRecordName("Orphan"), zoneID: .scenario))
        let missing = CKRecord.ID(recordName: UUID().uuidString, zoneID: .scenario)
        orphan["title"] = "Orphan"
        orphan["workspace"] = CKRecord.Reference(recordID: missing, action: .none)
        orphan.setParent(missing)
        server.seed([orphan] + feedLinks(1...1000).map { subscriptionRecord($0, title: "Title") }, account: "first")

        let device = TestDevice("B", server: server)
        server.hangDownloadAfterPages = 6
        try await device.launch(waitForSync: false)
        #expect(await waitUntil { server.hungDownloads == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try device.count(ScenarioSubscription.self) >= 400)
        device.terminate()

        let fetches = server.events(of: "B", .fetchChanges).count
        try await device.launch()
        #expect((server.events(of: "B", .fetchChanges).dropFirst(fetches).first?.tokenSequence ?? 0) >= 400)
        #expect(try device.count(ScenarioSubscription.self) == 1000)

        // Once its workspace arrives, it's stored
        let workspace = CKRecord(recordType: "ScenarioWorkspace", recordID: missing)
        workspace["title"] = "Late"
        server.seed([workspace], account: "first")
        await device.sync()
        #expect(try device.count(ScenarioDocument.self) == 1)
        device.terminate()
    }

    /// A record that failed to download doesn't keep the following pages from being saved, and is downloaded later.
    @Test func failedRecordDoesNotKeepPagesFromBeingSaved() async throws {
        let server = FakeCloudServer()
        server.pageSize = 100
        let links = feedLinks(1...1000)
        server.seed(links.map { subscriptionRecord($0, title: "Title") }, account: "first")
        let failing = subscriptionRecordName(links[0])
        server.failDownloading(where: { $0.recordName == failing }, with: CKError(.assetFileNotFound), count: 1)

        let device = TestDevice("B", server: server)
        server.hangDownloadAfterPages = 6
        try await device.launch(waitForSync: false)
        #expect(await waitUntil { server.hungDownloads == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try device.count(ScenarioSubscription.self) >= 400)
        device.terminate()

        try await device.launch()
        await device.sync()
        #expect(try device.count(ScenarioSubscription.self) == 1000)
        device.terminate()
    }

    // MARK: 8. Parents of Records That Exist Already

    /// A document saved before setup, whose record another device creates in the meantime with another parent. The
    /// record keeps its parent.
    @Test func backfilledDocumentKeepsTheParentOfTheRecord() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "Local")
            let document = ScenarioDocument(title: "d1")
            context.insert(workspace)
            context.insert(document)
            document.workspace = workspace
        }
        let otherWorkspace = CKRecord.ID(recordName: UUID().uuidString, zoneID: .scenario)
        server.beforeModifyRecords = { [server] _, names in
            guard names.contains(documentRecordName("d1")) else { return }
            server.beforeModifyRecords = nil
            let workspace = CKRecord(recordType: "ScenarioWorkspace", recordID: otherWorkspace)
            workspace["title"] = "From another device"
            let document = CKRecord(recordType: "ScenarioDocument", recordID: CKRecord.ID(recordName: documentRecordName("d1"), zoneID: .scenario))
            document["title"] = "d1"
            document["workspace"] = CKRecord.Reference(recordID: otherWorkspace, action: .none)
            document.setParent(otherWorkspace)
            document[SDSSynchronizer.Constants.parentWorkaroundKey] = CKRecord.Reference(recordID: otherWorkspace, action: .deleteSelf)
            server.seed([workspace, document], account: "first")
        }
        try await device.launch()
        await device.sync()
        await device.sync()

        let document = try #require(server.record(named: documentRecordName("d1"), account: "first"))
        #expect(document.parent?.recordID == otherWorkspace)
        #expect((document["workspace"] as? CKRecord.Reference)?.recordID == otherWorkspace)
        device.terminate()
    }

    // MARK: 9. The State Next to the Synchronization Data

    /// A download that was interrupted, with the state file lost, isn't taken for a complete one.
    @Test func lostStateDoesNotClaimACompleteDownload() async throws {
        let server = FakeCloudServer()
        server.pageSize = 100
        server.seed(feedLinks(1...600).map { subscriptionRecord($0, title: "Title") }, account: "first")
        let device = TestDevice("B", server: server)
        server.hangDownloadAfterPages = 3
        try await device.launch(waitForSync: false)
        #expect(await waitUntil { server.hungDownloads == 1 })
        try await Task.sleep(for: .milliseconds(100))
        device.terminate()

        try FileManager.default.removeItem(at: device.directory.appending(path: "Sync/CloudKitSync.state.json"))
        server.fetchFailure = CKError(.networkFailure)
        try await device.launch()
        #expect(!device.synchronizer.hasDownloadedOnce)
        server.fetchFailure = nil
        await device.sync()
        #expect(device.synchronizer.hasDownloadedOnce)
        device.terminate()
    }

    /// Moving the synchronization data into the app group moves the state that belongs to it.
    @Test func stateMovesWithTheSynchronizationData() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()
        device.terminate()

        let source = device.directory.appending(path: "Sync/CloudKitSync.sqlite")
        let destination = device.directory.appending(path: "Group/CloudKitSync.sqlite")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        SDSSynchronizer.moveSyncData(from: source, to: destination, coordinator: NSPersistentStoreCoordinator(managedObjectModel: SDSSynchronizer.syncDataModel))
        #expect(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appending(path: "CloudKitSync.state.json").path))
    }

    // MARK: 10. Values Cleared Elsewhere

    /// Switching to another account and back doesn't bring back a value another device cleared meanwhile.
    @Test func switchingBackDoesNotRestoreClearedValues() async throws {
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        let second = TestDevice("B", server: server)
        try await first.launch()
        try first.insertSubscriptions(["s1"])
        try first.editSubscription("s1") { $0.note = "Old note" }
        await first.sync()
        try await second.launch()

        first.switchAccount(to: .signedIn("second"))
        await first.sync()
        try second.editSubscription("s1") { $0.note = nil }
        await second.sync()
        #expect(second.serverSubscriptions().first?.note == nil)

        first.switchAccount(to: .signedIn("first"))
        await first.sync()
        await first.sync()
        #expect(first.serverSubscriptions(account: "first").first?.note == nil)
        #expect(try first.subscription("s1")?.note == nil)
        first.terminate()
        second.terminate()
    }

    // MARK: 11. Concurrent Edits of Records With an Overflow Asset

    /// A device edits one text of a record with an overflow asset while another device edits another text.
    @Test func overflowRecordKeepsConcurrentEditsOfOtherKeys() async throws {
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        let second = TestDevice("B", server: server)
        try await first.launch()
        try first.insertSubscriptions(["s1"])
        try first.editSubscription("s1") {
            $0.artwork = Data(count: 1_500_000)
            $0.note = "Note"
        }
        await first.sync()
        try await second.launch()

        // B uploads its note right after A downloaded
        server.beforeModifyRecords = { [server] device, names in
            guard device == "A", names.contains(subscriptionRecordName("s1")) else { return }
            server.beforeModifyRecords = nil
            let record = try! #require(server.record(named: subscriptionRecordName("s1"), account: "first"))
            let copy = CKRecord(recordType: record.recordType, recordID: record.recordID)
            for key in record.allKeys() where !(record[key] is CKAsset) {
                copy[key] = record[key]
            }
            copy["note"] = "B's note"
            copy[SDSOverflow.key] = record[SDSOverflow.key]
            server.seed([copy], account: "first")
        }
        try first.editSubscription("s1") { $0.title = "A's title" }
        await first.sync()

        let values = try #require(first.serverSubscriptions().first)
        #expect(values.title == "A's title")
        #expect(values.note == "B's note")
        first.terminate()
        second.terminate()
    }

    // MARK: 12. Stores Whose Objects Get New URIs

    /// A store rebuilt with the same data, whose objects have new URIs, doesn't duplicate them locally or in iCloud.
    @Test func rebuiltStoreIsNotDuplicated() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        try device.change { context in
            for index in 1...5 { context.insert(ScenarioNote(text: "Note \(index)")) }
        }
        await device.sync()
        device.terminate()

        let notes = try device.notes()
        let subscriptions = try device.subscriptions()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: device.storeURL.path + suffix))
        }
        try device.change { context in
            for note in notes { context.insert(ScenarioNote(text: note)) }
            for subscription in subscriptions { context.insert(ScenarioSubscription(feedLink: subscription.feedLink, title: subscription.title, position: subscription.position)) }
        }

        try await device.launch()
        await device.sync()
        await device.sync()
        #expect(try device.notes() == notes)
        #expect(device.serverNotes() == notes)
        #expect(device.serverSubscriptions().count == 2)
        device.terminate()
    }

    // MARK: 14. Account Changes Right Before a Synchronization

    /// A synchronization that starts right after the account changed checks it, rather than uploading the previous
    /// account's changes to the new one.
    @Test func synchronizationRightAfterAnAccountChange() async throws {
        let server = FakeCloudServer()
        server.seed([subscriptionRecord("s1", title: "Second's title")], account: "second")
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        device.synchronizer.stop()
        try device.editSubscription("s1") { $0.title = "First's edit" }
        device.synchronizer.start()
        #expect(device.synchronizer.hasDownloadedOnce)
        device.switchAccount(to: .signedIn("second"))
        // Noted right away, not in a task that a synchronization could start before
        #expect(device.synchronizer.accountNeedsCheck)
        #expect(!device.synchronizer.hasDownloadedOnce)
        await device.synchronizer.synchronize()
        await device.settle()
        await device.sync()

        #expect(device.serverSubscriptions(account: "second").first?.title == "Second's title")
        device.terminate()
    }

    // MARK: Found While Fixing

    /// The zone is deleted on another device between this device's download and its upload. CloudKit reports that for
    /// each record only, while the operation succeeds: the zone is created again, with every local model.
    @Test func zoneDeletedBetweenDownloadAndUpload() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        server.beforeModifyRecords = { [server] _, names in
            guard !names.isEmpty else { return }
            server.beforeModifyRecords = nil
            server.deleteZone(account: "first", byUser: false)
        }
        // Without another synchronization, e.g. a push or a save
        try device.editSubscription("s1") { $0.title = "Edited" }
        #expect(await waitUntil(timeout: 5) { device.serverSubscriptions().map(\.title) == ["Edited", "Title of s2"] })
        await device.settle()
        #expect(await device.state.error == nil)
        device.terminate()
    }

    // MARK: Minor

    /// A document saved before setup is linked to a new workspace. The workspace is uploaded before the document that
    /// references it as its parent.
    @Test func backfilledChildAfterItsNewParent() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try device.change { $0.insert(ScenarioDocument(title: "d1")) }
        try await device.launch(stopped: true)
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "New")
            context.insert(workspace)
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            document.workspace = workspace
        }
        await device.settle()
        device.synchronizer.start()
        await device.settle()
        await device.sync()

        let document = try #require(server.record(named: documentRecordName("d1"), account: "first"))
        #expect(document.parent != nil)
        #expect(await device.state.error == nil)
        device.terminate()
    }

    /// A download that fails for zones CloudKit asks to wait for, waits.
    @Test func partiallyFailedDownloadWaits() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        server.zoneFetchFailure = CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 30.0])
        await device.sync()
        #expect((await device.state.error as? CKError)?.retryAfterSeconds == 30)
        #expect(await device.sync() == false)
        device.terminate()
    }

    /// Starting while not stopped doesn't end the pause after iCloud was full.
    @Test func startWhileRunningKeepsTheQuotaPause() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        server.failNextModify(with: CKError(.quotaExceeded))
        try device.insertSubscriptions(["s1"])
        await device.settle()
        let saves = server.events(of: "A", .modifyRecords).count

        device.synchronizer.start()
        await device.sync()
        #expect(server.events(of: "A", .modifyRecords).count == saves)
        device.terminate()
    }
}
