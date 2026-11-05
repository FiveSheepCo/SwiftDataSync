import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// The scenarios of a third independent review of the natural keys and backfill.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct ThirdIndependentReviewTests {

    /// An app observes saves after the synchronizer was set up, and stamps the subscriptions being saved. The stamp is saved
    /// with the edit, so it's uploaded too, rather than reverted by the next download.
    @Test func valueAnObserverSetsWhileSavingIsUploaded() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.insertSubscriptions(["s1"])
        await device.sync()

        let observedStore = device.synchronizer.observedStore
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: nil, queue: nil) { notification in
            guard let context = notification.object as? NSManagedObjectContext, context.persistentStoreCoordinator == observedStore else { return }
            for object in context.updatedObjects where object.entity.name == "ScenarioSubscription" {
                object.setValue("Stamped", forKey: "note")
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try device.editSubscription("s1") { $0.title = "Edited" }
        NotificationCenter.default.removeObserver(observer)
        await device.sync()
        await device.sync()

        #expect(try device.subscription("s1")?.note == "Stamped")
        #expect(device.serverSubscriptions().first?.note == "Stamped")
        #expect(device.serverSubscriptions().first?.title == "Edited")
        device.terminate()
    }

    private func tagNames(_ device: TestDevice) throws -> [String] {
        let context = ModelContext(try #require(device.modelContainer))
        return try context.fetch(FetchDescriptor<ScenarioTag>()).map(\.name).sorted()
    }

    private func serverTagNames(_ server: FakeCloudServer) -> [String] {
        server.records(account: "first").filter { $0.recordType == "ScenarioTag" }.compactMap { $0["name"] as? String }.sorted()
    }

    /// Device B renames a tag whose name is unique, and creates a new tag with the old name. Device A downloads both, in
    /// either order. Neither is taken for a duplicate of the other, which would delete the renamed tag everywhere, or never
    /// give A the new one.
    @Test(arguments: [false, true]) func renamedUniqueValueUsedAgainKeepsBothTags(newRecordFirst: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.change { $0.insert(ScenarioTag(name: "work", color: "red")) }
        await a.sync()
        await b.sync()

        try b.change { context in
            try #require(try context.fetch(FetchDescriptor<ScenarioTag>()).first).name = "job"
        }
        if !newRecordFirst {
            await b.sync()
        }
        try b.change { $0.insert(ScenarioTag(name: "work", color: "blue")) }
        await b.sync()
        if newRecordFirst {
            // The renamed tag changes again, so its record comes after the new one
            try b.change { context in
                try #require(try context.fetch(FetchDescriptor<ScenarioTag>(predicate: #Predicate { $0.name == "job" })).first).color = "green"
            }
            await b.sync()
        }

        for _ in 0..<3 {
            await a.sync()
            await b.sync()
        }
        #expect(serverTagNames(server) == ["job", "work"])
        #expect(try tagNames(a) == ["job", "work"])
        #expect(try tagNames(b) == ["job", "work"])
        a.terminate()
        b.terminate()
    }

    /// Tags identified by their name and color, whose name is unique.
    private static let identifiedTags = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink"])),
        .init(entity: ScenarioTag.self, description: .sync(.without([]), identity: ["name", "color"]))
    ])

    /// Two devices create a tag of the same unique name, whose identities differ, so both records are named after their
    /// identities. Both devices keep the same one, rather than each the other's, which would delete both.
    @Test func duplicatesNamedAfterTheirIdentitiesKeepOne() async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch(configuration: Self.identifiedTags)
        try await b.launch(configuration: Self.identifiedTags)
        try a.change { $0.insert(ScenarioTag(name: "swift", color: "red")) }
        await a.sync()
        try b.change { $0.insert(ScenarioTag(name: "swift", color: "blue")) }
        server.failNextFetch(with: CKError(.networkFailure))
        await b.settle()

        // A's upload fails once, so both devices download the other's record before either removes its own
        server.failNextModify(with: CKError(.networkFailure))
        await a.sync()
        for _ in 0..<3 {
            await b.sync()
            await a.sync()
        }
        #expect(serverTagNames(server) == ["swift"])
        #expect(try a.count(ScenarioTag.self) == 1)
        #expect(try b.count(ScenarioTag.self) == 1)
        a.terminate()
        b.terminate()
    }

    /// Devices X and Y create the same tag, whose name is unique, before they synchronize with each other. Device C, which
    /// had X's record, downloads Y's, which is kept, and deletes X's. X downloads that deletion before Y's record, which
    /// changed since. X's tag is given Y's record, rather than deleted and inserted again, which would lose what isn't
    /// synchronized, and its children.
    @Test func duplicateDeletedElsewhereKeepsTheLocalObject() async throws {
        for _ in 0..<20 {
            let server = FakeCloudServer()
            server.freshRecordsConflict = false
            let x = TestDevice("X", server: server)
            let y = TestDevice("Y", server: server)
            let c = TestDevice("C", server: server)
            try await x.launch()
            try await y.launch()
            try x.change { $0.insert(ScenarioTag(name: "swift", color: "red")) }
            await x.sync()
            let xName = try #require(server.records(account: "first").first { $0.recordType == "ScenarioTag" }).recordID.recordName
            try await c.launch()
            await c.sync()
            try y.change { $0.insert(ScenarioTag(name: "swift", color: "blue")) }
            server.failNextFetch(with: CKError(.networkFailure))
            await y.settle()
            // Y's record has to be the one that's kept. Y has none if another device's download took the failure.
            guard
                let yName = server.records(account: "first").first(where: { $0.recordType == "ScenarioTag" && $0.recordID.recordName != xName })?.recordID.recordName,
                yName < xName
            else {
                x.terminate()
                y.terminate()
                c.terminate()
                continue
            }

            await c.sync()
            #expect(server.record(named: xName, account: "first") == nil)
            let before = try ModelContext(#require(x.modelContainer)).fetch(FetchDescriptor<ScenarioTag>()).first?.persistentModelID
            try y.change { try #require(try $0.fetch(FetchDescriptor<ScenarioTag>()).first).color = "edited on Y" }
            await y.settle()
            await x.sync()

            let tags = try ModelContext(#require(x.modelContainer)).fetch(FetchDescriptor<ScenarioTag>())
            #expect(tags.map(\.persistentModelID) == [before])
            #expect(tags.map(\.color) == ["edited on Y"])
            #expect(serverTagNames(server) == ["swift"])
            x.terminate()
            y.terminate()
            c.terminate()
            return
        }
        Issue.record("Y's record never got the name that's kept")
    }

    /// Subscriptions before the app gave them an identity, and afterwards.
    private static let withoutIdentity = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without([])))
    ])
    private static let withIdentity = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink"]))
    ])

    /// Device A uploaded a subscription before subscriptions had an identity, so its record isn't named after it. Device C,
    /// with the version that has identities, has the same subscription from before it synchronized for the first time. C's
    /// values, which are of unknown age, don't become a record of their own, which A would take over its edit.
    @Test func recordFromBeforeIdentitiesWinsOverBackfilledValues() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch(configuration: Self.withoutIdentity)
        try a.insertSubscriptions(["s1"], title: { _ in "Edited on A" })
        await a.sync()
        a.terminate()
        try await a.launch(configuration: Self.withIdentity)
        await a.sync()

        let c = TestDevice("C", server: server)
        try c.change { $0.insert(ScenarioSubscription(feedLink: "s1", title: "Old on C")) }
        try await c.launch(configuration: Self.withIdentity)
        for _ in 0..<3 {
            await c.sync()
            await a.sync()
        }

        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioSubscription" }.map { $0["title"] as? String } == ["Edited on A"])
        #expect(try c.subscriptions().map(\.title) == ["Edited on A"])
        #expect(try a.subscriptions().map(\.title) == ["Edited on A"])
        a.terminate()
        c.terminate()
    }

    /// Workspaces are sharable, documents are below them.
    private static let sharableConfiguration = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink"])),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]), isSharable: true)),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace"))
    ])

    /// A workspace saved before synchronizing started, whose backfilled values weren't uploaded yet, is shared. Saving the
    /// share creates its record without values, and the backfilled values are still uploaded to it, rather than dropped as
    /// the record exists. The fake server can't save shares, so sharing fails after the root record was saved.
    @Test func sharingAModelWithBackfilledValuesKeepsThem() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch(configuration: Self.sharableConfiguration)
        await device.sync()
        device.terminate()
        try device.changeInAnotherProcess { $0.insert(ScenarioWorkspace(title: "Groceries")) }
        server.failNextModify(with: CKError(.networkFailure))
        try await device.launch(configuration: Self.sharableConfiguration)
        await device.settle()

        let synchronizer = try #require(device.synchronizer)
        let observed = try #require(synchronizer.observedUpdateContext)
        let workspace = try observed.performAndWait {
            try #require(try observed.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioWorkspace")).first)
        }
        _ = try? await synchronizer.share(title: "Groceries", imageData: nil, object: workspace)
        await device.sync()
        await device.sync()

        let b = TestDevice("B", server: server)
        try await b.launch(configuration: Self.sharableConfiguration)
        await b.sync()
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioWorkspace" }.map { $0["title"] as? String } == ["Groceries"])
        #expect(try ModelContext(#require(b.modelContainer)).fetch(FetchDescriptor<ScenarioWorkspace>()).map(\.title) == ["Groceries"])
        device.terminate()
        b.terminate()
    }

    /// Moves a document to a new workspace and deletes its previous one, in one save.
    private func moveDocumentAndDeleteItsWorkspace(on device: TestDevice) throws {
        try device.change { context in
            let old = try #require(try context.fetch(FetchDescriptor<ScenarioWorkspace>()).first)
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            let new = ScenarioWorkspace(title: "W2")
            context.insert(new)
            document.workspace = new
            context.delete(old)
        }
    }

    private func insertDocumentInAWorkspace(on device: TestDevice) throws {
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "W1")
            context.insert(workspace)
            let document = ScenarioDocument(title: "D")
            context.insert(document)
            document.workspace = workspace
        }
    }

    /// A document is moved to a new workspace, and its previous workspace deleted. CloudKit rejects the document's record
    /// for now. The previous workspace's removal waits for it, as the document's record still references the workspace as
    /// its parent, which CloudKit would delete it with.
    @Test func removalWaitsForARejectedRecordThatReferencesIt() async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try insertDocumentInAWorkspace(on: a)
        await a.sync()
        await b.sync()

        server.failSaving(where: { $0.recordName == documentRecordName("D") }, with: CKError(.invalidArguments), count: 1)
        try moveDocumentAndDeleteItsWorkspace(on: a)
        await a.settle()
        await b.sync()
        #expect(try b.count(ScenarioDocument.self) == 1)

        // The rejected record is uploaded again once it changes
        try a.change { try #require(try $0.fetch(FetchDescriptor<ScenarioDocument>()).first).body = "Edited" }
        await a.sync()
        await b.sync()
        #expect(try a.count(ScenarioDocument.self) == 1)
        #expect(try b.count(ScenarioDocument.self) == 1)
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioWorkspace" }.map { $0["title"] as? String } == ["W2"])
        a.terminate()
        b.terminate()
    }

    /// Like above, but iCloud is full, so only removals are uploaded. The previous workspace's waits for the document.
    @Test func removalWaitsWhileICloudIsFullForARecordThatReferencesIt() async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server)
        try await a.launch()
        try insertDocumentInAWorkspace(on: a)
        await a.sync()

        server.failNextModify(with: CKError(.quotaExceeded))
        try moveDocumentAndDeleteItsWorkspace(on: a)
        await a.settle()
        await a.sync()
        await a.sync()
        #expect(try a.count(ScenarioDocument.self) == 1)
        #expect(server.records(account: "first").filter { $0.recordType == "ScenarioDocument" }.count == 1)
        a.terminate()
    }

    /// Device B renames a subscription. Device A renames it too, while saving the page with B's rename, either before the
    /// download looks for local changes, or right after. A's rename wins, as it's later, rather than being overwritten with
    /// B's, which A would then upload.
    @Test(arguments: [false, true]) func editSavedWhileAPageIsSavedWins(afterLookingForLocalChanges: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()
        try await b.launch()
        await b.sync()
        try b.editSubscription("s1") { $0.title = "B" }
        await b.sync()

        let isDone = OSAllocatedUnfairLock(initialState: false)
        let edit: @Sendable () -> Void = { [a] in
            guard isDone.withLock({ done in defer { done = true }; return !done }) else { return }
            try? a.editSubscription("s1") { $0.title = "A later" }
        }
        if afterLookingForLocalChanges {
            a.synchronizer.beforeSavingDownloadedObjects = edit
        } else {
            a.synchronizer.afterSavingDownloadedRecords = edit
        }
        await a.sync()
        await a.settle()
        await a.sync()
        await b.sync()

        #expect(isDone.withLock { $0 })
        #expect(try a.subscription("s1")?.title == "A later")
        #expect(a.serverSubscriptions().map(\.title) == ["A later"])
        #expect(try b.subscription("s1")?.title == "A later")
        a.terminate()
        b.terminate()
    }

    /// Documents only synchronize their title and body, so the workspace's unordered `documents` is the side that's
    /// synchronized, which uploads leave out. Downloading the workspace's record doesn't take that for an empty relationship.
    @Test func unorderedRelationshipIsNotClearedByDownloads() async throws {
        let configuration = SDSConfiguration(swiftDataEntities: [
            .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink"])),
            .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
            .init(entity: ScenarioDocument.self, description: .sync(.with(["title", "body"])))
        ])
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch(configuration: configuration)
        try insertDocumentInAWorkspace(on: a)
        await a.sync()
        try a.change { try #require(try $0.fetch(FetchDescriptor<ScenarioWorkspace>()).first).title = "W2" }
        await a.sync()
        await a.sync()

        let documents = try ModelContext(#require(a.modelContainer)).fetch(FetchDescriptor<ScenarioDocument>())
        #expect(documents.map { $0.workspace?.title } == ["W2"])
        a.terminate()
    }

    /// A version that doesn't synchronize notes.
    private static let withoutNotes = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without(["note"]), identity: ["feedLink"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    /// Device B updates to a version that synchronizes notes, which another device synchronized already, and catches up on
    /// them. The other device changes a note while B catches up. B doesn't upload the note it downloaded over the newer one.
    @Test func catchUpDoesNotUploadTheValuesItDownloaded() async throws {
        let server = FakeCloudServer()
        server.seed([subscriptionRecord("s1", title: "Title of s1", note: "From A")], account: "first")
        let b = TestDevice("B", server: server)
        try await b.launch(configuration: Self.withoutNotes)
        await b.sync()
        b.terminate()

        // Right after the catch-up's page
        let pages = OSAllocatedUnfairLock(initialState: 0)
        server.pageDelivered = { device, _ in
            guard device == "B", pages.withLock({ $0 += 1; return $0 }) == 1 else { return }
            server.seed([subscriptionRecord("s1", title: "Title of s1", note: "Newer from A")], account: "first")
        }
        try await b.launch()
        await b.sync()
        server.pageDelivered = nil
        await b.sync()

        #expect(b.serverSubscriptions().first?.note == "Newer from A")
        #expect(try b.subscription("s1")?.note == "Newer from A")
        b.terminate()
    }

    /// A version of the app stops synchronizing notes for a while, and a later one synchronizes them again. The later one
    /// catches up on what another device changed meanwhile, which the version in between skipped.
    @Test func keyThatWasSkippedForAWhileIsCaughtUpOn() async throws {
        let server = FakeCloudServer()
        let b = TestDevice("B", server: server)
        try await b.launch()
        try b.insertSubscriptions(["s1"])
        try b.editSubscription("s1") { $0.note = "First" }
        await b.sync()
        b.terminate()

        try await b.launch(configuration: Self.withoutNotes)
        server.seed([subscriptionRecord("s1", title: "Title of s1", note: "Changed elsewhere")], account: "first")
        await b.sync()
        b.terminate()

        try await b.launch()
        await b.sync()
        #expect(try b.subscription("s1")?.note == "Changed elsewhere")
        #expect(b.serverSubscriptions().first?.note == "Changed elsewhere")
        b.terminate()
    }

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

    /// Device B's extension, which synchronizes less, downloads with the app's synchronization data while another device
    /// changes a subscription's note, adds a note, and deletes another. B's app gets what the extension skipped.
    @Test func appGetsWhatAnExtensionSkipped() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        try a.change { $0.insert(ScenarioNote(text: "gone")) }
        await a.sync()
        try await b.launch()
        await b.sync()
        #expect(try b.notes() == ["gone"])
        b.terminate()

        try a.editSubscription("s1") { $0.note = "N"; $0.title = "T2" }
        try a.change { context in
            context.insert(ScenarioNote(text: "n1"))
            try context.fetch(FetchDescriptor<ScenarioNote>(predicate: #Predicate { $0.text == "gone" })).forEach(context.delete)
        }
        await a.sync()

        b.beforeSetup = { $0.isAppExtension = true }
        try await b.launch(configuration: Self.extensionConfiguration)
        await b.sync()
        b.terminate()
        b.beforeSetup = nil
        try await b.launch()
        await b.sync()

        #expect(try b.subscription("s1")?.title == "T2")
        #expect(try b.subscription("s1")?.note == "N")
        #expect(try b.notes() == ["n1"])
        a.terminate()
        b.terminate()
    }
}

