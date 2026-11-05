import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// A podcast subscription, identified by its feed like the models HardCast synchronizes.
@Model
final class ScenarioSubscription {
    var feedLink: String = ""
    var title: String = ""
    var position: Int = 0
    var isMuted: Bool = false
    var rating: Double = 0
    var addedAt: Date = Date.distantPast
    var note: String? = nil
    var artwork: Data? = nil
    @Relationship(deleteRule: .cascade, inverse: \ScenarioLink.subscription) var links: [ScenarioLink]? = []

    init(feedLink: String, title: String = "", position: Int = 0) {
        self.feedLink = feedLink
        self.title = title
        self.position = position
    }
}

/// How far an episode was played, identified by two values.
@Model
final class ScenarioEpisode {
    var feedLink: String = ""
    var guid: String = ""
    var elapsed: Double = 0
    var played: Bool = false

    init(feedLink: String, guid: String) {
        self.feedLink = feedLink
        self.guid = guid
    }
}

/// A model whose name is unique in the store, without an identity, e.g. one that existed before identities.
@Model
final class ScenarioTag {
    @Attribute(.unique) var name: String = ""
    var color: String = ""

    init(name: String, color: String = "") {
        self.name = name
        self.color = color
    }
}

/// A model without an identity that references a subscription, whose delete rule cascades to it.
@Model
final class ScenarioLink {
    var name: String = ""
    var subscription: ScenarioSubscription?

    init(name: String) {
        self.name = name
    }
}

/// A model without an identity, whose records are named randomly.
@Model
final class ScenarioNote {
    var text: String = ""

    init(text: String) {
        self.text = text
    }
}

/// A model with documents below it. It isn't sharable, as documents have an identity.
@Model
final class ScenarioWorkspace {
    var title: String = ""
    @Relationship(deleteRule: .cascade, inverse: \ScenarioDocument.workspace) var documents: [ScenarioDocument]? = []

    init(title: String) {
        self.title = title
    }
}

/// A document of a workspace, its parent, identified by its title.
@Model
final class ScenarioDocument {
    var title: String = ""
    var body: String = ""
    var workspace: ScenarioWorkspace?

    init(title: String) {
        self.title = title
    }
}

/// The values of a subscription, to compare them outside of their context.
struct SubscriptionValues: Equatable, Sendable, CustomStringConvertible {
    var feedLink: String
    var title: String
    var position: Int
    var isMuted: Bool
    var note: String?
    var artwork: Data?

    init(_ model: ScenarioSubscription) {
        feedLink = model.feedLink
        title = model.title
        position = model.position
        isMuted = model.isMuted
        note = model.note
        artwork = model.artwork
    }

    init(record: CKRecord) {
        feedLink = record["feedLink"] as? String ?? ""
        title = record["title"] as? String ?? ""
        position = (record["position"] as? Int64).map(Int.init) ?? 0
        isMuted = (record["isMuted"] as? Int64) == 1
        note = record["note"] as? String
        artwork = record["artwork"] as? Data
    }

    var description: String {
        "\(feedLink): \(title) #\(position)\(note.map { " note: \($0)" } ?? "")\(artwork.map { " artwork: \($0.count) bytes" } ?? "")"
    }
}

let scenarioConfiguration = SDSConfiguration(swiftDataEntities: [
    .init(entity: ScenarioSubscription.self, description: .sync(.without([]), identity: ["feedLink"])),
    .init(entity: ScenarioEpisode.self, description: .sync(.without([]), identity: ["feedLink", "guid"])),
    .init(entity: ScenarioNote.self, description: .sync(.without([]))),
    .init(entity: ScenarioLink.self, description: .sync(.without([]))),
    .init(entity: ScenarioTag.self, description: .sync(.without([]))),
    .init(entity: ScenarioWorkspace.self, description: .sync(.without([]))),
    .init(entity: ScenarioDocument.self, description: .sync(.without([]), parentKey: "workspace", identity: ["title"]))
])

