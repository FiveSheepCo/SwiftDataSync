import Foundation
import CoreData
import CloudKit
import SwiftData
import Testing
import os
@testable import SwiftDataSync

/// The scenarios of a second independent review of the natural keys and backfill.
@Suite(.coreDataReady, .serialized, .timeLimit(.minutes(3)))
struct SecondIndependentReviewTests {

    /// The synchronization data couldn't be loaded, e.g. as it's corrupt, and the app resets it, the natural remedy. The reset
    /// fails rather than crashing the app.
    @Test func resetWithoutSyncDataThrows() async throws {
        let synchronizer = SDSSynchronizer(
            syncDataDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Sync"),
            viewModel: SDSSynchronizationViewModel(),
            makeCloudContainer: { _ in FakeCloudContainer(server: FakeCloudServer(), device: "A", account: .signedIn("first")) },
            monitorsNetwork: false
        )
        #expect(!synchronizer.isSyncDataLoaded)
        await #expect(throws: (any Error).self) {
            try await synchronizer.resetSyncData()
        }
    }
}
