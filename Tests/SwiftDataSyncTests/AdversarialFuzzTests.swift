import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// What the fuzz run did, to check what must have survived.
private final class FuzzLedger {
    var createdSubs: Set<String> = []
    var deletedSubs: Set<String> = []
    var subTitles: [String: Set<String>] = [:]
    var notes: [Int: (deleted: Bool, values: Set<String>)] = [:]
    var nextNote = 0
    var linkSubs: [String: Set<String>] = [:]
    var deletedLinks: Set<String> = []
    var tagsTouched: Set<String> = []
    var deletedTags: Set<String> = []
    var docWorkspaces: [String: Set<String>] = [:]
    var deletedDocs: Set<String> = []
    var deletedWorkspaces: Set<String> = []
    var log: [String] = []
    /// Whether a store was lost with changes that weren't uploaded, which are lost with it.
    var lostPendingChanges = false
    /// Subscriptions created again after they were deleted, see `KnownLimitations.recreatedFeeds`.
    var recreatedSubs: Set<String> = []
    /// Subscriptions deleted while every change token expired, see `KnownLimitations.goneAfterExpiredTokens`.
    var goneSubs: Set<String> = []

    func created(_ feed: String, title: String) {
        if deletedSubs.contains(feed) { recreatedSubs.insert(feed) }
        createdSubs.insert(feed)
        subTitles[feed, default: []].insert(title)
    }
}

/// Inserts that a download's page save raced, made from `beforeSavingDownloadedObjects`, by feed with their titles.
private final class RaceInserts: @unchecked Sendable {
    let lock = NSLock()
    var fired: [(String, String)] = []
}

