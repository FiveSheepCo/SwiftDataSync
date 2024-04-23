import CoreData

extension NSManagedObject {
    func delete() {
        self.managedObjectContext?.delete(self)
    }
    
    var synchronizableContainer: SDSSynchronizableContainer? {
        SDSSynchronizer.shared.container(for: self)
    }
}
