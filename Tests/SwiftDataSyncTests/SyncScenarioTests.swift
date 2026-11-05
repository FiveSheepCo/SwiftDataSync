import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
@testable import SwiftDataSync

/// Waits until `condition` holds, for at most `timeout` seconds.
func waitUntil(timeout: TimeInterval = 20, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let end = Date.now.addingTimeInterval(timeout)
    while Date.now < end {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try await condition()
}

func feedLinks(_ range: ClosedRange<Int>) -> [String] {
    range.map { "https://example.com/feed/\($0)" }
}

extension SDSSynchronizationViewModel.State {
    var error: (any Error)? {
        if case .error(let error) = self { error } else { nil }
    }

    var isNotLoggedIn: Bool {
        if case .notLoggedIntoIcloud = self { true } else { false }
    }
}

/// Users in every state they can be in, with devices that synchronize with a fake CloudKit server through the real upload
/// and download code: turning sync on with a lot of data, merging with data in iCloud, restoring on a new device,
/// stopping, editing on several devices, switching accounts, losing zones and stores, large values and CloudKit's limits.
///
/// The devices share the files of assets with the rest of the process, so the scenarios run one by one.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct SyncScenarioTests {

    // MARK: Turning Sync On

    /// A user with a lot of data turns sync on, and iCloud has none of it. Once with a zone another device created, which
    /// doesn't upload what this device saved before it synchronized, and once without one.
    @Test(arguments: [false, true])
    func firstSyncUploadsEverything(zoneExists: Bool) async throws {
        let server = FakeCloudServer()
        if zoneExists {
            server.createZone(account: "first")
        }
        let device = TestDevice("A", server: server)
        let links = feedLinks(1...3000)
        try device.insertSubscriptions(links)
        try device.change { context in
            for index in 1...300 { context.insert(ScenarioNote(text: "Note \(index)")) }
        }

        let start = Date.now
        try await device.launch()
        await device.sync()
        let duration = Date.now.timeIntervalSince(start)

        #expect(device.serverSubscriptions().map(\.feedLink) == links.sorted())
        #expect(device.serverSubscriptions() == (try device.subscriptions()))
        #expect(device.serverNotes().count == 300)
        // Not every pending change once more for each operation of 400 records
        #expect(duration < 30, "The first synchronization took \(duration) seconds")
        #expect(server.events(of: "A", .modifyRecords).count <= 3300 / 400 + 3)
        #expect(device.synchronizer.hasDownloadedOnce)
        device.terminate()
    }

    /// 5 subscriptions in iCloud and 8 on the device, 3 of them for the same feeds with other values, plus models without an
    /// identity on both sides. Values of unknown age don't overwrite iCloud's: its records win completely.
    @Test func mergesTheCloudWithTheDevice() async throws {
        let server = FakeCloudServer()
        let cloudNote = CKRecord(recordType: "ScenarioNote", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: .scenario))
        cloudNote["text"] = "Cloud note"
        server.seed(feedLinks(1...5).map { subscriptionRecord($0, title: "Cloud \($0)") } + [cloudNote], account: "first")

        let device = TestDevice("A", server: server)
        try device.insertSubscriptions(feedLinks(3...10), title: { "Device \($0)" })
        let third = feedLinks(3...3)[0]
        try device.editSubscription(third) { $0.note = "Only on the device" }
        try device.change { $0.insert(ScenarioNote(text: "Device note")) }

        try await device.launch()
        await device.sync()

        let expected = feedLinks(1...10).map { link in
            feedLinks(1...5).contains(link) ? "Cloud \(link)" : "Device \(link)"
        }
        #expect(device.serverSubscriptions().map(\.feedLink) == feedLinks(1...10).sorted())
        #expect(device.serverSubscriptions().map(\.title) == zip(feedLinks(1...10), expected).sorted { $0.0 < $1.0 }.map(\.1))
        // Also over values the record lacks, which another device could have cleared
        #expect(device.serverSubscriptions().first { $0.feedLink == third }?.note == nil)
        #expect(device.serverNotes() == ["Cloud note", "Device note"])
        #expect(try device.subscriptions() == device.serverSubscriptions())
        #expect(try device.notes() == ["Cloud note", "Device note"])

        let other = TestDevice("B", server: server)
        try await other.launch()
        #expect(try other.subscriptions() == device.serverSubscriptions())
        #expect(try other.notes() == ["Cloud note", "Device note"])
        device.terminate()
        other.terminate()
    }

    /// Objects saved while the synchronizer didn't observe the store, e.g. by a process without it, are uploaded.
    @Test func changesSavedBeforeSetupAreUploaded() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()
        device.terminate()

        try device.insertSubscriptions(["s2"])
        try device.change { $0.insert(ScenarioNote(text: "Saved before setup")) }
        try await device.launch()
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])
        #expect(device.serverNotes() == ["Saved before setup"])
        device.terminate()
    }

    /// An object saved before setup and edited before the first synchronization: only the edited key wins over iCloud.
    @Test func editOfAnObjectSavedBeforeSetup() async throws {
        let server = FakeCloudServer()
        server.seed([subscriptionRecord("s1", title: "Cloud title", position: 1)], account: "first")
        let device = TestDevice("A", server: server)
        try device.insertSubscriptions(["s1"], title: { _ in "Device title" })

        try await device.launch(stopped: true)
        try device.editSubscription("s1") { $0.position = 7 }
        await device.settle()
        device.synchronizer.start()
        #expect(await waitUntil { device.serverSubscriptions().first?.position == 7 })
        await device.settle()

        #expect(device.serverSubscriptions().first?.title == "Cloud title")
        #expect(try device.subscriptions() == device.serverSubscriptions())
        device.terminate()
    }

    // MARK: New Devices

    /// A new device restores thousands of records over many pages. It's killed halfway, and the next launch continues where
    /// the download was, rather than starting over.
    @Test func newDeviceContinuesAKilledDownload() async throws {
        let server = FakeCloudServer()
        server.pageSize = 100
        let links = feedLinks(1...2400)
        server.seed(links.map { subscriptionRecord($0, title: "Title \($0)") }, account: "first")

        let device = TestDevice("B", server: server)
        server.hangDownloadAfterPages = 10
        try await device.launch(waitForSync: false)
        #expect(await waitUntil { server.hungDownloads == 1 })
        // The pages are saved, not kept in memory until the end
        try await Task.sleep(for: .milliseconds(100))
        #expect(try device.count(ScenarioSubscription.self) >= 900)
        let observedContext = try #require(device.synchronizer.observedUpdateContext)
        let unsaved = observedContext.performAndWait {
            observedContext.insertedObjects.count + observedContext.updatedObjects.count
        }
        #expect(unsaved <= server.pageSize)
        #expect(!device.synchronizer.hasDownloadedOnce)

        device.terminate()
        let fetchesBefore = server.events(of: "B", .fetchChanges).count
        try await device.launch()

        let resumed = try #require(server.events(of: "B", .fetchChanges).dropFirst(fetchesBefore).first)
        #expect((resumed.tokenSequence ?? 0) >= 900, "The download started over")
        #expect(try device.subscriptions().map(\.feedLink) == links.sorted())
        #expect(device.synchronizer.hasDownloadedOnce)
        // From any thread
        #expect(await MainActor.run { device.synchronizer.hasDownloadedOnce })
        device.terminate()
    }

    // MARK: Stopping

    /// Changes made while stopped are recorded without contacting iCloud, and uploaded once started again.
    @Test func changesWhileStoppedAreUploadedOnceStarted() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        device.synchronizer.stop()
        let eventCount = server.events.count
        try device.editSubscription("s1") { $0.title = "Edited while stopped" }
        try await Task.sleep(for: .milliseconds(300))
        await device.synchronizer.forceDownloadSync()
        await device.synchronizer.didReceiveRemoteNotification(userInfo: [:])
        #expect(server.events.count == eventCount)
        #expect(device.serverSubscriptions().first?.title == "Title of s1")
        guard case .stopped = await device.state else {
            Issue.record("Expected the stopped state, got \(await device.state)")
            return
        }

        device.synchronizer.start()
        #expect(await waitUntil { device.serverSubscriptions().first?.title == "Edited while stopped" })
        await device.settle()
        guard case .idle = await device.state else {
            Issue.record("Expected the idle state, got \(await device.state)")
            return
        }
        device.terminate()
    }

    // MARK: Several Devices

    /// Editing a record another device deleted doesn't bring back a partial record.
    @Test func editOfARecordDeletedElsewhereIsDiscarded() async throws {
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        let second = TestDevice("B", server: server)
        try await first.launch()
        try await second.launch()
        try first.insertSubscriptions(["s1", "s2"])
        await first.sync()
        await second.sync()
        #expect(try second.subscriptions().count == 2)

        try second.deleteSubscription("s1")
        await second.sync()
        try first.editSubscription("s1") { $0.title = "Edited on A" }
        await first.sync()
        await second.sync()

        #expect(first.serverSubscriptions().map(\.feedLink) == ["s2"])
        #expect(try first.subscriptions().map(\.feedLink) == ["s2"])
        #expect(try second.subscriptions().map(\.feedLink) == ["s2"])
        first.terminate()
        second.terminate()
    }

    /// Both devices create the same subscription before either synchronized: it becomes one record, the same on both.
    @Test(arguments: [true, false])
    func sameIdentityOnTwoDevicesBecomesOneRecord(freshRecordsConflict: Bool) async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = freshRecordsConflict
        let first = TestDevice("A", server: server)
        let second = TestDevice("B", server: server)
        try await first.launch()
        try await second.launch()

        // B only synchronizes once A uploaded, so the last upload is B's
        second.synchronizer.stop()
        try first.insertSubscriptions(["s1"], title: { _ in "From A" })
        try second.insertSubscriptions(["s1"], title: { _ in "From B" })
        try second.editSubscription("s1") { $0.note = "Note from B" }
        await first.sync()
        second.synchronizer.start()
        await second.settle()
        await second.sync()
        await first.sync()

        #expect(server.records(account: "first").count == 1)
        #expect(try first.subscriptions() == first.serverSubscriptions())
        #expect(try second.subscriptions() == first.serverSubscriptions())
        #expect(try first.subscriptions().first?.title == "From B")
        first.terminate()
        second.terminate()
    }

    /// Two devices edit different keys of the same model, and both edits stay.
    @Test(arguments: [true, false])
    func concurrentEditsOfDifferentKeysMerge(freshRecordsConflict: Bool) async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = freshRecordsConflict
        let first = TestDevice("A", server: server)
        let second = TestDevice("B", server: server)
        try await first.launch()
        try first.insertSubscriptions(["s1"])
        await first.sync()
        try await second.launch()

        try first.editSubscription("s1") { $0.title = "New title" }
        try second.editSubscription("s1") { $0.position = 42 }
        await first.sync()
        await second.sync()
        await first.sync()

        for values in [try first.subscriptions(), try second.subscriptions(), first.serverSubscriptions()] {
            #expect(values.first?.title == "New title")
            #expect(values.first?.position == 42)
        }
        first.terminate()
        second.terminate()
    }

    // MARK: Accounts

    /// Signing out and into the same account keeps the changes made meanwhile, and only uploads those.
    @Test func signingOutAndInKeepsPendingChanges() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2", "s3"])
        await device.sync()

        device.switchAccount(to: .noAccount)
        await device.sync()
        #expect(await device.state.isNotLoggedIn)
        try device.editSubscription("s1") { $0.title = "Edited while signed out" }
        await device.sync()
        let saves = server.events(of: "A", .modifyRecords).count

        device.switchAccount(to: .signedIn("first"))
        await device.sync()
        #expect(device.serverSubscriptions().first?.title == "Edited while signed out")
        let uploaded = server.events(of: "A", .modifyRecords).dropFirst(saves).flatMap(\.savedKeys.keys)
        #expect(uploaded == [subscriptionRecordName("s1")])
        #expect(device.synchronizer.hasDownloadedOnce)
        device.terminate()
    }

    /// Switching to an account with data brings every local model into it without overwriting its data, and switching back
    /// doesn't duplicate anything.
    @Test func switchingToAnAccountWithData() async throws {
        let server = FakeCloudServer()
        server.seed([subscriptionRecord("s2", title: "Second's s2"), subscriptionRecord("s9", title: "Second's s9")], account: "second")
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2", "s3"])
        try device.change { $0.insert(ScenarioNote(text: "A note")) }
        await device.sync()
        #expect(device.synchronizer.hasDownloadedOnce)

        // The new account's first download fails, so it wasn't downloaded yet
        server.fetchFailure = CKError(.networkFailure)
        device.switchAccount(to: .signedIn("second"))
        await device.sync()
        #expect(!device.synchronizer.hasDownloadedOnce)
        server.fetchFailure = nil
        await device.sync()
        #expect(device.synchronizer.hasDownloadedOnce)

        #expect(device.serverSubscriptions(account: "second").map(\.feedLink) == ["s1", "s2", "s3", "s9"])
        #expect(device.serverSubscriptions(account: "second").first { $0.feedLink == "s2" }?.title == "Second's s2")
        #expect(device.serverNotes(account: "second") == ["A note"])
        #expect(try device.subscriptions() == device.serverSubscriptions(account: "second"))
        // The previous account is left alone
        #expect(device.serverSubscriptions(account: "first").map(\.feedLink) == ["s1", "s2", "s3"])

        device.switchAccount(to: .signedIn("first"))
        await device.sync()
        await device.sync()
        #expect(device.serverNotes(account: "first") == ["A note"])
        #expect(device.serverSubscriptions(account: "first").map(\.feedLink) == ["s1", "s2", "s3", "s9"])
        #expect(device.serverSubscriptions(account: "first").first { $0.feedLink == "s2" }?.title == "Title of s2")
        #expect(try device.notes() == ["A note"])
        device.terminate()
    }

    @Test func switchingToAnEmptyAccount() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        try device.change { $0.insert(ScenarioNote(text: "A note")) }
        await device.sync()

        device.switchAccount(to: .signedIn("third"))
        await device.sync()
        #expect(device.serverSubscriptions(account: "third") == (try device.subscriptions()))
        #expect(device.serverNotes(account: "third") == ["A note"])
        device.terminate()
    }

    /// An account change while stopped is noticed once started again.
    @Test func accountChangedWhileStopped() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        device.synchronizer.stop()
        let eventCount = server.events.count
        device.switchAccount(to: .signedIn("second"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.events.count == eventCount)

        device.synchronizer.start()
        #expect(await waitUntil { device.serverSubscriptions(account: "second").map(\.feedLink) == ["s1"] })
        device.terminate()
    }

    /// While iCloud is temporarily unavailable, e.g. until the user enters their password, nothing is lost or reset.
    @Test func temporarilyUnavailableAccount() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        device.switchAccount(to: .temporarilyUnavailable)
        await device.sync()
        #expect(await device.state.isNotLoggedIn)
        try device.editSubscription("s1") { $0.title = "Edited meanwhile" }
        await device.sync()
        let saves = server.events(of: "A", .modifyRecords).count

        device.switchAccount(to: .signedIn("first"))
        await device.sync()
        #expect(device.serverSubscriptions().first?.title == "Edited meanwhile")
        #expect(server.events(of: "A", .modifyRecords).dropFirst(saves).flatMap(\.savedKeys.keys) == [subscriptionRecordName("s1")])
        device.terminate()
    }

    /// Signing out while a download runs keeps what was downloaded, and continues from there once signed in again.
    @Test func signingOutWhileDownloading() async throws {
        let server = FakeCloudServer()
        server.pageSize = 100
        server.seed(feedLinks(1...1000).map { subscriptionRecord($0, title: "Title") }, account: "first")
        let device = TestDevice("B", server: server)
        server.pageDelivered = { [cloud = device.cloud] _, pages in
            if pages == 3 {
                cloud.account = .noAccount
            }
        }
        try await device.launch()
        #expect(await device.state.isNotLoggedIn)
        #expect(try device.count(ScenarioSubscription.self) >= 200)
        #expect(!device.synchronizer.hasDownloadedOnce)

        server.pageDelivered = nil
        let fetches = server.events(of: "B", .fetchChanges).count
        device.switchAccount(to: .signedIn("first"))
        await device.sync()
        #expect(try device.count(ScenarioSubscription.self) == 1000)
        #expect((server.events(of: "B", .fetchChanges).dropFirst(fetches).first?.tokenSequence ?? 0) >= 200)
        #expect(device.synchronizer.hasDownloadedOnce)
        device.terminate()
    }

    // MARK: Zones and Stores

    /// When the user deletes the app's data in iCloud, nothing is uploaded until synchronizing is started again.
    @Test func zoneDeletedByTheUser() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        server.deleteZone(account: "first", byUser: true)
        try device.editSubscription("s1") { $0.title = "Edited" }
        await device.settle()
        #expect((await device.state.error as? CKError)?.code == .userDeletedZone)
        #expect(device.synchronizer.isStopped)
        #expect(try device.subscriptions().count == 2)
        #expect(!server.hasZone(account: "first"))

        device.synchronizer.start()
        #expect(await waitUntil { device.serverSubscriptions().count == 2 })
        await device.settle()
        #expect(try device.subscriptions() == device.serverSubscriptions())
        device.terminate()
    }

    /// A zone deleted on another device is created again with every local model, and other devices download it again.
    @Test func zoneDeletedOnAnotherDevice() async throws {
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        let second = TestDevice("B", server: server)
        try await first.launch()
        try await second.launch()
        try first.insertSubscriptions(["s1", "s2", "s3"])
        await first.sync()
        await second.sync()

        server.deleteZone(account: "first", byUser: false)
        try second.insertSubscriptions(["s4"])
        await second.sync()
        await second.sync()
        #expect(second.serverSubscriptions().map(\.feedLink) == ["s1", "s2", "s3", "s4"])

        await first.sync()
        await first.sync()
        #expect(try first.subscriptions() == second.serverSubscriptions())
        #expect(try second.subscriptions() == second.serverSubscriptions())
        first.terminate()
        second.terminate()
    }

    /// A store that was lost or replaced isn't taken for deletions, which would delete the data on every device.
    /// It's restored from iCloud instead.
    @Test func lostStoreIsRestored() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(feedLinks(1...20))
        await device.sync()
        device.terminate()

        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: device.storeURL.path + suffix))
        }
        try await device.launch()
        await device.sync()
        #expect(device.serverSubscriptions().count == 20)
        #expect(try device.subscriptions().count == 20)
        device.terminate()
    }

    /// `ModelContext.delete(model:where:)` deletes in the store directly, without the changes the synchronizer observes.
    /// The models' records aren't deleted, which would happen on every device: they're restored after the next launch.
    @Test func batchDeletesAreRestored() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        try device.change { context in
            try context.delete(model: ScenarioSubscription.self, where: #Predicate { $0.feedLink == "s1" })
        }
        await device.sync()
        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])

        device.terminate()
        try await device.launch()
        await device.sync()
        #expect(try device.subscriptions().map(\.feedLink) == ["s1", "s2"])
        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])
        device.terminate()
    }

    // MARK: Limits

    /// Values too large for a record are uploaded as an asset, and other devices read them like other values.
    @Test func recordOverOneMegabyte() async throws {
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        let second = TestDevice("B", server: server)
        try await first.launch()
        try await second.launch()

        let artwork = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try first.insertSubscriptions(["s1", "s2"])
        try first.editSubscription("s1") { $0.artwork = artwork }
        await first.sync()

        let record = try #require(server.record(named: subscriptionRecordName("s1"), account: "first"))
        #expect(record["artwork"] == nil)
        #expect(record["SDSOverflow"] is CKAsset)
        // Records that never needed it don't get the field, which production schemas might not have
        let small = server.events(of: "A", .modifyRecords).compactMap { $0.savedKeys[subscriptionRecordName("s2")] }
        #expect(!small.isEmpty && small.allSatisfy { !$0.contains("SDSOverflow") })

        await second.sync()
        #expect(try second.subscription("s1")?.artwork == artwork)
        #expect(try second.subscription("s1")?.title == "Title of s1")

        try first.editSubscription("s1") { $0.artwork = Data("small".utf8) }
        await first.sync()
        let smallRecord = try #require(server.record(named: subscriptionRecordName("s1"), account: "first"))
        #expect(smallRecord["artwork"] as? Data == Data("small".utf8))
        #expect(smallRecord["SDSOverflow"] == nil)
        await second.sync()
        #expect(try second.subscription("s1")?.artwork == Data("small".utf8))
        first.terminate()
        second.terminate()
    }

    /// An operation CloudKit finds too large is split until it fits.
    @Test func operationTooLargeIsSplit() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try device.insertSubscriptions(feedLinks(1...500))
        server.failNextModify(with: CKError(.limitExceeded))

        try await device.launch()
        #expect(device.serverSubscriptions().count == 500)
        let saves = server.events(of: "A", .modifyRecords)
        #expect(saves.first?.failed == true)
        #expect(saves.dropFirst().allSatisfy { !$0.failed && $0.savedKeys.count <= 200 })
        #expect(await device.state.error == nil)
        device.terminate()
    }

    /// CloudKit asks to wait after rate limiting a few records. The upload waits, rather than retrying right away.
    @Test func rateLimitedUploadWaits() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try device.insertSubscriptions(feedLinks(1...1000))
        let limited = Set(feedLinks(1...30).map(subscriptionRecordName))
        server.failSaving(where: { limited.contains($0.recordName) }, with: CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 1.0]), count: 30)

        try await device.launch()
        #expect((await device.state.error as? CKError)?.retryAfterSeconds == 1)
        #expect(server.events(of: "A", .modifyRecords).count == 1)
        #expect(await device.sync() == false, "Synchronized before CloudKit's delay")

        #expect(await waitUntil(timeout: 10) { device.serverSubscriptions().count == 1000 })
        let saves = server.events(of: "A", .modifyRecords)
        #expect(saves.count >= 2 && saves[1].date.timeIntervalSince(saves[0].date) >= 1)
        device.terminate()
    }

    /// A full iCloud doesn't set records aside or retry over and over. Uploads pause, the app can show why, and downloads go on.
    @Test func quotaExceededPausesUploads() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        device.timing.quotaExceededRetryInterval = 1
        try await device.launch()

        server.failNextModify(with: CKError(.quotaExceeded))
        try device.insertSubscriptions(["s1"])
        await device.settle()
        // CloudKit's error, which apps can tell by its code, with a description to show
        let error = try #require(await device.state.error as? CKError)
        #expect(error.code == .quotaExceeded)
        #expect(error.localizedDescription == "Your iCloud storage is full")

        let saves = server.events(of: "A", .modifyRecords).count
        let fetches = server.events(of: "A", .fetchChanges).count
        await device.sync()
        #expect(server.events(of: "A", .modifyRecords).count == saves)
        #expect(server.events(of: "A", .fetchChanges).count > fetches)

        try await Task.sleep(for: .seconds(1.1))
        await device.sync()
        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1"])
        device.terminate()
    }

    /// A development build creates every record type and field, so the schema can be deployed before anything uses them.
    @Test func initializeSchemaCreatesEveryField() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try await device.synchronizer.initializeSchema()

        #expect(server.schema["ScenarioSubscription"] == ["feedLink", "title", "position", "isMuted", "rating", "addedAt", "note", "artwork", "SDSOverflow"])
        #expect(server.schema["ScenarioEpisode"] == ["feedLink", "guid", "elapsed", "played"])
        #expect(server.schema["ScenarioNote"] == ["text", "SDSOverflow"])
        #expect(server.records(account: "first").isEmpty)

        server.isProduction = true
        try device.insertSubscriptions(["s1", "s2"])
        try device.editSubscription("s1") { $0.artwork = Data(count: 1_500_000) }
        await device.sync()
        #expect(device.serverSubscriptions().count == 2)
        #expect(await device.state.error == nil)
        device.terminate()
    }

    /// A production schema without a record type rejects its records. The state says why, so the app can show it.
    @Test func rejectedRecordsTellWhy() async throws {
        let server = FakeCloudServer()
        server.isProduction = true
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.settle()

        let error = try #require(await device.state.error as? SDSSyncError)
        #expect(error.isIncompleteUpload)
        let reason = try #require(error.underlyingError as? CKError)
        #expect(reason.code == .invalidArguments)
        #expect(reason.localizedDescription == "Cannot create new type ScenarioSubscription in production schema")

        // Later synchronizations leave the record out for a while, and still say why
        await device.sync()
        let again = try #require(await device.state.error as? SDSSyncError)
        #expect((again.underlyingError as? CKError)?.code == .invalidArguments)

        // Nothing synchronizes again by itself until the record's time is up
        let fetches = server.events(of: "A", .fetchChanges).count
        try await Task.sleep(for: .seconds(2))
        #expect(server.events(of: "A", .fetchChanges).count == fetches)

        // When the user asks for it, the record is tried again, which succeeds once the schema has the type
        server.isProduction = false
        await device.synchronizer.forceDownloadSync()
        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1"])
        #expect(await device.state.error == nil)
        device.terminate()
    }

    /// A reset forgets what the synchronizer knew about iCloud, without changing iCloud. Starting again downloads
    /// everything, finds the local objects iCloud has without duplicating them, and doesn't upload what changed before.
    @Test func resetStartsOverWithoutChangingICloud() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2", "s3"])
        await device.settle()
        #expect(device.serverSubscriptions().count == 3)

        device.synchronizer.stop()
        try device.deleteSubscription("s1")
        try device.editSubscription("s2") { $0.title = "Changed before the reset" }
        let saves = server.events(of: "A", .modifyRecords).count
        try await device.synchronizer.resetSyncData()
        #expect(!device.synchronizer.hasDownloadedOnce)
        #expect(server.events(of: "A", .modifyRecords).count == saves)

        device.synchronizer.start()
        await device.settle()
        #expect(device.synchronizer.hasDownloadedOnce)
        #expect(device.serverSubscriptions().map(\.feedLink).sorted() == ["s1", "s2", "s3"])
        #expect(device.serverSubscriptions().first { $0.feedLink == "s2" }?.title == "Title of s2")
        // The device has iCloud's data again, once each
        #expect(try device.subscriptions().map(\.feedLink).sorted() == ["s1", "s2", "s3"])
        #expect(try device.subscription("s2")?.title == "Title of s2")
        #expect(await device.state.error == nil)
        device.terminate()
    }
}
