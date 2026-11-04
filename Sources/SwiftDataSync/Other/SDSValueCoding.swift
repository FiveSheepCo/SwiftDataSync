import Foundation
import CoreData
import CloudKit
import OSLog

/// Converts the values of attributes to values records can store, and back.
///
/// Records store strings, numbers, dates, data, locations, assets, references and lists of these. Other values are converted,
/// e.g. UUIDs to strings, and values that can't be converted are left out of the record with a logged error, instead of crashing.
enum SDSValueCoding {

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SwiftDataSync", category: "SDSValueCoding")

    /// Thrown for a value that can't be converted. The key is left out, rather than storing a wrong value.
    struct UnsupportedValueError: Error, CustomStringConvertible {
        let description: String
    }

    /// The classes a `Codable` value stored as a composite attribute can consist of, see `cloudValue(for:attribute:)`.
    private static let compositeClasses: [AnyClass] = [
        NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSDate.self, NSData.self, NSUUID.self, NSURL.self, NSNull.self
    ]

    /// The value a record stores for an attribute's value.
    static func cloudValue(for value: Any, attribute: NSAttributeDescription?) throws -> CKRecordValue {
        if let attribute, let transformerName = attribute.valueTransformerName {
            let transformer = try self.transformer(named: transformerName)
            let transformed = isUnarchiving(transformer, name: transformerName) ? transformer.reverseTransformedValue(value) : transformer.transformedValue(value)
            guard let recordValue = transformed as? CKRecordValue else {
                throw UnsupportedValueError(description: "The value transformer `\(transformerName)` didn't return a value records can store")
            }
            return recordValue
        }
        if let recordValue = value as? CKRecordValue {
            return recordValue
        }
        if let uuid = value as? UUID {
            return uuid.uuidString as NSString
        }
        if let url = value as? URL {
            return url.absoluteString as NSString
        }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) {
            return data as NSData
        }
        // E.g. a `Codable` value with a date, which SwiftData stores as a composite attribute. Values that are valid JSON
        // are stored as such, like before, so devices with earlier versions can still read them.
        if attribute?.type == .composite, let dictionary = value as? NSDictionary {
            return try NSKeyedArchiver.archivedData(withRootObject: dictionary, requiringSecureCoding: true) as NSData
        }
        throw UnsupportedValueError(description: "`\(type(of: value))` isn't a value records can store")
    }

    /// The value of an attribute for the value a record stores, e.g. a UUID for a string. Other values are returned as they are.
    static func localValue(for value: Any?, attribute: NSAttributeDescription) throws -> Any? {
        switch value {
        case let data as Data where attribute.type != .binaryData:
            if let transformerName = attribute.valueTransformerName {
                let transformer = try self.transformer(named: transformerName)
                let value = isUnarchiving(transformer, name: transformerName) ? transformer.transformedValue(data) : transformer.reverseTransformedValue(data)
                // Rather than clearing the local value
                guard let value else {
                    throw UnsupportedValueError(description: "`\(transformerName)` can't read the data")
                }
                return value
            }
            if let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
            if attribute.type == .composite, let dictionary = try NSKeyedUnarchiver.unarchivedObject(ofClasses: compositeClasses, from: data) as? NSDictionary {
                return dictionary
            }
            throw UnsupportedValueError(description: "The data isn't JSON: \(String(data: data, encoding: .utf8) ?? "\(data.count) bytes")")
        case let string as String where attribute.type == .uri:
            guard let url = URL(string: string) else {
                throw UnsupportedValueError(description: "`\(string)` isn't a URL")
            }
            return url
        case let string as String where attribute.type == .uuid:
            guard let uuid = UUID(uuidString: string) else {
                throw UnsupportedValueError(description: "`\(string)` isn't a UUID")
            }
            return uuid
        default:
            return value
        }
    }

    /// `nil`, or empty relationships, for the synchronized keys a downloaded record leaves out, by record key.
    ///
    /// Records leave out keys without a value, so a missing key was cleared, e.g. on another device. Only optional keys are
    /// cleared, not `excludedKeys`, e.g. ones with local changes, and not the keys of a pending catch-up (`catchUpKeys`,
    /// as entity names or `Entity.key`), which records might leave out only because they were never uploaded.
    /// `presentKeys` are record keys that have values elsewhere, e.g. in the record's overflow asset (see `SDSOverflow`).
    static func clearedValues(
        of record: CKRecord,
        entity: NSEntityDescription,
        syncedKeys: [String],
        excludedKeys: Set<String>,
        catchUpKeys: Set<String>,
        presentKeys: Set<String> = []
    ) -> [String: Any?] {
        guard let entityName = entity.name, !catchUpKeys.contains(entityName) else { return [:] }

        let recordKeys = Set(record.allKeys()).union(presentKeys)
        var values: [String: Any?] = [:]
        for key in syncedKeys where !excludedKeys.contains(key) && !catchUpKeys.contains("\(entityName).\(key)") {
            guard let property = entity.propertiesByName[key], property.isOptional else { continue }
            let rawKey = property.renamingIdentifier ?? key
            guard !recordKeys.contains(rawKey), !recordKeys.contains(key) else { continue }

            if let relationship = property as? NSRelationshipDescription, relationship.isToMany {
                values[rawKey] = relationship.isOrdered ? NSOrderedSet() as Any : NSSet() as Any
            } else {
                values[rawKey] = .some(nil)
            }
        }
        return values
    }

    /// A transformer has to be registered by the app, also in its extensions.
    private static func transformer(named name: String) throws -> ValueTransformer {
        guard let transformer = ValueTransformer(forName: .init(name)) else {
            throw UnsupportedValueError(description: "The value transformer `\(name)` isn't registered")
        }
        return transformer
    }

    /// Unarchiving transformers turn data into values, the other way around than other transformers, so Core Data stores
    /// values with their `reverseTransformedValue`. SwiftData stores e.g. arrays with them.
    private static func isUnarchiving(_ transformer: ValueTransformer, name: String) -> Bool {
        transformer is NSSecureUnarchiveFromDataTransformer || ["NSKeyedUnarchiveFromData", "NSUnarchiveFromData"].contains(name)
    }
}

extension CKAsset {

    /// Where assets of uploaded records are written to. Their files are removed once they are uploaded, see `removeTemporaryFiles(of:)`.
    static var temporaryFilesDirectory: URL {
        URL.cachesDirectory.appending(component: "SwiftDataSync Assets", directoryHint: .isDirectory)
    }

    /// Writes the data to a file of its own, which is removed once the record was uploaded.
    convenience init(data: Data) throws {
        let directory = Self.temporaryFilesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appending(component: UUID().uuidString, directoryHint: .notDirectory)
        try data.write(to: tempURL)

        self.init(fileURL: tempURL)
    }

    /// Removes the files of the records' assets that `init(data:)` wrote, once the records were uploaded or failed to.
    /// Assets of other records, e.g. downloaded ones, are left alone.
    static func removeTemporaryFiles(of records: [CKRecord]) {
        let directory = temporaryFilesDirectory.standardizedFileURL.path
        for record in records {
            for key in record.allKeys() {
                guard
                    let fileURL = (record[key] as? CKAsset)?.fileURL,
                    fileURL.deletingLastPathComponent().standardizedFileURL.path == directory
                else { continue }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    /// Removes the files of earlier uploads that weren't removed, e.g. because the app was terminated while uploading.
    static func removeAllTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryFilesDirectory)
    }
}
