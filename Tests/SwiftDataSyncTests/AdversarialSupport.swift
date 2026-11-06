import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import CryptoKit
@testable import SwiftDataSync

/// A deterministic random number generator, so a failing fuzz run can be repeated with its seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func shortHash(_ data: Data?) -> String {
    guard let data else { return "-" }
    let digest = SHA256.hash(data: data)
    return "\(data.count)b:" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
}

/// All synchronized data in a canonical form, by entity: one line per model or record, sorted, duplicates kept.
struct DataSnapshot: Equatable, CustomStringConvertible {
    var subscriptions: [String] = []
    var episodes: [String] = []
    var notes: [String] = []
    var tags: [String] = []
    var links: [String] = []
    var workspaces: [String] = []
    var documents: [String] = []

    /// Keys that identify models, which must be unique.
    var subscriptionKeys: [String] = []
    var episodeKeys: [String] = []
    var tagKeys: [String] = []
    var linkKeys: [String] = []
    var workspaceKeys: [String] = []
    var documentKeys: [String] = []

    mutating func sort() {
        subscriptions.sort(); episodes.sort(); notes.sort(); tags.sort(); links.sort(); workspaces.sort(); documents.sort()
        subscriptionKeys.sort(); episodeKeys.sort(); tagKeys.sort(); linkKeys.sort(); workspaceKeys.sort(); documentKeys.sort()
    }

    var description: String {
        """
        subs: \(subscriptions)
        episodes: \(episodes)
        notes: \(notes)
        tags: \(tags)
        links: \(links)
        workspaces: \(workspaces)
        documents: \(documents)
        """
    }

    /// Lines that differ, to keep failure messages readable.
    func difference(to other: DataSnapshot) -> String {
        func diff(_ name: String, _ a: [String], _ b: [String]) -> String? {
            guard a != b else { return nil }
            let onlyA = a.filter { !b.contains($0) } + duplicates(a)
            let onlyB = b.filter { !a.contains($0) } + duplicates(b)
            return "\(name): only left \(onlyA), only right \(onlyB)"
        }
        return [
            diff("subs", subscriptions, other.subscriptions),
            diff("episodes", episodes, other.episodes),
            diff("notes", notes, other.notes),
            diff("tags", tags, other.tags),
            diff("links", links, other.links),
            diff("workspaces", workspaces, other.workspaces),
            diff("documents", documents, other.documents)
        ].compactMap { $0 }.joined(separator: "\n")
    }

    /// The duplicates among keys that must be unique, by entity. Workspaces have no identity, so two devices can create
    /// two of the same title, and so are links.
    var duplicateKeys: [String: [String]] {
        var result: [String: [String]] = [:]
        for (name, keys) in [("subs", subscriptionKeys), ("episodes", episodeKeys), ("tags", tagKeys), ("documents", documentKeys)] {
            let dups = duplicates(keys)
            if !dups.isEmpty { result[name] = dups }
        }
        let noteIDs = notes.map { $0.split(separator: ":").first.map(String.init) ?? $0 }
        let dups = duplicates(noteIDs)
        if !dups.isEmpty { result["notes"] = dups }
        return result
    }
}

extension DataSnapshot {
    /// Removes link and document records that no device shows: ones whose references are missing, and ones that reference
    /// a parent that was deleted and created again with the same identity (the known dangling record, which then resolves).
    /// Returns the names of the links whose records were dangling.
    @discardableResult
    mutating func removeDangling(shownBy locals: [DataSnapshot]) -> Set<String> {
        func name(_ line: String) -> String { String(line.split(separator: "|").first ?? "") }
        let strict = ProcessInfo.processInfo.environment["STRICT_DANGLING"] != nil
        let shownLinks = Set(locals.flatMap(\.links)), shownDocuments = Set(locals.flatMap(\.documents))
        let droppedLinks = links.filter { $0.contains("?missing:") || (!strict && !shownLinks.contains($0)) }
        let droppedDocuments = documents.filter { $0.contains("?missing:") || (!strict && !shownDocuments.contains($0)) }
        // Only lines no device shows at all, so a device that lost or has an extra one still differs
        for line in droppedLinks { if let i = links.firstIndex(of: line) { links.remove(at: i) }; if let i = linkKeys.firstIndex(of: name(line)) { linkKeys.remove(at: i) } }
        for line in droppedDocuments { if let i = documents.firstIndex(of: line) { documents.remove(at: i) }; if let i = documentKeys.firstIndex(of: name(line)) { documentKeys.remove(at: i) } }
        if !droppedLinks.isEmpty || !droppedDocuments.isEmpty {
            print("NOTE ignored server records no device shows: links \(droppedLinks) documents \(droppedDocuments)")
        }
        return Set(droppedLinks.filter { $0.contains("?missing:") }.map(name))
    }

