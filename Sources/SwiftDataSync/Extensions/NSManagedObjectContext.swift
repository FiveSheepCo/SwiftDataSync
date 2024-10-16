import CoreData

extension NSManagedObjectContext {
    func performAndWaitThrowing<T>(block: () throws -> T) throws -> T {
        let result: Result<T, Error> = self.performAndWait({
            do {
                return .success(try block())
            }
            catch {
                return .failure(error)
            }
        })
        
        switch result {
            case .success(let value): return value
            case .failure(let error): throw error
        }
    }
}
