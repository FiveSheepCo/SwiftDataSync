import Testing
@testable import SwiftDataSync

/// Errors are shown to users, so their titles must be the package's translated strings rather than their keys.
@Suite
struct SDSSyncErrorTests {

    @Test func titleIsLocalized() {
        #expect(SDSSyncError(title: "error.uploadIncomplete").title == "Some changes could not be uploaded")
        #expect(SDSSyncError(title: "share.error.notAccepted").title == "The share could not be accepted")
    }
}