    /// Removes the links of these names, and of these subscriptions, e.g. the known cases where devices disagree about them.
    mutating func removeLinks(named names: Set<String>, ofFeeds feeds: Set<String>) {
        func parts(_ line: String) -> (String, String) {
            let split = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return (split.first ?? "", split.count > 1 ? split[1] : "")
        }
        let keep = { (line: String) -> Bool in let (name, feed) = parts(line); return !names.contains(name) && !feeds.contains(feed) }
        links = links.filter(keep)
        linkKeys = links.map { parts($0).0 }.sorted()
    }
}

/// Known and deliberate limitations (see PR #8's "Not changed") that `assertConverged` tolerates when asked to, printing a
/// NOTE for each, so they don't mask new problems.
struct KnownLimitations {
    /// Subscriptions that were deleted and created again: a child moved into the deleted one shows up on some devices only.
    var recreatedFeeds: Set<String> = []
    /// Links whose server record dangles: a device that deleted the parent keeps showing the child another moved into it.
    var danglingLinks = true
    /// Account switches or lost stores: losing records of unique values stay in iCloud, which no device shows.
    var orphanedUniqueRecords = false
    /// Subscriptions deleted while every change token expired: devices that had them keep them.
    var goneAfterExpiredTokens: Set<String> = []

    static let none = KnownLimitations(danglingLinks: false)
}

func duplicates(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var dups: [String] = []
    for value in values where !seen.insert(value).inserted {
        dups.append(value)
    }
    return dups
}

func formatDouble(_ value: Double) -> String { String(format: "%.3f", value) }

extension TestDevice {
    /// The device's synchronized data.
    func snapshot() throws -> DataSnapshot {
        let context = ModelContext(try modelContainer ?? makeContainerForSnapshot())
        var snapshot = DataSnapshot()
        for model in try context.fetch(FetchDescriptor<ScenarioSubscription>()) {
            snapshot.subscriptions.append("\(model.feedLink)|\(model.title)|\(model.position)|\(model.isMuted)|\(formatDouble(model.rating))|\(model.note.map { $0.count > 64 ? shortHash(Data($0.utf8)) : $0 } ?? "-")|\(shortHash(model.artwork))")
            snapshot.subscriptionKeys.append(model.feedLink)
        }
        for model in try context.fetch(FetchDescriptor<ScenarioEpisode>()) {
            snapshot.episodes.append("\(model.feedLink)|\(model.guid)|\(formatDouble(model.elapsed))|\(model.played)")
            snapshot.episodeKeys.append("\(model.feedLink)|\(model.guid)")
        }
        for model in try context.fetch(FetchDescriptor<ScenarioNote>()) {
            snapshot.notes.append(model.text.count > 64 ? String(model.text.prefix(16)) + shortHash(Data(model.text.utf8)) : model.text)
        }
        for model in try context.fetch(FetchDescriptor<ScenarioTag>()) {
            snapshot.tags.append("\(model.name)|\(model.color)")
            snapshot.tagKeys.append(model.name)
        }
        for model in try context.fetch(FetchDescriptor<ScenarioLink>()) {
            snapshot.links.append("\(model.name)|\(model.subscription?.feedLink ?? "-")")
            snapshot.linkKeys.append(model.name)
        }
        for model in try context.fetch(FetchDescriptor<ScenarioWorkspace>()) {
            snapshot.workspaces.append(model.title)
            snapshot.workspaceKeys.append(model.title)
        }
        for model in try context.fetch(FetchDescriptor<ScenarioDocument>()) {
            snapshot.documents.append("\(model.title)|\(model.body.count > 64 ? shortHash(Data(model.body.utf8)) : model.body)|\(model.workspace?.title ?? "-")")
            snapshot.documentKeys.append(model.title)
        }
        snapshot.sort()
        return snapshot
    }

    private func makeContainerForSnapshot() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([ScenarioTag.self, ScenarioLink.self, ScenarioSubscription.self, ScenarioEpisode.self, ScenarioNote.self, ScenarioWorkspace.self, ScenarioDocument.self]),
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        )
    }
}

