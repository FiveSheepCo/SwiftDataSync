import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
@testable import SwiftDataSync

/// Scenarios of the fifth review: catch-ups that keep failing, uploads that keep deferring records, and deletions that
/// delete rules cascade to.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct FifthReviewScenarioTests {

    // MARK: Catching Up

    /// A record keeps failing to download while catching up. Later tries only upload the values of the records the earlier
    /// ones couldn't store, and catching up ends after a few tries, rather than every hour.
    @Test func catchUpThatKeepsFailingEndsAfterAFewTries() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        let withoutNotes = SDSConfiguration(swiftDataEntities: [
            .init(entity: ScenarioSubscription.self, description: .sync(.without(["note"]), identity: ["feedLink"])),
            .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
            .init(entity: ScenarioNote.self, description: .sync(.without([]))),
            .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
            .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
        ])
        try await device.launch(configuration: withoutNotes)
        try device.insertSubscriptions(["s1", "s2"])
        try device.editSubscription("s1") { $0.note = "Older" }
        try device.editSubscription("s2") { $0.note = "Only here" }
        await device.sync()
        server.seed([subscriptionRecord("s1", title: "Title of s1", note: "From another device")], account: "first")
        await device.sync()
        device.terminate()

        server.failDownloading(where: { $0.recordName == subscriptionRecordName("s1") }, with: CKError(.assetFileNotFound))
        try await device.launch()
        await device.sync()
        #expect(device.synchronizer.pendingCatchUp != nil)
        #expect(device.serverSubscriptions().first { $0.feedLink == "s2" }?.note == "Only here")

        // The next try, e.g. an hour later
        let savesBefore = server.events(of: "A", .modifyRecords).count
        device.synchronizer.postponeCatchUp(until: .distantPast)
        await device.sync()
        let savedNames = server.events(of: "A", .modifyRecords).dropFirst(savesBefore).flatMap(\.savedKeys.keys)
        #expect(!savedNames.contains(subscriptionRecordName("s2")))
        #expect(device.synchronizer.pendingCatchUp != nil)

        device.synchronizer.postponeCatchUp(until: .distantPast)
        await device.sync()
        #expect(device.synchronizer.pendingCatchUp == nil)
        #expect(device.serverSubscriptions().first { $0.feedLink == "s1" }?.note == "From another device")
        device.terminate()

        // Done for good, also after a relaunch
        try await device.launch()
        #expect(device.synchronizer.pendingCatchUp == nil)
        device.terminate()
    }

    // MARK: Uploading

    /// A record still waits for the record it references when the round was selected as often as it is. The round is
    /// selected again, rather than the upload ending as if nothing was left.
    @Test func recordsDeferredInEverySelectionAreSelectedAgain() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        device.timing.maximumSelectionPasses = 1
        try await device.launch()
        try device.change { $0.insert(ScenarioDocument(title: "Document")) }
        await device.sync()

        try device.changeInAnotherProcess { $0.insert(ScenarioWorkspace(title: "From an extension")) }
        try device.change { context in
            let workspace = try #require(try context.fetch(FetchDescriptor<ScenarioWorkspace>()).first)
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            document.workspace = workspace
        }
        // Only the synchronization after the save, which has to upload both
        await device.settle()

        let workspace = try #require(server.records(account: "first").first { $0.recordType == "ScenarioWorkspace" })
        #expect(server.record(named: documentRecordName("Document"), account: "first")?.parent?.recordID == workspace.recordID)
        #expect(server.events(of: "A", .modifyRecords).allSatisfy { !$0.failed })
        #expect(await device.state.error == nil)
        device.terminate()
    }

    // MARK: Recording Changes

    /// Deleting a workspace deletes its documents by its delete rule. Both deletions are uploaded.
    @Test func deletionsADeleteRuleCascadesToAreUploaded() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "Workspace")
            context.insert(workspace)
            let document = ScenarioDocument(title: "Document")
            context.insert(document)
            document.workspace = workspace
        }
        await device.sync()
        #expect(server.record(named: documentRecordName("Document"), account: "first") != nil)

        try device.change { context in
            try context.fetch(FetchDescriptor<ScenarioWorkspace>()).forEach(context.delete)
        }
        await device.sync()

        #expect(server.records(account: "first").filter { ["ScenarioWorkspace", "ScenarioDocument"].contains($0.recordType) }.isEmpty)
        device.terminate()
    }
}
