import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// The scenarios of a fourth independent review of the natural keys and backfill.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct FourthIndependentReviewTests {

    /// A save of the app fails, e.g. with a merge conflict, and the app rolls back. The keys it was about to save aren't taken
    /// for local changes afterwards, which would keep later downloads from storing the values of other devices.
    @Test func failedSaveKeepsDownloadedValuesFromBeingStored() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()
        try await b.launch()
        await b.sync()
        #expect(try b.subscription("s1")?.title == "Title of s1")

        // On A, a Core Data context (default merge policy: NSErrorMergePolicy) edits the title, while another save changes the row
        let coordinator = try #require(a.synchronizer.observedStore)
        let failing = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        failing.persistentStoreCoordinator = coordinator
        try failing.performAndWait {
            let object = try #require(try failing.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription")).first)
            object.setValue("Edit that is never saved", forKey: "title")
        }
        try a.editSubscription("s1") { $0.position = 7 }
        await a.sync()
        let saveFailed = failing.performAndWait { () -> Bool in
            do { try failing.save(); return false } catch { failing.rollback(); return true }
        }
        #expect(saveFailed)

        // B renames it later, A downloads it
        try b.editSubscription("s1") { $0.title = "Renamed on B" }
        await b.sync()
        #expect(b.serverSubscriptions().first?.title == "Renamed on B")
        await a.sync()
        await a.sync()

        #expect(try a.subscription("s1")?.title == "Renamed on B")
        #expect(a.serverSubscriptions().first?.title == "Renamed on B")
        a.terminate()
        b.terminate()
    }

    /// The app saves one context many times in a row. What's done once a save's keys are stored doesn't touch the keys of the
    /// next save of the same context, so every edit is uploaded.
    @Test func consecutiveSavesOfOneContextKeepTheirKeys() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch()
        let feedLinks = (0..<200).map { "s\($0)" }
        try a.insertSubscriptions(feedLinks)
        await a.sync()
        #expect(a.serverSubscriptions().count == 200)

        let coordinator = try #require(a.synchronizer.observedStore)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription"))
            for object in objects {
                object.setValue("Edited \(object.value(forKey: "feedLink") as! String)", forKey: "title")
                try context.save()
            }
        }
        await a.sync()
        await a.sync()

        let notUploaded = a.serverSubscriptions().filter { !$0.title.hasPrefix("Edited") }.map(\.feedLink)
        #expect(notUploaded.isEmpty, "\(notUploaded.count) edits weren't uploaded: \(notUploaded.prefix(10))")
        a.terminate()
    }

    /// The synchronizer's queue is busy, e.g. with a download, while the app saves a context twice. It becomes free while the
    /// second save runs, so what's done once the first save's keys are stored runs then. The second save's keys stay.
    @Test func secondSaveWhileTheFirstOneIsStoredIsUploaded() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()

        let synchronizer = try #require(a.synchronizer)
        let syncContext = synchronizer.context
        let observedStore = synchronizer.observedStore
        let appContext = ModelContext(try #require(a.modelContainer))
        appContext.autosaveEnabled = false
        let model = try #require(try appContext.fetch(FetchDescriptor<ScenarioSubscription>()).first)

        let gate = DispatchSemaphore(value: 0)
        enqueue(on: syncContext) { gate.wait() }
        model.title = "First"
        try appContext.save()

        let isArmed = OSAllocatedUnfairLock(initialState: true)
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: nil, queue: nil) { notification in
            guard
                let context = notification.object as? NSManagedObjectContext,
                context.persistentStoreCoordinator == observedStore,
                context !== synchronizer.observedUpdateContext,
                isArmed.withLock({ isArmed in defer { isArmed = false }; return isArmed })
            else { return }
            gate.signal()
            syncContext.performAndWait {}
        }
        model.position = 42
        try appContext.save()
        NotificationCenter.default.removeObserver(observer)

        await a.sync()
        await a.sync()
        #expect(a.serverSubscriptions().first?.title == "First")
        #expect(a.serverSubscriptions().first?.position == 42)
        a.terminate()
    }

    /// CloudKit keeps rejecting a document that moved to another workspace, e.g. in a share the user may only read. Deleting
    /// a subscription, which has nothing to do with it, is still uploaded. Only the previous workspace's removal would wait.
    @Test func rejectedMoveDoesNotHoldBackOtherRemovals() async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.change { context in
            let workspace = ScenarioWorkspace(title: "W1")
            context.insert(workspace)
            let document = ScenarioDocument(title: "D")
            context.insert(document)
            document.workspace = workspace
            context.insert(ScenarioSubscription(feedLink: "unrelated"))
        }
        await a.sync()

        server.failSaving(where: { $0.recordName == documentRecordName("D") }, with: CKError(.permissionFailure))
        try a.change { context in
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            let new = ScenarioWorkspace(title: "W2")
            context.insert(new)
            document.workspace = new
        }
        await a.sync()
        try a.deleteSubscription("unrelated")
        await a.sync()
        await a.sync()
        #expect(a.serverSubscriptions().isEmpty)
        a.terminate()
    }

    /// An extension that doesn't synchronize notes.
    private static let extensionConfiguration = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .noSync),
        .init(entity: ScenarioLink.self, description: .sync(.without([]))),
        .init(entity: ScenarioTag.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    /// Device B's extension skips 450 notes another device added, more than CloudKit fetches at once. The app still gets them.
    @Test func appGetsMoreRecordsThanCloudKitFetchesAtOnce() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        await b.sync()
        b.terminate()

        try a.change { context in
            for index in 0..<450 { context.insert(ScenarioNote(text: "n\(index)")) }
        }
        await a.sync()

        b.beforeSetup = { $0.isAppExtension = true }
        try await b.launch(configuration: Self.extensionConfiguration)
        await b.sync()
        b.terminate()
        b.beforeSetup = nil
        try await b.launch()
        await b.sync()

        #expect(try b.notes().count == 450)
        a.terminate()
        b.terminate()
    }

    /// Device B edits a subscription that device A deleted, which reaches iCloud after B's download, either before B's upload
    /// reads the record, or right before B saves it. B's edit doesn't create the record again with only the edited value,
    /// without its identity's, and the subscription is gone on both devices.
    @Test(arguments: [false, true]) func editOfARecordDeletedMeanwhileDoesNotCreateItAgain(rightBeforeSaving: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()
        await b.sync()

        let recordName = subscriptionRecordName("s1")
        let isDone = OSAllocatedUnfairLock(initialState: false)
        let deleteOnce: @Sendable () -> Void = {
            guard isDone.withLock({ done in defer { done = true }; return !done }) else { return }
            server.delete([recordName], account: "first")
        }
        if rightBeforeSaving {
            server.beforeModifyRecords = { device, saved in
                if device == "B" && saved.contains(recordName) { deleteOnce() }
            }
        } else {
            b.synchronizer.afterSavingDownloadedObjects = deleteOnce
        }
        try b.editSubscription("s1") { $0.position = 123 }
        await b.settle()
        server.beforeModifyRecords = nil
        b.synchronizer.afterSavingDownloadedObjects = nil
        await b.sync()
        await a.sync()

        #expect(isDone.withLock { $0 })
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioSubscription" }.isEmpty)
        #expect(try b.subscriptions().isEmpty)
        #expect(try a.subscriptions().isEmpty)
        a.terminate()
        b.terminate()
    }

    /// The links of each subscription, as `feedLink: [link names]`, and the links without a subscription under `-`.
    private func links(_ device: TestDevice) throws -> [String: [String]] {
        let links = try ModelContext(#require(device.modelContainer)).fetch(FetchDescriptor<ScenarioLink>())
        return Dictionary(grouping: links) { $0.subscription?.feedLink ?? "-" }.mapValues { $0.map(\.name).sorted() }
    }

    private func tags(_ device: TestDevice) throws -> [String] {
        try ModelContext(#require(device.modelContainer)).fetch(FetchDescriptor<ScenarioTag>()).map { "\($0.name):\($0.color)" }.sorted()
    }

    /// Device B deletes a tag whose name is unique, and creates a new one with the same name, whose record's name comes
    /// after the deleted one's. Device A gets the new tag with the same download that deletes its old one.
    @Test func uniqueValueDeletedAndCreatedAgainIsStoredInOneDownload() async throws {
        for _ in 0..<20 {
            let server = FakeCloudServer()
            let a = TestDevice("A", server: server)
            let b = TestDevice("B", server: server)
            try await a.launch()
            try await b.launch()
            try a.change { $0.insert(ScenarioTag(name: "work", color: "red")) }
            await a.sync()
            await b.sync()
            let oldName = try #require(server.records(account: "first").first { $0.recordType == "ScenarioTag" }).recordID.recordName

            try b.change { context in
                for tag in try context.fetch(FetchDescriptor<ScenarioTag>()) { context.delete(tag) }
            }
            try b.change { $0.insert(ScenarioTag(name: "work", color: "blue")) }
            await b.sync()
            let newName = try #require(server.records(account: "first").first { $0.recordType == "ScenarioTag" }).recordID.recordName
            // Only a new record whose name comes after loses to the old one until its deletion is applied
            guard newName > oldName else {
                a.terminate()
                b.terminate()
                continue
            }
            await a.sync()
            #expect(try tags(a) == ["work:blue"])
            a.terminate()
            b.terminate()
            return
        }
        Issue.record("The new record never got a name that comes after the deleted one's")
    }

    /// Device B moves a link into another subscription while it's stopped, and device A deletes that subscription. B gets the
    /// deletion before it uploads the move, so its delete rule deletes the link, which A doesn't know is in the subscription.
    /// The link is deleted everywhere, rather than only on B, while A and iCloud keep it at its previous subscription.
    @Test func linkMovedIntoASubscriptionDeletedBeforeTheMoveWasUploadedIsGoneEverywhere() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.insertSubscriptions(["s1", "s2"])
        try a.change { context in
            let link = ScenarioLink(name: "l1")
            context.insert(link)
            link.subscription = try context.fetch(FetchDescriptor<ScenarioSubscription>(predicate: #Predicate { $0.feedLink == "s1" })).first
        }
        await a.sync()
        await b.sync()

        b.synchronizer.stop()
        try b.change { context in
            let link = try #require(try context.fetch(FetchDescriptor<ScenarioLink>()).first)
            link.subscription = try context.fetch(FetchDescriptor<ScenarioSubscription>(predicate: #Predicate { $0.feedLink == "s2" })).first
        }
        try a.deleteSubscription("s2")
        await a.sync()
        b.synchronizer.start()
        await b.settle()
        await b.sync()
        await a.sync()

        #expect(try links(a).isEmpty)
        #expect(try links(b).isEmpty)
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioLink" }.isEmpty)
        a.terminate()
        b.terminate()
    }

    /// A subscription's artwork and note are both large, so both are in the record's overflow asset. Editing the note keeps
    /// the artwork in the asset, also as the upload reads the record from iCloud without its values first.
    @Test func editingOneLargeValueKeepsTheOthers() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        let artwork = Data(repeating: 7, count: 300_000)
        try a.insertSubscriptions(["s1"])
        try a.editSubscription("s1") {
            $0.artwork = artwork
            $0.note = String(repeating: "n", count: 300_000)
        }
        await a.sync()
        let note = String(repeating: "m", count: 300_000)
        try a.editSubscription("s1") { $0.note = note }
        await a.sync()
        await b.sync()

        #expect(try b.subscription("s1")?.note == note)
        #expect(try b.subscription("s1")?.artwork == artwork)
        a.terminate()
        b.terminate()
    }

    /// A large artwork, which is in the overflow asset, is cleared. Other devices clear it too, rather than reading the asset's
    /// value, which would stay in iCloud.
    @Test func clearingALargeValueSticks() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()
        try a.editSubscription("s1") { $0.artwork = Data(repeating: 7, count: 300_000) }
        await a.sync()
        await b.sync()
        #expect(try b.subscription("s1")?.artwork?.count == 300_000)

        try a.editSubscription("s1") { $0.artwork = nil }
        await a.sync()
        await b.sync()
        #expect(try b.subscription("s1")?.artwork == nil)
        a.terminate()
        b.terminate()
    }

    /// Device A changes a subscription's identity, so it moves to another record, while iCloud is full, or while CloudKit
    /// rejects the new record. The previous record isn't deleted before the new one is uploaded, which would delete the
    /// subscription on device B meanwhile. Once the new record can be uploaded, the previous one is deleted.
    @Test(arguments: [false, true]) func identityMoveKeepsThePreviousRecordUntilTheNewOneIsUploaded(rejected: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.insertSubscriptions(["s1", "s2"])
        await a.sync()
        await b.sync()

        let isFailing = OSAllocatedUnfairLock(initialState: true)
        let newRecord = subscriptionRecordName("s1x")
        if rejected {
            server.failSaving(where: { $0.recordName == newRecord && isFailing.withLock { $0 } }, with: CKError(.serverRejectedRequest))
        } else {
            server.failSaving(where: { _ in isFailing.withLock { $0 } }, with: CKError(.quotaExceeded))
        }
        try a.editSubscription("s1") { $0.feedLink = "s1x" }
        await a.sync()
        await a.sync()
        await b.sync()
        #expect(try b.subscriptions().map(\.feedLink) == ["s1", "s2"])

        isFailing.withLock { $0 = false }
        a.synchronizer.resetQuarantine()
        a.synchronizer.resumeUploads()
        await a.sync()
        await a.sync()
        await b.sync()
        #expect(a.serverSubscriptions().map(\.feedLink) == ["s1x", "s2"])
        #expect(try b.subscriptions().map(\.feedLink) == ["s1x", "s2"])
        a.terminate()
        b.terminate()
    }

    /// A subscription is deleted elsewhere while this device's change token expires, so this device never downloads the
    /// deletion, and keeps the subscription, with an edit that can't be uploaded. Changes of other models, e.g. a link, which
    /// is uploaded after subscriptions as it references them, are still uploaded.
    @Test func editOfARecordWhoseDeletionIsNeverDownloadedDoesNotStallUploads() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1", "s2"])
        await a.sync()
        server.deleteWhileTokensExpire([subscriptionRecordName("s1")], account: "first")
        try a.editSubscription("s1") { $0.title = "Edited" }
        await a.sync()

        try a.change { context in
            let link = ScenarioLink(name: "L")
            context.insert(link)
            link.subscription = try context.fetch(FetchDescriptor<ScenarioSubscription>(predicate: #Predicate { $0.feedLink == "s2" })).first
        }
        await a.sync()
        await a.sync()
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioLink" }.count == 1)
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioSubscription" }.count == 1)
        a.terminate()
    }
}

/// Runs a block on the context's queue without waiting for it.
private func enqueue(on context: NSManagedObjectContext, _ block: @escaping @Sendable () -> Void) {
    context.perform(block)
}
