import Foundation
import CoreData
import CloudKit

/// Values too large for a record, which the record carries in one asset instead.
///
/// Records hold at most 1 MB, not counting assets. When a model's large values, e.g. long texts or data, would make its
/// record exceed that, or one of them is large on its own, they're put into the asset field `SDSOverflow` as a binary
/// property list of record key → value, and the record leaves out their keys. Downloads read the asset's values like the
/// record's own, so its keys aren't taken for cleared ones.
///
/// Which values overflow only depends on the model's current values, so every upload that includes a key that can be large
/// makes the same split again. Compared with the keys the record's asset has (see `SDSSynchronizer.overflowKeys(of:)`), it
/// only sends the keys that move into or out of the asset, and the asset if its keys or values changed, or clears it once
/// the values fit. Production schemas reject fields they don't have, so only records that need the field or had it get it.
enum SDSOverflow {
    static let key = "SDSOverflow"

    /// A value at least this large always goes into the asset.
    static let largeValueSize = 256 * 1024
    /// The large values that stay in the record take at most this much of its 1 MB, which leaves room for the other values.
    static let recordBudget = 700 * 1024

    /// Whether the attribute's values can be large: texts, data, and values stored as data. Assets of `assetProperties`
    /// are assets already, and identity values have to stay in the record, as downloads match models by them.
    static func canBeLarge(_ attribute: NSAttributeDescription) -> Bool {
        switch attribute.type {
        case .string, .binaryData, .transformable, .composite, .uri: true
        default: false
        }
    }

    /// The keys of an entity whose values can overflow.
    static func keys(of entity: SDSInternalConfiguration.Entity, description: NSEntityDescription) -> [String] {
        entity.syncedProperties.filter { key in
            guard let attribute = description.attributesByName[key] else { return false }
            return canBeLarge(attribute) && !entity.assetProperties.contains(key) && !entity.identity.contains(key)
        }.sorted()
    }

    /// The record keys whose values go into the asset, given the sizes of the values that can be large, by record key.
    ///
    /// Deterministic: values that are large on their own, then the largest ones (by key for the same size) until the rest fits.
    static func overflowingKeys(sizes: [String: Int]) -> Set<String> {
        var overflowing = Set(sizes.filter { $0.value >= largeValueSize }.keys)
        var remaining = sizes.filter { !overflowing.contains($0.key) }.reduce(0) { $0 + $1.value }
        for (key, size) in sizes.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) where remaining > recordBudget && !overflowing.contains(key) {
            overflowing.insert(key)
            remaining -= size
        }
        return overflowing
    }

    /// The size a value takes in a record.
    static func size(of value: CKRecordValue?) -> Int {
        switch value {
        case nil: 0
        case let string as String: string.utf8.count
        case let data as Data: data.count
        default: 16
        }
    }

    /// The asset with the values, written to a file that's removed once the record was uploaded.
    static func asset(for values: [String: CKRecordValue]) throws -> CKAsset {
        try CKAsset(data: PropertyListSerialization.data(fromPropertyList: values as NSDictionary, format: .binary, options: 0))
    }

    /// The values of a record's asset, by record key, or `nil` if it has none. Throws if the asset can't be read.
    static func values(in record: CKRecord) throws -> [String: Any]? {
        guard let asset = record[key] as? CKAsset else { return nil }
        guard let fileURL = asset.fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: fileURL)
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return values
    }
}

extension SDSSynchronizableContainer {

    /// Which of the keys that can be large stay in the record, and which go into the overflow asset, see `SDSOverflow`.
    struct OverflowSplit {
        /// The record's values of every key that can be large, by record key: `nil` for the ones in the asset.
        var fields: [String: CKRecordValue?]
        /// The values that go into the asset, by record key, `nil` if the record needs no asset.
        var overflow: [String: CKRecordValue]?
    }

    /// The split of the object's current values, which only depends on them. Throws like `changeDictionary(for:)`.
    func overflowSplit(keys: [String]) throws -> OverflowSplit {
        let values = try changeDictionary(for: keys)
        let overflowing = SDSOverflow.overflowingKeys(sizes: values.mapValues { SDSOverflow.size(of: $0) })
        var fields: [String: CKRecordValue?] = [:]
        var overflow: [String: CKRecordValue] = [:]
        for (key, value) in values {
            // `updateValue`, as assigning `nil` through the subscript would remove the key instead of clearing it
            if overflowing.contains(key), let value {
                overflow[key] = value
                fields.updateValue(nil, forKey: key)
            } else {
                fields.updateValue(value, forKey: key)
            }
        }
        return OverflowSplit(fields: fields, overflow: overflow.isEmpty ? nil : overflow)
    }
}
