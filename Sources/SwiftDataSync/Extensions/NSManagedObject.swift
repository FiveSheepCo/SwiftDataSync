import CoreData

extension NSManagedObject {
    func delete() {
        self.managedObjectContext?.delete(self)
    }
}
