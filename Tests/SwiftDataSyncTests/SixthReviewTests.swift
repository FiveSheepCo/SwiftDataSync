import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
@testable import SwiftDataSync

/// Scenarios of the sixth review: resets that keep models lacking identity values or changed models, catch-ups across
/// resets, and identities swapped in one save.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct SixthReviewScenarioTests {

    /// Subscriptions whose notes are part of their identity, so ones without notes lack an identity value.
    private static let notesInIdentity = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink", "note"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    private static let withoutNotes = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without(["note"]), identity: ["feedLink"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    // MARK: Resetting

    /// Models that lack one of their identity values have randomly named records, like models without an identity. A reset
    /// matches them with their records by their values too, rather than uploading them again as duplicates.
    @Test func resetKeepsModelsLackingIdentityValuesOnce() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch(configuration: Self.notesInIdentity)
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()
        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])

        device.synchronizer.stop()
        try await device.synchronizer.resetSyncData()
        device.synchronizer.start()
        await device.settle()
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])
        #expect(try device.subscriptions().map(\.feedLink) == ["s1", "s2"])
        device.terminate()
    }

    /// Subscriptions without an identity, so they're matched with their records by their values after a reset.
    private static let subscriptionsWithoutIdentity = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without([]))),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    /// Changes the title of s1 and back, like an edit that's undone.
    private func editAndRevert(_ device: TestDevice) throws {
        for title in ["Edited", "Title of s1"] {
            try device.editSubscription("s1") { $0.title = title }
        }
    }

    /// A model without an identity changes after a reset, before its record is downloaded again. It's still matched with
    /// its record by its values, as some of them are of unknown age, so it was saved before, rather than its record being
    /// downloaded as a duplicate.
    @Test func modelsChangedAfterAResetAreMatchedByTheirValues() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch(configuration: Self.subscriptionsWithoutIdentity)
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()
        #expect(device.serverSubscriptions().count == 2)

        device.synchronizer.stop()
        try await device.synchronizer.resetSyncData()
        try editAndRevert(device)
        device.synchronizer.start()
        await device.settle()
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])
        #expect(try device.subscriptions().map(\.feedLink) == ["s1", "s2"])
        device.terminate()
    }

    /// A model is created after a reset with the values of another device's model. It stays a model of its own, rather
    /// than being taken for a copy of the other device's.
    @Test func modelsCreatedAfterAResetAreNotMatchedByTheirValues() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        device.synchronizer.stop()
        // Created while this device doesn't synchronize
        let other = TestDevice("B", server: server)
        try await other.launch()
        try other.change { $0.insert(ScenarioNote(text: "Hello")) }
        await other.settle()
        other.terminate()

        try await device.synchronizer.resetSyncData()
        try device.change { $0.insert(ScenarioNote(text: "Hello")) }
        device.synchronizer.start()
        await device.settle()
        await device.sync()

        #expect(device.serverNotes() == ["Hello", "Hello"])
        #expect(try device.notes() == ["Hello", "Hello"])
        device.terminate()
    }

    /// A model without an identity changes after a reset, and the download that would match it with its record fails.
    /// Nothing is uploaded until every record was downloaded again, rather than the model being uploaded as a new record.
    @Test func nothingIsUploadedWhileRecoveringIfTheDownloadFails() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch(configuration: Self.subscriptionsWithoutIdentity)
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        device.synchronizer.stop()
        try await device.synchronizer.resetSyncData()
        try editAndRevert(device)
        server.failNextFetch(with: CKError(.networkFailure))
        device.synchronizer.start()
        await device.settle()
        await device.sync()

        #expect(device.serverSubscriptions().map(\.feedLink) == ["s1", "s2"])
        #expect(try device.subscriptions().map(\.feedLink) == ["s1", "s2"])
        device.terminate()
    }

    /// A record fails to download while every record is downloaded again after a reset. Its model, which has no record yet,
    /// isn't uploaded as a new one until the record was downloaded and matched with it, rather than becoming a duplicate.
    @Test func recoveringWaitsForRecordsThatFailedToDownload() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { context in
            context.insert(ScenarioNote(text: "Hello"))
            context.insert(ScenarioNote(text: "World"))
        }
        await device.settle()
        let hello = try #require(server.records(account: "first").first { $0["text"] as? String == "Hello" }?.recordID.recordName)

        device.synchronizer.stop()
        try await device.synchronizer.resetSyncData()
        server.failDownloading(where: { $0.recordName == hello }, with: CKError(.networkFailure), count: 2)
        device.synchronizer.start()
        await device.settle()
        await device.sync()
        await device.sync()

        #expect(device.serverNotes() == ["Hello", "World"])
        #expect(try device.notes() == ["Hello", "World"])
        device.terminate()
    }

    /// While every record is downloaded again, the store's data isn't complete yet.
    @Test func notDownloadedOnceWhileRecovering() async throws {
        let device = TestDevice("A", server: FakeCloudServer())
        try await device.launch()
        #expect(device.synchronizer.hasDownloadedOnce)
        device.synchronizer.updateFileState { $0.isRecoveringVanishedObjects = true }
        #expect(!device.synchronizer.hasDownloadedOnce)
        device.terminate()
    }

    // MARK: Catching Up

    /// A catch-up couldn't store a record, and the upload of the other objects' values failed, when the synchronization data
    /// is reset. The next try uploads every object's values again, as the reset forgot the ones the first try queued.
    @Test func catchUpAfterAResetUploadsEveryObjectsValues() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch(configuration: Self.withoutNotes)
        try device.insertSubscriptions(["s1", "s2"])
        try device.editSubscription("s2") { $0.note = "Only here" }
        await device.sync()
        server.seed([subscriptionRecord("s1", title: "Title of s1", note: "From another device")], account: "first")
        await device.sync()
        device.terminate()

        server.failDownloading(where: { $0.recordName == subscriptionRecordName("s1") }, with: CKError(.assetFileNotFound))
        server.failNextModify(with: CKError(.networkUnavailable))
        try await device.launch()
        #expect(device.synchronizer.pendingCatchUp != nil)
        #expect(device.serverSubscriptions().first { $0.feedLink == "s2" }?.note == nil)

        device.synchronizer.stop()
        try await device.synchronizer.resetSyncData()
        device.synchronizer.start()
        await device.settle()
        device.synchronizer.postponeCatchUp(until: .distantPast)
        await device.sync()

        #expect(device.serverSubscriptions().first { $0.feedLink == "s2" }?.note == "Only here")
        device.terminate()
    }

    /// The count of tries that couldn't store every record belongs to the keys it counted. A catch-up of other keys, e.g.
    /// after another update, counts anew.
    @Test func catchUpTriesOfOtherKeysCountAnew() async throws {
        let device = TestDevice("A", server: FakeCloudServer())
        try await device.launch()
        let first = SDSSynchronizer.CatchUp(keys: ["A", "A.a"], newKeys: ["A.a"])
        #expect(device.synchronizer.countIncompleteCatchUp(first) == 1)
        #expect(device.synchronizer.countIncompleteCatchUp(first) == 2)
        let second = SDSSynchronizer.CatchUp(keys: ["A", "A.a", "A.b"], newKeys: ["A.a", "A.b"])
        #expect(device.synchronizer.countIncompleteCatchUp(second) == 1)
        device.terminate()
    }

    // MARK: Identities

    /// Two models swap their identities in one save. Both keep the records named after their identities, whichever is
    /// moved first, rather than one moving to a random name and the record of its identity being deleted.
    @Test(arguments: 1...4) func swappedIdentitiesKeepTheirRecordNames(attempt: Int) async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()
        let savesBefore = server.events(of: "A", .modifyRecords).count

        try device.change { context in
            for subscription in try context.fetch(FetchDescriptor<ScenarioSubscription>()) {
                subscription.title = "Was \(subscription.feedLink)"
                subscription.feedLink = subscription.feedLink == "s1" ? "s2" : "s1"
            }
        }
        await device.sync()

        let names = Set(server.records(account: "first").filter { $0.recordType == "ScenarioSubscription" }.map(\.recordID.recordName))
        #expect(names == [subscriptionRecordName("s1"), subscriptionRecordName("s2")])
        #expect(server.events(of: "A", .modifyRecords).dropFirst(savesBefore).allSatisfy { $0.deletedNames.isEmpty })
        #expect(device.serverSubscriptions().map(\.title) == ["Was s2", "Was s1"])
        device.terminate()
    }

    /// A save swaps the identities of more models than are stored in one batch. Models whose identities another model of
    /// another batch takes keep their records too.
    @Test func identitiesSwappedAcrossBatchesKeepTheirRecords() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        let feedLinks = (0..<1_000).map { String(format: "s%04d", $0) }
        try device.insertSubscriptions(feedLinks)
        await device.sync()
        let savesBefore = server.events(of: "A", .modifyRecords).count

        try device.change { context in
            // Each model takes the identity of its partner from the other end, so the models of many pairs are in different batches
            let subscriptions = try context.fetch(FetchDescriptor<ScenarioSubscription>()).sorted { $0.feedLink < $1.feedLink }
            let partners = subscriptions.reversed().map(\.feedLink)
            for (subscription, partner) in zip(subscriptions, partners) {
                subscription.title = "Was \(subscription.feedLink)"
                subscription.feedLink = partner
            }
        }
        await device.sync()

        let names = Set(server.records(account: "first").filter { $0.recordType == "ScenarioSubscription" }.map(\.recordID.recordName))
        #expect(names == Set(feedLinks.map(subscriptionRecordName)))
        #expect(server.events(of: "A", .modifyRecords).dropFirst(savesBefore).allSatisfy { $0.deletedNames.isEmpty })
        device.terminate()
    }

    /// A model is deleted, and another one moves to its identity before the deletion was uploaded. It takes the deleted
    /// model's record, rather than moving to a random name and both records being deleted.
    @Test func modelMovingToTheIdentityOfADeletedOneTakesItsRecord() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1", "s2"])
        await device.sync()

        try device.change { context in
            let subscriptions = try context.fetch(FetchDescriptor<ScenarioSubscription>())
            for subscription in subscriptions where subscription.feedLink == "s1" {
                context.delete(subscription)
            }
            for subscription in subscriptions where subscription.feedLink == "s2" {
                subscription.feedLink = "s1"
            }
        }
        await device.sync()

        let names = Set(server.records(account: "first").filter { $0.recordType == "ScenarioSubscription" }.map(\.recordID.recordName))
        #expect(names == [subscriptionRecordName("s1")])
        #expect(server.record(named: subscriptionRecordName("s1"), account: "first")?["title"] as? String == "Title of s2")
        device.terminate()
    }

    /// A new model takes the identity another model of the same save gives up. The record stays for the new model.
    @Test func identityGivenUpAndTakenInOneSaveKeepsItsName() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()
        let savesBefore = server.events(of: "A", .modifyRecords).count

        try device.change { context in
            context.insert(ScenarioSubscription(feedLink: "s1", title: "New"))
            let old = try #require(try context.fetch(FetchDescriptor<ScenarioSubscription>()).first { $0.title == "Title of s1" })
            old.feedLink = "s2"
        }
        await device.sync()

        let names = Set(server.records(account: "first").filter { $0.recordType == "ScenarioSubscription" }.map(\.recordID.recordName))
        #expect(names == [subscriptionRecordName("s1"), subscriptionRecordName("s2")])
        #expect(server.events(of: "A", .modifyRecords).dropFirst(savesBefore).allSatisfy { $0.deletedNames.isEmpty })
        device.terminate()
    }
}