/// A device with its own store, synchronization data and synchronizer, which synchronizes with a fake server.
/// A device can be terminated and launched again on the same files, like an app that is killed and relaunched.
final class TestDevice: @unchecked Sendable {
    let name: String
    let directory: URL
    let cloud: FakeCloudContainer
    private(set) var modelContainer: ModelContainer?
    private(set) var synchronizer: SDSSynchronizer!

    var timing = SDSSynchronizer.Timing(saveSynchronizationDelay: .milliseconds(50), routineRetryInterval: 3600)
    /// Called with a new synchronizer before it's set up.
    var beforeSetup: ((SDSSynchronizer) -> Void)?

    init(_ name: String, server: FakeCloudServer, account: String? = "first") {
        self.name = name
        directory = FileManager.default.temporaryDirectory.appending(path: "SwiftDataSync Tests/\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: directory.appending(path: "Sync"), withIntermediateDirectories: true)
        cloud = FakeCloudContainer(server: server, device: name, account: account.map { .signedIn($0) } ?? .noAccount)
    }

    var server: FakeCloudServer { cloud.server }
    var storeURL: URL { directory.appending(path: "Library.store") }
    var viewModel: SDSSynchronizationViewModel { synchronizer.viewModel }

    private func makeModelContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([ScenarioTag.self, ScenarioLink.self, ScenarioSubscription.self, ScenarioEpisode.self, ScenarioNote.self, ScenarioWorkspace.self, ScenarioDocument.self]),
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        )
    }

    /// Sets up a synchronizer, like an app that launches, and waits for its first synchronization.
    /// - Parameter stopped: Whether synchronizing is stopped before setting up, e.g. as the user turned it off.
    func launch(configuration: SDSConfiguration = scenarioConfiguration, waitForSync: Bool = true, stopped: Bool = false) async throws {
        let synchronizer = SDSSynchronizer(
            syncDataDirectory: directory.appending(path: "Sync"),
            viewModel: SDSSynchronizationViewModel(),
            makeCloudContainer: { [cloud] _ in cloud },
            monitorsNetwork: false,
            timing: timing
        )
        self.synchronizer = synchronizer
        beforeSetup?(synchronizer)
        if stopped {
            synchronizer.stop()
        }

        var created: ModelContainer?
        synchronizer.setup(
            containerName: "iCloud.test",
            configuration: configuration,
            modelContainer: { created = try? self.makeModelContainer(); return created }()
        )
        modelContainer = try #require(created)

        // The store is found through a notification on the main queue
        for _ in 0..<500 where !synchronizer.isObservingStore {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(synchronizer.isObservingStore, "\(name) doesn't observe its store")
        if waitForSync {
            // The first synchronization starts in a task, after the state is idle already, which `settle()` would take for
            // one that's done, e.g. while other tests keep the machine busy
            for _ in 0..<100 where !stopped && synchronizer.startedSynchronizationCount == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            await settle()
        }
    }

    /// Ends the synchronizer without saving anything, like a process that is killed.
    func terminate() {
        synchronizer?.invalidate()
        // Tasks of the synchronizer can still use the container's store, which a released container would remove
        Self.terminated.withLock { $0.append(Terminated(synchronizer: synchronizer, modelContainer: modelContainer)) }
        synchronizer = nil
        modelContainer = nil
    }

    private struct Terminated: @unchecked Sendable {
        let synchronizer: SDSSynchronizer?
        let modelContainer: ModelContainer?
    }
    private static let terminated = OSAllocatedUnfairLock<[Terminated]>(initialState: [])

    /// Waits until no synchronization runs or is about to start after a save.
    func settle() async {
        var idleChecks = 0
        for _ in 0..<6000 {
            let isBusy: Bool
            if synchronizer.hasPendingSaveSync {
                isBusy = true
            } else {
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

    /// Synchronizes once everything else is done, and returns whether a synchronization ran.
    @discardableResult
    func sync() async -> Bool {
        await settle()
        let count = synchronizer.startedSynchronizationCount
        await synchronizer.synchronize()
        await settle()
        return synchronizer.startedSynchronizationCount > count
    }

    var state: SDSSynchronizationViewModel.State {
        get async { await viewModel.state }
    }

    // MARK: The Store

    /// Changes the store, with the app's context once launched, or else like a process without a synchronizer.
    func change(_ body: (ModelContext) throws -> Void) throws {
        let container = try modelContainer ?? makeModelContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try body(context)
        try context.save()
    }

    func subscriptions() throws -> [SubscriptionValues] {
        let context = ModelContext(try modelContainer ?? makeModelContainer())
        return try context.fetch(FetchDescriptor<ScenarioSubscription>()).map(SubscriptionValues.init).sorted { $0.feedLink < $1.feedLink }
    }

    func subscription(_ feedLink: String) throws -> SubscriptionValues? {
        try subscriptions().first { $0.feedLink == feedLink }
    }

    func notes() throws -> [String] {
        let context = ModelContext(try modelContainer ?? makeModelContainer())
        return try context.fetch(FetchDescriptor<ScenarioNote>()).map(\.text).sorted()
    }

    /// Changes the store like another process without a synchronizer, e.g. an extension, while the app runs.
    func changeInAnotherProcess(_ body: (ModelContext) throws -> Void) throws {
        let context = ModelContext(try makeModelContainer())
        context.autosaveEnabled = false
        try body(context)
        try context.save()
    }

    func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        let context = ModelContext(try modelContainer ?? makeModelContainer())
        return try context.fetchCount(FetchDescriptor<T>())
    }

    func insertSubscriptions(_ feedLinks: [String], title: (String) -> String = { "Title of \($0)" }) throws {
        try change { context in
            for (index, feedLink) in feedLinks.enumerated() {
                context.insert(ScenarioSubscription(feedLink: feedLink, title: title(feedLink), position: index))
            }
        }
    }

    func editSubscription(_ feedLink: String, _ edit: @escaping (ScenarioSubscription) -> Void) throws {
        try change { context in
            let model = try #require(try context.fetch(FetchDescriptor<ScenarioSubscription>(predicate: #Predicate { $0.feedLink == feedLink })).first)
            edit(model)
        }
    }

    /// Deletes the models one by one, as `ModelContext.delete(model:where:)` deletes them in the store directly.
    func deleteSubscription(_ feedLink: String) throws {
        try change { context in
            for model in try context.fetch(FetchDescriptor<ScenarioSubscription>(predicate: #Predicate { $0.feedLink == feedLink })) {
                context.delete(model)
            }
        }
    }

    // MARK: The Server

    /// The subscriptions of the device's account on the server.
    func serverSubscriptions(account: String? = nil) -> [SubscriptionValues] {
        guard let account = account ?? cloud.accountName else { return [] }
        return server.records(account: account)
            .filter { $0.recordType == "ScenarioSubscription" }
            .map(SubscriptionValues.init(record:))
            .sorted { $0.feedLink < $1.feedLink }
    }

    func serverNotes(account: String? = nil) -> [String] {
        guard let account = account ?? cloud.accountName else { return [] }
        return server.records(account: account).filter { $0.recordType == "ScenarioNote" }.compactMap { $0["text"] as? String }.sorted()
    }

    /// Signs into another account, or out, and tells the synchronizer like iCloud does.
    func switchAccount(to account: FakeCloudContainer.AccountState) {
        cloud.account = account
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
    }
}

/// The record name of a subscription.
func subscriptionRecordName(_ feedLink: String) -> String {
    SDSIdentity.recordName(entityName: "ScenarioSubscription", values: [feedLink])
}

/// A record of a subscription, as another device would have uploaded it.
func subscriptionRecord(_ feedLink: String, title: String, position: Int = 0, note: String? = nil) -> CKRecord {
    let record = CKRecord(recordType: "ScenarioSubscription", recordID: CKRecord.ID(recordName: subscriptionRecordName(feedLink), zoneID: .scenario))
    record["feedLink"] = feedLink
    record["title"] = title
    record["position"] = Int64(position)
    record["isMuted"] = 0 as Int64
    record["rating"] = 0.0
    record["addedAt"] = Date.distantPast
    record["note"] = note
    return record
}
