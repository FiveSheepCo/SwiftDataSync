import Foundation
import CoreData
import SwiftData
import Testing
@testable import SwiftDataSync

@Model
final class TestModel {
    var name: String = ""
    
    init(name: String) {
        self.name = name
    }
}

/// The synchronizer finds models in the observed store by the URI of their identifier, which needs a store and no CloudKit.
@Suite
struct PersistentIdentifierTests {
    
    /// A model container and a coordinator on the same store, like the store the synchronizer observes.
    private struct Store {
        let modelContext: ModelContext
        let coordinator: NSPersistentStoreCoordinator
        
        init() throws {
            let url = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                .appending(path: "Test.store")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            let modelContainer = try ModelContainer(for: TestModel.self, configurations: ModelConfiguration(url: url))
            modelContext = ModelContext(modelContainer)
            modelContext.autosaveEnabled = false
            
            let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: [TestModel.self]))
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: url)
        }
    }
    
    /// Core Data raises an exception for the URI of an unsaved model, which would crash instead of failing this test.
    @Test func unsavedModelHasNoObjectID() throws {
        let store = try Store()
        let model = TestModel(name: "Unsaved")
        store.modelContext.insert(model)
        
        let implementation = try PersistentIdentifierRepresentation(model.persistentModelID).implementation
        #expect(implementation.isTemporary)
        #expect(implementation.objectID(in: store.coordinator) == nil)
    }
    
    @Test func savedModelHasObjectID() throws {
        let store = try Store()
        let model = TestModel(name: "Saved")
        store.modelContext.insert(model)
        try store.modelContext.save()
        
        let implementation = try PersistentIdentifierRepresentation(model.persistentModelID).implementation
        #expect(!implementation.isTemporary)
        let objectID = try #require(implementation.objectID(in: store.coordinator))
        #expect(objectID.entity.name == "TestModel")
        #expect(!objectID.isTemporaryID)
    }
}
