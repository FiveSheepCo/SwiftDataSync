import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
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

private func removeStore(of device: TestDevice) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: device.storeURL.path + suffix))
    }
}

/// Adversarial end-to-end scenarios: several devices, failures in between, relaunches, account switches, lost stores and
/// configuration changes. Each ends by checking that every device equals the server, without duplicates.
@Suite(.coreDataReady, .adversarial, .serialized, .timeLimit(.minutes(6)))
struct AdversarialScenarioTests {

    // MARK: 1. Edit, delete and re-create on three devices with failures in between

    @Test func threeDevicesEditDeleteAndRecreate() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(feedLinks(1...5))
        try a.change { for i in 1...5 { $0.insert(ScenarioNote(text: "n\(i):0")) } }
        await a.sync(); await b.sync(); await c.sync()

        let s1 = feedLinks(1...1)[0]
        try a.editSubscription(s1) { $0.title = "A edit" }
        try b.deleteSubscription(s1)
        try c.editSubscription(s1) { $0.position = 99 }
        server.failNextModify(with: CKError(.networkFailure))
        await a.sync()      // upload fails
        await b.sync()      // deletion uploaded
        await c.sync()      // edit discarded with the deletion
        await a.sync()

        // C creates it again, while B's download fails
        try c.change { $0.insert(ScenarioSubscription(feedLink: s1, title: "C again", position: 7)) }
        server.failNextFetch(with: CKError(.networkFailure))
        await b.sync()
        await c.sync()
        let snapshot = try await assertConverged([a, b, c])
        #expect(snapshot.subscriptions.contains { $0.hasPrefix("\(s1)|C again|7|") }, "\(snapshot.subscriptions)")
        #expect(snapshot.subscriptions.count == 5)

        // Notes: A edits, B deletes, C edits then everyone syncs with failures
        try a.change { context in try fetchNote(context, prefix: "n2:")?.text = "n2:A" }
        try b.change { context in if let note = try fetchNote(context, prefix: "n2:") { context.delete(note) } }
        try c.change { context in try fetchNote(context, prefix: "n2:")?.text = "n2:C" }
        try c.change { context in try fetchNote(context, prefix: "n3:")?.text = "n3:C" }
        try a.change { context in try fetchNote(context, prefix: "n3:")?.text = "n3:A" }
        server.failNextModify(with: CKError(.serviceUnavailable))
        await c.sync()
        await a.sync()
        await b.sync()
        await c.sync()
        let notes = try await assertConverged([a, b, c]).notes
        #expect(!notes.contains { $0.hasPrefix("n2:") }, "\(notes)")
        #expect(notes.filter { $0.hasPrefix("n3:") }.count == 1)
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: 2. Identity changes racing edits on other devices

    @Test func identityChangeRacesAnotherDevicesEdit() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2", "s3", "s4"])
        try a.change { context in
            let link = ScenarioLink(name: "l1")
            context.insert(link)
            link.subscription = try fetchSub(context, "s2")
        }
        await a.sync(); await b.sync(); await c.sync()

