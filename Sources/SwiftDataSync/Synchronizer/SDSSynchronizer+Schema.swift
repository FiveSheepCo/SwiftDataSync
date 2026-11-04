import Foundation
import CoreData
import CloudKit

extension SDSSynchronizer {

    /// Whether the private database was downloaded completely at least once with the current iCloud account.
    ///
    /// It's `false` on a device that never synchronized, e.g. right after installing the app on a new device, and again after
    /// switching to another iCloud account, until that account's data was downloaded, and while every record is downloaded
    /// again after the store's objects vanished, e.g. as it was lost or rebuilt. Apps can use it to tell missing data
    /// from data that isn't there yet, e.g. before deciding that something was deleted on another device, or to show that
    /// the user's data is still being restored. It stays `true` across launches. It can be read from any thread.
    public var hasDownloadedOnce: Bool {
        hasDownloadedOnceFlag
    }

    /// The zone `initializeSchema()` saves its records in, so other devices never download them.
    private static let schemaZoneName = "SDSSchemaInitialization"

    /// Creates every record type and field the configuration synchronizes in the development environment, like
    /// `NSPersistentCloudKitContainer.initializeCloudKitSchema`, so the whole schema can be deployed to production.
    ///
    /// Production rejects record types and fields it doesn't have, and the development environment only has the ones that
    /// development builds happened to save, e.g. not a field whose value was always empty, or the overflow asset of large
    /// values (see `SDSOverflow`). This saves a record of every synchronized entity, with every synchronized field set to a
    /// value of its type, in a zone of its own, and deletes the zone again. Other devices never see the records.
    ///
    /// Call it from development builds, e.g. behind `#if DEBUG`, once `setup` found the store and the user is signed into
    /// iCloud, and deploy the schema in the CloudKit Console afterwards. It fails in production, which rejects new fields.
    public func initializeSchema() async throws {
        guard let configuration, let model = observedStore?.managedObjectModel, let cloud else {
            throw SDSSyncError(title: "error.noObservedContext")
        }
        let database = cloud.privateDatabase
        let zoneID = CKRecordZone.ID(zoneName: Self.schemaZoneName)

        try await modifyZones(save: [CKRecordZone(zoneID: zoneID)], delete: [], in: database)

        // Referenced records come first, so references and parents find their records
        let entities = configuration.entities.sorted { ($0.value.referenceDepth, $0.key) < ($1.value.referenceDepth, $1.key) }
        let recordIDs = Dictionary(uniqueKeysWithValues: entities.map { name, _ in
            (name, CKRecord.ID(recordName: "SDSSchemaSample.\(name)", zoneID: zoneID))
        })

        // Parents get records of their own, without values, saved first: a record can't be its own parent, e.g. of an entity
        // whose parent is of the same entity, and a parent has to exist before the record that references it
        let parentEntityNames = Set(entities.compactMap { name, entity in
            entity.parentKey.flatMap { (model.entitiesByName[name]?.relationshipsByName[$0]?.destinationEntity?.name) }
        })
        let parentRecordIDs = Dictionary(uniqueKeysWithValues: parentEntityNames.sorted().map { name in
            (name, CKRecord.ID(recordName: "SDSSchemaSample.\(name).Parent", zoneID: zoneID))
        })
        var records: [CKRecord] = parentRecordIDs.sorted { $0.key < $1.key }.map { name, recordID in
            CKRecord(recordType: name, recordID: recordID)
        }
        for (entityName, entity) in entities {
            guard let description = model.entitiesByName[entityName], let recordID = recordIDs[entityName] else { continue }
            let record = CKRecord(recordType: entityName, recordID: recordID)

            for key in entity.syncedProperties {
                guard let property = description.propertiesByName[key] else { continue }
                let recordKey = property.renamingIdentifier ?? key

                if let attribute = property as? NSAttributeDescription {
                    record[recordKey] = try Self.sampleValue(for: attribute, isAsset: entity.assetProperties.contains(key))
                } else if
                    let relationship = property as? NSRelationshipDescription,
                    let destination = relationship.destinationEntity?.name,
                    let destinationID = recordIDs[destination]
                {
                    let targetID = key == entity.parentKey ? parentRecordIDs[destination] ?? destinationID : destinationID
                    let reference = CKRecord.Reference(recordID: targetID, action: .none)
                    if !relationship.isToMany {
                        record[recordKey] = reference
                    } else if relationship.isOrdered {
                        record[recordKey] = [reference] as CKRecordValue
                    }
                    if key == entity.parentKey {
                        record.setParent(targetID)
                        record[Constants.parentWorkaroundKey] = CKRecord.Reference(recordID: targetID, action: .deleteSelf)
                    }
                }
            }
            if !SDSOverflow.keys(of: entity, description: description).isEmpty {
                record[SDSOverflow.key] = try SDSOverflow.asset(for: [:])
            }
            records.append(record)
        }

        do {
            for start in stride(from: 0, to: records.count, by: CKModifyRecordsOperation.maximumRecords) {
                let batch = Array(records[start ..< min(start + CKModifyRecordsOperation.maximumRecords, records.count)])
                try await saveSampleRecords(batch, in: database)
            }
        } catch {
            CKAsset.removeTemporaryFiles(of: records)
            try? await modifyZones(save: [], delete: [zoneID], in: database)
            throw error
        }
        CKAsset.removeTemporaryFiles(of: records)

        // Deleting the zone deletes the records, while the schema keeps their types and fields
        try await modifyZones(save: [], delete: [zoneID], in: database)
        logger.log("Initialized the schema of \(records.count) record types")
    }

    /// A value of the attribute's type, as uploads store it, see `SDSValueCoding`.
    private static func sampleValue(for attribute: NSAttributeDescription, isAsset: Bool) throws -> CKRecordValue? {
        switch attribute.type {
        case .string: "SDSSchemaSample" as NSString
        case .integer16, .integer32, .integer64, .boolean: 1 as Int64 as NSNumber
        case .double, .float, .decimal: 1.5 as NSNumber
        case .date: Date(timeIntervalSince1970: 0) as NSDate
        case .binaryData: isAsset ? try CKAsset(data: Data([0])) : Data([0]) as NSData
        case .uuid: UUID().uuidString as NSString
        case .uri: "https://example.com" as NSString
        // Transformed and `Codable` values are stored as data
        case .transformable, .composite: Data([0]) as NSData
        default: nil
        }
    }

    private func saveSampleRecords(_ records: [CKRecord], in database: any SDSCloudDatabase) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .allKeys
            operation.isAtomic = true
            operation.modifyRecordsResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(operation)
        }
    }

    private func modifyZones(save: [CKRecordZone], delete: [CKRecordZone.ID], in database: any SDSCloudDatabase) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: save, recordZoneIDsToDelete: delete)
            operation.modifyRecordZonesResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(operation)
        }
    }
}
