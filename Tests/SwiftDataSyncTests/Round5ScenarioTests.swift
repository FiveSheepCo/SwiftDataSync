import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

private func fetchSub(_ context: ModelContext, _ feedLink: String) throws -> ScenarioSubscription? {
    try context.fetch(FetchDescriptor<ScenarioSubscription>(predicate: #Predicate { $0.feedLink == feedLink })).first
}

private func fetchNote(_ context: ModelContext, prefix: String) throws -> ScenarioNote? {
    try context.fetch(FetchDescriptor<ScenarioNote>()).first { $0.text.hasPrefix(prefix) }
}

private func fetchTag(_ context: ModelContext, _ name: String) throws -> ScenarioTag? {
    try context.fetch(FetchDescriptor<ScenarioTag>(predicate: #Predicate { $0.name == name })).first
}

private func fetchLink(_ context: ModelContext, _ name: String) throws -> ScenarioLink? {
    try context.fetch(FetchDescriptor<ScenarioLink>(predicate: #Predicate { $0.name == name })).first
}

private func fetchWorkspace(_ context: ModelContext, _ title: String) throws -> ScenarioWorkspace? {
    try context.fetch(FetchDescriptor<ScenarioWorkspace>(predicate: #Predicate { $0.title == title })).first
}

private func fetchDocument(_ context: ModelContext, _ title: String) throws -> ScenarioDocument? {
    try context.fetch(FetchDescriptor<ScenarioDocument>(predicate: #Predicate { $0.title == title })).first
}

/// Keeps the main actor busy in bursts, like an app's UI work or other tests under load.
final class MainActorHog: @unchecked Sendable {
    private var task: Task<Void, Never>?
    init(burst: TimeInterval = 0.08, pause: Duration = .milliseconds(5)) {
        guard ProcessInfo.processInfo.environment["NO_HOG"] == nil else { return }
        task = Task.detached {
            while !Task.isCancelled {
                await MainActor.run { Thread.sleep(forTimeInterval: burst) }
                try? await Task.sleep(for: pause)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

extension TestDevice {
    /// Like `settle()`, but also waits while a synchronization has claimed the synchronizer but not yet shown its state,
    /// which `settle()` takes for idle.
    func settleStrictly() async {
        var idleChecks = 0
        for _ in 0..<6000 {
            var isBusy = synchronizer.hasPendingSaveSync || synchronizer.isSynchronizing
            if !isBusy {
                switch await viewModel.state {
                case .bootstrapping, .uploading, .downloading, .processingSaveEvent, .waitingForSetup, .waitingForContainerDetection: isBusy = true
                default: isBusy = false
                }
            }
            idleChecks = isBusy ? 0 : idleChecks + 1
            if idleChecks >= 3 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("\(name) didn't finish synchronizing")
    }

    func syncStrictly() async {
        await settleStrictly()
        await synchronizer.synchronize()
        await settleStrictly()
    }
}

/// Round 5 scenarios, aimed at the mechanisms of the latest commits.
@Suite(.coreDataReady, .adversarial, .serialized, .timeLimit(.minutes(6)))
struct Round5ScenarioTests {

    // MARK: Overflow assets with records read without their values

    /// CloudKit returns only system fields for `desiredKeys: []`. An edit of an existing record is merged into such a record
    /// before its large values are placed, and an asset placed over it mustn't lose the values already in it.
    @Test(arguments: [false, true]) func largeEditKeepsTheOtherLargeValuesInTheAsset(otherDevice: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync(); await b.sync()

        let artwork = Data(repeating: 7, count: 300_000)
        try a.editSubscription("s1") { $0.artwork = artwork }
        await a.sync(); await b.sync()

        let note = String(repeating: "n", count: 300_000)
        let editor = otherDevice ? b : a
        try editor.editSubscription("s1") { $0.note = note }
        await editor.sync()
        await a.sync(); await b.sync()

        let server1 = server.snapshot(account: "first")
        #expect(server1.subscriptions.first?.contains(shortHash(artwork)) == true, "artwork lost on the server: \(server1.subscriptions)")
        for device in [a, b] {
            #expect(try device.subscription("s1")?.artwork == artwork, "\(device.name) lost the artwork")
            #expect(try device.subscription("s1")?.note == note, "\(device.name) lost the note")
        }
        a.terminate(); b.terminate()
    }

    /// Clearing a large value that's in the asset, with an edit merged into a record without values.
    @Test func clearingALargeValueKeepsTheOthers() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(["s1"])
        let artwork = Data(repeating: 7, count: 300_000)
        let note = String(repeating: "n", count: 300_000)
        try a.editSubscription("s1") { $0.artwork = artwork; $0.note = note }
        await a.sync(); await b.sync()

        try b.editSubscription("s1") { $0.note = nil }
        await b.sync(); await a.sync()
        for device in [a, b] {
            #expect(try device.subscription("s1")?.artwork == artwork, "\(device.name) lost the artwork")
            #expect(try device.subscription("s1")?.note == nil, "\(device.name) kept the note")
        }
        _ = try await assertConverged([a, b])
        a.terminate(); b.terminate()
    }

    // MARK: Zone deleted and created again before a device notices

    /// Another device deletes the zone, and a third creates it again before A downloads, so A's change token belongs to
    /// the zone that's gone (expired). A had a model nobody else downloaded yet. It must not be left only on A.
    @Test func zoneCreatedAgainBeforeADeviceNotices() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(["s1", "s2"])
        await a.sync(); await b.sync()
        b.synchronizer.stop()

        // B hasn't downloaded s3 yet when the zone goes
        try a.insertSubscriptions(["s3"])
        await a.sync()
        server.deleteZone(account: "first", byUser: false)
        b.synchronizer.start()
        await b.sync()
        await b.sync()
        #expect(server.hasZone(account: "first"))

        await a.sync()
        await a.sync()
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.subscriptionKeys == ["s1", "s2", "s3"], "\(snapshot.subscriptions)")
        a.terminate(); b.terminate()
    }

    // MARK: The two rare failures, with the main actor kept busy

    /// `ReviewScenarioTests.overflowRecordKeepsConcurrentEditsOfOtherKeys` while the main actor is busy.
    @Test(arguments: 0..<10) func overflowConcurrentEditsUnderMainActorLoad(run: Int) async throws {
        let strict = ProcessInfo.processInfo.environment["STRICT_SETTLE"] != nil
        let hog = MainActorHog()
        defer { hog.stop() }
        let server = FakeCloudServer()
        let first = TestDevice("A", server: server)
        let second = TestDevice("B", server: server)
        try await first.launch()
        try first.insertSubscriptions(["s1"])
        try first.editSubscription("s1") {
            $0.artwork = Data(count: 1_500_000)
            $0.note = "Note"
        }
        if strict { await first.syncStrictly() } else { await first.sync() }
        try await second.launch()

        let hookRan = OSAllocatedUnfairLock(initialState: false)
        server.beforeModifyRecords = { [server] device, names in
            guard device == "A", names.contains(subscriptionRecordName("s1")) else { return }
            server.beforeModifyRecords = nil
            hookRan.withLock { $0 = true }
            let record = server.record(named: subscriptionRecordName("s1"), account: "first")!
            let copy = CKRecord(recordType: record.recordType, recordID: record.recordID)
            for key in record.allKeys() where !(record[key] is CKAsset) {
                copy[key] = record[key]
            }
            copy["note"] = "B's note"
            copy[SDSOverflow.key] = record[SDSOverflow.key]
            server.seed([copy], account: "first")
        }
        try first.editSubscription("s1") { $0.title = "A's title" }
        let before = first.synchronizer.startedSynchronizationCount
        if strict { await first.syncStrictly() } else { await first.sync() }
        let hookRanBeforeRead = hookRan.withLock { $0 }
        let values = try #require(first.serverSubscriptions().first)
        #expect(values.title == "A's title", "hook ran: \(hookRanBeforeRead), started syncs: \(first.synchronizer.startedSynchronizationCount - before), synchronizing: \(first.synchronizer.isSynchronizing)")
        #expect(values.note == "B's note")
        if values.title != "A's title" {
            // Whether it's only late
            await first.settleStrictly()
            print("LATE title \(first.serverSubscriptions().first?.title ?? "-") note \(first.serverSubscriptions().first?.note ?? "-") hook \(hookRan.withLock { $0 })")
        }
        first.terminate()
        second.terminate()
    }

    /// `SecondIndependentReviewTests.overflowAssetKeepsAnotherDevicesValues` while the main actor is busy.
    @Test(arguments: 0..<10) func overflowAssetUnderMainActorLoad(run: Int) async throws {
        let strict = ProcessInfo.processInfo.environment["STRICT_SETTLE"] != nil
        let hog = MainActorHog()
        defer { hog.stop() }
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try await b.launch()
        try a.insertSubscriptions(["s1"])
        if strict { await a.syncStrictly(); await b.syncStrictly() } else { await a.sync(); await b.sync() }

        let artwork = Data(repeating: 7, count: 300_000)
        try a.editSubscription("s1") { $0.artwork = artwork }
        if strict { await a.syncStrictly() } else { await a.sync() }

        let fetchFailedBy = OSAllocatedUnfairLock<[String]>(initialState: [])
        server.fetchFailed = { device, _ in fetchFailedBy.withLock { $0.append(device) } }
        server.failNextFetch(with: CKError(.networkFailure))
        let note = String(repeating: "n", count: 300_000)
        try b.editSubscription("s1") { $0.note = note }
        if strict { await b.settleStrictly() } else { await b.settle() }

        if strict { await a.syncStrictly(); await b.syncStrictly() } else { await a.sync(); await b.sync() }
        server.fetchFailed = nil
        for device in [a, b] {
            let values = try device.subscription("s1")
            #expect(values?.artwork == artwork, "\(device.name) artwork \(values?.artwork?.count ?? -1), fetch failed by \(fetchFailedBy.withLock { $0 })")
            #expect(values?.note == note, "\(device.name) note \(values?.note?.count ?? -1), fetch failed by \(fetchFailedBy.withLock { $0 })")
        }
        a.terminate()
        b.terminate()
    }

    // MARK: A parent deleted and created again with the same identity

    /// A puts a new link into s1 and uploads it after C deleted s1 locally, so the link's record stays in iCloud referencing
    /// s1 (the known dangling record). Then B creates s1 again. Every device, and a new one, must agree about the link.
    @Test(arguments: [false, true]) func parentCreatedAgainAfterADanglingChild(cSyncsBeforeRecreation: Bool) async throws {
        let server = FakeCloudServer()
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2"])
        await a.sync(); await b.sync(); await c.sync()
        c.synchronizer.stop()

        try a.change { context in
            let link = ScenarioLink(name: "l1")
            context.insert(link)
            link.subscription = try fetchSub(context, "s1")
        }
        try c.deleteSubscription("s1")
        await a.sync()
        c.synchronizer.start()
        await c.sync()
        await a.sync(); await b.sync()
        if cSyncsBeforeRecreation { await c.sync() }

        try b.change { $0.insert(ScenarioSubscription(feedLink: "s1", title: "s1 again")) }
        await b.sync(); await c.sync(); await a.sync()
        let snapshot = try await assertConverged([a, b, c])
        let d = TestDevice("D", server: server)
        try await d.launch()
        await d.sync()
        let dLinks = try d.snapshot().links
        #expect(dLinks == snapshot.links, "A new device shows other links: \(dLinks) vs \(snapshot.links), server \(server.snapshot(account: "first").links)")
        for device in [a, b, c] {
            let links = try device.snapshot().links
            #expect(links == dLinks, "\(device.name): \(links) vs D \(dLinks)")
        }
        a.terminate(); b.terminate(); c.terminate(); d.terminate()
    }

    // MARK: Rapid and failed saves during synchronizations

    /// While A uploads and downloads, the app saves again and again, in several contexts, and some saves fail with merge
    /// conflicts. B edits other keys meanwhile. A's saved edits are uploaded, its failed ones aren't, and B's values arrive.
    @Test(arguments: 0..<3) func rapidAndFailedSavesWhileSynchronizing(variant: Int) async throws {
        let server = FakeCloudServer()
        server.pageSize = 4
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        let feeds = (0..<12).map { "s\($0)" }
        try a.insertSubscriptions(feeds)
        await a.sync(); await b.sync()

        let coordinator = try #require(a.synchronizer.observedStore)
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let failedSaves = OSAllocatedUnfairLock(initialState: 0)
        @Sendable func saveBurst() {
            let n = counter.withLock { $0 += 1; return $0 }
            guard n <= 30 else { return }
            // A context that will fail: it reads the row, another context changes it, then it saves
            let failing = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            failing.persistentStoreCoordinator = coordinator
            failing.performAndWait {
                if let object = try? failing.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription")).first(where: { ($0.value(forKey: "feedLink") as? String) == "s\(n % 12)" }) {
                    object.setValue("never \(n)", forKey: "note")
                }
            }
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.performAndWait {
                let objects = (try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription"))) ?? []
                for object in objects where (object.value(forKey: "feedLink") as? String) == "s\(n % 12)" {
                    object.setValue(n, forKey: "position")
                    try? context.save()
                    object.setValue("A\(n)", forKey: "title")
                    try? context.save()
                }
            }
            failing.performAndWait {
                do { try failing.save() } catch { failing.rollback(); failedSaves.withLock { $0 += 1 } }
            }
        }
        switch variant {
        case 0: server.beforeModifyRecords = { device, _ in if device == "A" { saveBurst() } }
        case 1: a.synchronizer.afterSavingDownloadedObjects = { saveBurst() }
        default: server.pageDelivered = { device, _ in if device == "A" { saveBurst() } }
        }
        try b.change { context in for feed in feeds { try fetchSub(context, feed)?.isMuted = true } }
        await b.sync()
        try a.editSubscription("s0") { $0.rating = 5 }
        for _ in 0..<6 {
            try a.change { context in try fetchSub(context, "s1")?.rating = Double(counter.withLock { $0 }) }
            await a.sync()
            try b.change { context in try fetchSub(context, "s2")?.note = "B \(counter.withLock { $0 })" }
            await b.sync()
        }
        server.beforeModifyRecords = nil
        server.pageDelivered = nil
        a.synchronizer.afterSavingDownloadedObjects = nil
        let snapshot = try await assertConverged([a, b])
        #expect(!snapshot.subscriptions.contains { $0.contains("never") }, "A failed save was uploaded: \(snapshot.subscriptions)")
        #expect(snapshot.subscriptions.allSatisfy { $0.contains("|true|") }, "B's mute was lost: \(snapshot.subscriptions)")
        // The last title each subscription got on A
        let total = min(counter.withLock { $0 }, 30)
        for feed in 0..<12 {
            let last = (1...max(total, 1)).filter { $0 % 12 == feed && $0 <= total }.last
            if let last {
                #expect(snapshot.subscriptions.contains { $0.hasPrefix("s\(feed)|A\(last)|\(last)|") }, "s\(feed) should have A\(last): \(snapshot.subscriptions.filter { $0.hasPrefix("s\(feed)|") })")
            }
        }
        print("BURSTS \(counter.withLock { $0 }) failed \(failedSaves.withLock { $0 })")
        a.terminate(); b.terminate()
    }

    // MARK: Rejected records that moved models

    /// A moves a link from s1 to s2 and deletes s1 in one save, but CloudKit rejects the link's record. s1's removal waits, so
    /// B doesn't delete the link with s1. An unrelated removal still goes through.
    @Test func rejectedMoveHoldsBackOnlyItsPreviousParent() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2", "s3"])
        try a.change { context in
            let link = ScenarioLink(name: "l1")
            context.insert(link)
            link.subscription = try fetchSub(context, "s1")
            context.insert(ScenarioNote(text: "n1"))
        }
        await a.sync(); await b.sync(); await c.sync()
        let linkID = try #require(server.records(account: "first").first { $0.recordType == "ScenarioLink" }).recordID

        server.failSaving(where: { $0 == linkID }, with: CKError(.invalidArguments))
        try a.change { context in
            let link = try #require(try fetchLink(context, "l1"))
            link.subscription = try fetchSub(context, "s2")
            context.delete(try #require(try fetchSub(context, "s1")))
            if let note = try fetchNote(context, prefix: "n1") { context.delete(note) }
        }
        // C deletes s3 meanwhile, which is unrelated
        try c.deleteSubscription("s3")
        await c.sync()
        await a.sync(); await a.sync()
        await b.sync()
        let bLinks = try b.snapshot().links
        #expect(bLinks == ["l1|s1"], "B lost the link: \(bLinks)")
        #expect(b.serverNotes().isEmpty, "The unrelated removal waits too: \(b.serverNotes())")
        #expect(try b.count(ScenarioNote.self) == 0)
        #expect(!b.serverSubscriptions().contains { $0.feedLink == "s3" })
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: Resets with edits and deletions on other devices

    /// B deletes a note and edits others without uploading, then resets, while A deletes and edits, and C adds.
    @Test func resetWithLocalDeletionsWhileOthersChange() async throws {
        let server = FakeCloudServer()
        server.pageSize = 7
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(feedLinks(1...12))
        try a.change { context in for i in 1...12 { context.insert(ScenarioNote(text: "n\(i):0")) } }
        try a.change { context in
            let w = ScenarioWorkspace(title: "w1"); context.insert(w)
            for i in 1...4 { let d = ScenarioDocument(title: "d\(i)"); context.insert(d); d.workspace = w }
        }
        await a.sync(); await b.sync(); await c.sync()

        b.synchronizer.stop()
        try b.change { context in
            if let note = try fetchNote(context, prefix: "n3:") { context.delete(note) }
            try fetchNote(context, prefix: "n4:")?.text = "n4:B"
            if let doc = try fetchDocument(context, "d1") { context.delete(doc) }
            try fetchSub(context, feedLinks(1...1)[0])?.title = "B title"
            context.insert(ScenarioNote(text: "n13:B"))
        }
        try a.change { context in
            if let note = try fetchNote(context, prefix: "n5:") { context.delete(note) }
            try fetchNote(context, prefix: "n4:")?.text = "n4:A"
            if let s = try fetchSub(context, feedLinks(2...2)[0]) { context.delete(s) }
            try fetchDocument(context, "d2")?.body = "A body"
        }
        await a.sync()
        try await b.synchronizer.resetSyncData()
        try c.change { context in
            context.insert(ScenarioNote(text: "n14:C"))
            try fetchNote(context, prefix: "n6:")?.text = "n6:C"
        }
        await c.sync()
        b.synchronizer.start()
        await b.settle()
        await b.sync()
        let snapshot = try await assertConverged([a, b, c])
        print("RESET5 notes \(snapshot.notes) docs \(snapshot.documents)")
        #expect(snapshot.notes.filter { $0.hasPrefix("n13:") }.count == 1)
        #expect(snapshot.notes.filter { $0.hasPrefix("n14:") }.count == 1)
        #expect(!snapshot.notes.contains { $0.hasPrefix("n5:") }, "A's deletion came back")
        #expect(!snapshot.subscriptionKeys.contains(feedLinks(2...2)[0]), "A's deletion came back")
        #expect(snapshot.notes.filter { $0.hasPrefix("n4:") }.count == 1)
        let n3Kept = snapshot.notes.contains { $0.hasPrefix("n3:") }
        let expectedNotes = n3Kept ? 13 : 12
        #expect(snapshot.notes.count == expectedNotes, "\(snapshot.notes)")
        // Observations, not requirements: whether B's local deletions survived the reset
        print("RESET5 n3 kept: \(snapshot.notes.contains { $0.hasPrefix("n3:") }) d1 kept: \(snapshot.documentKeys.contains("d1")) sub1: \(snapshot.subscriptions.first { $0.hasPrefix(feedLinks(1...1)[0] + "|") } ?? "-")")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: Extensions skipping many records

    private static let extensionConfiguration = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without(["note"]), identity: ["feedLink"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioNote.self, description: .noSync),
        .init(entity: ScenarioLink.self, description: .sync(.without([]))),
        .init(entity: ScenarioTag.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    /// B's extension downloads while A adds 450 notes, deletes and edits others, and edits notes of subscriptions the
    /// extension doesn't synchronize. Then B's app runs, and must end with exactly A's data.
    @Test(arguments: [false, true]) func extensionSkipsManyRecordsWithEditsAndDeletions(extensionTwice: Bool) async throws {
        let server = FakeCloudServer()
        server.pageSize = 50
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(feedLinks(1...20))
        try a.change { context in for i in 0..<60 { context.insert(ScenarioNote(text: "old\(i)")) } }
        await a.sync(); await b.sync()
        b.terminate()

        try a.change { context in
            for i in 0..<450 { context.insert(ScenarioNote(text: "new\(i)")) }
            for note in try context.fetch(FetchDescriptor<ScenarioNote>()) where note.text.hasPrefix("old") {
                let i = Int(note.text.dropFirst(3))!
                if i % 3 == 0 { context.delete(note) } else if i % 3 == 1 { note.text = "old\(i) edited" }
            }
            for i in 1...20 { try fetchSub(context, feedLinks(i...i)[0])?.note = "note \(i)" }
            for i in 1...5 { try fetchSub(context, feedLinks(i...i)[0])?.title = "A title \(i)" }
        }
        await a.sync()

        b.beforeSetup = { $0.isAppExtension = true }
        try await b.launch(configuration: Self.extensionConfiguration)
        await b.sync()
        if extensionTwice {
            try a.change { context in
                for note in try context.fetch(FetchDescriptor<ScenarioNote>()) where note.text.hasPrefix("new1") { context.delete(note) }
                try fetchSub(context, feedLinks(6...6)[0])?.note = "second"
            }
            await a.sync()
            b.terminate()
            try await b.launch(configuration: Self.extensionConfiguration)
            await b.sync()
        }
        b.terminate()
        b.beforeSetup = nil
        try await b.launch()
        await b.sync()
        _ = try await assertConverged([a, b])
        a.terminate(); b.terminate()
    }

    // MARK: Identity moves racing deletions

    /// A moves s1 to s1x while B deletes s1, and C edits s1. Links follow. Every order of uploads.
    @Test(arguments: 0..<6) func identityMoveRacesDeletion(order: Int) async throws {
        let server = FakeCloudServer()
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2"])
        try a.change { context in
            let link = ScenarioLink(name: "l1")
            context.insert(link)
            link.subscription = try fetchSub(context, "s1")
        }
        await a.sync(); await b.sync(); await c.sync()
        for device in [a, b, c] { device.synchronizer.stop() }

        try a.editSubscription("s1") { $0.feedLink = "s1x"; $0.title = "moved by A" }
        try b.deleteSubscription("s1")
        try c.editSubscription("s1") { $0.position = 77 }
        let orders = [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
        for device in orders[order] {
            device.synchronizer.start()
            await device.sync()
        }
        let snapshot = try await assertConverged([a, b, c])
        print("IDMOVE order \(order): subs \(snapshot.subscriptionKeys) links \(snapshot.links)")
        #expect(snapshot.subscriptionKeys.contains("s2"))
        #expect(!snapshot.subscriptionKeys.contains("s1") || order >= 4, "\(snapshot.subscriptions)")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: Unique constraints racing deletions

    /// A upserts tag red, B deletes it, C renames it to blue and creates red again. Every order.
    @Test(arguments: 0..<6) func uniqueValueRacesDeletion(order: Int) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.change { $0.insert(ScenarioTag(name: "red", color: "r0")) }
        await a.sync(); await b.sync(); await c.sync()
        for device in [a, b, c] { device.synchronizer.stop() }

        try a.change { $0.insert(ScenarioTag(name: "red", color: "rA")) }
        try b.change { context in if let tag = try fetchTag(context, "red") { context.delete(tag) } }
        try c.change { context in
            try fetchTag(context, "red")?.name = "blue"
            context.insert(ScenarioTag(name: "red", color: "rC"))
        }
        let orders = [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
        for device in orders[order] {
            device.synchronizer.start()
            await device.sync()
        }
        let snapshot = try await assertConverged([a, b, c])
        print("UNIQUE order \(order): tags \(snapshot.tags)")
        // B's deletion of the record wins over C's rename and A's upsert of it; C's new red stays, unless A's upsert reaches
        // the record of C's red first
        #expect(snapshot.tagKeys == ["red"], "\(snapshot.tags)")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: Edits racing deletions between download and upload, with four devices

    /// A edits s1, and B deletes s1 right after A downloaded; C edits s1 right before A saves; D deletes and creates s2 again.
    @Test(arguments: [false, true]) func editsRaceDeletionsWithFourDevices(deleteRightBeforeSaving: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server), d = TestDevice("D", server: server)
        try await a.launch(); try await b.launch(); try await c.launch(); try await d.launch()
        try a.insertSubscriptions(["s1", "s2", "s3"])
        try a.change { context in for i in 1...3 { let e = ScenarioEpisode(feedLink: "s1", guid: "g\(i)"); context.insert(e) } }
        await a.sync(); await b.sync(); await c.sync(); await d.sync()

        let fired = OSAllocatedUnfairLock(initialState: false)
        let race: @Sendable () -> Void = {
            guard fired.withLock({ f in defer { f = true }; return !f }) else { return }
            // B's deletion and C's edit land on the server between A's download and upload
            server.delete([subscriptionRecordName("s1"), SDSIdentity.recordName(entityName: "ScenarioEpisode", values: ["s1", "g1"])], account: "first")
        }
        if deleteRightBeforeSaving {
            server.beforeModifyRecords = { device, _ in if device == "A" { race() } }
        } else {
            a.synchronizer.afterSavingDownloadedObjects = race
        }
        try b.deleteSubscription("s1")
        try b.change { context in for e in try context.fetch(FetchDescriptor<ScenarioEpisode>()) where e.guid == "g1" { context.delete(e) } }
        try c.editSubscription("s3") { $0.title = "C title" }
        try d.deleteSubscription("s2")
        await d.sync()
        try d.change { $0.insert(ScenarioSubscription(feedLink: "s2", title: "D again")) }
        try a.editSubscription("s1") { $0.position = 5; $0.title = "A edit" }
        try a.change { context in for e in try context.fetch(FetchDescriptor<ScenarioEpisode>()) { e.elapsed = 9 } }
        await a.settle()
        server.beforeModifyRecords = nil
        a.synchronizer.afterSavingDownloadedObjects = nil
        await a.sync(); await b.sync(); await c.sync(); await d.sync()
        let snapshot = try await assertConverged([a, b, c, d])
        #expect(fired.withLock { $0 })
        #expect(!snapshot.subscriptionKeys.contains("s1"), "\(snapshot.subscriptions)")
        #expect(snapshot.subscriptions.contains { $0.hasPrefix("s2|D again|") }, "\(snapshot.subscriptions)")
        #expect(!snapshot.episodeKeys.contains("s1|g1"), "\(snapshot.episodes)")
        #expect(!snapshot.subscriptions.contains { $0.hasPrefix("|") }, "A partial record: \(snapshot.subscriptions)")
        a.terminate(); b.terminate(); c.terminate(); d.terminate()
    }

    // MARK: Minimal: a reset brings back what another device deleted

    /// A deletes a model with an identity (or a document, or a note) and uploads it. B, which hasn't downloaded that yet, resets
    /// its synchronization data. The deletion must stay.
    @Test(arguments: ["subscription", "episode", "document", "note", "tag"]) func resetDoesNotBringBackAnotherDevicesDeletion(kind: String) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(["s1", "s2"])
        try a.change { context in
            context.insert(ScenarioNote(text: "n1")); context.insert(ScenarioNote(text: "n2"))
            context.insert(ScenarioTag(name: "t1")); context.insert(ScenarioTag(name: "t2"))
            context.insert(ScenarioEpisode(feedLink: "s1", guid: "g1")); context.insert(ScenarioEpisode(feedLink: "s1", guid: "g2"))
            let w = ScenarioWorkspace(title: "w1"); context.insert(w)
            for title in ["d1", "d2"] { let d = ScenarioDocument(title: title); context.insert(d); d.workspace = w }
        }
        await a.sync(); await b.sync()
        b.synchronizer.stop()
        try a.change { context in
            switch kind {
            case "subscription": context.delete(try #require(try fetchSub(context, "s2")))
            case "episode": context.delete(try #require(try context.fetch(FetchDescriptor<ScenarioEpisode>()).first { $0.guid == "g2" }))
            case "document": context.delete(try #require(try fetchDocument(context, "d2")))
            case "note": context.delete(try #require(try fetchNote(context, prefix: "n2")))
            default: context.delete(try #require(try fetchTag(context, "t2")))
            }
        }
        await a.sync()
        try await b.synchronizer.resetSyncData()
        b.synchronizer.start()
        await b.settle()
        await b.sync()
        let snapshot = try await assertConverged([a, b])
        let all = snapshot.subscriptionKeys + snapshot.episodeKeys + snapshot.documentKeys + snapshot.notes + snapshot.tagKeys
        let deletedKey = ["subscription": "s2", "episode": "s1|g2", "document": "d2", "note": "n2", "tag": "t2"][kind]!
        #expect(!all.contains(deletedKey), "\(kind) came back: \(all)")
        a.terminate(); b.terminate()
    }

    // MARK: Rejected identity moves and document moves

    /// A renames s1 to s1x, but CloudKit rejects s1x's record. The removal of s1 waits, so B and C keep s1 and its link,
    /// while an unrelated deletion still reaches them. Once CloudKit accepts it, everyone moves to s1x.
    @Test(arguments: [false, true]) func rejectedIdentityMoveKeepsThePreviousRecord(quotaExceeded: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2", "s3"])
        try a.change { context in
            let link = ScenarioLink(name: "l1"); context.insert(link); link.subscription = try fetchSub(context, "s1")
        }
        await a.sync(); await b.sync(); await c.sync()
        let target = CKRecord.ID(recordName: subscriptionRecordName("s1x"), zoneID: .scenario)
        let rejecting = OSAllocatedUnfairLock(initialState: true)
        if quotaExceeded {
            // iCloud is full: no record can be saved, while removals still go through
            server.failSaving(where: { _ in rejecting.withLock { $0 } }, with: CKError(.quotaExceeded))
        } else {
            server.failSaving(where: { $0 == target && rejecting.withLock { $0 } }, with: CKError(.serverRejectedRequest))
        }
        try a.editSubscription("s1") { $0.feedLink = "s1x" }
        try a.deleteSubscription("s3")
        await a.sync(); await a.sync()
        await b.sync(); await c.sync()
        let bFeeds = try b.subscriptions().map(\.feedLink)
        #expect(bFeeds == ["s1", "s2"], "\(bFeeds)")
        let bLinks = try b.snapshot().links
        #expect(bLinks == ["l1|s1"], "B lost the link: \(bLinks)")

        // Accepted after the quarantine
        rejecting.withLock { $0 = false }
        a.synchronizer.resetQuarantine()
        a.synchronizer.resumeUploads()
        try a.editSubscription("s2") { $0.title = "poke" }
        await a.sync(); await a.sync()
        let snapshot = try await assertConverged([a, b, c])
        #expect(snapshot.subscriptionKeys == ["s1x", "s2"], "\(snapshot.subscriptions)")
        #expect(snapshot.links == ["l1|s1x"], "\(snapshot.links)")
        a.terminate(); b.terminate(); c.terminate()
    }

    /// A moves a document to workspace w2 and deletes w1, while CloudKit rejects the document. w1's removal waits, as the
    /// document's record in iCloud still has w1 as its parent, which CloudKit would delete it with.
    @Test func rejectedDocumentMoveKeepsItsPreviousParent() async throws {
        let server = FakeCloudServer()
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            let w1 = ScenarioWorkspace(title: "w1"), w2 = ScenarioWorkspace(title: "w2")
            context.insert(w1); context.insert(w2)
            let d = ScenarioDocument(title: "d1"); d.body = "body"; context.insert(d); d.workspace = w1
        }
        await a.sync(); await b.sync()
        let docID = CKRecord.ID(recordName: SDSIdentity.recordName(entityName: "ScenarioDocument", values: ["d1"]), zoneID: .scenario)
        server.failSaving(where: { $0 == docID }, with: CKError(.invalidArguments))
        try a.change { context in
            let d = try #require(try fetchDocument(context, "d1"))
            d.workspace = try fetchWorkspace(context, "w2")
            context.delete(try #require(try fetchWorkspace(context, "w1")))
        }
        await a.sync(); await a.sync(); await b.sync()
        #expect(server.record(named: docID.recordName, account: "first") != nil, "CloudKit deleted the document with its previous parent")
        let bDocs = try b.snapshot().documents
        #expect(bDocs == ["d1|body|w1"], "\(bDocs)")
        a.terminate(); b.terminate()
    }

    /// While iCloud is full, A renames s1 (nothing references it) to s1x. Only removals are uploaded then, so s1's removal
    /// must wait for s1x's record, or B loses the subscription until iCloud has room again.
    @Test(arguments: [false, true]) func identityMoveWhileICloudIsFull(rejectedInstead: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(["s1", "s2"])
        await a.sync(); await b.sync()
        let rejecting = OSAllocatedUnfairLock(initialState: true)
        let target = CKRecord.ID(recordName: subscriptionRecordName("s1x"), zoneID: .scenario)
        if rejectedInstead {
            server.failSaving(where: { $0 == target && rejecting.withLock { $0 } }, with: CKError(.serverRejectedRequest))
        } else {
            server.failSaving(where: { _ in rejecting.withLock { $0 } }, with: CKError(.quotaExceeded))
        }
        try a.editSubscription("s1") { $0.feedLink = "s1x"; $0.title = "renamed" }
        await a.sync(); await a.sync(); await b.sync()
        let bFeeds = try b.subscriptions().map(\.feedLink)
        #expect(bFeeds.contains("s1") || bFeeds.contains("s1x"), "B lost the subscription: \(bFeeds), server \(b.serverSubscriptions().map(\.feedLink))")
        rejecting.withLock { $0 = false }
        a.synchronizer.resetQuarantine()
        a.synchronizer.resumeUploads()
        try a.editSubscription("s2") { $0.title = "poke" }
        await a.sync(); await a.sync()
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.subscriptionKeys == ["s1x", "s2"], "\(snapshot.subscriptions)")
        a.terminate(); b.terminate()
    }

    // MARK: Many held records waiting for a record deleted on this device

    /// A puts 450 new links into s1, while C deleted s1 without knowing. C downloads them after uploading the deletion,
    /// so they're held, then resolved like C's delete rule (cascade) would have, in batches.
    @Test func manyHeldRecordsWaitingForADeletedRecord() async throws {
        let server = FakeCloudServer()
        server.pageSize = 100
        let a = TestDevice("A", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2"])
        await a.sync(); await c.sync()
        c.synchronizer.stop()
        try c.deleteSubscription("s1")
        try a.change { context in
            let s1 = try #require(try fetchSub(context, "s1"))
            for i in 0..<450 { let link = ScenarioLink(name: "m\(i)"); context.insert(link); link.subscription = s1 }
        }
        await a.sync()
        c.synchronizer.start()
        await c.sync(); await c.sync(); await c.sync()
        await a.sync()
        let snapshot = try await assertConverged([a, c])
        #expect(snapshot.links.isEmpty, "\(snapshot.links.count) links")
        let cLinks = try c.count(ScenarioLink.self)
        #expect(cLinks == 0)
        a.terminate(); c.terminate()
    }

    // MARK: The state after a save

    /// After a save, the state goes from processingSaveEvent to the synchronization it starts. An app that waits for
    /// `.idle` before it lets itself be suspended shouldn't see `.idle` in between, with the save not uploaded yet.
    @Test(arguments: 0..<5) func stateDoesNotShowIdleBetweenASaveAndItsSynchronization(run: Int) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()
        let viewModel = a.viewModel
        try a.editSubscription("s1") { $0.title = "edited" }
        var states: [String] = []
        for _ in 0..<3000 {
            let state = "\(await viewModel.state)"
            if states.last != state { states.append(state) }
            if a.serverSubscriptions().first?.title == "edited" { break }
            try await Task.sleep(for: .microseconds(300))
        }
        let i = states.firstIndex { $0.contains("processingSaveEvent") }
        let flicker = i.map { states[$0...].dropFirst().first == "idle" } ?? false
        #expect(!flicker, "states: \(states)")
        a.terminate()
    }

    // MARK: The same large key set and cleared at about the same time

    /// C sets a large artwork while B clears a small one, B's save reaching iCloud right before or after C's. Whatever wins,
    /// every device must end with the server's value.
    @Test(arguments: 0..<4) func largeValueSetAndClearedAtOnce(variant: Int) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1"])
        try a.editSubscription("s1") { $0.artwork = variant >= 2 ? Data(repeating: 1, count: 280_000) : Data("tiny".utf8) }
        await a.sync(); await b.sync(); await c.sync()
        for device in [a, b, c] { device.synchronizer.stop() }

        let big = Data(repeating: 9, count: 280_000)
        try c.editSubscription("s1") { $0.artwork = big }
        try b.editSubscription("s1") { $0.artwork = nil }
        let fired = OSAllocatedUnfairLock(initialState: false)
        let first = variant % 2 == 0 ? c : b, second = variant % 2 == 0 ? b : c
        // The second device's save reaches iCloud right before the first's
        server.beforeModifyRecords = { device, names in
            guard device == first.name, names.contains(subscriptionRecordName("s1")), fired.withLock({ f in defer { f = true }; return !f }) else { return }
            Task { second.synchronizer.start(); await second.synchronizer.synchronize() }
            Thread.sleep(forTimeInterval: 0.3)
        }
        first.synchronizer.start()
        await first.sync()
        server.beforeModifyRecords = nil
        second.synchronizer.start(); a.synchronizer.start()
        await second.sync(); await first.sync(); await a.sync()
        let snapshot = try await assertConverged([a, b, c])
        print("SETCLEAR \(variant): \(snapshot.subscriptions)")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: A local insert of an identity a download is inserting

    /// A creates s9 (or document d9) and uploads it. B creates the same identity itself while its download of A's record
    /// is about to be saved. The two must become one, rather than B's model getting a random record name.
    @Test(arguments: [false, true]) func localInsertWhileADownloadInsertsTheSameIdentity(document: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            let w = ScenarioWorkspace(title: "w1"); context.insert(w)
        }
        await a.sync(); await b.sync()
        try a.change { context in
            if document {
                let d = ScenarioDocument(title: "d9"); d.body = "from A"; context.insert(d); d.workspace = try fetchWorkspace(context, "w1")
            } else {
                context.insert(ScenarioSubscription(feedLink: "s9", title: "from A"))
            }
        }
        await a.sync()

        let fired = OSAllocatedUnfairLock(initialState: false)
        let container = try #require(b.modelContainer)
        b.synchronizer.beforeSavingDownloadedObjects = {
            guard fired.withLock({ f in defer { f = true }; return !f }) else { return }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            if document {
                let d = ScenarioDocument(title: "d9"); d.body = "from B"; context.insert(d)
            } else {
                context.insert(ScenarioSubscription(feedLink: "s9", title: "from B"))
            }
            try? context.save()
        }
        await b.sync()
        b.synchronizer.beforeSavingDownloadedObjects = nil
        await b.sync(); await a.sync()
        let snapshot = try await assertConverged([a, b])
        #expect(fired.withLock { $0 })
        print("RACEINSERT \(document): \(snapshot.subscriptions) \(snapshot.documents)")
        let ids = server.records(account: "first").filter { $0.recordType == (document ? "ScenarioDocument" : "ScenarioSubscription") }.map(\.recordID.recordName)
        #expect(ids.allSatisfy { !$0.contains("-") }, "A record with a random name: \(ids)")
        a.terminate(); b.terminate()
    }
}
