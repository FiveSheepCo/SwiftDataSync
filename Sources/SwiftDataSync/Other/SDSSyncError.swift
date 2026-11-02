import Foundation
import SwiftUI

public struct SDSSyncError: LocalizedError, Sendable {
    public let title: String
    public let message: String?
    
    init(
        title: LocalizedStringResource,
        message: LocalizedStringResource? = nil
    ) {
        self.title = Self.localized(title)
        self.message = message.map(Self.localized)
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
