import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// The scenarios of a fourth independent review of the natural keys and backfill.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct FourthIndependentReviewTests {

    /// A save of the app fails, e.g. with a merge conflict, and the app rolls back. The keys it was about to save aren't taken
    /// for local changes afterwards, which would keep later downloads from storing the values of other devices.
    @Test func failedSaveKeepsDownloadedValuesFromBeingStored() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        let b = TestDevice("B", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()
        try await b.launch()
        await b.sync()
        #expect(try b.subscription("s1")?.title == "Title of s1")

        // On A, a Core Data context (default merge policy: NSErrorMergePolicy) edits the title, while another save changes the row
        let coordinator = try #require(a.synchronizer.observedStore)
        let failing = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        failing.persistentStoreCoordinator = coordinator
        try failing.performAndWait {
            let object = try #require(try failing.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription")).first)
            object.setValue("Edit that is never saved", forKey: "title")
        }
        try a.editSubscription("s1") { $0.position = 7 }
        await a.sync()
        let saveFailed = failing.performAndWait { () -> Bool in
            do { try failing.save(); return false } catch { failing.rollback(); return true }
        }
        #expect(saveFailed)

        // B renames it later, A downloads it
        try b.editSubscription("s1") { $0.title = "Renamed on B" }
        await b.sync()
        #expect(b.serverSubscriptions().first?.title == "Renamed on B")
        await a.sync()
        await a.sync()

        #expect(try a.subscription("s1")?.title == "Renamed on B")
        #expect(a.serverSubscriptions().first?.title == "Renamed on B")
        a.terminate()
        b.terminate()
    }

    /// The app saves one context many times in a row. What's done once a save's keys are stored doesn't touch the keys of the
    /// next save of the same context, so every edit is uploaded.
    @Test func consecutiveSavesOfOneContextKeepTheirKeys() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch()
        let feedLinks = (0..<200).map { "s\($0)" }
        try a.insertSubscriptions(feedLinks)
        await a.sync()
        #expect(a.serverSubscriptions().count == 200)

        let coordinator = try #require(a.synchronizer.observedStore)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ScenarioSubscription"))
            for object in objects {
                object.setValue("Edited \(object.value(forKey: "feedLink") as! String)", forKey: "title")
                try context.save()
            }
        }
        await a.sync()
        await a.sync()

        let notUploaded = a.serverSubscriptions().filter { !$0.title.hasPrefix("Edited") }.map(\.feedLink)
        #expect(notUploaded.isEmpty, "\(notUploaded.count) edits weren't uploaded: \(notUploaded.prefix(10))")
        a.terminate()
    }

    /// The synchronizer's queue is busy, e.g. with a download, while the app saves a context twice. It becomes free while the
    /// second save runs, so what's done once the first save's keys are stored runs then. The second save's keys stay.
    @Test func secondSaveWhileTheFirstOneIsStoredIsUploaded() async throws {
        let server = FakeCloudServer()
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.insertSubscriptions(["s1"])
        await a.sync()

        let synchronizer = try #require(a.synchronizer)
        let syncContext = synchronizer.context
        let observedStore = synchronizer.observedStore
        let appContext = ModelContext(try #require(a.modelContainer))
        appContext.autosaveEnabled = false
        let model = try #require(try appContext.fetch(FetchDescriptor<ScenarioSubscription>()).first)

        let gate = DispatchSemaphore(value: 0)
        enqueue(on: syncContext) { gate.wait() }
        model.title = "First"
        try appContext.save()

        let isArmed = OSAllocatedUnfairLock(initialState: true)
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave, object: nil, queue: nil) { notification in
            guard
                let context = notification.object as? NSManagedObjectContext,
                context.persistentStoreCoordinator == observedStore,
                context !== synchronizer.observedUpdateContext,
                isArmed.withLock({ isArmed in defer { isArmed = false }; return isArmed })
            else { return }
            gate.signal()
            syncContext.performAndWait {}
        }
        model.position = 42
        try appContext.save()
        NotificationCenter.default.removeObserver(observer)

        await a.sync()
        await a.sync()
        #expect(a.serverSubscriptions().first?.title == "First")
        #expect(a.serverSubscriptions().first?.position == 42)
        a.terminate()
    }

    /// CloudKit keeps rejecting a document that moved to another workspace, e.g. in a share the user may only read. Deleting
    /// a subscription, which has nothing to do with it, is still uploaded. Only the previous workspace's removal would wait.
    @Test func rejectedMoveDoesNotHoldBackOtherRemovals() async throws {
        let server = FakeCloudServer()
        server.freshRecordsConflict = false
        let a = TestDevice("A", server: server)
        try await a.launch()
        try a.change { context in
            let workspace = ScenarioWorkspace(title: "W1")
            context.insert(workspace)
            let document = ScenarioDocument(title: "D")
            context.insert(document)
            document.workspace = workspace
            context.insert(ScenarioSubscription(feedLink: "unrelated"))
        }
        await a.sync()

        server.failSaving(where: { $0.recordName == documentRecordName("D") }, with: CKError(.permissionFailure))
        try a.change { context in
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            let new = ScenarioWorkspace(title: "W2")
            context.insert(new)
            document.workspace = new
        }
        await a.sync()
        try a.deleteSubscription("unrelated")
        await a.sync()
        await a.sync()
        #expect(a.serverSubscriptions().isEmpty)
        a.terminate()
    }
}

/// Runs a block on the context's queue without waiting for it.
private func enqueue(on context: NSManagedObjectContext, _ block: @escaping @Sendable () -> Void) {
    context.perform(block)
}
