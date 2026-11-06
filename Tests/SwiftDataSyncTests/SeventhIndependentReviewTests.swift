import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
@testable import SwiftDataSync

/// The scenarios of a seventh independent review of the natural keys and backfill.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct SeventhIndependentReviewTests {

    /// A version that doesn't synchronize notes.
    private static let withoutNotes = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without(["note"]), identity: ["feedLink"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    /// An extension that doesn't synchronize notes, neither the model nor the subscriptions' key.
    private static let extensionConfiguration = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without(["note"]), identity: ["feedLink"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .noSync),
        .init(entity: ScenarioLink.self, description: .sync(.without([]))),
        .init(entity: ScenarioTag.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    private func insertDocumentInWorkspace(_ device: TestDevice) throws {
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "W")
            context.insert(workspace)
            let document = ScenarioDocument(title: "D")
            context.insert(document)
            document.workspace = workspace
        }
    }

    private func workspacesOfDocuments(_ device: TestDevice) throws -> [String?] {
        try ModelContext(#require(device.modelContainer)).fetch(FetchDescriptor<ScenarioDocument>()).map { $0.workspace?.title }
    }

    /// Device B updates to a version that synchronizes notes, and catches up on a note too large for its record, which keeps
    /// it in an asset under a key that isn't a property. The catch-up doesn't stop at that key, and B gets the note.
    @Test func catchUpDownloadsLargeValues() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        let note = String(repeating: "Large note. ", count: 30_000)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        try a.editSubscription("s1") { $0.note = note }
        await a.sync()
        try await b.launch(configuration: Self.withoutNotes)
        await b.sync()
        b.terminate()

        try await b.launch()
        await b.sync()
        #expect(try b.subscription("s1")?.note == note)
        a.terminate()
        b.terminate()
    }

    /// An extension that synchronizes less than the app downloads a record with a parent, which keeps it in a key that isn't
    /// a property. It doesn't stop at that key, and the app gets the record.
    @Test func extensionDownloadsRecordsWithAParent() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        await a.sync()
        try await b.launch()
        await b.sync()
        b.terminate()

        try insertDocumentInWorkspace(a)
        await a.sync()

        b.beforeSetup = { $0.isAppExtension = true }
        try await b.launch(configuration: Self.extensionConfiguration)
        await b.sync()
        b.terminate()
        b.beforeSetup = nil
        try await b.launch()
        await b.sync()

        #expect(try workspacesOfDocuments(b) == ["W"])
        a.terminate()
        b.terminate()
    }
}
