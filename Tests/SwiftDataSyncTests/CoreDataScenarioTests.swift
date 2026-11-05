import Foundation
import CoreData
import CloudKit
import Testing
@testable import SwiftDataSync

/// A Core Data model with what SwiftData can't express: a playlist with an ordered list of items.
/// It isn't changed after it's made.
nonisolated(unsafe) private let playlistModel: NSManagedObjectModel = {
    let playlist = NSEntityDescription()
    playlist.name = "Playlist"
    let item = NSEntityDescription()
    item.name = "PlaylistItem"

    let title = NSAttributeDescription()
    title.name = "title"
    title.type = .string
    title.isOptional = true
    let name = NSAttributeDescription()
    name.name = "name"
    name.type = .string
    name.isOptional = true

    let items = NSRelationshipDescription()
    items.name = "items"
    items.destinationEntity = item
    items.isOrdered = true
    items.maxCount = 0
    items.isOptional = true
    items.deleteRule = .cascadeDeleteRule
    let owner = NSRelationshipDescription()
    owner.name = "playlist"
    owner.destinationEntity = playlist
    owner.maxCount = 1
    owner.isOptional = true
    owner.deleteRule = .nullifyDeleteRule
    items.inverseRelationship = owner
    owner.inverseRelationship = items

    playlist.properties = [title, items]
    item.properties = [name, owner]
    let model = NSManagedObjectModel()
    model.entities = [playlist, item]
    return model
}()

/// Folders in folders, whose parent is of their own entity. It isn't changed after it's made.
nonisolated(unsafe) private let folderModel: NSManagedObjectModel = {
    let folder = NSEntityDescription()
    folder.name = "Folder"
    let name = NSAttributeDescription()
    name.name = "name"
    name.type = .string
    name.isOptional = true
    let parent = NSRelationshipDescription()
    parent.name = "parent"
    parent.destinationEntity = folder
    parent.maxCount = 1
    parent.isOptional = true
    parent.deleteRule = .nullifyDeleteRule
    let children = NSRelationshipDescription()
    children.name = "children"
    children.destinationEntity = folder
    children.maxCount = 0
    children.isOptional = true
    children.deleteRule = .cascadeDeleteRule
    parent.inverseRelationship = children
    children.inverseRelationship = parent
    folder.properties = [name, parent, children]
    let model = NSManagedObjectModel()
    model.entities = [folder]
    return model
}()

/// Episodes, and local information about them that isn't synchronized, which can't exist without its episode. Its relationship
/// is required, while the episode's delete rule only nullifies it. It isn't changed after it's made.
nonisolated(unsafe) private let episodeInfoModel: NSManagedObjectModel = {
    let episode = NSEntityDescription()
    episode.name = "Episode"
    let info = NSEntityDescription()
    info.name = "EpisodeInfo"

    let title = NSAttributeDescription()
    title.name = "title"
    title.type = .string
    title.isOptional = true
    let toInfo = NSRelationshipDescription()
    toInfo.name = "info"
    toInfo.destinationEntity = info
    toInfo.maxCount = 1
    toInfo.isOptional = true
    toInfo.deleteRule = .nullifyDeleteRule
    let toEpisode = NSRelationshipDescription()
    toEpisode.name = "episode"
    toEpisode.destinationEntity = episode
    toEpisode.maxCount = 1
    toEpisode.minCount = 1
    toEpisode.isOptional = false
    toEpisode.deleteRule = .nullifyDeleteRule
    toInfo.inverseRelationship = toEpisode
    toEpisode.inverseRelationship = toInfo

    episode.properties = [title, toInfo]
    info.properties = [toEpisode]
    let model = NSManagedObjectModel()
    model.entities = [episode, info]
    return model
}()

/// Notes that count their revisions in `willSave()`, like models that stamp when they changed.
@objc(RevisedNote)
final class RevisedNote: NSManagedObject {
    override func willSave() {
        super.willSave()
        if isUpdated && !isDeleted && changedValues()["revision"] == nil {
            setValue((value(forKey: "revision") as? Int64 ?? 0) + 1, forKey: "revision")
        }
    }
}

nonisolated(unsafe) private let revisedNoteModel: NSManagedObjectModel = {
    let note = NSEntityDescription()
    note.name = "RevisedNote"
    note.managedObjectClassName = "RevisedNote"
    let text = NSAttributeDescription()
    text.name = "text"
    text.type = .string
    text.isOptional = true
    let revision = NSAttributeDescription()
    revision.name = "revision"
    revision.type = .integer64
    revision.isOptional = false
    revision.defaultValue = 0
    note.properties = [text, revision]
    let model = NSManagedObjectModel()
    model.entities = [note]
    return model
}()

