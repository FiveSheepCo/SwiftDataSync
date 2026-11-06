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

private func fetchWorkspace(_ context: ModelContext, _ title: String) throws -> ScenarioWorkspace? {
    try context.fetch(FetchDescriptor<ScenarioWorkspace>(predicate: #Predicate { $0.title == title })).first
}

private func fetchLink(_ context: ModelContext, _ name: String) throws -> ScenarioLink? {
    try context.fetch(FetchDescriptor<ScenarioLink>(predicate: #Predicate { $0.name == name })).first
}

/// Notes of an `NSManagedObjectContext` of the device's store, by text prefix.
private func coreDataNote(_ context: NSManagedObjectContext, prefix: String) throws -> NSManagedObject? {
    try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioNote")).first { ($0.value(forKey: "text") as? String)?.hasPrefix(prefix) == true }
}

/// Saves of a context made from an app's observer of `NSManagedObjectContextDidSave`, registered before any synchronizer, so
/// it runs before the synchronizer's. Each step runs in the DidSave of the save before it.
private final class NestedSaver: @unchecked Sendable {
    private let lock = NSLock()
    private var context: NSManagedObjectContext?
    private var steps: [(NSManagedObjectContext) -> Void] = []
    private var observer: NSObjectProtocol?
    private(set) var failures: [String] = []

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { [weak self] notification in
            guard let self, let context = notification.object as? NSManagedObjectContext else { return }
            let step: ((NSManagedObjectContext) -> Void)? = lock.withLock {
                guard self.context === context, !steps.isEmpty else { return nil }
                return steps.removeFirst()
            }
            guard let step else { return }
            step(context)
            do {
                try context.save()
            } catch {
                lock.withLock { failures.append("\(error)") }
                context.rollback()
            }
        }
    }

    func arm(_ context: NSManagedObjectContext, steps: [(NSManagedObjectContext) -> Void]) {
        lock.withLock {
            self.context = context
            self.steps = steps
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// A Core Data model with an identity and what SwiftData can't express: an ordered list of items, and an info that requires
/// its playlist.
nonisolated(unsafe) private let collisionModel: NSManagedObjectModel = {
    func attribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.type = .string
        attribute.isOptional = true
        return attribute
    }
    let playlist = NSEntityDescription(); playlist.name = "CPlaylist"
    let item = NSEntityDescription(); item.name = "CItem"
    let info = NSEntityDescription(); info.name = "CInfo"

    let items = NSRelationshipDescription()
    items.name = "items"; items.destinationEntity = item; items.isOrdered = true; items.maxCount = 0; items.isOptional = true
    items.deleteRule = .cascadeDeleteRule
    let owner = NSRelationshipDescription()
    owner.name = "playlist"; owner.destinationEntity = playlist; owner.maxCount = 1; owner.isOptional = true; owner.deleteRule = .nullifyDeleteRule
    items.inverseRelationship = owner; owner.inverseRelationship = items

    let toInfo = NSRelationshipDescription()
    toInfo.name = "info"; toInfo.destinationEntity = info; toInfo.maxCount = 1; toInfo.isOptional = true; toInfo.deleteRule = .cascadeDeleteRule
    let infoOwner = NSRelationshipDescription()
    infoOwner.name = "playlist"; infoOwner.destinationEntity = playlist; infoOwner.maxCount = 1; infoOwner.minCount = 1
    infoOwner.isOptional = false; infoOwner.deleteRule = .nullifyDeleteRule
    toInfo.inverseRelationship = infoOwner; infoOwner.inverseRelationship = toInfo

    playlist.properties = [attribute("title"), attribute("comment"), items, toInfo]
    item.properties = [attribute("name"), owner]
    info.properties = [attribute("text"), infoOwner]
    let model = NSManagedObjectModel()
    model.entities = [playlist, item, info]
    return model
}()

private let collisionConfiguration = SDSConfiguration(rawEntities: [
    "CPlaylist": .sync(.all, identity: ["title"]),
    "CItem": .sync(.all),
    "CInfo": .sync(.all)
])

/// A device of a Core Data store of `collisionModel`.
private final class CollisionDevice: @unchecked Sendable {
    let name: String
    let synchronizer: SDSSynchronizer
    let coordinator: NSPersistentStoreCoordinator

    init(_ name: String, server: FakeCloudServer) async throws {
        self.name = name
        let directory = FileManager.default.temporaryDirectory.appending(path: "SwiftDataSync Tests/\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "Sync"), withIntermediateDirectories: true)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: collisionModel)
        _ = try coordinator.addPersistentStore(type: .sqlite, at: directory.appending(path: "Collision.sqlite"))
        let cloud = FakeCloudContainer(server: server, device: name, account: .signedIn("first"))
        synchronizer = SDSSynchronizer(
            syncDataDirectory: directory.appending(path: "Sync"),
            viewModel: SDSSynchronizationViewModel(),
            makeCloudContainer: { _ in cloud },
            monitorsNetwork: false,
            timing: .init(saveSynchronizationDelay: .milliseconds(50), routineRetryInterval: 3600)
        )
        synchronizer.setup(containerName: "iCloud.test", configuration: collisionConfiguration, coordinator: coordinator)
        for _ in 0..<100 where synchronizer.startedSynchronizationCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await sync()
    }

    func sync() async {
        await settle()
        await synchronizer.synchronize()
        await settle()
    }

    func settle() async {
        var idleChecks = 0
        for _ in 0..<3000 {
            var isBusy = synchronizer.hasPendingSaveSync || synchronizer.hasPendingSyncStart || synchronizer.isSynchronizing
            if !isBusy {
                switch await synchronizer.viewModel.state {
                case .bootstrapping, .uploading, .downloading, .processingSaveEvent, .waitingForSetup, .waitingForContainerDetection: isBusy = true
                default: break
                }
            }
            idleChecks = isBusy ? 0 : idleChecks + 1
            if idleChecks >= 3 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("\(name) didn't finish synchronizing")
    }

    func change(_ body: (NSManagedObjectContext) throws -> Void) throws {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            try body(context)
            try context.save()
        }
    }

    /// Every playlist with its items in order and its info, sorted, duplicates kept.
    func snapshot() throws -> [String] {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return try context.performAndWait {
            var lines = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "CPlaylist")).map { playlist in
                let items = ((playlist.value(forKey: "items") as? NSOrderedSet)?.array as? [NSManagedObject] ?? []).map { $0.value(forKey: "name") as? String ?? "?" }
                let info = (playlist.value(forKey: "info") as? NSManagedObject)?.value(forKey: "text") as? String ?? "-"
                return "P \(playlist.value(forKey: "title") as? String ?? "?") comment=\(playlist.value(forKey: "comment") as? String ?? "-") items=\(items) info=\(info)"
            }
            lines += try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "CItem")).map { item in
                "I \(item.value(forKey: "name") as? String ?? "?") in \((item.value(forKey: "playlist") as? NSManagedObject)?.value(forKey: "title") as? String ?? "-")"
            }
            lines += try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "CInfo")).map { info in
                "F \(info.value(forKey: "text") as? String ?? "?") of \((info.value(forKey: "playlist") as? NSManagedObject)?.value(forKey: "title") as? String ?? "-")"
            }
            return lines.sorted()
        }
    }

    func invalidate() { synchronizer.invalidate() }
}

