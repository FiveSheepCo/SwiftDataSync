import Foundation
import SwiftUI

public struct SDSSyncError: LocalizedError, Sendable {
    public let title: String
    public let message: String?
    /// What caused it, if known, e.g. the error CloudKit rejected a record with. Its description is CloudKit's reason, like a
    /// record type that the production schema doesn't have.
    public let underlyingError: (any Error)?

    init(
        title: LocalizedStringResource,
        message: LocalizedStringResource? = nil,
        underlyingError: (any Error)? = nil
    ) {
        self.title = Self.localized(title)
        self.message = message.map(Self.localized)
        self.underlyingError = underlyingError
    }
    
    public var errorDescription: String? {
        title
    }
    
    public var failureReason: String? {
        message
    }
    
    /// The strings are in the package's bundle, whereas string literals refer to the app's.
    static func localized(_ resource: LocalizedStringResource) -> String {
        Bundle.module.localizedString(forKey: resource.key, value: nil, table: resource.table)
    }
}
