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
/// Uploads only send the values that changed, which they place on top of the record in iCloud, see `place(changedKeys:…)`:
/// the asset of a record is made from the server's, so another device's values in it are kept, rather than overwritten with
/// this device's, which can be older. Values that didn't change stay where they are. Changed values go into the asset if
/// they're large, or don't fit next to the values that stay in the record. Production schemas reject fields they don't
/// have, so only records that need the field or had it get it.
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

    /// Places the changed values that can be large, which are in their fields, into the record's fields or its asset, and
    /// returns the record keys in the asset. Values that didn't change stay where they are: in the asset if it has them, and
    /// in their fields otherwise. Changed values go into the asset if they're large on their own, or, largest first, until
    /// the values in the fields fit. Throws if the record's asset can't be read, or the new one can't be written.
    /// - Parameters:
    ///   - largeKeys: The record keys of the entity whose values can be large, see `keys(of:description:)`.
    ///   - hasServerValues: Whether the record is the one in iCloud, with its values and asset, and this device's changes.
    ///     Otherwise it only has the changes, e.g. as it doesn't exist yet.
    static func place(changedKeys: Set<String>, largeKeys: Set<String>, in record: CKRecord, hasServerValues: Bool) throws -> Set<String> {
        let previous = hasServerValues ? (try values(in: record) ?? [:]).compactMapValues { $0 as? CKRecordValue } : [:]
        var assetValues = previous.filter { !changedKeys.contains($0.key) }

        let sizes = Dictionary(changedKeys.map { ($0, size(of: record[$0])) }, uniquingKeysWith: { $1 })
        var overflowing = Set(sizes.filter { $0.value >= largeValueSize }.keys)
        // What stays in the fields: the values that didn't change and aren't in the asset, and the changed ones that fit
        var remaining = largeKeys.subtracting(changedKeys).filter { assetValues[$0] == nil }.reduce(0) { $0 + size(of: record[$1]) }
            + sizes.filter { !overflowing.contains($0.key) }.reduce(0) { $0 + $1.value }
        for (key, size) in sizes.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) where remaining > recordBudget && !overflowing.contains(key) {
            overflowing.insert(key)
            remaining -= size
        }
        for key in overflowing {
            assetValues[key] = record[key]
            record[key] = nil
        }

        if Set(assetValues.keys) != Set(previous.keys) || !overflowing.isEmpty || !changedKeys.isDisjoint(with: previous.keys) {
            record[Self.key] = assetValues.isEmpty ? nil : try asset(for: assetValues)
        }
        return Set(assetValues.keys)
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