        // A moves s2 to s2x, B edits s2, C swaps s3 and s4
        try a.editSubscription("s2") { $0.feedLink = "s2x"; $0.title = "renamed by A" }
        try b.editSubscription("s2") { $0.position = 42 }
        try c.change { context in
            let s3 = try #require(try fetchSub(context, "s3")), s4 = try #require(try fetchSub(context, "s4"))
            s3.feedLink = "tmp"; s4.feedLink = "s3"; s3.feedLink = "s4"
        }
        try b.editSubscription("s3") { $0.title = "B edit of s3" }
        await b.sync()
        await c.sync()
        server.failNextModify(with: CKError(.networkFailure))
        await a.sync()
        await a.sync()
        let snapshot = try await assertConverged([a, b, c])
        #expect(snapshot.subscriptionKeys == ["s1", "s2x", "s3", "s4"], "\(snapshot.subscriptions)")
        #expect(snapshot.links == ["l1|s2x"], "\(snapshot.links)")
        a.terminate(); b.terminate(); c.terminate()
    }

    /// Two devices move different models to the same new identity at about the same time, and a third creates it.
    @Test func threeDevicesTakeTheSameIdentity() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2"])
        await a.sync(); await b.sync(); await c.sync()

        try a.editSubscription("s1") { $0.feedLink = "target"; $0.title = "from A" }
        try b.editSubscription("s2") { $0.feedLink = "target"; $0.title = "from B" }
        try c.change { $0.insert(ScenarioSubscription(feedLink: "target", title: "from C")) }
        await a.sync(); await b.sync(); await c.sync()
        let snapshot = try await assertConverged([a, b, c])
        #expect(snapshot.subscriptionKeys == ["target"], "\(snapshot.subscriptions)")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: 3. Unique constraints

    @Test func uniqueTagsOnThreeDevices() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()

        try a.change { $0.insert(ScenarioTag(name: "red", color: "A")) }
        try b.change { $0.insert(ScenarioTag(name: "red", color: "B")) }
        try c.change { $0.insert(ScenarioTag(name: "red", color: "C")); $0.insert(ScenarioTag(name: "blue", color: "C")) }
        await a.sync(); await b.sync(); await c.sync()
        var snapshot = try await assertConverged([a, b, c])
        #expect(snapshot.tagKeys == ["blue", "red"], "\(snapshot.tags)")

        // A renames red to green while B recreates... B deletes blue and C renames blue to red
        try a.change { context in try fetchTag(context, "red")?.name = "green" }
        try b.change { context in if let tag = try fetchTag(context, "blue") { context.delete(tag) } }
        try c.change { context in
            if let red = try fetchTag(context, "red") { context.delete(red) }
            try fetchTag(context, "blue")?.name = "red"
        }
        server.failNextFetch(with: CKError(.networkFailure))
        await c.sync(); await a.sync(); await b.sync()
        snapshot = try await assertConverged([a, b, c])
        #expect(Set(snapshot.tagKeys).isSubset(of: ["green", "red", "blue"]), "\(snapshot.tags)")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: 4. Moving children between parents while parents are deleted

    @Test(arguments: [false, true])
    func linksMoveWhileTheirSubscriptionsAreDeleted(bFirst: Bool) async throws {
        let server = FakeCloudServer()
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2", "s3"])
        try a.change { context in
            for (index, name) in ["l1", "l2", "l3", "l4"].enumerated() {
                let link = ScenarioLink(name: name)
                context.insert(link)
                link.subscription = try fetchSub(context, ["s1", "s1", "s2", "s3"][index])
            }
        }
        await a.sync(); await b.sync(); await c.sync()

        // B moves l1 to s2 and l3 to s1; A deletes s2; C moves l4 to s2 and deletes s1
        try b.change { context in
            try fetchLink(context, "l1")?.subscription = try fetchSub(context, "s2")
            try fetchLink(context, "l3")?.subscription = try fetchSub(context, "s1")
        }
        try a.deleteSubscription("s2")
        try c.change { context in
            try fetchLink(context, "l4")?.subscription = try fetchSub(context, "s2")
        }
        if bFirst {
            await b.sync(); await a.sync(); await c.sync()
        } else {
            await a.sync(); await c.sync(); await b.sync()
        }
        try c.deleteSubscription("s1")
        await c.sync(); await b.sync(); await a.sync()
        let snapshot = try await assertConverged([a, b, c])
        #expect(snapshot.subscriptionKeys == ["s3"], "\(snapshot.subscriptions)")
        #expect(!snapshot.links.contains { $0.contains("?missing") }, "\(snapshot.links)")
        a.terminate(); b.terminate(); c.terminate()
    }

    @Test(arguments: [false, true])
    func documentsMoveWhileTheirWorkspacesAreDeleted(moveFirst: Bool) async throws {
        let server = FakeCloudServer()
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.change { context in
            for title in ["w1", "w2", "w3"] { context.insert(ScenarioWorkspace(title: title)) }
            for (title, workspace) in [("d1", "w1"), ("d2", "w1"), ("d3", "w2"), ("d4", "w3")] {
                let document = ScenarioDocument(title: title)
                document.body = "body \(title)"
                context.insert(document)
                document.workspace = try fetchWorkspace(context, workspace)
            }
        }
        await a.sync(); await b.sync(); await c.sync()

        // B moves d1 to w2, A deletes w1, C edits d1 and d2 and moves d4 to w1
        try b.change { context in try fetchDocument(context, "d1")?.workspace = try fetchWorkspace(context, "w2") }
        try a.change { context in if let w = try fetchWorkspace(context, "w1") { context.delete(w) } }
        try c.change { context in
            try fetchDocument(context, "d1")?.body = "C edit"
            try fetchDocument(context, "d2")?.body = "C edit"
            try fetchDocument(context, "d4")?.workspace = try fetchWorkspace(context, "w1")
        }
        if moveFirst {
            await b.sync(); await c.sync(); await a.sync()
        } else {
            await a.sync(); await b.sync(); await c.sync()
        }
        let snapshot = try await assertConverged([a, b, c])
        #expect(!snapshot.workspaces.contains("w1"), "\(snapshot.workspaces)")
        #expect(!snapshot.documents.contains { $0.contains("?missing") || $0.hasSuffix("|w1") }, "\(snapshot.documents)")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: 5. Large values from several devices

    @Test func largeValuesFromThreeDevices() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2"])
        await a.sync(); await b.sync(); await c.sync()

        let artA = Data((0..<400_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let noteB = String(repeating: "b", count: 300_000)
        try a.editSubscription("s1") { $0.artwork = artA }
        await a.sync()
        try b.editSubscription("s1") { $0.note = noteB }
        try c.editSubscription("s1") { $0.title = "C title" }
        await b.sync(); await c.sync()
        var snapshot = try await assertConverged([a, b, c])
        let s1 = snapshot.subscriptions.first { $0.hasPrefix("s1|") } ?? ""
        #expect(s1.contains("C title") && s1.contains(shortHash(artA)) && s1.contains(shortHash(Data(noteB.utf8))), "\(s1)")

        // Values shrink back below the limit on one device while another grows another value, with a failed upload
        try a.editSubscription("s1") { $0.note = "small" }
        let artC = Data(repeating: 3, count: 600_000)
        try c.editSubscription("s1") { $0.artwork = artC }
        try b.editSubscription("s1") { $0.position = 5 }
        server.failNextModify(with: CKError(.networkFailure))
        await a.sync()
        await c.sync()
        await b.sync()
        await a.sync()
        snapshot = try await assertConverged([a, b, c])
        let s1b = snapshot.subscriptions.first { $0.hasPrefix("s1|") } ?? ""
        #expect(s1b.contains("|5|") && s1b.contains("|small|") && s1b.contains(shortHash(artC)), "\(s1b)")

        // Clear everything large on one device, set a large note on s2 on another, in a single sync each
        try b.editSubscription("s1") { $0.artwork = nil; $0.note = nil }
        try a.editSubscription("s2") { $0.note = String(repeating: "x", count: 700_000); $0.artwork = Data(repeating: 1, count: 500_000) }
        await b.sync(); await a.sync()
        snapshot = try await assertConverged([a, b, c])
        let s1c = snapshot.subscriptions.first { $0.hasPrefix("s1|") } ?? ""
        #expect(s1c.hasSuffix("|-|-"), "\(s1c)")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: 6. A device offline for a long time

    @Test func deviceOfflineForALongTimeReturns() async throws {
        let server = FakeCloudServer()
        server.pageSize = 25
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), d = TestDevice("D", server: server)
        try await a.launch(); try await b.launch(); try await d.launch()
        try a.insertSubscriptions(feedLinks(1...100))
        try a.change { for i in 1...60 { $0.insert(ScenarioNote(text: "n\(i):0")) } }
        await a.sync(); await b.sync(); await d.sync()

        // D goes offline (stopped) and edits a lot
        d.synchronizer.stop()
        try d.change { context in
            for i in 1...40 { try fetchSub(context, feedLinks(i...i)[0])?.title = "D offline \(i)" }
            for i in 1...20 { try fetchNote(context, prefix: "n\(i):")?.text = "n\(i):D" }
            for i in 101...110 { context.insert(ScenarioSubscription(feedLink: feedLinks(i...i)[0], title: "D new \(i)")) }
            context.insert(ScenarioNote(text: "nD:new"))
        }
        // Meanwhile A and B delete, re-create and edit
        for round in 0..<5 {
            try a.change { context in
                for i in stride(from: 1 + round, through: 30, by: 5) {
                    if let model = try fetchSub(context, feedLinks(i...i)[0]) { context.delete(model) }
                }
                for i in stride(from: 1 + round, through: 30, by: 10) where round > 2 {
                    context.insert(ScenarioSubscription(feedLink: feedLinks(i...i)[0], title: "A recreated \(i)"))
                }
            }
            try b.change { context in
                for i in (10 + round * 5)...(14 + round * 5) {
                    if let note = try fetchNote(context, prefix: "n\(i):") { context.delete(note) }
                }
                for i in 50...60 { try fetchSub(context, feedLinks(i...i)[0])?.position = round * 1000 + i }
            }
            await a.sync(); await b.sync()
        }
        try b.change { context in for i in 105...107 { context.insert(ScenarioSubscription(feedLink: feedLinks(i...i)[0], title: "B new \(i)")) } }
        await b.sync()
        d.synchronizer.start()
        await d.settle()
        let snapshot = try await assertConverged([a, b, d])
        // Notes deleted by B are gone, D's edits of other notes are there
        for i in 10...34 { #expect(!snapshot.notes.contains { $0.hasPrefix("n\(i):") }, "n\(i) came back") }
        for i in 1...9 { #expect(snapshot.notes.contains("n\(i):D")) }
        #expect(snapshot.notes.contains("nD:new"))
        for i in 101...110 { #expect(snapshot.subscriptionKeys.contains(feedLinks(i...i)[0])) }
        a.terminate(); b.terminate(); d.terminate()
    }

    // MARK: 7. A new device restores a large library while another edits, killed mid-download twice

    @Test func newDeviceRestoresWhileAnotherEdits() async throws {
        let server = FakeCloudServer()
        server.pageSize = 40
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.insertSubscriptions(feedLinks(1...600))
        try a.change { context in
            for i in 1...200 { context.insert(ScenarioNote(text: "n\(i):0")) }
            for i in 1...50 {
                let link = ScenarioLink(name: "l\(i)")
                context.insert(link)
                link.subscription = try fetchSub(context, feedLinks(i...i)[0])
            }
        }
        await a.sync()

        let b = TestDevice("B", server: server)
        server.hangDownloadDevice = "B"
        server.hangDownloadAfterPages = 4
        try await b.launch(waitForSync: false)
        #expect(await waitUntil { server.hungDownloads == 1 })
        // A deletes things B has and hasn't downloaded yet, and edits others
        try a.change { context in
            for i in stride(from: 1, through: 600, by: 7) {
                if let model = try fetchSub(context, feedLinks(i...i)[0]) { context.delete(model) }
            }
            for i in stride(from: 2, through: 600, by: 11) { try fetchSub(context, feedLinks(i...i)[0])?.title = "A edit \(i)" }
            for i in stride(from: 1, through: 200, by: 9) { if let note = try fetchNote(context, prefix: "n\(i):") { context.delete(note) } }
            for i in 1...20 { try fetchLink(context, "l\(i)")?.subscription = try fetchSub(context, feedLinks(300...300)[0]) }
        }
        await a.sync()
        b.terminate()

        server.hangDownloadAfterPages = 6
        try await b.launch(waitForSync: false)
        #expect(await waitUntil { server.hungDownloads == 2 })
        var editedThird = false
        try b.change { context in
            // B edits what it has (the download might not have reached them), and re-creates one A deleted
            for i in 3...5 {
                if let model = try fetchSub(context, feedLinks(i...i)[0]) { model.position = 5000 + i; editedThird = editedThird || i == 3 }
            }
            context.insert(ScenarioSubscription(feedLink: feedLinks(8...8)[0], title: "B recreated"))
        }
        try a.change { context in
            for i in 590...600 { try fetchSub(context, feedLinks(i...i)[0])?.isMuted = true }
        }
        await a.sync()
        print("RESTORE before kill B s3 \(String(describing: try b.subscription(feedLinks(3...3)[0]))) server \(server.snapshot(account: "first").subscriptions.filter { $0.hasPrefix(feedLinks(3...3)[0] + "|") })")
        b.terminate()
        try await b.launch(waitForSync: false)
        print("RESTORE relaunched B s3 \(String(describing: try b.subscription(feedLinks(3...3)[0])))")
        await b.settle()
        print("RESTORE synced B s3 \(String(describing: try b.subscription(feedLinks(3...3)[0]))) server \(server.snapshot(account: "first").subscriptions.filter { $0.hasPrefix(feedLinks(3...3)[0] + "|") }) events \(server.events(of: "B", .modifyRecords).map { $0.savedKeys.count })")
        let snapshot = try await assertConverged([a, b])
        #expect(b.synchronizer.hasDownloadedOnce)
        if editedThird {
            #expect(snapshot.subscriptions.contains { $0.hasPrefix("\(feedLinks(3...3)[0])|") && $0.contains("|5003|") })
        }
        a.terminate(); b.terminate()
    }

    // MARK: 8. Account switches back and forth

    @Test func accountSwitchesBackAndForth() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server, account: "second")
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2", "s3"])
        try a.change { $0.insert(ScenarioNote(text: "n1:0")) }
        try c.insertSubscriptions(["c1", "s1"], title: { "C \($0)" })
        await a.sync(); await b.sync(); await c.sync()

        // A switches to the second account, edits there, while B edits in the first
        a.switchAccount(to: .signedIn("second"))
        await a.settle(); await a.sync()
        try a.editSubscription("s2") { $0.title = "A on second" }
        try a.change { $0.insert(ScenarioNote(text: "n2:A-second")) }
        await a.sync()
        try b.editSubscription("s3") { $0.title = "B on first" }
        try b.deleteSubscription("s1")
        await b.sync()
        try await assertConverged([a, c], account: "second")

        // Back to the first, then quickly second and first again with a failed fetch in between
        a.switchAccount(to: .signedIn("first"))
        server.failNextFetch(with: CKError(.networkFailure))
        await a.sync()
        a.switchAccount(to: .signedIn("second"))
        a.switchAccount(to: .signedIn("first"))
        await a.settle(); await a.sync()
        let first = try await assertConverged([a, b], account: "first")
        #expect(first.subscriptionKeys.filter { $0 == "s2" }.count == 1)
        a.switchAccount(to: .signedIn("second"))
        await a.settle(); await a.sync()
        try await assertConverged([a, c], account: "second")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: 9. Stores lost or replaced

    @Test func storeLostAndReplacedWithAnOlderCopy() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(feedLinks(1...20))
        try a.change { context in
            for i in 1...10 { context.insert(ScenarioNote(text: "n\(i):0")) }
            context.insert(ScenarioWorkspace(title: "w1"))
            let document = ScenarioDocument(title: "d1")
            context.insert(document)
            document.workspace = try fetchWorkspace(context, "w1")
        }
        await a.sync(); await b.sync()

        // A keeps a copy of its store, edits and syncs more
        a.terminate()
        let backup = a.directory.appending(path: "backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: a.storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: backup.appending(path: "Library.store" + suffix))
            }
        }
        try await a.launch()
        try a.change { context in
            for i in 1...5 { try fetchSub(context, feedLinks(i...i)[0])?.title = "A newer \(i)" }
            for i in 1...3 { if let note = try fetchNote(context, prefix: "n\(i):") { context.delete(note) } }
            context.insert(ScenarioNote(text: "n11:0"))
        }
        await a.sync()
        try b.change { context in for i in 6...8 { try fetchSub(context, feedLinks(i...i)[0])?.title = "B newer \(i)" } }
        await b.sync()

        // The older copy replaces the store
        a.terminate()
        removeStore(of: a)
        for suffix in ["", "-wal", "-shm"] {
            let source = backup.appending(path: "Library.store" + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: a.storeURL.path + suffix))
            }
        }
        try await a.launch()
        var snapshot = try await assertConverged([a, b])
        // By design: the older copy's models without records (deleted since) can't be told from models created offline,
        // so they're uploaded again
        #expect(snapshot.notes.count == 11, "\(snapshot.notes)")
        #expect(snapshot.subscriptions.filter { $0.contains("newer") }.count == 8, "\(snapshot.subscriptions)")

        // Then lost completely, while B edits
        a.terminate()
        removeStore(of: a)
        try b.change { context in try fetchDocument(context, "d1")?.body = "B body" }
        await b.sync()
        try await a.launch()
        snapshot = try await assertConverged([a, b])
        #expect(snapshot.documents == ["d1|B body|w1"], "\(snapshot.documents)")
        a.terminate(); b.terminate()
    }

    // MARK: 10. Configuration changes between launches

    private static let withoutNotesAndTitles = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.without(["title"]), identity: ["feedLink"])),
        .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
        .init(entity: ScenarioLink.self, description: .sync(.without([]))),
        .init(entity: ScenarioTag.self, description: .sync(.without([]))),
        .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
        .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
    ])

    private static let extensionConfiguration = SDSConfiguration(swiftDataEntities: [
        .init(entity: ScenarioSubscription.self, description: .sync(.with(["feedLink", "position"]), identity: ["feedLink"])),
        .init(entity: ScenarioNote.self, description: .sync(.without([])))
    ])

    @Test func configurationChangesBetweenLaunches() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(["s1", "s2", "s3"])
        try a.change { for i in 1...3 { $0.insert(ScenarioNote(text: "n\(i):0")) } }
        await a.sync(); await b.sync()

        // B runs a version without notes and titles, while A changes them
        b.terminate()
        try await b.launch(configuration: Self.withoutNotesAndTitles)
        try a.editSubscription("s1") { $0.title = "A title" }
        try a.change { context in
            try fetchNote(context, prefix: "n1:")?.text = "n1:A"
            if let note = try fetchNote(context, prefix: "n2:") { context.delete(note) }
            context.insert(ScenarioNote(text: "n4:A"))
        }
        await a.sync()
        try b.editSubscription("s2") { $0.position = 22 }
        try b.change { context in context.insert(ScenarioNote(text: "n5:B-unsynced")) }
        await b.sync()

        // An extension with fewer keys runs on B's data meanwhile
        b.terminate()
        try a.editSubscription("s3") { $0.title = "A title 3"; $0.position = 33 }
        try a.change { context in if let note = try fetchNote(context, prefix: "n3:") { context.delete(note) } }
        await a.sync()
        try await b.launch(configuration: Self.extensionConfiguration)
        try b.editSubscription("s1") { $0.position = 11 }
        await b.sync()
        b.terminate()

        // The keys come back
        try await b.launch()
        await b.sync()
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.notes == ["n1:A", "n4:A", "n5:B-unsynced"], "\(snapshot.notes)")
        #expect(snapshot.subscriptions.contains { $0.hasPrefix("s1|A title|11|") }, "\(snapshot.subscriptions)")
        #expect(snapshot.subscriptions.contains { $0.hasPrefix("s3|A title 3|33|") }, "\(snapshot.subscriptions)")
        a.terminate(); b.terminate()
    }

    // MARK: 11. Relaunches mid-upload

    @Test func killedWhileUploading() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        await a.sync()
        try a.insertSubscriptions(feedLinks(1...30))
        try a.change { context in
            for i in 1...30 { context.insert(ScenarioNote(text: "n\(i):0")) }
            for i in 1...5 {
                let link = ScenarioLink(name: "l\(i)")
                context.insert(link)
                link.subscription = try fetchSub(context, feedLinks(i...i)[0])
            }
        }
        // The upload is applied on the server, but the device is killed before it hears back
        let killed = OSAllocatedUnfairLockBox(false)
        server.beforeModifyRecords = { device, _ in
            guard device == "A", killed.take() == false else { return }
            a.terminate()
        }
        #expect(await waitUntil { killed.value })
        server.beforeModifyRecords = nil
        try await Task.sleep(for: .milliseconds(200))
        try await a.launch()
        await a.sync()
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.notes.count == 30, "\(snapshot.notes)")
        #expect(snapshot.subscriptions.count == 30)
        #expect(snapshot.links.count == 5)
        a.terminate(); b.terminate()
    }

    // MARK: 12. An edit uploaded right after another device's deletion

    /// B saves the position of an episode it plays, while A deletes the episode: A's deletion lands between B's download
    /// and B's upload. B's upload must not create a partial record without the identity values.
    @Test(arguments: [false, true])
    func editRacesDeletionBetweenDownloadAndUpload(subscription: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            context.insert(ScenarioEpisode(feedLink: "f", guid: "g1"))
            context.insert(ScenarioSubscription(feedLink: "f", title: "Feed"))
        }
        await a.sync(); await b.sync()

        try a.change { context in
            if subscription {
                for model in try context.fetch(FetchDescriptor<ScenarioSubscription>()) { context.delete(model) }
            } else {
                for model in try context.fetch(FetchDescriptor<ScenarioEpisode>()) { context.delete(model) }
            }
        }
        let once = OSAllocatedUnfairLockBox(false)
        server.beforeModifyRecords = { device, saved in
            guard device == "B", !saved.isEmpty, once.take() == false else { return }
            // A's upload lands right now, after B downloaded
            Task { await a.synchronizer.synchronize() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        try b.change { context in
            if subscription {
                for model in try context.fetch(FetchDescriptor<ScenarioSubscription>()) { model.position = 123 }
            } else {
                for model in try context.fetch(FetchDescriptor<ScenarioEpisode>()) { model.elapsed = 123 }
            }
        }
        await b.settle()
        await a.settle()
        server.beforeModifyRecords = nil
        let snapshot = try await assertConverged([a, b])
        #expect(!snapshot.episodeKeys.contains("|") && !snapshot.subscriptionKeys.contains(""), "Partial record: \(snapshot.episodes) \(snapshot.subscriptions)")
        for record in server.records(account: "first") {
            #expect(record["feedLink"] != nil, "\(record.recordType) without its identity: \(record.allKeys())")
        }
        a.terminate(); b.terminate()
    }

    // MARK: 13. A child moved into a parent another device deletes

    @Test func linkMovedIntoADeletedSubscription() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(["s1", "s2"])
        try a.change { context in
            let link = ScenarioLink(name: "l1")
            context.insert(link)
            link.subscription = try fetchSub(context, "s1")
        }
        await a.sync(); await b.sync()

        b.synchronizer.stop()
        a.synchronizer.stop()
        try b.change { context in try fetchLink(context, "l1")?.subscription = try fetchSub(context, "s2") }
        try a.deleteSubscription("s2")
        b.synchronizer.start(); await b.settle(); await b.sync()
        a.synchronizer.start(); await a.settle(); await a.sync()
        await b.sync()
        let snapshot = try await assertConverged([a, b])
        #expect(!snapshot.links.contains { $0.contains("?missing") }, "\(snapshot.links)")
        a.terminate(); b.terminate()
        let c = TestDevice("C", server: server)
        try await c.launch()
        #expect(try c.snapshot().links == snapshot.links)
        c.terminate()
    }

    // MARK: 14. A reset on one device while others edit and delete

    @Test func resetWhileOthersEditAndDelete() async throws {
        let server = FakeCloudServer()
        server.pageSize = 10
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(feedLinks(1...30))
        try a.change { context in for i in 1...30 { context.insert(ScenarioNote(text: "n\(i):0")) } }
        await a.sync(); await b.sync(); await c.sync()

        try b.change { context in
            for i in 1...10 { try fetchNote(context, prefix: "n\(i):")?.text = "n\(i):B" }
            context.insert(ScenarioNote(text: "n31:B"))
        }
        try await b.synchronizer.resetSyncData()
        try c.change { context in
            for i in 5...15 { if let note = try fetchNote(context, prefix: "n\(i):") { context.delete(note) } }
            for i in 1...5 { try fetchSub(context, feedLinks(i...i)[0])?.title = "C edit \(i)" }
        }
        await c.sync()
        b.synchronizer.start()
        await b.settle()
        try a.change { context in for i in 20...25 { if let model = try fetchSub(context, feedLinks(i...i)[0]) { context.delete(model) } } }
        await a.sync()
        let snapshot = try await assertConverged([a, b, c])
        #expect(snapshot.subscriptions.count == 24)
        #expect(snapshot.notes.filter { $0.hasPrefix("n31:") }.count == 1)
        a.terminate(); b.terminate(); c.terminate()
    }

    /// The deterministic part of the above: an edit that wasn't uploaded yet when the data is reset.
    @Test func resetWithAnEditThatWasntUploaded() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in for i in 1...3 { context.insert(ScenarioNote(text: "n\(i):0")) } }
        try a.insertSubscriptions(["s1"])
        await a.sync(); await b.sync()

        b.synchronizer.stop()
        try b.change { context in
            try fetchNote(context, prefix: "n1:")?.text = "n1:B"
            try fetchSub(context, "s1")?.title = "B title"
        }
        try a.change { context in if let note = try fetchNote(context, prefix: "n2:") { context.delete(note) } }
        await a.sync()
        try b.change { context in try fetchNote(context, prefix: "n2:")?.text = "n2:B" }
        try await b.synchronizer.resetSyncData()
        b.synchronizer.start()
        await b.settle()
        let snapshot = try await assertConverged([a, b])
        print("RESET notes \(snapshot.notes) subs \(snapshot.subscriptions)")
        #expect(snapshot.notes.filter { $0.hasPrefix("n1:") }.count == 1, "\(snapshot.notes)")
        a.terminate(); b.terminate()
    }

    // MARK: 15. The zone deleted on one device while two others edit

    @Test func zoneDeletedWhileOthersEdit() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(feedLinks(1...10))
        try a.change { context in for i in 1...10 { context.insert(ScenarioNote(text: "n\(i):0")) } }
        await a.sync(); await b.sync(); await c.sync()

        server.deleteZone(account: "first", byUser: false)
        try b.change { context in
            for i in 1...3 { try fetchSub(context, feedLinks(i...i)[0])?.title = "B \(i)" }
            if let note = try fetchNote(context, prefix: "n1:") { context.delete(note) }
        }
        try c.change { context in
            for i in 2...4 { try fetchSub(context, feedLinks(i...i)[0])?.position = 100 + i }
            context.insert(ScenarioNote(text: "n11:C"))
        }
        await b.sync(); await c.sync(); await a.sync()
        let snapshot = try await assertConverged([a, b, c])
        #expect(snapshot.subscriptionKeys.count == 10)
        #expect(snapshot.notes.contains("n11:C"))
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: 16. Throttled uploads while other devices delete

    @Test func throttledUploadWhileOthersDelete() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(feedLinks(1...10))
        await a.sync(); await b.sync()

        server.failNextModify(with: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 1.0]))
        try a.change { context in for i in 1...10 { try fetchSub(context, feedLinks(i...i)[0])?.title = "A \(i)" } }
        await a.settle()
        try b.change { context in for i in 1...5 { if let model = try fetchSub(context, feedLinks(i...i)[0]) { context.delete(model) } } }
        await b.sync()
        try await Task.sleep(for: .seconds(2))
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.subscriptionKeys.count == 5, "\(snapshot.subscriptions)")
        #expect(!snapshot.subscriptionKeys.contains(""))
        a.terminate(); b.terminate()
    }

    // MARK: 17. Both devices swap the same identities, sequentially (no upload races)

    @Test func twoDevicesSwapTheSameIdentities() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.insertSubscriptions(["s1", "s2", "s3"])
        try a.change { context in
            for (name, feed) in [("l1", "s1"), ("l2", "s2")] {
                let link = ScenarioLink(name: name)
                context.insert(link)
                link.subscription = try fetchSub(context, feed)
            }
        }
        await a.sync(); await b.sync(); await c.sync()
        for device in [a, b, c] { device.synchronizer.stop() }

        for device in [a, b] {
            try device.change { context in
                let s1 = try #require(try fetchSub(context, "s1")), s2 = try #require(try fetchSub(context, "s2"))
                s1.feedLink = "tmp"; s2.feedLink = "s1"; s1.feedLink = "s2"
                s1.title = "was s1 on \(device.name)"
            }
        }
        try c.change { context in
            try fetchSub(context, "s1")?.position = 77
            try fetchLink(context, "l1")?.subscription = try fetchSub(context, "s3")
        }
        for device in [a, b, c] {
            device.synchronizer.start(); await device.settle(); await device.sync()
            device.synchronizer.stop(); await device.settle()
        }
        for device in [a, b, c] { device.synchronizer.start() }
        let snapshot = try await assertConverged([a, b, c])
        #expect(snapshot.subscriptionKeys == ["s1", "s2", "s3"], "\(snapshot.subscriptions)")
        #expect(snapshot.links.count == 2, "\(snapshot.links)")
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: 18. Large values edited while killed mid-upload and relaunched with paging

    @Test func largeValuesKilledMidUpload() async throws {
        let server = FakeCloudServer()
        server.pageSize = 2
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(["s1", "s2", "s3"])
        await a.sync(); await b.sync()

        let big = Data(repeating: 9, count: 500_000)
        let killed = OSAllocatedUnfairLockBox(false)
        server.beforeModifyRecords = { device, _ in
            guard device == "A", killed.take() == false else { return }
            a.terminate()
        }
        try a.change { context in
            try fetchSub(context, "s1")?.artwork = big
            try fetchSub(context, "s2")?.note = String(repeating: "z", count: 400_000)
        }
        #expect(await waitUntil { killed.value })
        server.beforeModifyRecords = nil
        try b.change { context in
            try fetchSub(context, "s1")?.title = "B title"
            try fetchSub(context, "s2")?.artwork = Data(repeating: 1, count: 300_000)
        }
        await b.sync()
        try await Task.sleep(for: .milliseconds(200))
        try await a.launch()
        try a.change { context in try fetchSub(context, "s1")?.note = String(repeating: "q", count: 300_000) }
        await a.sync()
        let snapshot = try await assertConverged([a, b])
        let s1 = snapshot.subscriptions.first { $0.hasPrefix("s1|") } ?? ""
        #expect(s1.contains("B title") && s1.contains(shortHash(big)), "\(s1)")
        a.terminate(); b.terminate()
    }

    // MARK: 19. Upserting a model with a unique value

    /// Inserting a model whose unique value exists replaces the existing one's values (SwiftData's upsert).
    @Test func upsertOfAUniqueValueIsUploaded() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { $0.insert(ScenarioTag(name: "red", color: "first")) }
        await a.sync(); await b.sync()

        try a.change { $0.insert(ScenarioTag(name: "red", color: "second")) }
        await a.sync(); await b.sync()
        print("UPSERT A \(try a.snapshot().tags) server \(server.snapshot(account: "first").tags) B \(try b.snapshot().tags)")
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.tags == ["red|second"], "\(snapshot.tags)")
        a.terminate(); b.terminate()
    }

    /// Upserts in quick succession, while synchronizations run, like the fuzz run that left a color behind.
    @Test(arguments: 0..<4) func upsertsInQuickSuccession(delayMs: Int) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try b.change { $0.insert(ScenarioTag(name: "red", color: "b0")) }
        await b.sync(); await a.sync()
        try a.change { $0.insert(ScenarioTag(name: "red", color: "a1")) }
        try a.change { $0.insert(ScenarioTag(name: "red", color: "a2")) }
        try await Task.sleep(for: .milliseconds(delayMs * 30))
        try a.change { $0.insert(ScenarioTag(name: "red", color: "a3")) }
        try await Task.sleep(for: .milliseconds(delayMs * 20))
        try a.change { $0.insert(ScenarioTag(name: "red", color: "a4")) }
        await a.settle()
        print("UPSERT2 \(delayMs) A \(try a.snapshot().tags) server \(server.snapshot(account: "first").tags)")
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.tags == ["red|a4"], "\(snapshot.tags)")
        a.terminate(); b.terminate()
    }

    /// The fuzz run's sequence: a tag is created and upserted right away, synchronized, and upserted again later.
    @Test(arguments: [false, true]) func upsertAfterAnInsertAndUpsert(syncBetween: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { $0.insert(ScenarioTag(name: "red", color: "c39")) }
        if syncBetween { await a.settle() }
        try a.change { $0.insert(ScenarioTag(name: "red", color: "c40")) }
        await a.settle()
        await a.sync(); await b.sync()
        try a.change { $0.insert(ScenarioTag(name: "red", color: "c53")) }
        await a.settle()
        await a.sync()
        let tagCount = try a.count(ScenarioTag.self)
        print("UPSERT3 \(syncBetween) A \(try a.snapshot().tags) count \(tagCount) server \(server.snapshot(account: "first").tags)")
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.tags == ["red|c53"], "\(snapshot.tags)")
        a.terminate(); b.terminate()
    }

    /// An upsert saved while a download is applied or saved.
    @Test(arguments: [false, true]) func upsertWhileDownloading(touchTag: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try b.change { $0.insert(ScenarioTag(name: "red", color: "c40")) }
        await b.sync(); await a.sync()
        try a.insertSubscriptions(["s1", "s2"])
        if touchTag { try a.change { context in try fetchTag(context, "red")?.color = "fromA" } }
        await a.sync()
        let once = OSAllocatedUnfairLockBox(false)
        server.beforePageTokenUpdate = { device, _ in
            guard device == "B", once.take() == false else { return }
            try? b.change { $0.insert(ScenarioTag(name: "red", color: "c53")) }
        }
        await b.sync()
        server.beforePageTokenUpdate = nil
        await b.sync()
        print("UPSERT4 \(touchTag) B \(try b.snapshot().tags) server \(server.snapshot(account: "first").tags)")
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.tags == ["red|c53"], "\(snapshot.tags)")
        a.terminate(); b.terminate()
    }

    /// An upsert saved while the tag's previous upsert is being uploaded.
    @Test(arguments: [false, true]) func upsertWhileUploading(firstInsert: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        if !firstInsert {
            try b.change { $0.insert(ScenarioTag(name: "red", color: "c0")) }
            await b.sync()
        }
        let once = OSAllocatedUnfairLockBox(false)
        server.beforeModifyRecords = { device, saved in
            guard device == "B", !saved.isEmpty, once.take() == false else { return }
            try? b.change { $0.insert(ScenarioTag(name: "red", color: "c53")) }
        }
        try b.change { $0.insert(ScenarioTag(name: "red", color: "c40")) }
        await b.settle()
        server.beforeModifyRecords = nil
        await b.sync()
        print("UPSERT5 \(firstInsert) B \(try b.snapshot().tags) server \(server.snapshot(account: "first").tags)")
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.tags == ["red|c53"], "\(snapshot.tags)")
        a.terminate(); b.terminate()
    }

    /// A new device edits a model it downloaded while its download is still running, and is killed a second later.
    @Test(arguments: [false, true]) func editDuringAHungDownloadSurvivesAKill(otherDeviceEdits: Bool) async throws {
        let server = FakeCloudServer()
        server.pageSize = 40
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.insertSubscriptions(feedLinks(1...400))
        await a.sync()

        let b = TestDevice("B", server: server)
        server.hangDownloadDevice = "B"
        server.hangDownloadAfterPages = 4
        try await b.launch(waitForSync: false)
        #expect(await waitUntil { server.hungDownloads == 1 })
        b.terminate()
        if otherDeviceEdits {
            try a.change { context in for i in stride(from: 1, through: 400, by: 7) { if let m = try fetchSub(context, feedLinks(i...i)[0]) { context.delete(m) } } }
            await a.sync()
        }
        server.hangDownloadAfterPages = 6
        try await b.launch(waitForSync: false)
        #expect(await waitUntil { server.hungDownloads == 2 })
        try b.change { context in for i in 3...5 { try fetchSub(context, feedLinks(i...i)[0])?.position = 5000 + i } }
        try await Task.sleep(for: .seconds(1))
        b.terminate()
        try await b.launch()
        await b.sync()
        let snapshot = try await assertConverged([a, b])
        for i in 3...5 {
            #expect(snapshot.subscriptions.contains { $0.hasPrefix("\(feedLinks(i...i)[0])|") && $0.contains("|\(5000 + i)|") }, "Edit of \(i) lost")
        }
        a.terminate(); b.terminate()
    }
}

/// A tiny lock box for flags set from the fake server's queue.
final class OSAllocatedUnfairLockBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func set(_ value: Value) { lock.withLock { _value = value } }
}

extension OSAllocatedUnfairLockBox where Value == Bool {
    /// Returns the previous value and sets it to true.
    func take() -> Bool { lock.withLock { defer { _value = true }; return _value } }
}
