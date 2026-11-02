import Foundation
import CloudKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The calls the synchronizer makes to a CloudKit database. `CKDatabase` implements them, and tests replace it with a fake
/// server, so the upload and download code runs as it does with CloudKit.
protocol SDSCloudDatabase: AnyObject, Sendable {
    func add(_ operation: CKDatabaseOperation)
    func allRecordZones() async throws -> [CKRecordZone]
    func allSubscriptions() async throws -> [CKSubscription]
    func records(for ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
}

extension CKDatabase: SDSCloudDatabase {}

/// The calls the synchronizer makes to a CloudKit container, see `SDSCloudDatabase`.
protocol SDSCloudContainer: Sendable {
    var privateDatabase: any SDSCloudDatabase { get }
    var sharedDatabase: any SDSCloudDatabase { get }
    func accountStatus() async throws -> CKAccountStatus
    func userRecordID() async throws -> CKRecord.ID
    /// Runs an operation of the container, e.g. accepting shares.
    func add(_ operation: CKOperation)
    /// Database subscriptions only notify an app that registered for remote notifications.
    func registerForRemoteNotifications() async
    /// The CloudKit container, e.g. for a `UICloudSharingController`. `nil` for a fake.
    var ckContainer: CKContainer? { get }
}

/// The CloudKit container of an app.
struct SDSCloudKitContainer: SDSCloudContainer {
    let container: CKContainer

    init(identifier: String) {
        container = CKContainer(identifier: identifier)
    }

    var privateDatabase: any SDSCloudDatabase { container.privateCloudDatabase }
    var sharedDatabase: any SDSCloudDatabase { container.sharedCloudDatabase }
    var ckContainer: CKContainer? { container }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func userRecordID() async throws -> CKRecord.ID {
        try await container.userRecordID()
    }

    func add(_ operation: CKOperation) {
        container.add(operation)
    }

    func registerForRemoteNotifications() async {
        #if os(macOS)
        await NSApplication.shared.registerForRemoteNotifications()
        #else
        await UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
}
