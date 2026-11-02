import Foundation
import CoreData
import Testing

/// Core Data's classes can deadlock when two threads use them for the first time at once: their `+initialize` methods
/// wait for each other, e.g. `NSManagedObjectID`'s and `NSPersistentStoreCoordinator`'s. Tests run in parallel, so every
/// suite waits until one thread has set them up. Apps don't need this, they use Core Data on one thread first.
struct CoreDataReady: SuiteTrait, TestScoping {
    private static let setUp: Void = {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
        _ = try? coordinator.addPersistentStore(type: .inMemory, at: URL(fileURLWithPath: "/dev/null"))
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        _ = coordinator.managedObjectID(forURIRepresentation: URL(string: "x-coredata://none/None/p1")!)
        for type in [NSManagedObjectID.self, NSManagedObject.self, NSEntityDescription.self, NSPersistentContainer.self, NSFetchRequest<NSManagedObject>.self] as [AnyClass] {
            _ = (type as AnyObject).description
        }
    }()

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        _ = Self.setUp
        try await function()
    }
}

extension Trait where Self == CoreDataReady {
    /// See `CoreDataReady`.
    static var coreDataReady: Self { Self() }
}