/// Round 6 scenarios, aimed at the latest commits: nested saves, inserts racing downloads of the same identity, large values,
/// identity moves while iCloud is full, and records gone after expired change tokens.
@Suite(.coreDataReady, .adversarial, .serialized, .timeLimit(.minutes(6)))
struct Round6ScenarioTests {

    // MARK: Nested saves from DidSave observers

    /// The app's DidSave observer, which runs before the synchronizer's, saves the context again, and that save fails
    /// (validation). The first save's edit must still be uploaded, and the failed save's value must not.
    @Test(arguments: [false, true]) func failedNestedSaveKeepsTheOuterSavesEdits(withDeletion: Bool) async throws {
        let saver = NestedSaver()
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            for index in 1...3 { context.insert(ScenarioNote(text: "n\(index)")) }
        }
        await a.sync(); await b.sync()

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = try #require(a.synchronizer.observedStore)
        try context.performAndWait {
            saver.arm(context, steps: [{ context in
                // Text is required, so this save fails
                try? coreDataNote(context, prefix: "n2")?.setValue(nil, forKey: "text")
            }])
            try coreDataNote(context, prefix: "n1")?.setValue("n1 edited", forKey: "text")
            if withDeletion, let n3 = try coreDataNote(context, prefix: "n3") { context.delete(n3) }
            try context.save()
        }
        #expect(saver.failures.count == 1, "The nested save was expected to fail: \(saver.failures)")
        await a.sync(); await a.sync(); await b.sync()
        let expected = withDeletion ? ["n1 edited", "n2"] : ["n1 edited", "n2", "n3"]
        #expect(a.serverNotes() == expected, "server \(a.serverNotes())")
        try await assertConverged([a, b])
        a.terminate(); b.terminate()
    }

    /// The app's DidSave observer, which runs before the synchronizer's, saves the context again without changes, e.g. an
    /// unconditional `try context.save()`, or a deletion of an object the context doesn't have. The first save's edits must
    /// still be uploaded.
    @Test(arguments: [false, true]) func emptyNestedSaveKeepsTheOuterSavesEdits(touchesNothing: Bool) async throws {
        let saver = NestedSaver()
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            for index in 1...2 { context.insert(ScenarioNote(text: "n\(index)")) }
        }
        await a.sync(); await b.sync()
        let willSaves = OSAllocatedUnfairLock(initialState: 0)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = try #require(a.synchronizer.observedStore)
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: context, queue: nil) { _ in
            willSaves.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try context.performAndWait {
            saver.arm(context, steps: [{ context in
                if !touchesNothing {
                    // Read, but not changed
                    _ = try? coreDataNote(context, prefix: "n2")?.value(forKey: "text")
                }
            }])
            try coreDataNote(context, prefix: "n1")?.setValue("n1 edited", forKey: "text")
            try context.save()
        }
        print("EMPTYNESTED WillSave notifications: \(willSaves.withLock { $0 })")
        await a.sync(); await a.sync(); await b.sync()
        #expect(a.serverNotes() == ["n1 edited", "n2"], "server \(a.serverNotes())")
        try await assertConverged([a, b])
        a.terminate(); b.terminate()
    }

    /// Like `failedNestedSaveKeepsTheOuterSavesEdits`, but the nested save fails with a merge conflict, as another context
    /// (e.g. a download) saved n2 in between, and the context has the default merge policy (`NSErrorMergePolicy`).
    @Test func nestedSaveWithAMergeConflictKeepsTheOuterSavesEdits() async throws {
        let saver = NestedSaver()
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            for index in 1...2 { context.insert(ScenarioNote(text: "n\(index)")) }
        }
        await a.sync(); await b.sync()
        let coordinator = try #require(a.synchronizer.observedStore)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            _ = try coreDataNote(context, prefix: "n2")?.value(forKey: "text")
            saver.arm(context, steps: [{ context in
                // Another context saves n2 meanwhile
                let other = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                other.persistentStoreCoordinator = coordinator
                other.performAndWait {
                    try? coreDataNote(other, prefix: "n2")?.setValue("n2 other", forKey: "text")
                    try? other.save()
                }
                try? coreDataNote(context, prefix: "n2")?.setValue("n2 nested", forKey: "text")
            }])
            try coreDataNote(context, prefix: "n1")?.setValue("n1 edited", forKey: "text")
            try context.save()
        }
        print("MERGECONFLICT nested failures: \(saver.failures)")
        await a.sync(); await a.sync(); await b.sync()
        let aNotes = try a.notes()
        #expect(a.serverNotes() == ["n1 edited", "n2 other"], "server \(a.serverNotes()), A \(aNotes)")
        try await assertConverged([a, b])
        a.terminate(); b.terminate()
    }

    /// Saves nested three deep from the app's DidSave observer, with edits, an insert and a deletion in each. Everything that
    /// was saved is uploaded.
    @Test(arguments: 0..<3) func nestedSavesThreeDeep(variant: Int) async throws {
        let saver = NestedSaver()
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            for index in 1...5 { context.insert(ScenarioNote(text: "n\(index)")) }
            context.insert(ScenarioSubscription(feedLink: "s1", title: "s1"))
        }
        await a.sync(); await b.sync()
        // B edits other keys meanwhile, so downloads run while A's keys are stacked
        try b.editSubscription("s1") { $0.position = 7 }
        await b.sync()

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = try #require(a.synchronizer.observedStore)
        try context.performAndWait {
            saver.arm(context, steps: [
                { context in
                    try? coreDataNote(context, prefix: "n2")?.setValue("n2 depth1", forKey: "text")
                    let note = NSEntityDescription.insertNewObject(forEntityName: "ScenarioNote", into: context)
                    note.setValue("n6 depth1", forKey: "text")
                },
                { context in
                    if let n4 = try? coreDataNote(context, prefix: "n4") { context.delete(n4) }
                    try? coreDataNote(context, prefix: "n1")?.setValue("n1 depth2", forKey: "text")
                    if variant == 1 {
                        let sub = try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription")).first
                        sub?.setValue("s1 depth2", forKey: "title")
                    }
                },
                { context in
                    try? coreDataNote(context, prefix: "n3")?.setValue("n3 depth3", forKey: "text")
                    if variant == 2 {
                        // Fails, so depth 3 isn't saved
                        try? coreDataNote(context, prefix: "n5")?.setValue(nil, forKey: "text")
                    }
                }
            ])
            try coreDataNote(context, prefix: "n1")?.setValue("n1 depth0", forKey: "text")
            try coreDataNote(context, prefix: "n5")?.setValue("n5 depth0", forKey: "text")
            try context.save()
        }
        await a.sync(); await a.sync(); await b.sync()
        let local = try a.notes()
        #expect(a.serverNotes() == local, "server \(a.serverNotes()) local \(local)")
        let snapshot = try await assertConverged([a, b])
        print("NESTED \(variant): \(snapshot.notes) \(snapshot.subscriptions)")
        a.terminate(); b.terminate()
    }

    // MARK: Inserts racing downloads of the same identity

    /// B's app checks that s9 (or document d9) doesn't exist, and inserts it, but saves it (e.g. autosave) only after B
    /// downloaded A's s9. The store then has two models of one identity, which must not become two records everywhere.
    @Test(arguments: [false, true]) func insertSavedRightAfterADownloadOfTheSameIdentity(document: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { $0.insert(ScenarioWorkspace(title: "w1")) }
        await a.sync(); await b.sync()
        try a.change { context in
            if document {
                let d = ScenarioDocument(title: "d9"); d.body = "from A"; context.insert(d); d.workspace = try fetchWorkspace(context, "w1")
            } else {
                context.insert(ScenarioSubscription(feedLink: "s9", title: "from A"))
            }
        }
        await a.sync()

        // B's app context: it looked for s9 and didn't find it, and inserts it, unsaved
        let appContext = ModelContext(try #require(b.modelContainer))
        appContext.autosaveEnabled = false
        if document {
            #expect(try appContext.fetch(FetchDescriptor<ScenarioDocument>()).isEmpty)
            let d = ScenarioDocument(title: "d9"); d.body = "from B"; appContext.insert(d)
        } else {
            #expect(try fetchSub(appContext, "s9") == nil)
            appContext.insert(ScenarioSubscription(feedLink: "s9", title: "from B"))
        }
        await b.sync()
        try appContext.save()
        await b.sync(); await a.sync(); await b.sync()
        let snapshot = try await assertConverged([a, b])
        print("RACEB \(document): \(snapshot.subscriptions) \(snapshot.documents)")
        let records = server.records(account: "first").filter { $0.recordType == (document ? "ScenarioDocument" : "ScenarioSubscription") }
        #expect(records.count == 1, "\(records.map(\.recordID.recordName))")
        a.terminate(); b.terminate()
    }

    /// Like `Round5ScenarioTests.localInsertWhileADownloadInsertsTheSameIdentity`, but B is killed right after the download
    /// that found the collision, before a later page or download merged it.
    @Test(arguments: [false, true]) func collisionThenKilledBeforeTheMerge(document: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { $0.insert(ScenarioWorkspace(title: "w1")) }
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
        #expect(fired.withLock { $0 })
        let afterFirst = server.records(account: "first").filter { $0.recordType == (document ? "ScenarioDocument" : "ScenarioSubscription") }.map(\.recordID.recordName)
        print("COLLISIONKILL \(document) after the first sync: \(afterFirst)")
        b.terminate()
        try await b.launch()
        await b.sync(); await a.sync(); await b.sync()
        let snapshot = try await assertConverged([a, b])
        print("COLLISIONKILL \(document): \(snapshot.subscriptions) \(snapshot.documents)")
        let records = server.records(account: "first").filter { $0.recordType == (document ? "ScenarioDocument" : "ScenarioSubscription") }
        #expect(records.count == 1, "\(records.map(\.recordID.recordName))")
        a.terminate(); b.terminate()
    }

    /// A creates s9 with link La, B creates s9 with link Lb while its download inserts A's. Both links end up in the one s9.
    @Test(arguments: [false, true]) func collisionWithChildrenOnBothSides(linkInLaterPage: Bool) async throws {
        let server = FakeCloudServer()
        if linkInLaterPage { server.pageSize = 1 }
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            let s = ScenarioSubscription(feedLink: "s9", title: "from A"); context.insert(s)
            let link = ScenarioLink(name: "La"); context.insert(link); link.subscription = s
        }
        await a.sync()

        let fired = OSAllocatedUnfairLock(initialState: false)
        let container = try #require(b.modelContainer)
        b.synchronizer.beforeSavingDownloadedObjects = {
            guard fired.withLock({ f in defer { f = true }; return !f }) else { return }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let s = ScenarioSubscription(feedLink: "s9", title: "from B"); context.insert(s)
            let link = ScenarioLink(name: "Lb"); context.insert(link); link.subscription = s
            try? context.save()
        }
        await b.sync()
        b.synchronizer.beforeSavingDownloadedObjects = nil
        await b.sync(); await a.sync(); await b.sync()
        let snapshot = try await assertConverged([a, b])
        print("COLLISIONCHILD \(linkInLaterPage): \(snapshot.subscriptions) \(snapshot.links)")
        #expect(snapshot.subscriptionKeys == ["s9"])
        #expect(snapshot.links.sorted() == ["La|s9", "Lb|s9"], "\(snapshot.links)")
        a.terminate(); b.terminate()
    }

    /// Core Data: a playlist with an identity, ordered items and an info that requires it, created on A, and on B while
    /// B's download inserts A's. Every device and a new one must agree, without duplicates or lost items.
    @Test(arguments: 0..<3) func collisionWithOrderedAndRequiredRelationships(variant: Int) async throws {
        let server = FakeCloudServer()
        let a = try await CollisionDevice("A", server: server)
        let b = try await CollisionDevice("B", server: server)
        try a.change { context in
            let p = NSEntityDescription.insertNewObject(forEntityName: "CPlaylist", into: context)
            p.setValue("P", forKey: "title"); p.setValue("from A", forKey: "comment")
            let items = ["a1", "a2"].map { name in
                let item = NSEntityDescription.insertNewObject(forEntityName: "CItem", into: context)
                item.setValue(name, forKey: "name")
                return item
            }
            p.setValue(NSOrderedSet(array: items), forKey: "items")
            if variant != 2 {
                let info = NSEntityDescription.insertNewObject(forEntityName: "CInfo", into: context)
                info.setValue("info A", forKey: "text"); info.setValue(p, forKey: "playlist")
            }
        }
        await a.sync()

        let fired = OSAllocatedUnfairLock(initialState: false)
        let coordinator = b.coordinator
        b.synchronizer.beforeSavingDownloadedObjects = {
            guard fired.withLock({ f in defer { f = true }; return !f }) else { return }
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.performAndWait {
                let p = NSEntityDescription.insertNewObject(forEntityName: "CPlaylist", into: context)
                p.setValue("P", forKey: "title"); p.setValue("from B", forKey: "comment")
                if variant != 1 {
                    let item = NSEntityDescription.insertNewObject(forEntityName: "CItem", into: context)
                    item.setValue("b1", forKey: "name")
                    p.setValue(NSOrderedSet(array: [item]), forKey: "items")
                }
                let info = NSEntityDescription.insertNewObject(forEntityName: "CInfo", into: context)
                info.setValue("info B", forKey: "text"); info.setValue(p, forKey: "playlist")
                do { try context.save() } catch { Issue.record("B's save failed: \(error)") }
            }
        }
        await b.sync()
        b.synchronizer.beforeSavingDownloadedObjects = nil
        #expect(fired.withLock { $0 })
        for _ in 0..<3 { await b.sync(); await a.sync() }
        let c = try await CollisionDevice("C", server: server)
        await c.sync()
        let (sa, sb, sc) = (try a.snapshot(), try b.snapshot(), try c.snapshot())
        print("CDCOLLISION \(variant)\n A \(sa)\n B \(sb)\n C \(sc)")
        #expect(sa == sb, "A \(sa)\nB \(sb)")
        #expect(sc == sb, "C \(sc)\nB \(sb)")
        #expect(sb.filter { $0.hasPrefix("P ") }.count == 1, "\(sb)")
        let records = server.records(account: "first").filter { $0.recordType == "CPlaylist" }
        #expect(records.count == 1, "\(records.map(\.recordID.recordName))")
        for name in ["a1", "a2"] + (variant != 1 ? ["b1"] : []) {
            #expect(sb.contains("I \(name) in P"), "\(name) lost: \(sb)")
        }
        let infoRecords = server.records(account: "first").filter { $0.recordType == "CInfo" }
        print("CDCOLLISION \(variant) info records \(infoRecords.map { "\($0["text"] ?? "-")->\(($0["playlist"] as? CKRecord.Reference)?.recordID.recordName.prefix(12) ?? "-")" })")
        a.invalidate(); b.invalidate(); c.invalidate()
    }

    // MARK: Large values on several devices

    /// Three devices edit large and small values of s1 in random orders, syncing at random, with records read without values.
    @Test(arguments: 0..<12) func largeValuesOnThreeDevices(seed: Int) async throws {
        var rng = SplitMix64(seed: UInt64(seed) &+ 6000)
        // Like other synchronizers of the process (or processes sharing the caches directory) being set up meanwhile
        let purger = ProcessInfo.processInfo.environment["PURGE_TEMP_ASSETS"] == nil ? nil : Task.detached {
            while !Task.isCancelled {
                CKAsset.removeLeftoverTemporaryFiles(now: .distantFuture)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 5..<60)))
            }
        }
        defer { purger?.cancel() }
        let server = FakeCloudServer()
        let devices = ["A", "B", "C"].map { TestDevice($0, server: server) }
        for device in devices { try await device.launch() }
        try devices[0].change { context in
            let s = ScenarioSubscription(feedLink: "s1", title: "t0")
            s.note = String(repeating: "x", count: 300_000)
            s.artwork = Data(repeating: 1, count: 280_000)
            context.insert(s)
            context.insert(ScenarioSubscription(feedLink: "s2", title: "t0"))
        }
        await devices[0].sync()
        for device in devices { await device.sync() }
        var written: [String: Set<String>] = ["note": [shortHash(Data(String(repeating: "x", count: 300_000).utf8)), "-"], "artwork": [shortHash(Data(repeating: 1, count: 280_000))]]
        var log: [String] = []
        func edit(_ device: TestDevice, _ feed: String, _ body: @escaping (ScenarioSubscription) -> Void) throws {
            guard try device.subscription(feed) != nil else {
                Issue.record("\(device.name) lost \(feed): local \(try device.subscriptions().map(\.feedLink)), server \(server.snapshot(account: "first").subscriptionKeys)\n\(log.joined(separator: "\n"))")
                return
            }
            try device.editSubscription(feed, body)
        }
        for step in 0..<30 {
            let device = devices[Int.random(in: 0..<3, using: &rng)]
            let roll = Int.random(in: 0..<10, using: &rng)
            let feed = Int.random(in: 0..<4, using: &rng) == 0 ? "s2" : "s1"
            switch roll {
            case 0..<3:
                let kind = Int.random(in: 0..<3, using: &rng)
                let value: String? = kind == 0 ? nil : (kind == 1 ? "small \(device.name)\(step)" : String(repeating: "n", count: 250_000 + step) + device.name)
                log.append("\(step) \(device.name) note \(feed) \(kind)")
                try edit(device, feed) { $0.note = value }
                if feed == "s1" { written["note", default: []].insert(value.map { $0.count > 64 ? shortHash(Data($0.utf8)) : $0 } ?? "-") }
            case 3..<6:
                let kind = Int.random(in: 0..<3, using: &rng)
                let value: Data? = kind == 0 ? nil : (kind == 1 ? Data("a\(device.name)\(step)".utf8) : Data(repeating: UInt8(step), count: 260_000 + step))
                log.append("\(step) \(device.name) artwork \(feed) \(kind)")
                try edit(device, feed) { $0.artwork = value }
                if feed == "s1" { written["artwork", default: []].insert(shortHash(value)) }
            case 6:
                log.append("\(step) \(device.name) title \(feed)")
                try edit(device, feed) { $0.title = "t\(device.name)\(step)" }
            default:
                log.append("\(step) \(device.name) sync")
                await device.sync()
            }
        }
        let snapshot = try await assertConverged(devices)
        let line = try #require(snapshot.subscriptions.first { $0.hasPrefix("s1|") }).split(separator: "|").map(String.init)
        #expect(written["note"]?.contains(line[5]) == true, "note nobody wrote: \(line[5]) \(log)")
        #expect(written["artwork"]?.contains(line[6]) == true, "artwork nobody wrote: \(line[6]) \(log)")
        for device in devices { device.terminate() }
    }

    // MARK: Identity moves while iCloud is full

    /// While iCloud is full, A moves s1 (with a link) to s1x, edits it, moves it again or back, adds a link, and B edits s1
    /// meanwhile. Once there's room, everyone agrees, with nothing lost or duplicated.
    @Test(arguments: 0..<4) func identityMovesWhileICloudIsFullThenMoreEdits(variant: Int) async throws {
        let server = FakeCloudServer()
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server), c = TestDevice("C", server: server)
        try await a.launch(); try await b.launch(); try await c.launch()
        try a.change { context in
            let s1 = ScenarioSubscription(feedLink: "s1", title: "s1"); context.insert(s1)
            context.insert(ScenarioSubscription(feedLink: "s2", title: "s2"))
            let link = ScenarioLink(name: "L1"); context.insert(link); link.subscription = s1
        }
        await a.sync(); await b.sync(); await c.sync()

        let full = OSAllocatedUnfairLock(initialState: true)
        server.failSaving(where: { _ in full.withLock { $0 } }, with: CKError(.quotaExceeded))
        try a.editSubscription("s1") { $0.feedLink = "s1x"; $0.title = "moved" }
        await a.sync()
        try a.editSubscription("s1x") { $0.position = 5 }
        await a.sync()
        switch variant {
        case 0:
            try a.editSubscription("s1x") { $0.feedLink = "s1y" }
        case 1:
            try a.editSubscription("s1x") { $0.feedLink = "s1" }
        case 2:
            try a.deleteSubscription("s2")
            try a.editSubscription("s1x") { $0.feedLink = "s2" }
        default:
            try a.deleteSubscription("s1x")
        }
        await a.sync()
        try a.change { context in
            guard let s = try fetchSub(context, variant == 0 ? "s1y" : (variant == 1 ? "s1" : "s2")) else { return }
            let link = ScenarioLink(name: "L2"); context.insert(link); link.subscription = s
        }
        try b.editSubscription("s1") { $0.isMuted = true }
        await a.sync(); await b.sync(); await c.sync(); await a.sync()
        let midC = try c.subscriptions().map(\.feedLink)
        let midLinks = try c.snapshot().links
        print("FULLMOVES \(variant) while full C has \(midC) links \(midLinks), server \(server.snapshot(account: "first").subscriptions)")
        if variant != 3 {
            #expect(!midC.isEmpty && (midC.contains("s1") || midC.contains("s1x") || midC.contains("s1y")) || variant == 2, "C lost the subscription while iCloud is full: \(midC)")
            #expect(midLinks.contains { $0.hasPrefix("L1|") }, "C lost L1 while iCloud is full: \(midLinks)")
        }

        full.withLock { $0 = false }
        for device in [a, b, c] { device.synchronizer.resetQuarantine(); device.synchronizer.resumeUploads() }
        try a.editSubscription(variant == 3 ? "s2" : (variant == 0 ? "s1y" : (variant == 1 ? "s1" : "s2"))) { $0.rating = 1 }
        await a.sync(); await b.sync(); await a.sync()
        let snapshot = try await assertConverged([a, b, c])
        print("FULLMOVES \(variant): \(snapshot.subscriptions) links \(snapshot.links)")
        switch variant {
        case 0: #expect(snapshot.subscriptionKeys == ["s1y", "s2"]); #expect(snapshot.linkKeys.sorted() == ["L1", "L2"])
        case 1: #expect(snapshot.subscriptionKeys == ["s1", "s2"]); #expect(snapshot.linkKeys.sorted() == ["L1", "L2"])
        case 2: #expect(snapshot.subscriptionKeys == ["s2"]); #expect(snapshot.linkKeys.sorted() == ["L1", "L2"])
        default: #expect(snapshot.subscriptionKeys == ["s2"]); #expect(snapshot.linkKeys == ["L2"])
        }
        a.terminate(); b.terminate(); c.terminate()
    }

    // MARK: Records gone after expired change tokens

    /// s1 is deleted elsewhere while A's change token expires, so A never downloads the deletion. A edits s1, puts a link
    /// into it, deletes s3, edits s2 and adds notes; B edits s2's other key. A's other changes must arrive everywhere.
    @Test(arguments: [false, true]) func goneRecordsAfterExpiredTokensMixedWithOtherUpdates(manyGone: Bool) async throws {
        let server = FakeCloudServer()
        server.cascadesDeleteSelf = true
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        let goneFeeds = manyGone ? (0..<30).map { "g\($0)" } : ["g0"]
        try a.insertSubscriptions(goneFeeds + ["s2", "s3"])
        await a.sync(); await b.sync()
        b.synchronizer.stop()
        try b.change { context in
            for feed in goneFeeds { if let s = try fetchSub(context, feed) { context.delete(s) } }
        }
        server.deleteWhileTokensExpire(goneFeeds.map(subscriptionRecordName), account: "first")

        try a.change { context in
            for feed in goneFeeds { try fetchSub(context, feed)?.title = "edited after gone" }
            let link = ScenarioLink(name: "Lg"); context.insert(link); link.subscription = try fetchSub(context, "g0")
            if let s3 = try fetchSub(context, "s3") { context.delete(s3) }
            try fetchSub(context, "s2")?.title = "A's title"
            for index in 0..<3 { context.insert(ScenarioNote(text: "note \(index)")) }
        }
        await a.sync(); await a.sync()
        b.synchronizer.start()
        try b.editSubscription("s2") { $0.position = 9 }
        await b.sync(); await a.sync(); await b.sync()

        let serverSnapshot = server.snapshot(account: "first")
        print("GONE \(manyGone) server \(serverSnapshot.subscriptions) links \(serverSnapshot.links) notes \(serverSnapshot.notes.count)")
        #expect(serverSnapshot.subscriptionKeys == ["s2"], "server \(serverSnapshot.subscriptionKeys)")
        #expect(serverSnapshot.subscriptions.first?.contains("A's title|9|") == true, "\(serverSnapshot.subscriptions)")
        #expect(serverSnapshot.notes.count == 3)
        let aSubs = try a.subscriptions().map(\.feedLink)
        print("GONE \(manyGone) A keeps \(aSubs), links \(try a.snapshot().links); B \(try b.subscriptions().map(\.feedLink)) links \(try b.snapshot().links)")
        try await assertConverged([a, b])
        a.terminate(); b.terminate()
    }

    // MARK: Temporary asset files

    /// Another synchronizer of the process is set up while A uploads a large value (or the system removes the cache), which
    /// removes every file in the shared temporary assets directory, also the one A's upload is about to send. CloudKit
    /// fails such a record with `assetFileNotFound`. The edit must still arrive soon, rather than an hour later.
    @Test func temporaryAssetFileRemovedWhileUploading() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync(); await b.sync()
        let removed = OSAllocatedUnfairLock(initialState: false)
        server.beforeReadingUploadedAssets = { device in
            guard device == "A", removed.withLock({ r in defer { r = true }; return !r }) else { return }
            CKAsset.removeLeftoverTemporaryFiles(now: .distantFuture)
        }
        let note = String(repeating: "n", count: 300_000)
        try a.editSubscription("s1") { $0.note = note }
        await a.sync(); await a.sync(); await b.sync()
        #expect(removed.withLock { $0 })
        let aState = await a.state
        #expect(try b.subscription("s1")?.note == note, "B didn't get the note, A's state \(aState)")
        // More edits and downloads, as in `largeValuesOnThreeDevices`
        try a.editSubscription("s1") { $0.note = "small" }
        await a.sync(); await b.sync(); await b.sync()
        if try b.subscription("s1") != nil { try b.editSubscription("s1") { $0.title = "B" } }
        await b.sync(); await a.sync()
        print("TMPASSET B \(try b.subscriptions()) A \(try a.subscriptions()) server \(server.snapshot(account: "first").subscriptions)")
        #expect(try b.subscription("s1") != nil, "B lost s1")
        #expect(try a.subscription("s1") != nil, "A lost s1")
        a.terminate(); b.terminate()
    }

    /// B downloads an edit of s1 whose overflow asset file is gone (e.g. the system removed it), once or every time. B must
    /// keep s1, and get the edit once the asset can be read.
    @Test(arguments: [1, 3]) func downloadedOverflowAssetUnreadable(times: Int) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            let s = ScenarioSubscription(feedLink: "s1", title: "t")
            s.artwork = Data(repeating: 3, count: 300_000)
            context.insert(s)
            context.insert(ScenarioSubscription(feedLink: "s2", title: "t"))
        }
        await a.sync(); await b.sync()
        #expect(try b.subscription("s1")?.artwork?.count == 300_000)
        let name = subscriptionRecordName("s1")
        server.breakAssetFiles(where: { $0.recordName == name }, count: times)
        try a.editSubscription("s1") { $0.title = "edited"; $0.note = String(repeating: "n", count: 300_000) }
        await a.sync()
        await b.sync()
        let afterFirst = try b.subscriptions().map(\.feedLink)
        #expect(afterFirst.contains("s1"), "B lost s1 after downloading an unreadable asset: \(afterFirst)")
        for _ in 0..<times { await b.sync() }
        let snapshot = try await assertConverged([a, b])
        #expect(snapshot.subscriptions.first?.contains("edited") == true, "\(snapshot.subscriptions)")
        a.terminate(); b.terminate()
    }

    /// The record of s1 in iCloud gets an overflow asset whose file can never be read, e.g. as it was uploaded without
    /// it. B, which has s1, downloads it. B must keep s1 (and its other values), rather than deleting it.
    @Test(arguments: [false, true]) func permanentlyUnreadableOverflowAsset(inTempDirectory: Bool) async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server), b = TestDevice("B", server: server)
        try await a.launch(); try await b.launch()
        try a.change { context in
            let s = ScenarioSubscription(feedLink: "s1", title: "t")
            s.artwork = Data(repeating: 3, count: 300_000)
            context.insert(s)
            context.insert(ScenarioSubscription(feedLink: "s2", title: "t"))
        }
        await a.sync(); await b.sync()
        let record = try #require(server.records(account: "first").first { $0.recordID.recordName == subscriptionRecordName("s1") })
        let directory = inTempDirectory ? CKAsset.temporaryFilesDirectory : FileManager.default.temporaryDirectory
        record["title"] = "edited"
        record[SDSOverflow.key] = CKAsset(fileURL: directory.appending(component: "missing-\(UUID().uuidString)"))
        server.seed([record], account: "first")
        await b.sync(); await b.sync()
        let bSubs = try b.subscriptions().map(\.feedLink)
        #expect(bSubs.contains("s1"), "B deleted s1 after downloading a record with an unreadable asset: \(bSubs)")
        let state = await b.state
        print("UNREADABLE \(inTempDirectory): B \(try b.subscriptions()) state \(state)")
        a.terminate(); b.terminate()
    }
}