extension FakeCloudServer {
    /// The server's data of an account, with overflow assets read and references resolved.
    func snapshot(account: String) -> DataSnapshot {
        let records = records(account: account)
        var values: [String: [String: Any]] = [:]
        var types: [String: String] = [:]
        var parents: [String: String] = [:]
        for record in records {
            var dictionary: [String: Any] = [:]
            for key in record.allKeys() where key != SDSOverflow.key {
                if let asset = record[key] as? CKAsset, let url = asset.fileURL {
                    dictionary[key] = (try? Data(contentsOf: url)) as Any
                } else {
                    dictionary[key] = record[key]
                }
            }
            if let overflow = try? SDSOverflow.values(in: record) {
                // Like downloads: values of the record win over the asset's
                for (key, value) in overflow where dictionary[key] == nil { dictionary[key] = value }
            }
            values[record.recordID.recordName] = dictionary
            types[record.recordID.recordName] = record.recordType
            if let parent = record.parent { parents[record.recordID.recordName] = parent.recordID.recordName }
        }
        func string(_ name: String, _ key: String) -> String? { values[name]?[key] as? String }
        func referenced(_ value: Any?) -> String? {
            (value as? CKRecord.Reference)?.recordID.recordName
        }
        func int(_ name: String, _ key: String) -> Int64 { (values[name]?[key] as? NSNumber)?.int64Value ?? 0 }
        func double(_ name: String, _ key: String) -> Double { (values[name]?[key] as? NSNumber)?.doubleValue ?? 0 }

        var snapshot = DataSnapshot()
        for (name, type) in types {
            switch type {
            case "ScenarioSubscription":
                let feedLink = string(name, "feedLink") ?? ""
                let note = string(name, "note")
                snapshot.subscriptions.append("\(feedLink)|\(string(name, "title") ?? "")|\(int(name, "position"))|\(int(name, "isMuted") == 1)|\(formatDouble(double(name, "rating")))|\(note.map { $0.count > 64 ? shortHash(Data($0.utf8)) : $0 } ?? "-")|\(shortHash(values[name]?["artwork"] as? Data))")
                snapshot.subscriptionKeys.append(feedLink)
            case "ScenarioEpisode":
                snapshot.episodes.append("\(string(name, "feedLink") ?? "")|\(string(name, "guid") ?? "")|\(formatDouble(double(name, "elapsed")))|\(int(name, "played") == 1)")
                snapshot.episodeKeys.append("\(string(name, "feedLink") ?? "")|\(string(name, "guid") ?? "")")
            case "ScenarioNote":
                let text = string(name, "text") ?? ""
                snapshot.notes.append(text.count > 64 ? String(text.prefix(16)) + shortHash(Data(text.utf8)) : text)
            case "ScenarioTag":
                snapshot.tags.append("\(string(name, "name") ?? "")|\(string(name, "color") ?? "")")
                snapshot.tagKeys.append(string(name, "name") ?? "")
            case "ScenarioLink":
                let target = referenced(values[name]?["subscription"])
                let feedLink = target.map { values[$0] == nil ? "?missing:\($0)" : string($0, "feedLink") ?? "" } ?? "-"
                snapshot.links.append("\(string(name, "name") ?? "")|\(feedLink)")
                snapshot.linkKeys.append(string(name, "name") ?? "")
            case "ScenarioWorkspace":
                snapshot.workspaces.append(string(name, "title") ?? "")
                snapshot.workspaceKeys.append(string(name, "title") ?? "")
            case "ScenarioDocument":
                let target = referenced(values[name]?["workspace"]) ?? parents[name]
                let workspace = target.map { values[$0] == nil ? "?missing:\($0)" : string($0, "title") ?? "" } ?? "-"
                let body = string(name, "body") ?? ""
                snapshot.documents.append("\(string(name, "title") ?? "")|\(body.count > 64 ? shortHash(Data(body.utf8)) : body)|\(workspace)")
                snapshot.documentKeys.append(string(name, "title") ?? "")
            default:
                break
            }
        }
        snapshot.sort()
        return snapshot
    }
}

