import CoreData

extension NSManagedObjectContext {
    
    /// All synchronization metadata entries of an entity with an `id` in `ids`. Has to be called on the context's queue.
    func metadataEntries(of entityName: String, withIds ids: [String]) -> [NSManagedObject] {
        guard !ids.isEmpty else { return [] }
        
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.sortDescriptors = []
        request.predicate = NSPredicate(format: "id IN %@", ids)
        return (try? fetch(request)) ?? []
    }
}