/// Podcasts with their episodes, and the episode each currently plays, so their records reference each other.
nonisolated(unsafe) private let currentEpisodeModel: NSManagedObjectModel = {
    let podcast = NSEntityDescription()
    podcast.name = "Podcast"
    let episode = NSEntityDescription()
    episode.name = "Episode"
    let title = NSAttributeDescription()
    title.name = "title"
    title.type = .string
    title.isOptional = true
    let name = NSAttributeDescription()
    name.name = "name"
    name.type = .string
    name.isOptional = true

    let episodes = NSRelationshipDescription()
    episodes.name = "episodes"
    episodes.destinationEntity = episode
    episodes.maxCount = 0
    episodes.deleteRule = .cascadeDeleteRule
    let toPodcast = NSRelationshipDescription()
    toPodcast.name = "podcast"
    toPodcast.destinationEntity = podcast
    toPodcast.maxCount = 1
    toPodcast.deleteRule = .nullifyDeleteRule
    episodes.inverseRelationship = toPodcast
    toPodcast.inverseRelationship = episodes

    let current = NSRelationshipDescription()
    current.name = "current"
    current.destinationEntity = episode
    current.maxCount = 1
    current.deleteRule = .nullifyDeleteRule
    let currentOf = NSRelationshipDescription()
    currentOf.name = "currentOf"
    currentOf.destinationEntity = podcast
    currentOf.maxCount = 1
    currentOf.deleteRule = .nullifyDeleteRule
    current.inverseRelationship = currentOf
    currentOf.inverseRelationship = current

    podcast.properties = [title, episodes, current]
    episode.properties = [name, toPodcast, currentOf]
    let model = NSManagedObjectModel()
    model.entities = [podcast, episode]
    return model
}()

/// A device whose store is a Core Data store, set up with its coordinator.
private final class CoreDataDevice: @unchecked Sendable {
    let synchronizer: SDSSynchronizer
    let coordinator: NSPersistentStoreCoordinator

    init(_ name: String, server: FakeCloudServer, model: NSManagedObjectModel = playlistModel, configuration: SDSConfiguration = .init(rawEntities: [:])) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SwiftDataSync Tests/\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "Sync"), withIntermediateDirectories: true)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(type: .sqlite, at: directory.appending(path: "Playlists.sqlite"))

        let cloud = FakeCloudContainer(server: server, device: name, account: .signedIn("first"))
        synchronizer = SDSSynchronizer(
            syncDataDirectory: directory.appending(path: "Sync"),
            viewModel: SDSSynchronizationViewModel(),
            makeCloudContainer: { _ in cloud },
            monitorsNetwork: false,
            timing: .init(saveSynchronizationDelay: .milliseconds(50), routineRetryInterval: 3600)
        )
        synchronizer.setup(containerName: "iCloud.test", configuration: configuration, coordinator: coordinator)
        // The first synchronization starts in a task, after the state is idle already, see `TestDevice.launch`
        for _ in 0..<100 where synchronizer.startedSynchronizationCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await sync()
    }

    /// Synchronizes once everything else is done, and waits until that's done too: one that's requested while another
    /// runs follows it, rather than running now.
    func sync() async {
        await settle()
        await synchronizer.synchronize()
        await settle()
    }

    private func settle() async {
        var idleChecks = 0
        for _ in 0..<1000 {
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
    }

    func change(_ body: (NSManagedObjectContext) throws -> Void) throws {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            try body(context)
            try context.save()
        }
    }

    /// The names of the items of every playlist, by title.
    func playlists() throws -> [String: [String]] {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return try context.performAndWait {
            let playlists = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Playlist"))
            return Dictionary(uniqueKeysWithValues: playlists.map { playlist in
                let items = (playlist.value(forKey: "items") as? NSOrderedSet)?.array as? [NSManagedObject] ?? []
                return (playlist.value(forKey: "title") as? String ?? "", items.map { $0.value(forKey: "name") as? String ?? "" })
            })
        }
    }
}

/// Models of Core Data stores, set up with their coordinator.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(1)))
struct CoreDataScenarioTests {

    /// Ordered relationships are stored as lists of references, which a download turns into the related objects again.
    @Test func orderedRelationshipsAreDownloaded() async throws {
        let server = FakeCloudServer()
        let first = try await CoreDataDevice("A", server: server)
        let second = try await CoreDataDevice("B", server: server)

        try first.change { context in
            let playlist = NSEntityDescription.insertNewObject(forEntityName: "Playlist", into: context)
            playlist.setValue("Commute", forKey: "title")
            let items = ["First", "Second", "Third"].map { name in
                let item = NSEntityDescription.insertNewObject(forEntityName: "PlaylistItem", into: context)
                item.setValue(name, forKey: "name")
                return item
            }
            playlist.setValue(NSOrderedSet(array: items), forKey: "items")
        }
        await first.sync()
        await second.sync()

        #expect(try second.playlists() == ["Commute": ["First", "Second", "Third"]])
        first.synchronizer.invalidate()
        second.synchronizer.invalidate()
    }

    /// An entity whose parent is of its own entity gets a sample record whose parent is another sample record, rather than itself.
    @Test func schemaOfAnEntityThatIsItsOwnParent() async throws {
        let server = FakeCloudServer()
        let device = try await CoreDataDevice("A", server: server, model: folderModel, configuration: .init(rawEntities: [
            "Folder": .sync(.all, parentKey: "parent")
        ]))
        try await device.synchronizer.initializeSchema()
        #expect(server.schema["Folder"]?.isSuperset(of: ["name", "parent", SDSSynchronizer.Constants.parentWorkaroundKey]) == true)
        device.synchronizer.invalidate()
    }

