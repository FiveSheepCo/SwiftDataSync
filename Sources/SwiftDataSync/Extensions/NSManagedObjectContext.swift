import CoreData

extension NSManagedObjectContext {

    /// `performAndWait` for blocks that use managed objects or other values that aren't `Sendable`.
    ///
    /// The block runs before this returns, so nothing it captures is used concurrently by the caller.
    /// Core Data's rule still applies: managed objects may only be used on the queue of the context they belong to.
    func performAndWaitUnchecked<T>(_ block: () throws -> T) rethrows -> T {
        try withoutActuallyEscaping(block) { block in
            nonisolated(unsafe) let block = block
            return try performAndWait { try block() }
        }
    }
}
