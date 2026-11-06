import Foundation
import CoreData
import Testing
@testable import SwiftDataSync

private func reproNote(_ context: NSManagedObjectContext, prefix: String) -> NSManagedObject? {
    let request = NSFetchRequest<NSManagedObject>(entityName: "ScenarioNote")
    return (try? context.fetch(request))?.first { ($0.value(forKey: "text") as? String)?.hasPrefix(prefix) == true }
}

/// Saves the context again from an app's DidSave observer, registered before the synchronizer's, so it runs first. Each step
/// runs in the DidSave of the save before it, e.g. two observers that each react to the other's save.
private final class ReproNestedSaver: @unchecked Sendable {
    private let lock = NSLock()
    private var context: NSManagedObjectContext?
    private var steps: [(NSManagedObjectContext) -> Void] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { [weak self] notification in
            guard let self, let context = notification.object as? NSManagedObjectContext else { return }
            let step: ((NSManagedObjectContext) -> Void)? = lock.withLock {
                guard self.context === context, !steps.isEmpty else { return nil }
                return steps.removeFirst()
            }
            guard let step else { return }
            step(context)
            try? context.save()
        }
    }

    func arm(_ context: NSManagedObjectContext, steps: [(NSManagedObjectContext) -> Void]) {
        lock.withLock { self.context = context; self.steps = steps }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@Suite(.coreDataReady, .serialized)
struct NestedSaveTests {

    /// The app edits n1 and saves. In its DidSave, an observer that runs before the synchronizer's saves the context again,
    /// inserting n4, and in that save's DidSave, the context is saved once more (fuzz seeds 71027, 71031, 71035, 71036,
    /// 71037, 71001). Every save succeeds. The edit of n1 must be uploaded.
    ///
    /// The insert-only save has no updated or deleted objects, so `takeKeysBeingSaved(by:savedObjects:)` matches it to the
    /// innermost save's DidSave too; the insert-only save's own DidSave then finds no match and takes the newest entry, the
    /// outer save's, whose keys are dropped as n1 isn't among that notification's updated objects. The outer save's DidSave
    /// then finds nothing. `main` stored changes when they were made, so it uploads the edit.
    @Test(arguments: ["insert", "edit", "delete"])
    func insertOnlyNestedSaveFollowedByAnotherKeepsTheOuterSavesEdit(innermost: String) async throws {
        let saver = ReproNestedSaver()
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
            saver.arm(context, steps: [
                { context in NSEntityDescription.insertNewObject(forEntityName: "ScenarioNote", into: context).setValue("n4", forKey: "text") },
                { context in
                    switch innermost {
                    case "insert": NSEntityDescription.insertNewObject(forEntityName: "ScenarioNote", into: context).setValue("n5", forKey: "text")
                    case "edit": reproNote(context, prefix: "n2")?.setValue("n2 edited", forKey: "text")
                    default: if let n3 = reproNote(context, prefix: "n3") { context.delete(n3) }
                    }
                }
            ])
            reproNote(context, prefix: "n1")?.setValue("n1 edited", forKey: "text")
            try context.save()
        }
        await a.sync(); await a.sync(); await b.sync()
        let expected: [String] = switch innermost {
        case "insert": ["n1 edited", "n2", "n3", "n4", "n5"]
        case "edit": ["n1 edited", "n2 edited", "n3", "n4"]
        default: ["n1 edited", "n2", "n4"]
        }
        #expect(try a.notes() == expected, "local")
        #expect(a.serverNotes() == expected, "server \(a.serverNotes())")
        #expect(try b.notes() == expected, "B")
        a.terminate(); b.terminate()
    }
}
