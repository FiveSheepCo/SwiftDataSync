import Foundation
import Combine
import CoreData

import Combine

/// A publisher for properties marked with the `@Published` attribute.
public struct PublishablePublisher<Value>: Combine.Publisher {
    public typealias Output = Value
    public typealias Failure = Never
    
    public let subject: Combine.CurrentValueSubject<Value, Never>
    
    public init(_ output: Output) {
        subject = .init(output)
    }
    
    public func receive<Downstream: Subscriber>(subscriber: Downstream)
    where Downstream.Input == Value, Downstream.Failure == Never
    {
        subject.subscribe(subscriber)
    }
}

@propertyWrapper
public struct NSCodableManagedStorage<Value, Enclosing>: Publishable where Value: NSObject, Value: NSCoding {
    private let keyPath: ReferenceWritableKeyPath<Enclosing, Data?>
    private var wasFetched: Bool = false
    private var value: Value?
    
    public init(wrappedValue: Value?, keyPath: ReferenceWritableKeyPath<Enclosing, Data?>) {
        self.keyPath = keyPath
        self.value = wrappedValue
    }
    
    public var wrappedValue: Value? {
        get { fatalError() }
        set { fatalError() }
    }
    
    // MARK: - Publishable
    
    public var publisher: PublishablePublisher<Value?>?
    
    public var objectWillChange: ObservableObjectPublisher?
    
    public static subscript<EnclosingSelf: NSManagedObject>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value?>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, NSCodableManagedStorage<Value, Enclosing>>
    ) -> Value? {
        get {
            let enclosing = object as! Enclosing
            let keyPath = object[keyPath: storageKeyPath].keyPath
            
            if !object[keyPath: storageKeyPath].wasFetched,
               let data = enclosing[keyPath: keyPath],
               let value = try? NSKeyedUnarchiver.unarchivedObject(ofClass: Value.self, from: data) {
                object[keyPath: storageKeyPath].value = value
            }
            object[keyPath: storageKeyPath].wasFetched = true
            return object[keyPath: storageKeyPath].value
        }
        set {
            let enclosing = object as! Enclosing
            let keyPath = object[keyPath: storageKeyPath].keyPath
            
            object.objectWillChange.send()
            object[keyPath: storageKeyPath].objectWillChange?.send()
            object[keyPath: storageKeyPath].publisher?.subject.send(newValue)
            
            object[keyPath: storageKeyPath].value = newValue
            
            if let newValue = newValue,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: false) {
                enclosing[keyPath: keyPath] = data
            } else {
                enclosing[keyPath: keyPath] = nil
            }
        }
    }
}

public protocol Publishable {
    associatedtype Value
    
    var wrappedValue: Value { get set }
    var publisher: PublishablePublisher<Value>? { get set }
    var objectWillChange: ObservableObjectPublisher? { get set }
}

public extension Publishable {
    
    /// The property that can be accessed with the `$` syntax and allows access to
    /// the `Publisher`
    var projectedValue: PublishablePublisher<Value> {
        mutating get {
            if let publisher = publisher {
                return publisher
            }
            let publisher = PublishablePublisher(wrappedValue)
            self.publisher = publisher
            return publisher
        }
    }
    
    static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Self>
    ) -> Value {
        get {
            return object[keyPath: storageKeyPath].wrappedValue
        }
        set {
            (object.objectWillChange as! ObservableObjectPublisher).send()
            object[keyPath: storageKeyPath].objectWillChange?.send()
            object[keyPath: storageKeyPath].publisher?.subject.send(newValue)
            object[keyPath: storageKeyPath].wrappedValue = newValue
        }
    }
}
