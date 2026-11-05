import Foundation
import CloudKit
import CryptoKit
import OSLog

/// Records a download couldn't store yet, kept in files next to the synchronization data, so the download's change token
/// can move past them.
///
/// E.g. a record whose reference wasn't downloaded yet, one that references a record that's gone, or one that can't be
/// stored as it is. Holding back the change token instead would keep every later record of a long download in memory, and
/// start it over if the app is terminated. Later downloads try them again, until they're stored, or their records change
/// or are deleted. Records that failed to download are kept by their IDs, and downloaded again.
///
/// Only used on the queue of a download's callbacks, one download at a time.
final class SDSHeldRecords {
    private let directory: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SwiftDataSync", category: "SDSHeldRecords")

    init(directory: URL) {
        self.directory = directory
    }

    private var failedIDsURL: URL {
        directory.appending(component: "failed.archive")
    }

    /// The file name of a record, as record names can contain any character.
    private func fileName(of recordID: CKRecord.ID) -> String {
        let digest = SHA256.hash(data: Data("\(recordID.zoneID.ownerName)/\(recordID.zoneID.zoneName)/\(recordID.recordName)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The held records, by name.
    func load() -> [CKRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "record" }.compactMap { url in
            do {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: Data(contentsOf: url))
            } catch {
                logger.error("Failed to read a held record, forgetting it: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
    }

    /// Keeps a record, with copies of its assets, whose downloaded files CloudKit removes.
    func hold(_ record: CKRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = fileName(of: record.recordID)
        let copy = record.copy() as! CKRecord
        for key in copy.allKeys() {
            guard let fileURL = (copy[key] as? CKAsset)?.fileURL else { continue }
            let assetURL = directory.appending(component: "\(name).\(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)).asset")
            if fileURL.standardizedFileURL != assetURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: assetURL)
                try FileManager.default.copyItem(at: fileURL, to: assetURL)
            }
            copy[key] = CKAsset(fileURL: assetURL)
        }
        let data = try NSKeyedArchiver.archivedData(withRootObject: copy, requiringSecureCoding: true)
        try data.write(to: directory.appending(component: "\(name).record"), options: .atomic)
    }

    /// Forgets a record, e.g. once it's stored, or a newer version of it arrived.
    func release(_ recordID: CKRecord.ID) {
        let name = fileName(of: recordID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(name + ".") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The IDs of records that failed to download, which are downloaded again.
    func loadFailedIDs() -> Set<CKRecord.ID> {
        guard
            let data = try? Data(contentsOf: failedIDsURL),
            let ids = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: CKRecord.ID.self, from: data)
        else { return [] }
        return Set(ids)
    }

    func storeFailedIDs(_ ids: Set<CKRecord.ID>) throws {
        guard !ids.isEmpty else {
            try? FileManager.default.removeItem(at: failedIDsURL)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try NSKeyedArchiver.archivedData(withRootObject: Array(ids) as NSArray, requiringSecureCoding: true).write(to: failedIDsURL, options: .atomic)
    }

    private var deferredDeletionsURL: URL {
        directory.appending(component: "deferred-deletions.archive")
    }

    /// The IDs of deleted records whose objects are deleted at the end of a zone's download, see
    /// `CKDownloadHandler.deferredDeletions`.
    func loadDeferredDeletions() -> Set<CKRecord.ID> {
        guard
            let data = try? Data(contentsOf: deferredDeletionsURL),
            let ids = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: CKRecord.ID.self, from: data)
        else { return [] }
        return Set(ids)
    }

    func storeDeferredDeletions(_ ids: Set<CKRecord.ID>) throws {
        guard !ids.isEmpty else {
            try? FileManager.default.removeItem(at: deferredDeletionsURL)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try NSKeyedArchiver.archivedData(withRootObject: Array(ids) as NSArray, requiringSecureCoding: true).write(to: deferredDeletionsURL, options: .atomic)
    }

    private var skippedIDsURL: URL {
        directory.appending(component: "skipped.archive")
    }

    /// The IDs of records an extension skipped, which the app downloads again, see `CKDownloadHandler.skippedRecordIDs`.
    func loadSkippedIDs() -> Set<CKRecord.ID> {
        guard
            let data = try? Data(contentsOf: skippedIDsURL),
            let ids = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: CKRecord.ID.self, from: data)
        else { return [] }
        return Set(ids)
    }

    func storeSkippedIDs(_ ids: Set<CKRecord.ID>) throws {
        guard !ids.isEmpty else {
            try? FileManager.default.removeItem(at: skippedIDsURL)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try NSKeyedArchiver.archivedData(withRootObject: Array(ids) as NSArray, requiringSecureCoding: true).write(to: skippedIDsURL, options: .atomic)
    }

    private var deletedNamesURL: URL {
        directory.appending(component: "deleted.archive")
    }

    /// How long the names of deleted records are kept, see `noteDeleted(_:)`.
    static let deletedNamesLifetime: TimeInterval = 90 * 24 * 60 * 60
    /// How many names of deleted records are kept at most, the newest ones.
    static let maximumDeletedNames = 20_000

    /// The names of records this device knows to be deleted, as it downloaded their deletions, or uploaded them, with when,
    /// see `CKDownloadHandler.resolveReferences(toDeleted:current:)`.
    func loadDeletedNames() -> [String: Date] {
        guard
            let data = try? Data(contentsOf: deletedNamesURL),
            let names = try? PropertyListDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return names
    }

    /// Remembers that records were deleted, and forgets the ones deleted long ago.
    func noteDeleted(_ names: [String], now: Date = .now) throws {
        guard !names.isEmpty else { return }
        var deleted = loadDeletedNames().filter { now.timeIntervalSince($0.value) < Self.deletedNamesLifetime }
        for name in names {
            deleted[name] = now
        }
        if deleted.count > Self.maximumDeletedNames {
            deleted = Dictionary(uniqueKeysWithValues: deleted.sorted { $0.value > $1.value }.prefix(Self.maximumDeletedNames).map { ($0.key, $0.value) })
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(deleted).write(to: deletedNamesURL, options: .atomic)
    }

    /// Forgets everything, e.g. after switching accounts.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
