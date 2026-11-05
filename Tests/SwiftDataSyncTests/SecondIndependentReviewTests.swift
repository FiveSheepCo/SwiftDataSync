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

    /// A document, which has a parent, is edited. Saving its record conflicts, as with `.changedKeys` for a record that exists,
    /// so the edit is saved over the server's record, which keeps its parent. The upload finishes.
    @Test func childEditAfterAConflictFinishes() async throws {
        let server = FakeCloudServer()
        let device = TestDevice("A", server: server)
        try await device.launch()
        try device.change { context in
            let workspace = ScenarioWorkspace(title: "W")
            context.insert(workspace)
            let document = ScenarioDocument(title: "D")
            context.insert(document)
            document.workspace = workspace
        }
        await device.sync()
        try device.change { context in
            let document = try #require(try context.fetch(FetchDescriptor<ScenarioDocument>()).first)
            document.body = "Edited"
        }
        await device.sync()

        #expect(await device.state.error == nil)
        #expect(server.record(named: documentRecordName("D"), account: "first")?["body"] as? String == "Edited")
        let pendingCount = device.synchronizer.context.performAndWait {
            (try? device.synchronizer.context.count(for: CloudKitUpdate.fetchRequest())) ?? -1
        }
        #expect(pendingCount == 0)
        device.terminate()
    }
}