/// Saves made from an app's observer of `NSManagedObjectContextDidSave`, registered before every synchronizer of the fuzz
/// run, so it runs before theirs. Each step runs in the DidSave of the save before it.
private final class FuzzNestedSaver: @unchecked Sendable {
    private let lock = NSLock()
    private var context: NSManagedObjectContext?
    private var steps: [(NSManagedObjectContext) -> Void] = []
    private var observer: NSObjectProtocol?
    var failures = 0
    var lastError = ""

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { [weak self] notification in
            guard let self, let context = notification.object as? NSManagedObjectContext else { return }
            let step: ((NSManagedObjectContext) -> Void)? = lock.withLock {
                guard self.context === context, !steps.isEmpty else { return nil }
                return steps.removeFirst()
            }
            guard let step else { return }
            step(context)
            do { try context.save() } catch { lock.withLock { failures += 1; lastError = "\(error)".prefix(160).description }; context.rollback() }
        }
    }

    func arm(_ context: NSManagedObjectContext?, steps: [(NSManagedObjectContext) -> Void]) {
        lock.withLock { self.context = context; self.steps = steps }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

struct FuzzOptions: Sendable, CustomTestStringConvertible {
    var seed: UInt64
    var steps = 120
    var concurrent = true
    var failures = true
    var kills = true
    var accountSwitches = false
    var storeLoss = false
    var pageSize = 6
    /// Round 6 operations: nested saves, iCloud full, identity moves, inserts racing downloads, and (opt-in) records gone
    /// after expired tokens and saves right after a download.
    var round6 = false
    var testDescription: String { "seed \(seed) concurrent \(concurrent) kills \(kills) accounts \(accountSwitches) storeLoss \(storeLoss)\(round6 ? " r6" : "")" }
}

@Suite(.coreDataReady, .adversarial, .serialized, .timeLimit(.minutes(10)))
struct AdversarialFuzzTests {

    static let sequential: [FuzzOptions] = (1...6).map { FuzzOptions(seed: $0, concurrent: false) }
    static let concurrent: [FuzzOptions] = (11...16).map { FuzzOptions(seed: $0, concurrent: true) }
    static let chaos: [FuzzOptions] = (21...24).map { FuzzOptions(seed: $0, concurrent: true, accountSwitches: true, storeLoss: true) }

    /// More seeds from the environment: FUZZ_START, FUZZ_COUNT, FUZZ_STEPS, FUZZ_MODE (sequential, concurrent or chaos).
    static let bulk: [FuzzOptions] = {
        let env = ProcessInfo.processInfo.environment
        let start = UInt64(env["FUZZ_START"] ?? "") ?? 100
        let count = UInt64(env["FUZZ_COUNT"] ?? "") ?? 0
        let steps = Int(env["FUZZ_STEPS"] ?? "") ?? 200
        let mode = env["FUZZ_MODE"] ?? "concurrent"
        let seeds: [UInt64] = env["FUZZ_SEEDS"].map { $0.split(separator: ",").compactMap { UInt64($0) } } ?? Array(start..<(start + count))
        guard !seeds.isEmpty else { return [] }
        return seeds.map { seed in
            FuzzOptions(seed: seed, steps: steps, concurrent: mode != "sequential", accountSwitches: mode == "chaos", storeLoss: mode == "chaos", round6: env["FUZZ_R6"] != "0")
        }
    }()
    @Test(arguments: bulk) func fuzzBulk(options: FuzzOptions) async throws { try await fuzz(options) }

    @Test(arguments: sequential) func fuzzSequential(options: FuzzOptions) async throws { try await fuzz(options) }
    @Test(arguments: concurrent) func fuzzConcurrent(options: FuzzOptions) async throws { try await fuzz(options) }
    @Test(arguments: chaos) func fuzzChaos(options: FuzzOptions) async throws { try await fuzz(options) }

    private let feeds = (0..<8).map { "f\($0)" }
    private let tagNames = ["red", "green", "blue", "gold"]
    private let workspaceTitles = ["w0", "w1", "w2"]
    private let docTitles = (0..<6).map { "d\($0)" }

    func fuzz(_ options: FuzzOptions) async throws {
        var rng = SplitMix64(seed: options.seed)
        let env = ProcessInfo.processInfo.environment
        // Registered before every synchronizer of this run, so it runs before theirs
        let nestedSaver = FuzzNestedSaver()
        let raceInserts = RaceInserts()
        let iCloudFull = OSAllocatedUnfairLock(initialState: false)
        let server = FakeCloudServer()
        server.failSaving(where: { _ in iCloudFull.withLock { $0 } }, with: CKError(.quotaExceeded))
        server.pageSize = options.pageSize
        server.cascadesDeleteSelf = true
        let devices = ["A", "B", "C"].map { TestDevice($0, server: server) }
        for device in devices {
            try await device.launch()
            if !options.concurrent { device.synchronizer.stop() }
        }
        let ledger = FuzzLedger()
        var running = Set(devices.map(\.name))
        var accountOf = Dictionary(uniqueKeysWithValues: devices.map { ($0.name, "first") })

        func syncSequential(_ device: TestDevice) async {
            device.synchronizer.start()
            await device.settle()
            await device.sync()
            device.synchronizer.stop()
            await device.settle()
        }

        func takeRaceInserts() {
            let fired = raceInserts.lock.withLock { defer { raceInserts.fired = [] }; return raceInserts.fired }
            for (feed, title) in fired {
                ledger.created(feed, title: title)
                ledger.log.append("   race insert of \(feed) fired")
            }
        }

        for step in 0..<options.steps {
            takeRaceInserts()
            let device = devices[Int.random(in: 0..<devices.count, using: &rng)]
            let tag = "\(device.name)\(step)"
            let isRunning = running.contains(device.name)
            let roll = Int.random(in: 0..<(options.round6 ? 113 : 100), using: &rng)
            if env["FUZZ_PRINT_STEPS"] != nil { print("STEP \(step) \(device.name) roll \(roll)") }
            do {
                if !isRunning {
                    ledger.log.append("\(step) \(device.name) relaunch")
                    try await device.launch(waitForSync: Bool.random(using: &rng))
                    if !options.concurrent { await device.settle(); device.synchronizer.stop() }
                    running.insert(device.name)
                    continue
                }
                switch roll {
                case 0..<10:
                    let feed = feeds.randomElement(using: &rng)!
                    ledger.log.append("\(step) \(device.name) insert sub \(feed)")
                    try device.change { context in
                        if try fetch(context, sub: feed) == nil {
                            context.insert(ScenarioSubscription(feedLink: feed, title: "t\(tag)", position: step))
                            ledger.created(feed, title: "t\(tag)")
                        }
                    }
                case 10..<25:
                    let feed = feeds.randomElement(using: &rng)!
                    let which = Int.random(in: 0..<5, using: &rng)
                    ledger.log.append("\(step) \(device.name) edit sub \(feed) \(which)")
                    try device.change { context in
                        guard let sub = try fetch(context, sub: feed) else { return }
                        switch which {
                        case 0: sub.title = "t\(tag)"; ledger.subTitles[feed, default: []].insert("t\(tag)")
                        case 1: sub.position = step
                        case 2: sub.isMuted.toggle(); sub.rating = Double(step)
                        case 3: sub.note = Bool.random() ? nil : (step % 5 == 0 ? String(repeating: "n", count: 300_000) + tag : "note \(tag)")
                        default: sub.artwork = step % 4 == 0 ? Data(repeating: UInt8(step % 256), count: 280_000) : (step % 4 == 1 ? nil : Data(tag.utf8))
                        }
                    }
                case 25..<30:
                    let feed = feeds.randomElement(using: &rng)!
                    ledger.log.append("\(step) \(device.name) delete sub \(feed)")
                    try device.change { context in
                        if let sub = try fetch(context, sub: feed) {
                            for link in sub.links ?? [] { ledger.deletedLinks.insert(link.name) }
                            context.delete(sub)
                            ledger.deletedSubs.insert(feed)
                        }
                    }
                case 30..<38:
                    ledger.nextNote += 1
                    let id = ledger.nextNote
                    ledger.log.append("\(step) \(device.name) insert note n\(id)")
                    try device.change { $0.insert(ScenarioNote(text: "n\(id):\(tag)")) }
                    ledger.notes[id] = (false, ["n\(id):\(tag)"])
                case 38..<46:
                    guard let id = ledger.notes.keys.sorted().randomElement(using: &rng) else { continue }
                    ledger.log.append("\(step) \(device.name) edit note n\(id)")
                    try device.change { context in
                        guard let note = try context.fetch(FetchDescriptor<ScenarioNote>()).first(where: { $0.text.hasPrefix("n\(id):") }) else { return }
                        note.text = "n\(id):\(tag)"
                        ledger.notes[id]?.values.insert("n\(id):\(tag)")
                    }
                case 46..<50:
                    guard let id = ledger.notes.keys.sorted().randomElement(using: &rng) else { continue }
                    ledger.log.append("\(step) \(device.name) delete note n\(id)")
                    try device.change { context in
                        for note in try context.fetch(FetchDescriptor<ScenarioNote>()) where note.text.hasPrefix("n\(id):") {
                            context.delete(note)
                            ledger.notes[id]?.deleted = true
                        }
                    }
                case 50..<56:
                    let name = "l\(Int.random(in: 0..<6, using: &rng))"
                    let feed = feeds.randomElement(using: &rng)!
                    ledger.log.append("\(step) \(device.name) put link \(name) in \(feed)")
                    try device.change { context in
                        guard let sub = try fetch(context, sub: feed) else { return }
                        if let link = try context.fetch(FetchDescriptor<ScenarioLink>(predicate: #Predicate { $0.name == name })).first {
                            link.subscription = sub
                        } else {
                            let link = ScenarioLink(name: name)
                            context.insert(link)
                            link.subscription = sub
                        }
                        ledger.linkSubs[name, default: []].insert(feed)
                    }
                case 56..<58:
                    let name = "l\(Int.random(in: 0..<6, using: &rng))"
                    ledger.log.append("\(step) \(device.name) delete link \(name)")
                    try device.change { context in
                        for link in try context.fetch(FetchDescriptor<ScenarioLink>(predicate: #Predicate { $0.name == name })) {
                            context.delete(link)
                            ledger.deletedLinks.insert(name)
                        }
                    }
                case 58..<63:
                    let name = tagNames.randomElement(using: &rng)!
                    let delete = Int.random(in: 0..<4, using: &rng) == 0
                    ledger.log.append("\(step) \(device.name) \(delete ? "delete" : "upsert") tag \(name)")
                    try device.change { context in
                        if delete {
                            for t in try context.fetch(FetchDescriptor<ScenarioTag>(predicate: #Predicate { $0.name == name })) {
                                context.delete(t)
                                ledger.deletedTags.insert(name)
                            }
                        } else {
                            // Inserting a model with a unique value that exists replaces it
                            context.insert(ScenarioTag(name: name, color: "c\(tag)"))
                            ledger.tagsTouched.insert(name)
                        }
                    }
                case 63..<70:
                    let title = docTitles.randomElement(using: &rng)!
                    let workspace = workspaceTitles.randomElement(using: &rng)!
                    let action = Int.random(in: 0..<4, using: &rng)
                    ledger.log.append("\(step) \(device.name) doc \(title) action \(action) \(workspace)")
                    let docName = SDSIdentity.recordName(entityName: "ScenarioDocument", values: [title])
                    let syncContext = device.synchronizer.context
                    let synchronizer = device.synchronizer!
                    let before = syncContext.performAndWait { (CloudKitLocalEntity.entry(forId: docName, in: syncContext)?.localId ?? "none", synchronizer.temporaryObject(for: docName) != nil) }
                    let hadDoc = (try? ModelContext(device.modelContainer!).fetch(FetchDescriptor<ScenarioDocument>(predicate: #Predicate { $0.title == title })).count) ?? -1
                    ledger.log.append("   \(device.name) \(title) before: local docs \(hadDoc), entity \(before.0.suffix(30)), reserved by download \(before.1)")
                    try device.change { context in
                        var w = try context.fetch(FetchDescriptor<ScenarioWorkspace>(predicate: #Predicate { $0.title == workspace })).first
                        let d = try context.fetch(FetchDescriptor<ScenarioDocument>(predicate: #Predicate { $0.title == title })).first
                        switch action {
                        case 0:
                            if w == nil { w = ScenarioWorkspace(title: workspace); context.insert(w!) }
                            if let d { d.workspace = w } else {
                                let new = ScenarioDocument(title: title)
                                new.body = "b\(tag)"
                                context.insert(new)
                                new.workspace = w
                            }
                            ledger.docWorkspaces[title, default: []].insert(workspace)
                        case 1:
                            d?.body = "b\(tag)"
                        case 2:
                            if let d { context.delete(d); ledger.deletedDocs.insert(title) }
                        default:
                            if let w {
                                for doc in w.documents ?? [] { ledger.deletedDocs.insert(doc.title) }
                                context.delete(w)
                                ledger.deletedWorkspaces.insert(workspace)
                            }
                        }
                    }
                case 70..<74:
                    let feed = feeds.randomElement(using: &rng)!
                    let guid = "g\(Int.random(in: 0..<3, using: &rng))"
                    ledger.log.append("\(step) \(device.name) episode \(feed) \(guid)")
                    try device.change { context in
                        if let e = try context.fetch(FetchDescriptor<ScenarioEpisode>(predicate: #Predicate { $0.feedLink == feed && $0.guid == guid })).first {
                            if step % 7 == 0 { context.delete(e) } else { e.elapsed = Double(step); e.played = step % 2 == 0 }
                        } else {
                            let e = ScenarioEpisode(feedLink: feed, guid: guid)
                            e.elapsed = Double(step)
                            context.insert(e)
                        }
                    }
                case 74..<86:
                    ledger.log.append("\(step) \(device.name) sync")
                    if options.concurrent { await device.sync() } else { await syncSequential(device) }
                case 86..<90:
                    guard options.failures else { continue }
                    let kind = Int.random(in: 0..<3, using: &rng)
                    ledger.log.append("\(step) \(device.name) inject failure \(kind) then sync")
                    switch kind {
                    case 0: server.failNextModify(with: CKError(.networkFailure))
                    case 1: server.failNextFetch(with: CKError(.serviceUnavailable))
                    default: server.failSaving(where: { _ in true }, with: CKError(.networkFailure), count: 1)
                    }
                    if options.concurrent { await device.sync() } else { await syncSequential(device) }
                case 90..<93:
                    guard options.kills else { continue }
                    let hang = Int.random(in: 0..<2, using: &rng) == 0
                    ledger.log.append("\(step) \(device.name) kill \(hang ? "mid-download" : "")")
                    if hang {
                        server.hangDownloadDevice = device.name
                        server.hangDownloadAfterPages = 1
                        if options.concurrent {
                            Task { await device.synchronizer.synchronize() }
                        } else {
                            device.synchronizer.start()
                        }
                        _ = await waitUntil(timeout: 2) { server.hangDownloadAfterPages == nil }
                        server.hangDownloadAfterPages = nil
                        server.hangDownloadDevice = nil
                    }
                    device.terminate()
                    running.remove(device.name)
                case 93..<95:
                    guard options.accountSwitches else { continue }
                    let target = accountOf[device.name] == "first" ? "second" : "first"
                    ledger.log.append("\(step) \(device.name) switch to \(target), notes \((try? device.notes()) ?? [])")
                    if !options.concurrent { device.synchronizer.start() }
                    device.switchAccount(to: .signedIn(target))
                    accountOf[device.name] = target
                    await device.settle()
                    if !options.concurrent { device.synchronizer.stop() }
                case 95..<97:
                    guard options.storeLoss else { continue }
                    ledger.log.append("\(step) \(device.name) store lost")
                    if options.concurrent { await device.sync() } else { await syncSequential(device) }
                    let pendingContext = device.synchronizer.context
                    let pending = pendingContext.performAndWait { (try? pendingContext.count(for: CloudKitUpdate.fetchRequest())) ?? -1 }
                    let localNotes = (try? device.notes()) ?? []
                    if pending != 0 { ledger.lostPendingChanges = true }
                    let state = await device.state
                    ledger.log.append("\(step) \(device.name) store lost with \(pending) pending updates, notes \(localNotes), account \(accountOf[device.name] ?? "-"), state \(state), recovering \(device.synchronizer.isRecoveringVanishedObjects), downloadedOnce \(device.synchronizer.hasDownloadedOnce), cloud account \(device.cloud.accountName ?? "-")")
                    device.terminate()
                    for suffix in ["", "-wal", "-shm"] {
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: device.storeURL.path + suffix))
                    }
                    try await device.launch()
                    if !options.concurrent { device.synchronizer.stop() }
                case 100..<103:
                    // Nested saves from the app's DidSave observer: an edit, then edits, an insert and a deletion nested
                    let ids = ledger.notes.filter { !$0.value.deleted }.keys.sorted()
                    guard ids.count >= 2, let coordinator = device.synchronizer.observedStore else { continue }
                    let outer = ids.randomElement(using: &rng)!
                    let failing = env["FUZZ_NESTED_FAIL"] != nil && Int.random(in: 0..<4, using: &rng) == 0
                    let depth = Int.random(in: 1...3, using: &rng)
                    var plan: [(kind: Int, id: Int)] = []
                    for _ in 0..<depth {
                        let kind = Int.random(in: 0..<3, using: &rng)
                        if kind == 1 { ledger.nextNote += 1; plan.append((1, ledger.nextNote)) } else { plan.append((kind, ids.randomElement(using: &rng)!)) }
                    }
                    if failing { plan.append((3, ids.randomElement(using: &rng)!)) }
                    ledger.log.append("\(step) \(device.name) nested saves: edit n\(outer), then \(plan.map { ["edit", "insert", "delete", "fail"][$0.kind] + " n\($0.id)" })")
                    let storedBefore = (try? device.notes()) ?? []
                    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                    context.persistentStoreCoordinator = coordinator
                    let noteText = { (context: NSManagedObjectContext, id: Int) -> NSManagedObject? in
                        try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioNote")).first { ($0.value(forKey: "text") as? String)?.hasPrefix("n\(id):") == true }
                    }
                    let steps: [(NSManagedObjectContext) -> Void] = plan.enumerated().map { index, item in
                        { context in
                            switch item.kind {
                            case 0: noteText(context, item.id)?.setValue("n\(item.id):\(tag)d\(index + 1)", forKey: "text")
                            case 1: NSEntityDescription.insertNewObject(forEntityName: "ScenarioNote", into: context).setValue("n\(item.id):\(tag)d\(index + 1)", forKey: "text")
                            case 2: if let note = noteText(context, item.id) { context.delete(note) }
                            default: noteText(context, item.id)?.setValue(nil, forKey: "text")
                            }
                        }
                    }
                    try context.performAndWait {
                        nestedSaver.arm(context, steps: steps)
                        noteText(context, outer)?.setValue("n\(outer):\(tag)d0", forKey: "text")
                        defer { nestedSaver.arm(nil, steps: []) }
                        try context.save()
                    }
                    if nestedSaver.failures > 0 {
                        ledger.log.append("   nested saves failed so far: \(nestedSaver.failures) (\(nestedSaver.lastError))")
                    }
                    // What was saved is what the store has now
                    let stored = (try? device.notes()) ?? []
                    for id in Set([outer] + plan.map(\.id)) {
                        let present = stored.filter { $0.hasPrefix("n\(id):") }
                        if present.isEmpty {
                            // Only a deletion of the plan; the device may not have downloaded the note yet
                            if ledger.notes[id] != nil && plan.contains(where: { $0.kind == 2 && $0.id == id }) && storedBefore.contains(where: { $0.hasPrefix("n\(id):") }) { ledger.notes[id]?.deleted = true }
                        } else {
                            for value in present {
                                if ledger.notes[id] == nil { ledger.notes[id] = (false, [value]) } else { ledger.notes[id]?.values.insert(value) }
                            }
                        }
                    }
                case 103..<105:
                    let isFull = iCloudFull.withLock { full in full.toggle(); return full }
                    ledger.log.append("\(step) iCloud \(isFull ? "full" : "has room again")")
                    if !isFull {
                        for other in devices where running.contains(other.name) {
                            other.synchronizer.resetQuarantine()
                            other.synchronizer.resumeUploads()
                        }
                    }
                case 105..<108:
                    // An identity move
                    let feed = feeds.randomElement(using: &rng)!
                    let target = feeds.randomElement(using: &rng)!
                    guard feed != target else { continue }
                    ledger.log.append("\(step) \(device.name) move sub \(feed) to \(target)")
                    try device.change { context in
                        guard let sub = try fetch(context, sub: feed), try fetch(context, sub: target) == nil else { return }
                        sub.feedLink = target
                        ledger.created(target, title: sub.title)
                        ledger.subTitles[target, default: []].formUnion(ledger.subTitles[feed] ?? [])
                        ledger.deletedSubs.insert(feed)
                        for link in sub.links ?? [] { ledger.linkSubs[link.name, default: []].insert(target) }
                    }
                case 108..<110:
                    // An insert that races a download of the same identity
                    let feed = feeds.randomElement(using: &rng)!
                    let title = "t\(tag)r"
                    let afterwards = env["FUZZ_RACEB"] != nil && Bool.random(using: &rng)
                    ledger.log.append("\(step) \(device.name) insert sub \(feed) racing a download\(afterwards ? ", saved after it" : "")")
                    let container = try #require(device.modelContainer)
                    if afterwards {
                        let context = ModelContext(container)
                        context.autosaveEnabled = false
                        let exists = try fetch(context, sub: feed) != nil
                        if !exists { context.insert(ScenarioSubscription(feedLink: feed, title: title, position: step)) }
                        if options.concurrent { await device.sync() } else { await syncSequential(device) }
                        if !exists {
                            try context.save()
                            ledger.created(feed, title: title)
                        }
                    } else {
                        let fired = OSAllocatedUnfairLock(initialState: false)
                        device.synchronizer.beforeSavingDownloadedObjects = { [raceInserts] in
                            guard fired.withLock({ f in defer { f = true }; return !f }) else { return }
                            let context = ModelContext(container)
                            context.autosaveEnabled = false
                            guard (try? context.fetch(FetchDescriptor<ScenarioSubscription>(predicate: #Predicate { $0.feedLink == feed })).first) == nil else { return }
                            context.insert(ScenarioSubscription(feedLink: feed, title: title, position: step))
                            if (try? context.save()) != nil {
                                raceInserts.lock.withLock { raceInserts.fired.append((feed, title)) }
                            }
                        }
                        if options.concurrent { await device.sync() } else { await syncSequential(device) }
                        device.synchronizer.beforeSavingDownloadedObjects = nil
                    }
                case 110..<112:
                    guard env["FUZZ_EXPIRE"] != nil else { continue }
                    // Deleted elsewhere while every change token expires, so no device downloads the deletion
                    let feed = feeds.randomElement(using: &rng)!
                    ledger.log.append("\(step) sub \(feed) gone while tokens expire")
                    server.deleteWhileTokensExpire([SDSIdentity.recordName(entityName: "ScenarioSubscription", values: [feed])], account: accountOf[device.name] ?? "first")
                    ledger.deletedSubs.insert(feed)
                    ledger.goneSubs.insert(feed)
                default:
                    try await Task.sleep(for: .milliseconds(Int.random(in: 0..<120, using: &rng)))
                }
            } catch {
                ledger.log.append("\(step) \(device.name) error \(error)")
            }
        }

        // Everything settles: every device is launched, signed into the first account and started
        server.hangDownloadAfterPages = nil
        server.fetchFailure = nil
        iCloudFull.withLock { $0 = false }
        takeRaceInserts()
        for device in devices {
            if !running.contains(device.name) {
                try await device.launch()
            }
            if accountOf[device.name] != "first" {
                device.switchAccount(to: .signedIn("first"))
                await device.settle()
            }
            device.synchronizer.beforeSavingDownloadedObjects = nil
            device.synchronizer.resetQuarantine()
            device.synchronizer.resumeUploads()
            device.synchronizer.start()
            await device.settle()
        }
        var known = KnownLimitations(recreatedFeeds: ledger.recreatedSubs, orphanedUniqueRecords: options.accountSwitches || options.storeLoss)
        known.goneAfterExpiredTokens = ledger.goneSubs
        let snapshot = try await assertConverged(devices, rounds: 4, known: known)
        takeRaceInserts()
        print("FUZZ \(options.testDescription): subs \(snapshot.subscriptions.count) notes \(snapshot.notes.count) links \(snapshot.links.count) tags \(snapshot.tags.count) docs \(snapshot.documents.count) episodes \(snapshot.episodes.count) ops \(ledger.log.count) deletedSubs \(ledger.deletedSubs.count) deletedNotes \(ledger.notes.values.filter(\.deleted).count)")
        if let dir = ProcessInfo.processInfo.environment["FUZZ_LOG_DIR"] {
            var text = ledger.log.joined(separator: "\n") + "\n\nSERVER\n\(snapshot)\n"
            for device in devices { text += "\n\(device.name)\n\((try? device.snapshot())?.description ?? "")\n" }
            let file = ProcessInfo.processInfo.environment["FUZZ_LOG_UNIQUE"] != nil ? "seed-\(options.seed)-\(UUID().uuidString.prefix(4)).txt" : "seed-\(options.seed).txt"
            try? text.write(toFile: "\(dir)/\(file)", atomically: true, encoding: .utf8)
            print("FUZZLOG \(file)")
        }
        let context = "seed \(options.seed)\n" + ledger.log.suffix(400).joined(separator: "\n")

        // Nothing that nobody deleted is lost
        for feed in ledger.createdSubs.subtracting(ledger.deletedSubs) {
            #expect(ledger.lostPendingChanges || snapshot.subscriptionKeys.contains(feed), "Subscription \(feed) was lost. \(context)")
        }
        for feed in snapshot.subscriptionKeys {
            #expect(ledger.createdSubs.contains(feed), "Unknown subscription \(feed): \(snapshot.subscriptions)")
            let title = snapshot.subscriptions.first { $0.hasPrefix("\(feed)|") }?.split(separator: "|")[1] ?? ""
            #expect(ledger.subTitles.values.contains { $0.contains(String(title)) }, "Subscription \(feed) has a title nobody wrote: \(title)")
        }
        for (id, note) in ledger.notes {
            let present = snapshot.notes.filter { $0.hasPrefix("n\(id):") }
            if !note.deleted {
                #expect(present.count == 1 || (ledger.lostPendingChanges && present.isEmpty), "Note n\(id) should exist once: \(present). \(context)")
            } else if !options.accountSwitches {
                #expect(present.isEmpty, "Deleted note n\(id) came back: \(present). \(context)")
            }
            for value in present {
                #expect(note.values.contains(value) || value.count > 64, "Note n\(id) has a value nobody wrote: \(value)")
            }
        }
        for (name, subs) in ledger.linkSubs where !ledger.deletedLinks.contains(name) && subs.isDisjoint(with: ledger.deletedSubs) {
            #expect(ledger.lostPendingChanges || snapshot.linkKeys.contains(name), "Link \(name) was lost. \(context)")
        }
        for title in Set(ledger.docWorkspaces.keys) where !ledger.deletedDocs.contains(title) && ledger.docWorkspaces[title]!.isDisjoint(with: ledger.deletedWorkspaces) {
            #expect(ledger.lostPendingChanges || snapshot.documentKeys.contains(title), "Document \(title) was lost. \(context)")
        }
        for name in ledger.tagsTouched.subtracting(ledger.deletedTags) {
            #expect(ledger.lostPendingChanges || snapshot.tagKeys.contains(name), "Tag \(name) was lost. \(context)")
        }
        #expect(!snapshot.subscriptionKeys.contains(""), "A subscription without identity values")
        #expect(!snapshot.episodeKeys.contains("|"), "An episode without identity values")
        #expect(!snapshot.documentKeys.contains(""), "A document without identity values")
        for device in devices { device.terminate() }
    }

    private func fetch(_ context: ModelContext, sub feed: String) throws -> ScenarioSubscription? {
        try context.fetch(FetchDescriptor<ScenarioSubscription>(predicate: #Predicate { $0.feedLink == feed })).first
    }
}