    /// Device B has local information about an episode, which requires it. Device A deletes the episode. The download of the
    /// deletion deletes the information too, rather than failing to save again and again, which would keep every later
    /// change from being downloaded.
    @Test func downloadedDeletionTakesObjectsThatRequireItWithIt() async throws {
        let server = FakeCloudServer()
        let configuration = SDSConfiguration(rawEntities: [
            "Episode": .sync(.without(["info"])),
            "EpisodeInfo": .noSync
        ])
        let first = try await CoreDataDevice("A", server: server, model: episodeInfoModel, configuration: configuration)
        let second = try await CoreDataDevice("B", server: server, model: episodeInfoModel, configuration: configuration)
        let count = { (device: CoreDataDevice, entityName: String) in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = device.coordinator
            return context.performAndWait { (try? context.count(for: NSFetchRequest<NSManagedObject>(entityName: entityName))) ?? -1 }
        }
        let titles = { (device: CoreDataDevice) in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = device.coordinator
            return context.performAndWait {
                ((try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Episode"))) ?? []).compactMap { $0.value(forKey: "title") as? String }
            }
        }

        try first.change { context in
            NSEntityDescription.insertNewObject(forEntityName: "Episode", into: context).setValue("First", forKey: "title")
        }
        await first.sync()
        await second.sync()
        try second.change { context in
            let episode = try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Episode")).first)
            NSEntityDescription.insertNewObject(forEntityName: "EpisodeInfo", into: context).setValue(episode, forKey: "episode")
        }
        await second.sync()

        try first.change { context in
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Episode")).forEach(context.delete)
        }
        await first.sync()
        await second.sync()
        #expect(count(second, "Episode") == 0)
        #expect(count(second, "EpisodeInfo") == 0)

        // Later changes are downloaded
        try first.change { context in
            NSEntityDescription.insertNewObject(forEntityName: "Episode", into: context).setValue("Second", forKey: "title")
        }
        await first.sync()
        await second.sync()
        #expect(titles(second) == ["Second"])
        first.synchronizer.invalidate()
        second.synchronizer.invalidate()
    }

    /// A note counts its revisions in `willSave()`, which Core Data calls once the save started. The revision is uploaded with
    /// the edit, and the next download doesn't revert it.
    @Test func valueSetWhileSavingIsUploaded() async throws {
        let server = FakeCloudServer()
        let device = try await CoreDataDevice("A", server: server, model: revisedNoteModel)
        try device.change { NSEntityDescription.insertNewObject(forEntityName: "RevisedNote", into: $0).setValue("a", forKey: "text") }
        await device.sync()
        try device.change { context in
            try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RevisedNote")).first).setValue("b", forKey: "text")
        }
        await device.sync()
        await device.sync()

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = device.coordinator
        let local = try context.performAndWait {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RevisedNote")).first?.value(forKey: "revision") as? Int64
        }
        let remote = server.records(account: "first").first { $0.recordType == "RevisedNote" }?["revision"] as? Int64
        #expect(local == 1)
        #expect(remote == 1)
        device.synchronizer.invalidate()
    }

    /// A podcast references the episode it currently plays, and the episode references its podcast, so each record waits
    /// for the other's object. Both are downloaded, with both references.
    @Test func recordsThatReferenceEachOtherAreDownloaded() async throws {
        let server = FakeCloudServer()
        let configuration = SDSConfiguration(rawEntities: [
            "Podcast": .sync(.all),
            "Episode": .sync(.without(["currentOf"]))
        ])
        let first = try await CoreDataDevice("A", server: server, model: currentEpisodeModel, configuration: configuration)
        let second = try await CoreDataDevice("B", server: server, model: currentEpisodeModel, configuration: configuration)
        try first.change { context in
            let podcast = NSEntityDescription.insertNewObject(forEntityName: "Podcast", into: context)
            podcast.setValue("P", forKey: "title")
            let episode = NSEntityDescription.insertNewObject(forEntityName: "Episode", into: context)
            episode.setValue("E", forKey: "name")
            episode.setValue(podcast, forKey: "podcast")
            podcast.setValue(episode, forKey: "current")
        }
        await first.sync()
        await second.sync()

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = second.coordinator
        let (podcastTitles, current, episodePodcast) = try context.performAndWait {
            let podcasts = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Podcast"))
            let episodes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Episode"))
            return (
                podcasts.map { $0.value(forKey: "title") as? String },
                podcasts.map { ($0.value(forKey: "current") as? NSManagedObject)?.value(forKey: "name") as? String },
                episodes.map { ($0.value(forKey: "podcast") as? NSManagedObject)?.value(forKey: "title") as? String }
            )
        }
        #expect(podcastTitles == ["P"])
        #expect(current == ["E"])
        #expect(episodePodcast == ["P"])
        first.synchronizer.invalidate()
        second.synchronizer.invalidate()
    }
}

