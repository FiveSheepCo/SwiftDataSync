import Foundation
import CoreData
import CloudKit
import Testing
import os
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

/// Like `playlistModel`, but items can't exist without their playlist, whose delete rule only nullifies them. It isn't
/// changed after it's made.
nonisolated(unsafe) private let requiredPlaylistModel: NSManagedObjectModel = {
    let model = playlistModel.copy() as! NSManagedObjectModel
    let playlist = model.entitiesByName["Playlist"]!
    let item = model.entitiesByName["PlaylistItem"]!
    playlist.relationshipsByName["items"]!.deleteRule = .nullifyDeleteRule
    let owner = item.relationshipsByName["playlist"]!
    owner.isOptional = false
    owner.minCount = 1
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

/// Synchronized folders, items that can't exist without their folder, parts that can't exist without their item, and notes
/// that an item's delete rule deletes with it, and favorites and lists that reference items. The relationships to the folder and the item are required, while their delete
/// rules only nullify them. It isn't changed after it's made.
nonisolated(unsafe) private let requiredFolderModel: NSManagedObjectModel = {
    let folder = NSEntityDescription()
    folder.name = "RFolder"
    let item = NSEntityDescription()
    item.name = "RItem"

    let folderName = NSAttributeDescription()
    folderName.name = "name"
    folderName.type = .string
    folderName.isOptional = true
    let itemName = NSAttributeDescription()
    itemName.name = "name"
    itemName.type = .string
    itemName.isOptional = true
    let items = NSRelationshipDescription()
    items.name = "items"
    items.destinationEntity = item
    items.maxCount = 0
    items.isOptional = true
    items.deleteRule = .nullifyDeleteRule
    let toFolder = NSRelationshipDescription()
    toFolder.name = "folder"
    toFolder.destinationEntity = folder
    toFolder.maxCount = 1
    toFolder.minCount = 1
    toFolder.isOptional = false
    toFolder.deleteRule = .nullifyDeleteRule
    items.inverseRelationship = toFolder
    toFolder.inverseRelationship = items

    let part = NSEntityDescription()
    part.name = "RPart"
    let partName = NSAttributeDescription()
    partName.name = "name"
    partName.type = .string
    partName.isOptional = true
    let parts = NSRelationshipDescription()
    parts.name = "parts"
    parts.destinationEntity = part
    parts.maxCount = 0
    parts.isOptional = true
    parts.deleteRule = .nullifyDeleteRule
    let toItem = NSRelationshipDescription()
    toItem.name = "item"
    toItem.destinationEntity = item
    toItem.maxCount = 1
    toItem.minCount = 1
    toItem.isOptional = false
    toItem.deleteRule = .nullifyDeleteRule
    parts.inverseRelationship = toItem
    toItem.inverseRelationship = parts
    part.properties = [partName, toItem]

    let note = NSEntityDescription()
    note.name = "RNote"
    let noteName = NSAttributeDescription()
    noteName.name = "name"
    noteName.type = .string
    noteName.isOptional = true
    let notes = NSRelationshipDescription()
    notes.name = "notes"
    notes.destinationEntity = note
    notes.maxCount = 0
    notes.isOptional = true
    notes.deleteRule = .cascadeDeleteRule
    let noteItem = NSRelationshipDescription()
    noteItem.name = "item"
    noteItem.destinationEntity = item
    noteItem.maxCount = 1
    noteItem.isOptional = true
    noteItem.deleteRule = .nullifyDeleteRule
    notes.inverseRelationship = noteItem
    noteItem.inverseRelationship = notes
    note.properties = [noteName, noteItem]

    let favorite = NSEntityDescription()
    favorite.name = "RFavorite"
    let favoriteItem = NSRelationshipDescription()
    favoriteItem.name = "item"
    favoriteItem.destinationEntity = item
    favoriteItem.maxCount = 1
    favoriteItem.isOptional = true
    favoriteItem.deleteRule = .nullifyDeleteRule
    let favorites = NSRelationshipDescription()
    favorites.name = "favorites"
    favorites.destinationEntity = favorite
    favorites.maxCount = 0
    favorites.isOptional = true
    favorites.deleteRule = .nullifyDeleteRule
    favoriteItem.inverseRelationship = favorites
    favorites.inverseRelationship = favoriteItem
    let favoriteName = NSAttributeDescription()
    favoriteName.name = "name"
    favoriteName.type = .string
    favoriteName.isOptional = true
    favorite.properties = [favoriteName, favoriteItem]

    let list = NSEntityDescription()
    list.name = "RList"
    let entries = NSRelationshipDescription()
    entries.name = "entries"
    entries.destinationEntity = item
    entries.maxCount = 0
    entries.isOrdered = true
    entries.isOptional = true
    entries.deleteRule = .nullifyDeleteRule
    let lists = NSRelationshipDescription()
    lists.name = "lists"
    lists.destinationEntity = list
    lists.maxCount = 0
    lists.isOptional = true
    lists.deleteRule = .nullifyDeleteRule
    entries.inverseRelationship = lists
    lists.inverseRelationship = entries
    let listName = NSAttributeDescription()
    listName.name = "name"
    listName.type = .string
    listName.isOptional = true
    list.properties = [listName, entries]

    folder.properties = [folderName, items]
    item.properties = [itemName, toFolder, parts, notes, favorites, lists]
    let model = NSManagedObjectModel()
    model.entities = [folder, item, part, note, favorite, list]
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

/// Workspaces whose names are unique, with documents below them. It isn't changed after it's made.
nonisolated(unsafe) private let uniqueWorkspaceModel: NSManagedObjectModel = {
    let workspace = NSEntityDescription()
    workspace.name = "UWorkspace"
    let document = NSEntityDescription()
    document.name = "UDocument"
    let name = NSAttributeDescription()
    name.name = "name"
    name.type = .string
    name.isOptional = true
    let title = NSAttributeDescription()
    title.name = "title"
    title.type = .string
    title.isOptional = true
    let documents = NSRelationshipDescription()
    documents.name = "documents"
    documents.destinationEntity = document
    documents.maxCount = 0
    documents.isOptional = true
    documents.deleteRule = .cascadeDeleteRule
    let toWorkspace = NSRelationshipDescription()
    toWorkspace.name = "workspace"
    toWorkspace.destinationEntity = workspace
    toWorkspace.maxCount = 1
    toWorkspace.isOptional = true
    toWorkspace.deleteRule = .nullifyDeleteRule
    documents.inverseRelationship = toWorkspace
    toWorkspace.inverseRelationship = documents
    workspace.properties = [name, documents]
    workspace.uniquenessConstraints = [["name"]]
    document.properties = [title, toWorkspace]
    let model = NSManagedObjectModel()
    model.entities = [workspace, document]
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

    func count(_ entityName: String) -> Int {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context.performAndWait { (try? context.count(for: NSFetchRequest<NSManagedObject>(entityName: entityName))) ?? -1 }
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

    /// A folder is deleted elsewhere while this device puts a synchronized item, which requires a folder, into it, without
    /// uploading that yet. The item goes with the folder everywhere, like a child moved into a parent whose delete rule
    /// cascades, and so does what requires it, or what its delete rule deletes. What refers to it doesn't anymore, also with
    /// this device's other edits. Nothing stays pointing at the deleted folder.
    /// A record that lacks a required relationship, e.g. one uploaded by a device that couldn't reference the related
    /// model, can't be stored. It's set aside, rather than failing every download, which would also keep every upload
    /// from running.
    @Test func downloadedRecordWithoutARequiredRelationshipDoesNotStopSynchronizing() async throws {
        let server = FakeCloudServer()
        let device = try await CoreDataDevice("A", server: server, model: requiredFolderModel)

        let broken = CKRecord(recordType: "RItem", recordID: CKRecord.ID(recordName: "broken", zoneID: .scenario))
        broken["name"] = "Without folder"
        let alsoBroken = CKRecord(recordType: "RItem", recordID: CKRecord.ID(recordName: "alsoBroken", zoneID: .scenario))
        alsoBroken["name"] = "Also without folder"
        server.seed([broken, alsoBroken], account: "first")
        await device.sync()

        if case .error(let error) = await device.synchronizer.viewModel.state {
            Issue.record("Synchronizing failed: \(error)")
        }
        #expect(device.count("RItem") == 0)

        // Later changes are still uploaded
        try device.change { context in
            NSEntityDescription.insertNewObject(forEntityName: "RFolder", into: context).setValue("New", forKey: "name")
        }
        await device.sync()
        #expect(server.records(account: "first").contains { $0.recordType == "RFolder" && $0["name"] as? String == "New" })
        if case .error(let error) = await device.synchronizer.viewModel.state {
            Issue.record("Synchronizing failed: \(error)")
        }
    }

    @Test(arguments: [true, false]) func downloadedDeletionTakesSynchronizedObjectsWithUnuploadedRelationships(isCreated: Bool) async throws {
        let server = FakeCloudServer()
        let first = try await CoreDataDevice("A", server: server, model: requiredFolderModel)
        let second = try await CoreDataDevice("B", server: server, model: requiredFolderModel)
        let names = { (device: CoreDataDevice, entityName: String) in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = device.coordinator
            return context.performAndWait {
                ((try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: entityName))) ?? []).compactMap { $0.value(forKey: "name") as? String }.sorted()
            }
        }
        let folderOfItems = { (device: CoreDataDevice) in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = device.coordinator
            return context.performAndWait {
                ((try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RItem"))) ?? []).map {
                    ($0.value(forKey: "folder") as? NSManagedObject)?.value(forKey: "name") as? String
                }
            }
        }

        try first.change { context in
            let kept = NSEntityDescription.insertNewObject(forEntityName: "RFolder", into: context)
            kept.setValue("Kept", forKey: "name")
            NSEntityDescription.insertNewObject(forEntityName: "RFolder", into: context).setValue("Deleted", forKey: "name")
            if !isCreated {
                let item = NSEntityDescription.insertNewObject(forEntityName: "RItem", into: context)
                item.setValue("Item", forKey: "name")
                item.setValue(kept, forKey: "folder")
                // A part of the item, which requires it
                let part = NSEntityDescription.insertNewObject(forEntityName: "RPart", into: context)
                part.setValue("Part", forKey: "name")
                part.setValue(item, forKey: "item")
                // A note, which the item's delete rule would delete with it
                let note = NSEntityDescription.insertNewObject(forEntityName: "RNote", into: context)
                note.setValue("Note", forKey: "name")
                note.setValue(item, forKey: "item")
                // A favorite and a list that reference the item
                let favorite = NSEntityDescription.insertNewObject(forEntityName: "RFavorite", into: context)
                favorite.setValue("Favorite", forKey: "name")
                favorite.setValue(item, forKey: "item")
                let list = NSEntityDescription.insertNewObject(forEntityName: "RList", into: context)
                list.setValue("List", forKey: "name")
                list.setValue(NSOrderedSet(array: [item]), forKey: "entries")
            }
        }
        await first.sync()
        await second.sync()

        // A deletes the folder, while B puts the item in it without uploading it yet: B downloads the deletion first
        try first.change { context in
            let folders = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RFolder"))
            context.delete(try #require(folders.first { $0.value(forKey: "name") as? String == "Deleted" }))
        }
        await first.sync()
        try second.change { context in
            let folders = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RFolder"))
            let deleted = try #require(folders.first { $0.value(forKey: "name") as? String == "Deleted" })
            if isCreated {
                let item = NSEntityDescription.insertNewObject(forEntityName: "RItem", into: context)
                item.setValue("Item", forKey: "name")
                item.setValue(deleted, forKey: "folder")
            } else {
                // With other edits of the item, its note, and the list, in the same save
                let item = try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RItem")).first)
                item.setValue(deleted, forKey: "folder")
                item.setValue("Renamed", forKey: "name")
                try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RNote")).first).setValue("Edited note", forKey: "name")
                let other = NSEntityDescription.insertNewObject(forEntityName: "RItem", into: context)
                other.setValue("Other", forKey: "name")
                other.setValue(folders.first { $0.value(forKey: "name") as? String == "Kept" }, forKey: "folder")
                let list = try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RList")).first)
                list.setValue(NSOrderedSet(array: [item, other]), forKey: "entries")
            }
        }
        await second.sync()
        await first.sync()
        await second.sync()
        await first.sync()

        #expect(names(second, "RFolder") == ["Kept"])
        #expect(names(first, "RFolder") == ["Kept"])
        #expect(folderOfItems(second).allSatisfy { $0 == "Kept" })
        #expect(folderOfItems(first).allSatisfy { $0 == "Kept" })
        #expect(names(second, "RItem") == names(first, "RItem"))
        #expect(names(first, "RItem") == (isCreated ? [] : ["Other"]))
        #expect(names(second, "RPart") == names(first, "RPart"))
        #expect(names(first, "RPart") == [])
        #expect(names(second, "RNote") == names(first, "RNote"))
        #expect(names(first, "RNote") == [])
        let references = { (device: CoreDataDevice) in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = device.coordinator
            return context.performAndWait {
                let favorites = ((try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RFavorite"))) ?? []).map {
                    ($0.value(forKey: "item") as? NSManagedObject)?.value(forKey: "name") as? String ?? "none"
                }
                let entries = ((try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RList"))) ?? []).flatMap {
                    (($0.value(forKey: "entries") as? NSOrderedSet)?.array ?? []).map { ($0 as? NSManagedObject)?.value(forKey: "name") as? String ?? "none" }
                }
                return favorites + entries
            }
        }
        #expect(references(second) == references(first))
        #expect(references(first) == (isCreated ? [] : ["none", "Other"]))
        #expect(server.records(account: "first").filter { $0.recordType == "RItem" }.count == (isCreated ? 0 : 1))
        first.synchronizer.invalidate()
        second.synchronizer.invalidate()
    }

    /// The same, when this device moves the item while a download runs, which deletes the folder on a later page.
    @Test func itemMovedDuringADownloadIntoAFolderDeletedElsewhereIsGoneEverywhere() async throws {
        let server = FakeCloudServer()
        let first = try await CoreDataDevice("A", server: server, model: requiredFolderModel)
        let second = try await CoreDataDevice("B", server: server, model: requiredFolderModel)
        try first.change { context in
            let kept = NSEntityDescription.insertNewObject(forEntityName: "RFolder", into: context)
            kept.setValue("Kept", forKey: "name")
            NSEntityDescription.insertNewObject(forEntityName: "RFolder", into: context).setValue("Deleted", forKey: "name")
            NSEntityDescription.insertNewObject(forEntityName: "RFolder", into: context).setValue("Other", forKey: "name")
            let item = NSEntityDescription.insertNewObject(forEntityName: "RItem", into: context)
            item.setValue("Item", forKey: "name")
            item.setValue(kept, forKey: "folder")
        }
        await first.sync()
        await second.sync()

        // A renames a folder, then deletes another, which B downloads on two pages
        try first.change { try Self.folder("Other", $0).setValue("Renamed", forKey: "name") }
        await first.sync()
        try first.change { $0.delete(try Self.folder("Deleted", $0)) }
        await first.sync()
        server.pageSize = 1
        let hasMoved = OSAllocatedUnfairLock(initialState: false)
        second.synchronizer.afterSavingDownloadedObjects = { [second] in
            guard hasMoved.withLock({ hasMoved in defer { hasMoved = true }; return !hasMoved }) else { return }
            try? second.change { context in
                let item = try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RItem")).first)
                item.setValue(try Self.folder("Deleted", context), forKey: "folder")
            }
            // Until the move is stored
            Thread.sleep(forTimeInterval: 0.3)
        }
        await second.sync()
        second.synchronizer.afterSavingDownloadedObjects = nil
        await first.sync()
        await second.sync()

        #expect(second.count("RItem") == 0)
        #expect(first.count("RItem") == 0)
        #expect(server.records(account: "first").filter { $0.recordType == "RItem" }.isEmpty)
        first.synchronizer.invalidate()
        second.synchronizer.invalidate()
    }

    private static func folder(_ name: String, _ context: NSManagedObjectContext) throws -> NSManagedObject {
        try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "RFolder")).first { $0.value(forKey: "name") as? String == name })
    }

    /// The same, when the relationship is synchronized on the parent's side, as an ordered list of its children: this device
    /// moves an item into a playlist another device deleted, without uploading it. The item is gone everywhere, whether the
    /// playlist's delete rule deletes it, or it can't exist without the playlist.
    @Test(arguments: [false, true]) func itemMovedIntoAPlaylistDeletedElsewhereIsGoneEverywhere(isRequired: Bool) async throws {
        let server = FakeCloudServer()
        let model = isRequired ? requiredPlaylistModel : playlistModel
        let first = try await CoreDataDevice("A", server: server, model: model)
        let second = try await CoreDataDevice("B", server: server, model: model)
        try first.change { context in
            let kept = NSEntityDescription.insertNewObject(forEntityName: "Playlist", into: context)
            kept.setValue("Kept", forKey: "title")
            NSEntityDescription.insertNewObject(forEntityName: "Playlist", into: context).setValue("Deleted", forKey: "title")
            let item = NSEntityDescription.insertNewObject(forEntityName: "PlaylistItem", into: context)
            item.setValue("Item", forKey: "name")
            item.setValue(kept, forKey: "playlist")
        }
        await first.sync()
        await second.sync()
        #expect(try second.playlists() == ["Kept": ["Item"], "Deleted": []])

        try first.change { context in
            let playlists = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Playlist"))
            context.delete(try #require(playlists.first { $0.value(forKey: "title") as? String == "Deleted" }))
        }
        await first.sync()
        try second.change { context in
            let playlists = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Playlist"))
            let item = try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "PlaylistItem")).first)
            item.setValue(playlists.first { $0.value(forKey: "title") as? String == "Deleted" }, forKey: "playlist")
        }
        await second.sync()
        await first.sync()
        await second.sync()

        #expect(try second.playlists() == ["Kept": []])
        #expect(try first.playlists() == ["Kept": []])
        #expect(first.count("PlaylistItem") == 0)
        #expect(server.records(account: "first").filter { $0.recordType == "PlaylistItem" }.isEmpty)
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

    /// Device B has a workspace with a document. Another device uploaded a workspace of the same unique name, whose record
    /// wins. B moves its workspace to that record, re-points its document, and deletes its own workspace record. If iCloud is
    /// full, or CloudKit rejects the document, only the removal could be uploaded: it waits for the document's update, as the
    /// document's record still has B's previous workspace record as its parent, which CloudKit deletes it with.
    @Test(arguments: [0, 1, 2]) func replacedRecordsRemovalWaitsForTheRecordsThatReferenceIt(failure: Int) async throws {
        let configuration = SDSConfiguration(rawEntities: [
            "UWorkspace": .sync(.all),
            "UDocument": .sync(.all, parentKey: "workspace")
        ])
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        server.cascadesDeleteSelf = true
        let b = try await CoreDataDevice("B", server: server, model: uniqueWorkspaceModel, configuration: configuration)
        try b.change { context in
            let workspace = NSEntityDescription.insertNewObject(forEntityName: "UWorkspace", into: context)
            workspace.setValue("W", forKey: "name")
            let document = NSEntityDescription.insertNewObject(forEntityName: "UDocument", into: context)
            document.setValue("D", forKey: "title")
            document.setValue(workspace, forKey: "workspace")
        }
        await b.sync()
        let documentName = try #require(server.records(account: "first").first { $0.recordType == "UDocument" }?.recordID.recordName)

        // Another device's workspace of the same name, whose record name sorts first, so it's kept
        let other = CKRecord(recordType: "UWorkspace", recordID: CKRecord.ID(recordName: "00000000-0000-0000-0000-000000000000", zoneID: .scenario))
        other["name"] = "W"
        server.seed([other], account: "first")
        // 0: nothing fails, 1: iCloud is full, 2: CloudKit rejects the document
        if failure == 1 {
            server.failSaving(where: { _ in true }, with: CKError(.quotaExceeded))
        } else if failure == 2 {
            server.failSaving(where: { $0.recordName == documentName }, with: CKError(.serverRejectedRequest))
        }
        await b.sync()
        await b.sync()
        await b.sync()
        #expect(server.records(account: "first").filter { $0.recordType == "UDocument" }.count == 1)
        #expect(b.count("UDocument") == 1)
        #expect(b.count("UWorkspace") == 1)
        b.synchronizer.invalidate()
    }
}
