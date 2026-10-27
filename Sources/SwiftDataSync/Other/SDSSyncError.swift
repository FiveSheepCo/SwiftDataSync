import Foundation
import SwiftUI

public struct SDSSyncError: Error, Sendable {
    public let title: String
    public let message: String?
    
    init(
        title: LocalizedStringResource,
        message: LocalizedStringResource? = nil
    ) {
        self.title = Self.localized(title)
        self.message = message.map(Self.localized)
    }
    
    /// The strings are in the package's bundle, whereas string literals refer to the app's.
    private static func localized(_ resource: LocalizedStringResource) -> String {
        Bundle.module.localizedString(forKey: resource.key, value: nil, table: resource.table)
    }
}
