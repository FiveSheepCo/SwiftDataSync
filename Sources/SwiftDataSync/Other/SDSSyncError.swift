import Foundation
import SwiftUI

public struct SDSSyncError: Error, Sendable {
    public let title: String
    public let message: String?
    
    init(
        title: LocalizedStringResource,
        message: LocalizedStringResource? = nil
    ) {
        self.title = String(localized: title)
        self.message = message.map { String(localized: $0) }
    }
}