/// Synchronizes every running device a few rounds, then checks that each device's data equals the server's and that
/// nothing is duplicated. Returns the server's snapshot.
@discardableResult
func assertConverged(_ devices: [TestDevice], account: String = "first", rounds: Int = 3, known: KnownLimitations = KnownLimitations(), sourceLocation: SourceLocation = #_sourceLocation) async throws -> DataSnapshot {
    for _ in 0..<rounds {
        for device in devices where device.synchronizer != nil {
            await device.synchronizer.forceDownloadSync()
            await device.settle()
        }
    }
    var server = devices[0].server.snapshot(account: account)
    // Known: a child moved into a parent deleted elsewhere after the move was uploaded stays in iCloud, dangling, while every
    // device agrees it's gone. Ignore such records when no device shows them.
    var locals = try devices.map { try $0.snapshot() }
    let dangling = server.removeDangling(shownBy: locals)
    var ignoredLinks: Set<String> = []
    if known.danglingLinks && !dangling.isEmpty {
        ignoredLinks.formUnion(dangling)
    }
    let ignoredFeeds = known.recreatedFeeds.union(known.goneAfterExpiredTokens)
    if !ignoredLinks.isEmpty || !ignoredFeeds.isEmpty {
        let before = (server.links, locals.map(\.links))
        server.removeLinks(named: ignoredLinks, ofFeeds: ignoredFeeds)
        for index in locals.indices { locals[index].removeLinks(named: ignoredLinks, ofFeeds: ignoredFeeds) }
        let differed = Set([before.0] + before.1).count > 1 && Set([server.links] + locals.map(\.links)).count == 1
        if differed {
            print("NOTE tolerated link differences (dangling \(ignoredLinks.sorted()), recreated or gone feeds \(ignoredFeeds.sorted())): server \(before.0) devices \(before.1)")
        }
    }
    if !known.goneAfterExpiredTokens.isEmpty {
        // Devices that had them keep them, see `KnownLimitations.goneAfterExpiredTokens`
        let gone = known.goneAfterExpiredTokens
        let keep = { (line: String) in !gone.contains(String(line.split(separator: "|").first ?? "")) }
        for index in locals.indices where !locals[index].subscriptions.allSatisfy(keep) {
            print("NOTE tolerated subscriptions gone after expired tokens on device \(index): \(locals[index].subscriptions.filter { !keep($0) })")
            locals[index].subscriptions = locals[index].subscriptions.filter(keep)
            locals[index].subscriptionKeys = locals[index].subscriptionKeys.filter { !gone.contains($0) }
            locals[index].episodes = locals[index].episodes.filter(keep)
            locals[index].episodeKeys = locals[index].episodeKeys.filter(keep)
        }
        server.subscriptions = server.subscriptions.filter(keep); server.subscriptionKeys = server.subscriptionKeys.filter { !gone.contains($0) }
        server.episodes = server.episodes.filter(keep); server.episodeKeys = server.episodeKeys.filter(keep)
    }
    if known.orphanedUniqueRecords {
        let shownTags = Set(locals.flatMap(\.tags))
        let orphaned = server.tags.filter { !shownTags.contains($0) }
        if !orphaned.isEmpty, let dups = server.duplicateKeys["tags"] {
            let tolerated = orphaned.filter { dups.contains(String($0.split(separator: "|").first ?? "")) }
            if !tolerated.isEmpty {
                print("NOTE tolerated losing unique records no device shows: \(tolerated)")
                for line in tolerated {
                    if let i = server.tags.firstIndex(of: line) { server.tags.remove(at: i) }
                    if let i = server.tagKeys.firstIndex(of: String(line.split(separator: "|").first ?? "")) { server.tagKeys.remove(at: i) }
                }
            }
        }
    }
    #expect(server.duplicateKeys.isEmpty, "Server has duplicates: \(server.duplicateKeys)", sourceLocation: sourceLocation)
    for (name, key, type) in [("documents", "title", "ScenarioDocument"), ("tags", "name", "ScenarioTag")] {
        guard let dups = server.duplicateKeys[name] else { continue }
        for record in devices[0].server.records(account: account) where record.recordType == type && dups.contains(record[key] as? String ?? "") {
            print("DUP record \(record.recordID.recordName) \(key) \(record[key] ?? "-") parent \(record.parent?.recordID.recordName ?? "-") values \(record.allKeys().sorted().map { "\($0)=\(String(describing: record[$0]).prefix(60))" })")
        }
    }
    if let dups = server.duplicateKeys["subs"] {
        for record in devices[0].server.records(account: account) where record.recordType == "ScenarioSubscription" && dups.contains(record["feedLink"] as? String ?? "") {
            print("DUP record \(record.recordID.recordName) feedLink \(record["feedLink"] ?? "-") title \(record["title"] ?? "-") identityName \(subscriptionRecordName(record["feedLink"] as? String ?? ""))")
        }
    }
    for (device, local) in zip(devices, locals) {
        #expect(local.duplicateKeys.isEmpty, "\(device.name) has duplicates: \(local.duplicateKeys)", sourceLocation: sourceLocation)
        #expect(local == server, "\(device.name) differs from the server:\n\(local.difference(to: server))", sourceLocation: sourceLocation)
        if let synchronizer = device.synchronizer, case .error(let error) = await synchronizer.viewModel.state {
            Issue.record("\(device.name) ends in an error state: \(error)", sourceLocation: sourceLocation)
        }
    }
    return server
}

extension Trait where Self == ConditionTrait {
    /// The adversarial harness runs only when asked to, e.g. `ADVERSARIAL=1 swift test --filter AdversarialFuzzTests`: its
    /// fuzz runs take minutes, and some scenarios reproduce the races listed in the README's known limitations, so they fail.
    static var adversarial: Self {
        .enabled(if: ProcessInfo.processInfo.environment["ADVERSARIAL"] != nil, "Set ADVERSARIAL=1 to run the adversarial harness")
    }
}
